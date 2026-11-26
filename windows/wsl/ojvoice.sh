#!/usr/bin/env bash
# ojvoice.sh — Un turno de conversación por voz con JARVIS, 100 % local.
#   stdin : audio WAV del usuario     stdout: audio WAV de la respuesta
#   stderr: líneas "TÚ: …", "JARVIS: …" o "ERROR: …" (las muestra Talk-Jarvis.ps1)
# Modo texto:  ojvoice.sh --text "pregunta"
# Códigos de salida: 0 ok · 10 servidor caído · 11 fallo STT · 12 fallo inferencia · 13 fallo TTS · 2 sin audio
# Nunca oculta errores HTTP: muestra código y cuerpo de la respuesta del servidor.
set -uo pipefail
API=${OJ_API:-http://127.0.0.1:8000}
CFG="${OPENJARVIS_HOME:-$HOME/.openjarvis}/config.toml"
MODEL=${OJ_MODEL:-$(sed -n 's/^default_model = "\(.*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)}; MODEL=${MODEL:-qwen3.5:2b}
VOICE=${OJ_VOICE:-ef_dora}
HIST="${OPENJARVIS_HOME:-$HOME/.openjarvis}/voice_history.jsonl"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say() { echo "$*" >&2; }
die() { say "ERROR: $2"; exit "$1"; }
# http MÉTODO RUTA SALIDA [args curl]  -> código HTTP; deja el cuerpo en SALIDA
http() { local m=$1 p=$2 o=$3 c; shift 3; c=$(curl -s -m 300 -X "$m" -o "$o" -w '%{http_code}' "$@" "$API$p"); echo "${c:-000}"; }
body() { head -c 300 "$1" 2>/dev/null | tr -d '\0\n'; }
json_get() { python3 -c "import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print('JSON inválido: %s' % e, file=sys.stderr); sys.exit(1)
$2" "$1"; }

c=$(http GET /health "$TMP/h.json"); [ "$c" = 200 ] || die 10 "el servidor JARVIS no responde (HTTP $c). Ejecute Repair-OpenJarvisLab.ps1."

if [ "${1:-}" = "--text" ]; then user_text=${2:-}
else
  cat > "$TMP/in.wav"
  [ "$(stat -c %s "$TMP/in.wav")" -gt 1000 ] || die 2 "no se recibió audio del micrófono (archivo vacío)"
  c=$(http POST /v1/speech/transcribe "$TMP/stt.json" -F "file=@$TMP/in.wav;filename=in.wav" -F language=es)
  [ "$c" = 200 ] || die 11 "transcripción falló (HTTP $c): $(body "$TMP/stt.json")"
  user_text=$(json_get "$TMP/stt.json" "print(d.get('text','').strip())") || die 11 "transcripción devolvió datos no válidos: $(body "$TMP/stt.json")"
fi
[ -n "${user_text// /}" ] || die 11 "no se entendió nada en el audio (¿micrófono silenciado?)"
say "TÚ: $user_text"

python3 - "$HIST" "$MODEL" "$user_text" > "$TMP/req.json" <<'EOF'
import json, sys, os
hist, model, text = sys.argv[1], sys.argv[2], sys.argv[3]
msgs = [{"role": "system", "content": "Eres JARVIS, asistente personal de Jerónimo. Responde en español, breve (máximo 3 frases), en texto plano apto para ser leído en voz alta, sin markdown ni emojis."}]
if os.path.exists(hist):
    for l in open(hist, encoding="utf-8").read().splitlines()[-12:]:
        try: msgs.append(json.loads(l))
        except ValueError: pass
msgs.append({"role": "user", "content": text})
print(json.dumps({"model": model, "messages": msgs}))
EOF
c=$(http POST /v1/chat/completions "$TMP/chat.json" -H 'Content-Type: application/json' --data-binary "@$TMP/req.json")
[ "$c" = 200 ] || die 12 "inferencia falló (HTTP $c, modelo $MODEL): $(body "$TMP/chat.json")"
answer=$(json_get "$TMP/chat.json" "import re; t=d['choices'][0]['message']['content']; print(re.sub(r'[*#_\`>]+','',t).strip())") \
  || die 12 "respuesta de inferencia no válida: $(body "$TMP/chat.json")"
[ -n "$answer" ] || die 12 "el modelo devolvió una respuesta vacía"
say "JARVIS: $answer"
mkdir -p "$(dirname "$HIST")" 2>/dev/null
python3 - "$HIST" "$user_text" "$answer" <<'EOF' || say "AVISO: no se pudo guardar el historial de voz en $HIST"
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({"role": "user", "content": sys.argv[2]}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"role": "assistant", "content": sys.argv[3]}, ensure_ascii=False) + "\n")
EOF
python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1][:1500], 'voice_id': sys.argv[2]}))" "$answer" "$VOICE" > "$TMP/tts.json"
c=$(http POST /v1/speech/synthesize "$TMP/out.wav" -H 'Content-Type: application/json' --data-binary "@$TMP/tts.json")
[ "$c" = 200 ] && [ "$(head -c 4 "$TMP/out.wav")" = RIFF ] || die 13 "síntesis de voz falló (HTTP $c): $(body "$TMP/out.wav")"
cat "$TMP/out.wav"
