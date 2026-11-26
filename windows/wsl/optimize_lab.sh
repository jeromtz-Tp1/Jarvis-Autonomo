#!/usr/bin/env bash
# optimize_lab.sh — Optimización de rendimiento REVERSIBLE de OpenJarvisLab (Fase 2C). Ejecutar como root en la distro.
#   apply  --model BASE [--threads N] [--ctx 4096]   aplica (idempotente) y deja copias de seguridad
#   revert                                           restaura exactamente el estado anterior
#   status                                           muestra lo aplicado
# Cambios (todos locales, sin descargas, sin tocar la seguridad):
#   1. Voz por el camino directo en streaming: [server] agent = "simple" (sin catálogo de herramientas en cada turno);
#      la memoria se sigue inyectando y registrando. Se retira la herramienta "think" (razonamiento extra).
#   2. Contexto 4096 (OpenJarvis forzaba 16384 por petición con JARVIS_NUM_CTX) y modelo residente (OLLAMA_KEEP_ALIVE=-1).
#   3. Modelo derivado "jarvis-voz:<tag>" (Modelfile local: num_thread y num_ctx óptimos; reutiliza los mismos pesos).
#   4. STT rápido: parche 0002 + beam_size=1, VAD y sin condicionamiento al texto previo.
#   5. CPU: cuota = todas las CPU de la VM (evita la penalización por estrangulamiento de hilos de llama.cpp).
#   6. Precarga al arrancar (ojl-warmup.service): modelo, Whisper y Kokoro en memoria antes de la primera pregunta.
#   7. ojvoice.py: TTS por frase en paralelo y reproducción por fragmentos.
#   8. Memoria rápida (parche 0003): hechos ordenados por relevancia con presupuesto de 512 tokens (antes 2048, solo
#      por antigüedad) y extracción de memoria diferida mientras dura un turno de voz.
set -uo pipefail
PREFIX=/opt/oj; OJUSER=jarvis; CMD=status
MODEL=""; THREADS=""; CTX=4096
while [ $# -gt 0 ]; do case "$1" in --prefix) PREFIX=$2; shift 2;; --user) OJUSER=$2; shift 2;; --model) MODEL=$2; shift 2;;
  --threads) THREADS=$2; shift 2;; --ctx) CTX=$2; shift 2;; apply|revert|status) CMD=$1; shift;; *) echo "argumento desconocido $1"; exit 2;; esac; done
cd /tmp
B="$(cd "$(dirname "$0")/../.." && pwd)"; H="$PREFIX/home"; source "$B/windows/wsl/ojlib.sh"
ST="$PREFIX/optimize/state"; CFG="$H/.openjarvis/config.toml"; ENVF="$PREFIX/deploy/ojl.env"
mkdir -p "$ST"
BEGIN="# >>> OJ-OPT (optimize_lab.sh; eliminar con: optimize_lab.sh revert)"; END="# <<< OJ-OPT"

backup() { for f in "$@"; do [ -e "$f" ] && [ ! -e "$ST/$(echo "$f" | tr / _)" ] && cp -a "$f" "$ST/$(echo "$f" | tr / _)"; done; true; }
restore() { for f in "$@"; do b="$ST/$(echo "$f" | tr / _)"; [ -e "$b" ] && cp -a "$b" "$f"; done; true; }
strip_block() { [ -f "$1" ] && sed -i "/^# >>> OJ-OPT/,/^# <<< OJ-OPT/d" "$1"; true; }
toml_set() {  # toml_set SECCION CLAVE VALOR (crea la sección o la clave si no existen)
  python3 - "$CFG" "$1" "$2" "$3" <<'EOF'
import re, sys
path, sec, key, val = sys.argv[1:5]
lines = open(path, encoding="utf-8").read().splitlines()
out, in_sec, done, seen = [], False, False, False
for l in lines:
    m = re.match(r"\s*\[([^\]]+)\]\s*$", l)
    if m:
        if in_sec and not done: out.append(f"{key} = {val}"); done = True
        in_sec = m.group(1).strip() == sec; seen = seen or in_sec
    elif in_sec and re.match(rf"\s*{re.escape(key)}\s*=", l):
        out.append(f"{key} = {val}"); done = True; continue
    out.append(l)
if in_sec and not done: out.append(f"{key} = {val}"); done = True
if not seen: out += ["", f"[{sec}]", f"{key} = {val}"]
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
EOF
}
ollama_cli() { asu "OLLAMA_HOST=127.0.0.1:11434 $PREFIX/ollama/bin/ollama $*"; }

apply() {
  [ -n "$MODEL" ] || { echo "falta --model"; exit 2; }
  oj_model_present "$MODEL" || { oj_fail "el modelo base $MODEL no está instalado (no se descarga nada)"; exit 3; }
  [ -n "$THREADS" ] || THREADS=$(nproc)
  oj_log "Optimización: modelo base $MODEL, hilos $THREADS, contexto $CTX"
  backup "$CFG" "$ENVF" "$PREFIX/bin/ojenv.sh" "$PREFIX/bin/ojvoice.sh" "$PREFIX/bin/ojctl.sh"
  [ -f "$ST/default_model" ] || oj_config_model > "$ST/default_model"

  # 4. Parche STT 0002 (idempotente, reversible)
  install -m 644 "$B/patches/0002-stt-tunable-beam-vad.patch" "$PREFIX/0002.patch"; chown "$OJUSER" "$PREFIX/0002.patch"
  if asu "cd $PREFIX/src && git apply --check $PREFIX/0002.patch" 2>/dev/null; then asu "cd $PREFIX/src && git apply $PREFIX/0002.patch" && touch "$ST/patch0002"; oj_ok "parche STT 0002 aplicado"
  elif asu "cd $PREFIX/src && git apply -R --check $PREFIX/0002.patch" 2>/dev/null; then oj_ok "parche STT 0002 ya presente"
  else oj_fail "parche STT 0002 no aplicable"; fi

  # Memoria rápida (parche 0003): hechos por relevancia con presupuesto 512 tokens y extracción diferida durante la voz
  install -m 644 "$B/patches/0003-memory-fact-ranking-and-deferred-extraction.patch" "$PREFIX/0003.patch"; chown "$OJUSER" "$PREFIX/0003.patch"
  if asu "cd $PREFIX/src && git apply --check $PREFIX/0003.patch" 2>/dev/null; then asu "cd $PREFIX/src && git apply $PREFIX/0003.patch" && touch "$ST/patch0003"; oj_ok "parche de memoria 0003 aplicado"
  elif asu "cd $PREFIX/src && git apply -R --check $PREFIX/0003.patch" 2>/dev/null; then oj_ok "parche de memoria 0003 ya presente"
  else oj_fail "parche de memoria 0003 no aplicable"; fi
  toml_set memory context_max_tokens 512

  # 2/4. Variables de entorno (servicio y shell) en bloque marcado
  for f in "$ENVF" "$PREFIX/bin/ojenv.sh"; do
    [ -f "$f" ] || continue; strip_block "$f"
    pre=""; [ "$f" = "$PREFIX/bin/ojenv.sh" ] && pre="export "
    { echo "$BEGIN"; for kv in "JARVIS_NUM_CTX=$CTX" "OLLAMA_CONTEXT_LENGTH=$CTX" "OLLAMA_KEEP_ALIVE=-1" "OJ_STT_BEAM_SIZE=1" "OJ_STT_VAD=1" "OJ_STT_NO_PREV_TEXT=1" "OJ_MEMORY_FACT_RANK=1" "OJ_MEMORY_DEFER_FILE=$H/.openjarvis/.voice_busy" "OJ_MEMORY_DEFER_MAX_S=30"; do echo "$pre$kv"; done; echo "$END"; } >> "$f"
  done
  oj_ok "entorno: contexto $CTX, modelo residente, STT beam=1 + VAD, memoria por relevancia (512 tokens) y extracción diferida"

  # 1. Camino directo para la voz y sin herramienta de razonamiento extra
  toml_set server agent '"simple"'
  sed -i -E '/^\[tools\]/,/^\[/ s/"think",?\s*//; /^\[tools\]/,/^\[/ s/,\s*\]/]/' "$CFG"
  oj_ok "voz por streaming directo (server.agent=simple) y sin herramienta 'think'"

  # 3. Modelo derivado con hilos y contexto óptimos (mismos pesos; sin descarga)
  local tag=${MODEL#*:}; local derived="jarvis-voz:$tag"
  printf 'FROM %s\nPARAMETER num_thread %s\nPARAMETER num_ctx %s\n' "$MODEL" "$THREADS" "$CTX" > "$PREFIX/optimize/Modelfile.$tag"
  chown "$OJUSER" "$PREFIX/optimize/Modelfile.$tag"
  oj_services_restart >/dev/null || { oj_fail "servicios no arrancan para crear el modelo derivado"; exit 4; }
  if ollama_cli "create $derived -f $PREFIX/optimize/Modelfile.$tag" >/dev/null 2>&1 && oj_model_present "$derived"; then
    echo "$derived" >> "$ST/derived_models"; toml_set intelligence default_model "\"$derived\""; oj_ok "modelo $derived (hilos=$THREADS, ctx=$CTX) como predeterminado"
  else oj_fail "no se pudo crear $derived; se usa $MODEL directamente"; toml_set intelligence default_model "\"$MODEL\""; fi

  # 7. Voz de baja latencia
  install -m 755 "$B/windows/wsl/ojvoice.py" "$PREFIX/bin/ojvoice.py"; install -m 755 "$B/windows/wsl/ojvoice.sh" "$PREFIX/bin/ojvoice.sh"
  install -m 755 "$B/windows/wsl/ojbench.py" "$PREFIX/bin/ojbench.py"

  # 6. Precarga al arrancar
  cat > "$PREFIX/bin/ojwarmup.sh" <<EOF
#!/usr/bin/env bash
# Precarga modelo, STT y TTS para que la primera pregunta no pague la carga en frío.
for _ in \$(seq 240); do curl -s -m 3 http://127.0.0.1:8000/health | grep -q ok && break; sleep 1; done
M=\$(sed -n 's/^default_model = "\(.*\)".*/\1/p' $CFG | head -1)
curl -s -m 600 http://127.0.0.1:11434/api/generate -d "{\"model\":\"\$M\",\"prompt\":\"\",\"keep_alive\":-1}" >/dev/null
curl -s -m 300 -F "file=@$PREFIX/fixtures/stt_es.wav;filename=w.wav" -F language=es http://127.0.0.1:8000/v1/speech/transcribe >/dev/null
curl -s -m 300 -H 'Content-Type: application/json' -d '{"text":"Listo.","voice_id":"ef_dora"}' http://127.0.0.1:8000/v1/speech/synthesize -o /dev/null
echo "precarga completada \$(date -u +%FT%TZ) modelo=\$M"
EOF
  chmod 755 "$PREFIX/bin/ojwarmup.sh"
  if systemd_active; then
    cat > /etc/systemd/system/ojl-warmup.service <<EOF
[Unit]
Description=OpenJarvisLab - precarga de modelo, STT y TTS
After=ojl-server.service
Requires=ojl-server.service
[Service]
Type=oneshot
User=$OJUSER
ExecStart=$PREFIX/bin/ojwarmup.sh
IPAddressDeny=any
IPAddressAllow=localhost
NoNewPrivileges=yes
[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/system/openjarvis.slice.d
    printf '[Slice]\nCPUQuota=%s%%\n' "$(( $(nproc) * 100 ))" > /etc/systemd/system/openjarvis.slice.d/20-performance.conf
    systemctl daemon-reload; systemctl enable ojl-warmup.service >/dev/null 2>&1
    oj_ok "precarga al arrancar (ojl-warmup.service) y cuota CPU = $(nproc) CPU"
  fi
  touch "$ST/applied"
  oj_services_restart >/dev/null || { oj_fail "servicios no arrancan tras optimizar"; exit 4; }
  if systemd_active; then systemctl start ojl-warmup.service; else runuser -u "$OJUSER" -- "$PREFIX/bin/ojwarmup.sh"; fi
  oj_ok "servicios reiniciados y precargados"
}

revert() {
  if ! [ -f "$ST/applied" ] && [ -z "$(ls "$ST" 2>/dev/null)" ]; then
    echo "no hay optimización aplicada"
    oj_models_installed | grep '^jarvis-voz:' | while read -r m; do ollama_cli "rm $m" >/dev/null 2>&1 && oj_ok "modelo derivado huérfano $m eliminado"; done
    return 0; fi
  oj_log "Revirtiendo optimización"
  restore "$CFG" "$ENVF" "$PREFIX/bin/ojenv.sh" "$PREFIX/bin/ojvoice.sh" "$PREFIX/bin/ojctl.sh"
  strip_block "$ENVF"; strip_block "$PREFIX/bin/ojenv.sh"
  if [ -f "$ST/patch0003" ]; then asu "cd $PREFIX/src && git apply -R $PREFIX/0003.patch" && oj_ok "parche 0003 retirado"; fi
  if [ -f "$ST/patch0002" ]; then asu "cd $PREFIX/src && git apply -R $PREFIX/0002.patch" && oj_ok "parche 0002 retirado"; fi
  rm -f "$PREFIX/bin/ojvoice.py" "$PREFIX/bin/ojwarmup.sh"
  if systemd_active; then systemctl disable --now ojl-warmup.service >/dev/null 2>&1; rm -f /etc/systemd/system/ojl-warmup.service /etc/systemd/system/openjarvis.slice.d/20-performance.conf; systemctl daemon-reload; fi
  oj_services_restart >/dev/null
  { cat "$ST/derived_models" 2>/dev/null; oj_models_installed | grep '^jarvis-voz:'; } | sort -u | while read -r m; do
    [ -n "$m" ] && ollama_cli "rm $m" >/dev/null 2>&1 && oj_ok "modelo derivado $m eliminado (los pesos base se conservan)"; done
  rm -rf "$ST"; oj_ok "estado anterior restaurado (modelo: $(oj_config_model))"
}

status() {
  if [ -f "$ST/applied" ]; then echo "OPTIMIZACIÓN APLICADA"; echo "  modelo: $(oj_config_model)  (anterior: $(cat "$ST/default_model" 2>/dev/null))"
    grep -E "JARVIS_NUM_CTX|KEEP_ALIVE|OJ_STT" "$ENVF" 2>/dev/null | sed 's/^/  /'; grep -A2 '^\[server\]' "$CFG" | sed 's/^/  /'
  else echo "SIN OPTIMIZAR (modelo: $(oj_config_model))"; fi
}
case "$CMD" in apply) apply;; revert) revert;; status) status;; *) echo "uso: $0 apply|revert|status"; exit 2;; esac
exit $(( ${OJ_FAILS:-0} > 0 ))
