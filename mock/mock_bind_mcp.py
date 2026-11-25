#!/usr/bin/env python3
"""Servidor MCP SIMULADO, solo lectura, datos 100% ficticios (no toca BIND real).

Modos:
  stdio (por defecto): JSON-RPC delimitado por líneas en stdin/stdout.
  --http PORT [--oauth]: Streamable HTTP en 127.0.0.1. Con --oauth exige un
  Bearer emitido por un flujo OAuth y responde 401 + WWW-Authenticate
  (RFC 9728) como haría un servidor MCP con OAuth 2.1 + PKCE.
Cada llamada se registra en /opt/oj/mock/calls.log (evidencia).
"""
import json, sys, datetime, os

LOG = os.environ.get("MOCK_MCP_LOG", "/opt/oj/mock/calls.log")
CLIENTES = [
    {"cliente": "ACME FICTICIA SA", "saldo_mxn": 125000.50, "dias_vencido": 12},
    {"cliente": "LOGISTICA DEMO SC", "saldo_mxn": 48300.00, "dias_vencido": 45},
    {"cliente": "PRUEBAS XYZ SA", "saldo_mxn": 9100.75, "dias_vencido": 0},
]
TOOLS = [
    {"name": "cobranza_resumen", "description": "Devuelve el resumen SINTETICO de cuentas por cobrar (solo lectura).",
     "inputSchema": {"type": "object", "properties": {"min_dias": {"type": "integer", "description": "Filtra por días vencidos mínimos"}}}},
    {"name": "crear_factura", "description": "NO PERMITIDO: operación de escritura deshabilitada en el simulador.",
     "inputSchema": {"type": "object", "properties": {"monto": {"type": "number"}}}},
]

def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), **entry}, ensure_ascii=False) + "\n")

def handle(req):
    m, rid, p = req.get("method"), req.get("id"), req.get("params") or {}
    if m == "initialize":
        res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "mock-bind-readonly", "version": "0.1"}}
    elif m == "tools/list":
        res = {"tools": TOOLS}
    elif m == "tools/call":
        name, args = p.get("name"), p.get("arguments") or {}
        log({"tool": name, "args": args})
        if name == "cobranza_resumen":
            md = int(args.get("min_dias", 0) or 0)
            rows = [c for c in CLIENTES if c["dias_vencido"] >= md]
            total = round(sum(c["saldo_mxn"] for c in rows), 2)
            payload = {"fuente": "SIMULADOR (datos ficticios)", "total_mxn": total, "registros": rows}
            res = {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}], "isError": False}
        else:
            res = {"content": [{"type": "text", "text": "Rechazado: servidor de solo lectura."}], "isError": True}
    elif m and m.startswith("notifications/"):
        return None
    else:
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": rid, "result": res}

def stdio():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        resp = handle(json.loads(line))
        if resp is not None and "id" in resp and resp["id"] is not None:
            sys.stdout.write(json.dumps(resp) + "\n"); sys.stdout.flush()

def http(port, oauth):
    from http.server import BaseHTTPRequestHandler, HTTPServer
    VALID = "token-sintetico-obtenido-por-oauth"
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _json(self, code, obj, extra=None):
            b = json.dumps(obj).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json")
            for k, v in (extra or {}).items(): self.send_header(k, v)
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def do_GET(self):
            if self.path == "/.well-known/oauth-protected-resource":
                log({"http": "GET prm"})
                return self._json(200, {"resource": f"http://127.0.0.1:{port}/mcp", "authorization_servers": [f"http://127.0.0.1:{port}"]})
            if self.path == "/.well-known/oauth-authorization-server":
                log({"http": "GET as-metadata"})
                return self._json(200, {"issuer": f"http://127.0.0.1:{port}", "authorization_endpoint": f"http://127.0.0.1:{port}/authorize",
                    "token_endpoint": f"http://127.0.0.1:{port}/token", "code_challenge_methods_supported": ["S256"]})
            self._json(404, {})
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            auth = self.headers.get("Authorization", "")
            log({"http": "POST", "method": body.get("method"), "auth_header": "present" if auth else "absent"})
            if oauth and auth != f"Bearer {VALID}":
                return self._json(401, {"error": "invalid_token"}, {"WWW-Authenticate":
                    f'Bearer resource_metadata="http://127.0.0.1:{port}/.well-known/oauth-protected-resource"'})
            resp = handle(body)
            if resp is None:
                self.send_response(202); self.end_headers(); return
            self._json(200, resp, {"Mcp-Session-Id": "mock-session-1"})
    HTTPServer(("127.0.0.1", port), H).serve_forever()

if __name__ == "__main__":
    if "--http" in sys.argv:
        http(int(sys.argv[sys.argv.index("--http") + 1]), "--oauth" in sys.argv)
    else:
        stdio()
