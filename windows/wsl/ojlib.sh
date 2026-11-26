#!/usr/bin/env bash
# ojlib.sh — Funciones comunes de instalación, reparación y autodiagnóstico de OpenJarvisLab.
# Se carga con:  source ojlib.sh   (requiere PREFIX y OJUSER definidos)
# Principios: nunca ocultar errores (pipefail + códigos HTTP visibles), nunca depender del directorio actual,
# descargas de modelos solo en modo mantenimiento explícito (los servicios quedan sin salida a Internet).

: "${PREFIX:?PREFIX no definido}"; : "${OJUSER:?OJUSER no definido}"
OJ_API=${OJ_API:-http://127.0.0.1:8000}
OJ_OLLAMA=${OJ_OLLAMA:-http://127.0.0.1:11434}
OJ_MAINT_PORT=11435                       # Ollama temporal SOLO para descargas de mantenimiento
H="$PREFIX/home"   # siempre derivado de PREFIX (no heredar un H ajeno del entorno)

oj_log()  { echo "[$(date -u +%T)] $*"; }
oj_ok()   { echo "  [OK]   $*"; }
oj_warn() { echo "  [AVISO] $*"; }
oj_fail() { echo "  [FALLO] $*"; OJ_FAILS=$(( ${OJ_FAILS:-0} + 1 )); }

# Ejecuta como el usuario sin privilegios, SIEMPRE desde un directorio propio (evita /root/uv.toml),
# con pipefail para que una tubería no oculte un fallo, y sin leer configuraciones uv ajenas.
asu() { runuser -u "$OJUSER" -- bash -c "set -o pipefail; cd '$PREFIX/workspace' 2>/dev/null || cd /tmp; export UV_NO_CONFIG=1; source '$PREFIX/bin/ojenv.sh'; $*"; }

systemd_active() { [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ]; }

# oj_http MÉTODO URL SALIDA [args curl...]  -> imprime el código HTTP; muestra cuerpo del error si no es 2xx.
oj_http() {
  local method=$1 url=$2 out=$3; shift 3
  local code; code=$(curl -s -m "${OJ_HTTP_TIMEOUT:-300}" -X "$method" -o "$out" -w '%{http_code}' "$@" "$url"); code=${code:-000}
  if [ "${code:0:1}" != 2 ]; then
    echo "  HTTP $code en $method ${url#$OJ_API}: $(head -c 400 "$out" 2>/dev/null | tr -d '\0')" >&2
  fi
  echo "$code"
}

# ---------- Recursos: presupuesto adaptativo y persistente (drop-in de la slice) ----------
# Política: hasta 10 GB y 6 CPU (valores con los que la inferencia 4B + voz funcionó en la PC real),
# sin exceder lo que la VM de WSL tiene (deja 1.5 GB al sistema de la distro).
oj_compute_resources() {
  local mem_mb cpus
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); cpus=$(nproc)
  OJ_MEM_MAX_MB=$(( mem_mb - 1536 )); [ $OJ_MEM_MAX_MB -gt 10240 ] && OJ_MEM_MAX_MB=10240
  OJ_MEM_HIGH_MB=$(( OJ_MEM_MAX_MB - 512 ))
  OJ_CPUS=$cpus; [ $OJ_CPUS -gt 6 ] && OJ_CPUS=6
  OJ_VM_MEM_MB=$mem_mb; OJ_VM_CPUS=$cpus
}
oj_write_slice_dropin() {
  oj_compute_resources
  mkdir -p /etc/systemd/system/openjarvis.slice.d
  cat > /etc/systemd/system/openjarvis.slice.d/10-resources.conf <<EOF
# Generado por ojlib.sh $(date -u +%FT%TZ): VM WSL con ${OJ_VM_MEM_MB} MB y ${OJ_VM_CPUS} CPU
[Slice]
MemoryHigh=${OJ_MEM_HIGH_MB}M
MemoryMax=${OJ_MEM_MAX_MB}M
CPUQuota=$(( OJ_CPUS * 100 ))%
EOF
  echo "MemoryMax=${OJ_MEM_MAX_MB}M CPUQuota=$(( OJ_CPUS * 100 ))% (VM: ${OJ_VM_MEM_MB} MB, ${OJ_VM_CPUS} CPU)"
}

# ---------- Modelos: comprobación local (sin red) y descarga de mantenimiento ----------
# Ollama guarda los modelos descargados en manifests/registry.ollama.ai/… y (desde 0.40) los creados localmente en
# manifests-v2/ollama.com/…: se aceptan ambos formatos.
oj_model_manifest() { local m=$1 name=${1%%:*} tag=${1#*:} c; [ "$tag" = "$m" ] && tag=latest
  for c in "$H/.ollama/models/manifests/registry.ollama.ai/library/$name/$tag" "$H/.ollama/models/manifests-v2/ollama.com/library/$name/$tag" "$H"/.ollama/models/manifests-v2/*/library/"$name/$tag"; do
    [ -s "$c" ] && { echo "$c"; return 0; }; done
  echo "$H/.ollama/models/manifests/registry.ollama.ai/library/$name/$tag"; }
oj_model_present() { [ -s "$(oj_model_manifest "$1")" ]; }
oj_models_installed() { ls -d "$H"/.ollama/models/manifests/*/library/*/* "$H"/.ollama/models/manifests-v2/*/library/*/* 2>/dev/null | awk -F/ '{print $(NF-1)":"$NF}' | sort -u; }
oj_hf_cached() { ls -d "$H/.cache/huggingface/hub/models--$1" >/dev/null 2>&1; }

# Descarga un modelo con un Ollama TEMPORAL (sin restricciones systemd, puerto 11435, solo loopback)
# y lo detiene al terminar. El servicio permanente sigue sin salida a Internet.
oj_pull_model_maintenance() {
  local model=$1 rc
  oj_log "Mantenimiento: descarga de $model con Ollama temporal en 127.0.0.1:$OJ_MAINT_PORT"
  asu "OLLAMA_HOST=127.0.0.1:$OJ_MAINT_PORT nohup $PREFIX/ollama/bin/ollama serve > $PREFIX/logs/ollama_maint.log 2>&1 & echo \$! > $PREFIX/logs/ollama_maint.pid"
  for _ in $(seq 30); do curl -s -m 2 "http://127.0.0.1:$OJ_MAINT_PORT/api/version" >/dev/null && break; sleep 1; done
  asu "OLLAMA_HOST=127.0.0.1:$OJ_MAINT_PORT $PREFIX/ollama/bin/ollama pull $model"; rc=$?
  kill "$(cat "$PREFIX/logs/ollama_maint.pid" 2>/dev/null)" 2>/dev/null; sleep 2; pkill -u "$OJUSER" -f "llama-server" 2>/dev/null || true
  if [ $rc -ne 0 ] || ! oj_model_present "$model"; then oj_fail "descarga de $model (código $rc). Ver $PREFIX/logs/ollama_maint.log"; return 1; fi
  oj_ok "modelo $model descargado y verificado"
}

oj_config_model() { sed -n 's/^default_model = "\(.*\)".*/\1/p' "$H/.openjarvis/config.toml" 2>/dev/null | head -1; }

# ---------- Servicios ----------
oj_wait_health() {   # oj_wait_health SEGUNDOS
  local t=${1:-180}
  for _ in $(seq "$t"); do curl -s -m 3 "$OJ_API/health" | grep -q '"ok"' && return 0; sleep 1; done
  return 1
}
oj_services_restart() {
  if systemd_active && [ -f /etc/systemd/system/ojl-server.service ]; then
    systemctl daemon-reload
    systemctl enable ojl-ollama.service ojl-server.service ojl-monitor.timer >/dev/null 2>&1
    systemctl restart ojl-ollama.service; systemctl restart ojl-server.service; systemctl start ojl-monitor.timer
  else
    "$PREFIX/bin/ojctl.sh" stop >/dev/null 2>&1; "$PREFIX/bin/ojctl.sh" start >/dev/null 2>&1
  fi
  if oj_wait_health 240; then oj_ok "servicios activos y /health = ok"; return 0; fi
  oj_fail "el servidor no respondió /health en 240 s"
  if systemd_active; then journalctl -u ojl-server -u ojl-ollama -n 40 --no-pager 2>/dev/null | sed 's/^/    /'; else tail -40 "$PREFIX/logs/server.log" | sed 's/^/    /'; fi
  return 1
}

# oj_chat_stream MODELO PREGUNTA SALIDA -> texto de la respuesta por el MISMO camino que la voz (streaming directo)
oj_chat_stream() {
  python3 - "$OJ_API" "$1" "$2" > "$3" 2>&1 <<'PYEOF'
import json, sys, urllib.request
api, model, q = sys.argv[1:4]
body = {"model": model, "stream": True, "max_tokens": 120, "temperature": 0.2,
        "messages": [{"role": "system", "content": "Eres JARVIS. Responde en español, en una frase."}, {"role": "user", "content": q}]}
r = urllib.request.Request(api + "/v1/chat/completions", data=json.dumps(body).encode(), method="POST", headers={"Content-Type": "application/json"})
out = ""
with urllib.request.urlopen(r, timeout=300) as resp:
    for ln in resp:
        ln = ln.decode("utf-8", "replace").strip()
        if ln.startswith("data:") and ln[5:].strip() != "[DONE]":
            try: out += json.loads(ln[5:])["choices"][0].get("delta", {}).get("content") or ""
            except Exception: pass
print(out)
PYEOF
}

# oj_memtest DIR MODELO — prueba de memoria persistente sin falsos positivos:
#  a) escribe un hecho de verificación con el almacén oficial; b) el archivo debe existir y contenerlo;
#  c) reinicia el servidor; d) JARVIS debe recordarlo; e) la extracción automática debe guardar un hecho nuevo.
oj_memtest() {
  local ev=$1 model=$2 f="$H/.openjarvis/memory_facts.jsonl" before after tok
  tok=$(( 1000 + RANDOM % 8999 ))$(( RANDOM % 10 ))   # único por ejecución: evita falsos positivos al repetir
  local fact="Dato de verificación de JARVIS: el código de prueba de memoria es MEM-7731."
  grep -q '^enabled = true' <(sed -n '/^\[memory\]/,/^\[/p' "$H/.openjarvis/config.toml") || { oj_fail "Memoria: [memory] enabled no es true en config.toml"; return; }
  before=$(cat "$f" 2>/dev/null | grep -c . || true); before=${before:-0}
  asu "python -c \"from openjarvis.memory.store import LocalFactStore as S; s=S(); s.add('$fact', source='selftest', trust='trusted'); print(len(s.list()))\"" > "$ev/mem_write.txt" 2>&1
  if [ -s "$f" ] && grep -q "MEM-7731" "$f"; then oj_ok "Memoria: archivo $f existe y contiene el hecho de verificación ($(grep -c . "$f") hechos)"
  else oj_fail "Memoria: no se pudo escribir/leer $f ($(head -c 200 "$ev/mem_write.txt"))"; return; fi
  if systemd_active && [ -f /etc/systemd/system/ojl-server.service ]; then systemctl restart ojl-server.service; else "$PREFIX/bin/ojctl.sh" restart >/dev/null 2>&1; fi
  oj_wait_health 240 || { oj_fail "Memoria: el servidor no volvió tras reiniciar"; return; }
  oj_chat_stream "$model" "¿Cuál es el código de prueba de memoria?" "$ev/mem_recall.txt"
  grep -q "7731" "$ev/mem_recall.txt" && oj_ok "Memoria: recordado tras reiniciar el servidor (MEM-7731)" \
    || oj_fail "Memoria: tras reiniciar NO recordó el hecho. Respuesta: $(head -c 160 "$ev/mem_recall.txt")"
  oj_chat_stream "$model" "Recuerda este dato personal: mi número de casillero de prueba es $tok." "$ev/mem_extract_chat.txt"
  for _ in $(seq 60); do grep -q "$tok" "$f" 2>/dev/null && break; sleep 3; done
  after=$(cat "$f" 2>/dev/null | grep -c . || true); after=${after:-0}
  grep -q "$tok" "$f" 2>/dev/null && oj_ok "Memoria: la extracción automática guardó un hecho nuevo ($before -> $after hechos)" \
    || oj_fail "Memoria: la extracción automática no guardó hechos en 180 s ($before -> $after). Revise el servicio de memoria en el log del servidor"
}

# ---------- Autodiagnóstico independiente: STT, inferencia, TTS, voz extremo a extremo, memoria, seguridad ----------
oj_selftest() {
  local ev=${1:-$PREFIX/evidence/selftest_$(date -u +%Y%m%dT%H%M%SZ)} model code t0 fx
  mkdir -p "$ev"; chown "$OJUSER" "$ev"; OJ_FAILS=0; model=$(oj_config_model)
  fx="$PREFIX/fixtures/stt_es.wav"
  oj_log "Autodiagnóstico (evidencia en $ev)"

  # 1. Inferencia (LLM vía API del servidor -> Ollama)
  t0=$(date +%s)
  code=$(oj_http POST "$OJ_API/v1/chat/completions" "$ev/llm.json" -H 'Content-Type: application/json' \
         -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"¿Cuánto es 17 + 25? Responde solo el número.\"}]}")
  if [ "$code" = 200 ] && python3 -c "import json,sys; t=json.load(open('$ev/llm.json'))['choices'][0]['message']['content']; sys.exit(0 if '42' in t else 1)" 2>/dev/null
  then oj_ok "Inferencia ($model): 17+25 -> 42 en $(( $(date +%s)-t0 )) s"
  else oj_fail "Inferencia ($model): HTTP $code, respuesta: $(head -c 200 "$ev/llm.json")"; fi

  # 2. STT con audio de referencia incluido en el paquete (no depende del TTS)
  if [ -s "$fx" ]; then
    code=$(oj_http POST "$OJ_API/v1/speech/transcribe" "$ev/stt.json" -F "file=@$fx;filename=stt_es.wav" -F language=es)
    if [ "$code" = 200 ] && grep -qi "cobranza" "$ev/stt.json"; then oj_ok "STT: $(python3 -c "import json; print(json.load(open('$ev/stt.json'))['text'])")"
    else oj_fail "STT: HTTP $code, respuesta: $(head -c 200 "$ev/stt.json")"; fi
  else oj_fail "STT: falta el audio de referencia $fx"; fi

  # 3. TTS
  code=$(oj_http POST "$OJ_API/v1/speech/synthesize" "$ev/tts.wav" -H 'Content-Type: application/json' -d '{"text":"Prueba de voz de Jarvis.","voice_id":"ef_dora"}')
  if [ "$code" = 200 ] && [ "$(head -c 4 "$ev/tts.wav")" = RIFF ] && [ "$(stat -c %s "$ev/tts.wav")" -gt 10000 ]; then oj_ok "TTS: WAV de $(stat -c %s "$ev/tts.wav") bytes"
  else oj_fail "TTS: HTTP $code, respuesta: $(head -c 200 "$ev/tts.wav" | tr -d '\0')"; fi

  # 4. Voz extremo a extremo (misma ruta que Talk-Jarvis.ps1)
  if [ -s "$fx" ] && runuser -u "$OJUSER" -- bash -c "cd /tmp; '$PREFIX/bin/ojvoice.sh' < '$fx' > '$ev/voice_out.wav' 2> '$ev/voice_dialog.txt'"; then
    oj_ok "Voz extremo a extremo: $(grep '^JARVIS:' "$ev/voice_dialog.txt" | head -c 120)"
  else oj_fail "Voz extremo a extremo: $(tail -3 "$ev/voice_dialog.txt" 2>/dev/null | tr '\n' ' ')"; fi

  # 5. Memoria persistente REAL (sustituye la comprobación que daba falso positivo)
  oj_memtest "$ev" "$model"

  # 6. Seguridad conservada
  local exposed; exposed=$(for f in /proc/net/tcp /proc/net/tcp6; do tail -n +2 "$f" 2>/dev/null; done | awk '$4=="0A"{print $2}' | grep -E ':(1F40|2CAA)$' | grep -vE '^(0100007F|00000000000000000000000001000000):' || true)
  [ -z "$exposed" ] && oj_ok "Seguridad: API y Ollama solo en 127.0.0.1" || oj_fail "Seguridad: puerto 8000/11434 expuesto fuera de loopback"
  grep -q 'OPENJARVIS_STRICT_TOOLS=1' "$PREFIX/bin/ojenv.sh" && grep -q '^mode = "block"' "$H/.openjarvis/config.toml" \
    && oj_ok "Seguridad: allowlist estricta y modo block activos" || oj_fail "Seguridad: falta allowlist estricta o modo block"
  if systemd_active; then
    systemctl show ojl-server -p IPAddressDeny --value | grep -q . && oj_ok "Seguridad: servicios sin salida a Internet (IPAddressDeny)" || oj_fail "Seguridad: IPAddressDeny no aplicado"
    oj_ok "Recursos aplicados: MemoryMax=$(systemctl show openjarvis.slice -p MemoryMax --value) CPUQuotaPerSec=$(systemctl show openjarvis.slice -p CPUQuotaPerSecUSec --value)"
  else oj_warn "systemd no es PID 1: límites de recursos y bloqueo de red de systemd no activos"; fi
  grep -q '^enabled=false' /etc/wsl.conf 2>/dev/null && oj_ok "Aislamiento WSL: unidades de Windows no montadas" || oj_warn "Aislamiento WSL: automount no desactivado en /etc/wsl.conf"

  echo "SELFTEST_FAILS=$OJ_FAILS"
  return $(( OJ_FAILS > 0 ))
}
