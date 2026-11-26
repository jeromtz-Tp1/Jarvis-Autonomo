#!/usr/bin/env python3
"""ojbench.py — Banco de pruebas de latencia y calidad de JARVIS (Fase 2C). Solo lectura: no cambia configuración.

Mide por separado: STT, TTS, LLM crudo en Ollama (razonamiento on/off, hilos), LLM por el camino del servidor
(el que usa la voz) y voz de extremo a extremo. Evalúa calidad de cada modelo con preguntas verificables.
Uso: ojbench.py --label antes --models qwen3.5:2b,qwen3.5:4b --runs 3 --out res.json [--server-mode stream|agent]
     [--threads 4,6,8] [--skip-think] [--voice-cmd "/opt/oj/bin/ojvoice.sh"] [--fixture stt_es.wav]
"""
import argparse, io, json, os, statistics, subprocess, time, urllib.error, urllib.request, uuid, wave

p = argparse.ArgumentParser()
p.add_argument("--label", default="bench"); p.add_argument("--models", default="")
p.add_argument("--runs", type=int, default=3); p.add_argument("--out", required=True)
p.add_argument("--api", default="http://127.0.0.1:8000"); p.add_argument("--ollama", default="http://127.0.0.1:11434")
p.add_argument("--server-mode", default="agent", choices=["agent", "stream"])
p.add_argument("--threads", default=""); p.add_argument("--skip-think", action="store_true")
p.add_argument("--voice-cmd", default=""); p.add_argument("--fixture", default="")
p.add_argument("--num-ctx", type=int, default=0)
p.add_argument("--server-model", default="", help="modelo configurado en el servidor (el camino del servidor solo se mide con él para no forzar intercambios de modelo en Ollama)")
p.add_argument("--gap-s", type=float, default=8.0, help="pausa entre turnos (tiempo realista de escucha y habla del usuario; deja terminar la extracción de memoria)")
a = p.parse_args()
SYSTEM = ("Eres JARVIS, asistente personal de Jerónimo. Responde en español, en una o dos frases cortas, "
          "en texto plano apto para leerse en voz alta, sin markdown, listas ni emojis. No hagas preguntas de seguimiento.")
QUALITY = [  # (pregunta, palabras requeridas (alguna de cada grupo))
    ("¿Cuál es la capital de Francia?", [["parís", "paris"]]),
    ("¿Cuánto es 15 por 4?", [["60", "sesenta"]]),
    ("¿Qué día de la semana viene después del viernes?", [["sábado", "sabado"]]),
    ("¿Cuántas horas tiene un día?", [["24", "veinticuatro"]]),
    ("Traduce al inglés: buenos días.", [["good morning"]]),
    ("Responde sí o no: ¿el agua hierve a 100 grados al nivel del mar?", [["sí", "si"]]),
    ("¿Cuál es el planeta más grande del sistema solar?", [["júpiter", "jupiter"]]),
    ("Saluda brevemente a Jerónimo.", [["jerónimo", "jeronimo"]]),
]


def now():
    return time.monotonic()


def req(url, body=None, ctype="application/json", timeout=600, method=None):
    r = urllib.request.Request(url, data=body, method=method or ("POST" if body is not None else "GET"))
    if body is not None:
        r.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # noqa: BLE001
        return 0, str(e).encode()


def stats(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    xs = sorted(xs)
    return {"n": len(xs), "p50": round(statistics.median(xs)), "min": round(xs[0]), "max": round(xs[-1])}


def jpost(url, obj, timeout=600):
    return req(url, json.dumps(obj).encode(), timeout=timeout)


res = {"label": a.label, "fecha_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "server_mode": a.server_mode,
       "cpus": os.cpu_count(), "mem_mb": int(open("/proc/meminfo").read().split()[1]) // 1024, "errores": []}

# ---- STT
if a.fixture:
    audio = open(a.fixture, "rb").read()
    with wave.open(a.fixture) as w:
        res["stt_audio_s"] = round(w.getnframes() / w.getframerate(), 2)
    t_list, txt = [], ""
    for _ in range(a.runs + 1):  # la primera es calentamiento
        b = uuid.uuid4().hex
        body = (f'--{b}\r\nContent-Disposition: form-data; name="language"\r\n\r\nes\r\n--{b}\r\nContent-Disposition: form-data; '
                f'name="file"; filename="f.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode() + audio + f"\r\n--{b}--\r\n".encode()
        t = now(); c, d = req(a.api + "/v1/speech/transcribe", body, f"multipart/form-data; boundary={b}")
        t_list.append((now() - t) * 1000)
        if c != 200:
            res["errores"].append(f"STT HTTP {c}: {d[:200]!r}"); break
        txt = json.loads(d).get("text", "")
    res["stt_ms"] = stats(t_list[1:]); res["stt_texto"] = txt; res["stt_ok"] = "cobranza" in txt.lower()

# ---- TTS
t_list, dur = [], 0
for i in range(a.runs + 1):
    t = now(); c, d = jpost(a.api + "/v1/speech/synthesize", {"text": "Claro, Jerónimo. Mañana tienes dos reuniones por la mañana.", "voice_id": "ef_dora"})
    t_list.append((now() - t) * 1000)
    if c != 200 or d[:4] != b"RIFF":
        res["errores"].append(f"TTS HTTP {c}: {d[:200]!r}"); break
    with wave.open(io.BytesIO(d)) as w:
        dur = w.getnframes() / w.getframerate()
res["tts_ms"] = stats(t_list[1:]); res["tts_audio_s"] = round(dur, 2)

models = [m for m in a.models.split(",") if m]
res["modelos"] = {}
for m in models:
    R = res["modelos"][m] = {}
    opts = {"num_predict": 160, "temperature": 0.3}
    if a.num_ctx:
        opts["num_ctx"] = a.num_ctx
    base = {"model": m, "stream": False, "keep_alive": "30m",
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": "¿Cuál es la capital de Francia?"}]}
    # carga en frío / calentamiento
    t = now(); c, d = jpost(a.ollama + "/api/chat", dict(base, think=False, options=opts)); R["carga_ms"] = round((now() - t) * 1000)
    if c != 200:
        res["errores"].append(f"{m}: Ollama HTTP {c}: {d[:200]!r}"); continue

    def raw(think, extra=None):
        o = dict(opts, **(extra or {}))
        t = now(); c, d = jpost(a.ollama + "/api/chat", dict(base, think=think, options=o))
        wall = (now() - t) * 1000
        if c != 200:
            return {"error": f"HTTP {c}"}
        j = json.loads(d)
        ev, evd = j.get("eval_count", 0), j.get("eval_duration", 1)
        return {"wall_ms": round(wall), "tokens_salida": ev, "tokens_entrada": j.get("prompt_eval_count", 0),
                "tok_s_generacion": round(ev / (evd / 1e9), 1) if evd else None,
                "tok_s_prompt": round(j.get("prompt_eval_count", 0) / (j.get("prompt_eval_duration", 1) / 1e9), 1) if j.get("prompt_eval_duration") else None,
                "razonamiento_chars": len((j.get("message") or {}).get("thinking") or ""),
                "texto": (j.get("message") or {}).get("content", "")[:160]}
    runs = [raw(False) for _ in range(a.runs)]
    R["sin_razonamiento"] = {"wall_ms": stats([r.get("wall_ms") for r in runs]), "muestra": runs[-1]}
    if not a.skip_think:
        R["con_razonamiento"] = raw(True, {"num_predict": 1024})
    if a.threads:
        R["hilos"] = {}
        for th in [int(x) for x in a.threads.split(",")]:
            raw(False, {"num_thread": th})  # descartada: cambiar num_thread recarga el modelo en Ollama
            rr = [raw(False, {"num_thread": th}) for _ in range(max(1, a.runs - 1))]
            R["hilos"][str(th)] = {"wall_ms": stats([r.get("wall_ms") for r in rr]),
                                   "tok_s_generacion": rr[-1].get("tok_s_generacion"), "tok_s_prompt": rr[-1].get("tok_s_prompt")}
    # Calidad y latencia del MODELO (Ollama directo, sin razonamiento): comparable entre modelos
    q_ok, brevity, lat = 0, 0, []
    R["calidad_detalle"] = []
    for q, groups in QUALITY:
        body = {"model": m, "stream": False, "think": False, "keep_alive": "30m", "options": dict(opts),
                "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}]}
        t = now(); c, d = jpost(a.ollama + "/api/chat", body); lat.append((now() - t) * 1000)
        text = (json.loads(d).get("message") or {}).get("content", "") if c == 200 else ""
        if c != 200:
            res["errores"].append(f"{m} calidad HTTP {c}")
        tl = text.lower(); ok = all(any(w in tl for w in g) for g in groups); short_ok = len(text) <= 260
        q_ok += ok; brevity += short_ok
        R["calidad_detalle"].append({"pregunta": q, "ok": ok, "breve": short_ok, "ms": round(lat[-1]), "respuesta": text[:200]})
    R["modelo_ms"] = stats(lat)
    R["calidad"] = f"{q_ok}/{len(QUALITY)}"; R["calidad_pct"] = round(100 * q_ok / len(QUALITY)); R["brevedad"] = f"{brevity}/{len(QUALITY)}"

# ---- Camino REAL del servidor (el de la voz), solo con el modelo configurado y con pausas realistas
if a.server_model:
    jpost(a.ollama + "/api/generate", {"model": a.server_model, "prompt": "", "keep_alive": "30m"})  # precarga (descartada)
    lat, ttft = [], []
    marker = os.environ.get("OJ_MEMORY_DEFER_FILE")  # igual que ojvoice: difiere la extracción durante el turno
    for q, _ in QUALITY[: max(3, a.runs + 1)]:
        time.sleep(a.gap_s)
        if marker:
            open(marker, "w").close()
        body = {"model": a.server_model, "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}],
                "max_tokens": 160, "temperature": 0.3, "stream": a.server_mode == "stream"}
        t = now(); first = None
        if a.server_mode == "stream":
            r = urllib.request.Request(a.api + "/v1/chat/completions", data=json.dumps(body).encode(), method="POST")
            r.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(r, timeout=600) as resp:
                    for raw_line in resp:
                        ln = raw_line.decode("utf-8", "replace").strip()
                        if ln.startswith("data:") and ln[5:].strip() != "[DONE]":
                            dlt = json.loads(ln[5:])["choices"][0].get("delta", {}).get("content") or ""
                            if dlt and first is None:
                                first = (now() - t) * 1000
            except Exception as e:  # noqa: BLE001
                res["errores"].append(f"servidor stream: {e}")
        else:
            c, d = jpost(a.api + "/v1/chat/completions", body)
            if c != 200:
                res["errores"].append(f"servidor HTTP {c}: {d[:160]!r}")
        lat.append((now() - t) * 1000); ttft.append(first)
        if marker and os.path.exists(marker):
            os.remove(marker)
    res["servidor"] = {"modelo": a.server_model, "modo": a.server_mode, "pausa_s": a.gap_s, "ms": stats(lat), "primer_token_ms": stats(ttft)}

# ---- Voz extremo a extremo (comando real de la voz)
if a.voice_cmd and a.fixture:
    tot, first, details = [], [], []
    for _ in range(a.runs):
        time.sleep(a.gap_s)
        t = now()
        p2 = subprocess.run(a.voice_cmd.split(), stdin=open(a.fixture, "rb"), capture_output=True, timeout=600)
        wall = (now() - t) * 1000; err = p2.stderr.decode("utf-8", "replace")
        if p2.returncode != 0:
            res["errores"].append(f"voz exit {p2.returncode}: {err[-300:]}"); break
        tline = next((l for l in err.splitlines() if l.startswith("TIEMPOS:")), "")
        kv = dict(x.split("=", 1) for x in tline[8:].split() if "=" in x)
        tot.append(wall); first.append(int(kv["primera_voz_ms"]) if "primera_voz_ms" in kv else None)
        details.append(kv or {"nota": "sin desglose (versión anterior de ojvoice)"})
    res["voz_total_ms"] = stats(tot); res["voz_primera_voz_ms"] = stats(first); res["voz_desglose"] = details[-1] if details else {}

json.dump(res, open(a.out, "w"), ensure_ascii=False, indent=1)
print(json.dumps({k: res[k] for k in res if k not in ("modelos",)}, ensure_ascii=False))
for m, R in res.get("modelos", {}).items():
    print(m, json.dumps({k: R.get(k) for k in ("carga_ms", "modelo_ms", "calidad", "brevedad")}, ensure_ascii=False))
if "servidor" in res:
    print("servidor", json.dumps(res["servidor"], ensure_ascii=False))
