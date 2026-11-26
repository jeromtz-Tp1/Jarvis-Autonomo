#!/usr/bin/env bash
# ojvoice.sh — Un turno de conversación por voz con JARVIS, 100 % local.
#   stdin : audio WAV del usuario (micrófono)      stdout: audio WAV de la respuesta
#   stderr: transcripción y respuesta en texto (para mostrarlas en pantalla)
# Modo texto (pruebas):  ojvoice.sh --text "pregunta"   -> stdout WAV, stderr texto
# Usa solo la API local http://127.0.0.1:8000 dentro de la distro (no requiere exponer puertos a Windows).
# Mantiene un historial corto de conversación; la memoria persistente la gestiona el servicio de memoria de OpenJarvis.
set -euo pipefail
API=${OJ_API:-http://127.0.0.1:8000}
MODEL=${OJ_MODEL:-$(sed -n 's/^default_model = "\(.*\)"/\1/p' "${OPENJARVIS_HOME:-$HOME/.openjarvis}/config.toml" 2>/dev/null | head -1)}
MODEL=${MODEL:-qwen3.5:2b}
VOICE=${OJ_VOICE:-ef_dora}
HIST="${OPENJARVIS_HOME:-$HOME/.openjarvis}/voice_history.jsonl"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say() { echo "$*" >&2; }

if [ "${1:-}" = "--text" ]; then user_text=$2
else
  cat > "$TMP/in.wav"
  [ -s "$TMP/in.wav" ] || { say "ERROR: no se recibió audio"; exit 2; }
  user_text=$(curl -sf -m 120 -F "file=@$TMP/in.wav;filename=in.wav" -F language=es "$API/v1/speech/transcribe" \
              | python3 -c "import sys,json; print(json.load(sys.stdin).get('text','').strip())")
fi
[ -n "$user_text" ] || { say "No entendí el audio (transcripción vacía)."; user_text="(silencio)"; }
say "TÚ: $user_text"

# Petición: instrucciones de estilo para voz + últimos 6 turnos + mensaje actual
python3 - "$HIST" "$MODEL" "$user_text" > "$TMP/req.json" <<'EOF'
import json, sys, os
hist, model, text = sys.argv[1], sys.argv[2], sys.argv[3]
msgs = [{"role": "system", "content": "Eres JARVIS, asistente personal de Jerónimo. Responde en español, breve (máximo 3 frases), en texto plano apto para ser leído en voz alta, sin markdown ni emojis."}]
if os.path.exists(hist):
    lines = open(hist, encoding="utf-8").read().splitlines()[-12:]
    msgs += [json.loads(l) for l in lines if l.strip()]
msgs.append({"role": "user", "content": text})
print(json.dumps({"model": model, "messages": msgs}))
EOF
answer=$(curl -sf -m 300 "$API/v1/chat/completions" -H 'Content-Type: application/json' --data-binary "@$TMP/req.json" \
         | python3 -c "import sys,json,re; t=json.load(sys.stdin)['choices'][0]['message']['content']; t=re.sub(r'[*#_\`>]+','',t); print(t.strip())")
say "JARVIS: $answer"
python3 - "$HIST" "$user_text" "$answer" <<'EOF'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({"role": "user", "content": sys.argv[2]}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"role": "assistant", "content": sys.argv[3]}, ensure_ascii=False) + "\n")
EOF
python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1][:1500], 'voice_id': sys.argv[2]}))" "$answer" "$VOICE" > "$TMP/tts.json"
curl -sf -m 300 "$API/v1/speech/synthesize" -H 'Content-Type: application/json' --data-binary "@$TMP/tts.json" -o "$TMP/out.wav"
cat "$TMP/out.wav"
