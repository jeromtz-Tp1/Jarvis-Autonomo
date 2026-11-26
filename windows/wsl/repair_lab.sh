#!/usr/bin/env bash
# repair_lab.sh — Reparación EN SITIO de OpenJarvisLab (sin reinstalar ni descargar modelos).
# Ejecutar como root dentro de la distro:  bash repair_lab.sh [--prefix /opt/oj] [--user jarvis] [--allow-model-download]
# Salida: líneas [OK]/[AVISO]/[FALLO]; códigos: 0 sano · 1 fallos en pruebas · 3 instalación incompleta · 4 servicios no arrancan
#         y "WSLCONF_CHANGED=1" si hay que reiniciar la distro para aplicar /etc/wsl.conf.
set -uo pipefail
PREFIX=/opt/oj; OJUSER=jarvis; ALLOW_DL=0
while [ $# -gt 0 ]; do case "$1" in --prefix) PREFIX=$2; shift 2;; --user) OJUSER=$2; shift 2;; --allow-model-download) ALLOW_DL=1; shift;; *) echo "argumento desconocido $1"; exit 2;; esac; done
cd /tmp
B="$(cd "$(dirname "$0")/../.." && pwd)"; H="$PREFIX/home"
source "$B/windows/wsl/ojlib.sh"
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root de la distro"; exit 2; }
LOG="$PREFIX/logs/repair_$(date -u +%Y%m%dT%H%M%SZ).log"; mkdir -p "$PREFIX/logs"; exec > >(tee -a "$LOG") 2>&1
OJ_FAILS=0

oj_log "1/7 Diagnóstico de la distro"
echo "  VM WSL: $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) MB RAM, $(nproc) CPU; PID1=$(ps -p 1 -o comm=); disco libre $(df -BG --output=avail "$PREFIX" | tail -1 | tr -d ' ')"
id "$OJUSER" >/dev/null 2>&1 || { oj_fail "no existe el usuario $OJUSER: la instalación no está presente (usar Install-OpenJarvisLab.ps1)"; exit 3; }

oj_log "2/7 Aislamiento WSL (/etc/wsl.conf)"
want=$'[boot]\nsystemd=true\n[automount]\nenabled=false\nmountFsTab=false\n[interop]\nenabled=false\nappendWindowsPath=false\n[user]\ndefault=root\n[network]\ngenerateHosts=true\ngenerateResolvConf=true'
if [ "$(cat /etc/wsl.conf 2>/dev/null | tr -d '\r')" != "$want" ]; then printf '%s\n' "$want" > /etc/wsl.conf; oj_warn "wsl.conf corregido (se reiniciará la distro)"; echo "WSLCONF_CHANGED=1"; WSLCONF_PENDING=1
else oj_ok "wsl.conf correcto (systemd activo, sin unidades de Windows, sin interop)"; fi

oj_log "3/7 Componentes instalados (verificación local, sin descargas)"
miss=0
for f in "$PREFIX/venv/bin/jarvis" "$PREFIX/ollama/bin/ollama" "$PREFIX/src/pyproject.toml" "$H/.openjarvis/config.toml"; do
  [ -e "$f" ] && oj_ok "$f" || { oj_fail "falta $f"; miss=1; }; done
"$PREFIX/venv/bin/python" -c "import openjarvis, openjarvis_rust" 2>/dev/null && oj_ok "OpenJarvis + extensión Rust importables" || { oj_fail "OpenJarvis/Rust no importables"; miss=1; }
[ $miss = 1 ] && { echo "Instalación incompleta: no se puede reparar en sitio."; exit 3; }
MODEL=$(oj_config_model); MODEL=${MODEL:-qwen3.5:4b}
if oj_model_present "$MODEL"; then oj_ok "modelo $MODEL presente ($(du -sh "$H/.ollama/models" | cut -f1) en disco)"
elif [ $ALLOW_DL = 1 ]; then oj_pull_model_maintenance "$MODEL" || exit 3
else
  alt=$(oj_models_installed | grep -v '^jarvis-voz' | head -1)
  if [ -n "$alt" ]; then oj_warn "el modelo configurado $MODEL no está; se usa el instalado: $alt"; MODEL=$alt
    sed -i "s#^default_model = .*#default_model = \"$MODEL\"#" "$H/.openjarvis/config.toml"
  else oj_fail "no hay ningún modelo descargado. Repita con -AllowModelDownload"; exit 3; fi
fi
oj_hf_cached "Systran--faster-whisper-base" && oj_ok "modelo STT Whisper base en caché" || oj_fail "falta el modelo Whisper base en caché (reinstalar voz con -AllowModelDownload)"
oj_hf_cached "hexgrad--Kokoro-82M" && oj_ok "modelo TTS Kokoro en caché" || oj_fail "falta el modelo Kokoro en caché (-AllowModelDownload)"

oj_log "4/7 Scripts y configuración corregidos"
# Conservar la optimización de la Fase 2C (bloque OJ-OPT) si está aplicada
OPTBLK_ENV=$(sed -n '/^# >>> OJ-OPT/,/^# <<< OJ-OPT/p' "$PREFIX/bin/ojenv.sh" 2>/dev/null)
OPTBLK_UNIT=$(sed -n '/^# >>> OJ-OPT/,/^# <<< OJ-OPT/p' "$PREFIX/deploy/ojl.env" 2>/dev/null)
cat > "$PREFIX/bin/ojenv.sh" <<EOF
# Entorno aislado de OpenJarvis (sin secretos) — regenerado por repair_lab.sh $(date -u +%F)
export HOME=$H OPENJARVIS_HOME=$H/.openjarvis UV_NO_CONFIG=1
export PATH=$PREFIX/venv/bin:$H/.cargo/bin:$PREFIX/bin:$PREFIX/tools/bin:/usr/local/bin:/usr/bin:/bin
export RUSTUP_HOME=$H/.rustup CARGO_HOME=$H/.cargo UV_CACHE_DIR=$H/.cache/uv HF_HOME=$H/.cache/huggingface
export OLLAMA_MODELS=$H/.ollama/models OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_CONTEXT_LENGTH=8192
export HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1
export NIM_HOST=http://127.0.0.1:9 OPENJARVIS_STRICT_TOOLS=1
EOF
[ -f "$PREFIX/ca-bundle.crt" ] && echo "export SSL_CERT_FILE=$PREFIX/ca-bundle.crt REQUESTS_CA_BUNDLE=$PREFIX/ca-bundle.crt CURL_CA_BUNDLE=$PREFIX/ca-bundle.crt GIT_SSL_CAINFO=$PREFIX/ca-bundle.crt" >> "$PREFIX/bin/ojenv.sh"
[ -n "$OPTBLK_ENV" ] && printf '%s\n' "$OPTBLK_ENV" >> "$PREFIX/bin/ojenv.sh" && oj_ok "optimización 2C conservada en ojenv.sh"
sed -e "s#@PREFIX@#$PREFIX#g" -e "s#@OJUSER@#$OJUSER#g" "$B/windows/wsl/ojctl.sh" > "$PREFIX/bin/ojctl.sh"; chmod 755 "$PREFIX/bin/ojctl.sh"
install -m 755 "$B/windows/wsl/ojvoice.sh" "$PREFIX/bin/ojvoice.sh"; install -m 755 "$B/windows/wsl/ojvoice.py" "$PREFIX/bin/ojvoice.py"
install -d "$PREFIX/fixtures"; install -m 644 "$B/windows/wsl/fixtures/stt_es.wav" "$PREFIX/fixtures/stt_es.wav"
grep -q '^mode = "block"' "$H/.openjarvis/config.toml" || { sed -i 's/^mode = .*/mode = "block"/' "$H/.openjarvis/config.toml"; oj_warn "security.mode restaurado a block"; }
grep -q '^host = "127.0.0.1"' "$H/.openjarvis/config.toml" || oj_fail "server.host no es 127.0.0.1 en config.toml (revisar)"
oj_ok "ojenv.sh (UV_NO_CONFIG, PATH), ojctl.sh, ojvoice.sh y audio de referencia actualizados"

oj_log "5/7 Servicios systemd y recursos persistentes"
if systemd_active; then
  install -d "$PREFIX/deploy"; cp "$B/deploy/phase2-72h/"* "$PREFIX/deploy/"; sed -i "s#/opt/oj#$PREFIX#g" "$PREFIX/deploy/"*
  sed -i "s#^User=jarvis#User=$OJUSER#; s#^Group=jarvis#Group=$OJUSER#" "$PREFIX/deploy/"*.service
  [ -n "$OPTBLK_UNIT" ] && printf '%s\n' "$OPTBLK_UNIT" >> "$PREFIX/deploy/ojl.env"
  cp "$PREFIX/deploy/"*.slice "$PREFIX/deploy/"*.service "$PREFIX/deploy/"*.timer /etc/systemd/system/
  oj_ok "unidades reinstaladas; recursos: $(oj_write_slice_dropin)"
  systemd-analyze verify /etc/systemd/system/ojl-*.service /etc/systemd/system/openjarvis.slice 2>&1 | grep -iE "unknown|invalid" && oj_fail "unidades systemd con errores" || oj_ok "unidades systemd válidas"
else
  oj_warn "systemd no es PID 1 todavía (se activará tras reiniciar la distro)"
fi
chown -R "$OJUSER:$OJUSER" "$PREFIX/home" "$PREFIX/logs" "$PREFIX/workspace" "$PREFIX/evidence" "$PREFIX/fixtures" 2>/dev/null
[ -n "${WSLCONF_PENDING:-}" ] && { echo "Reinicio de distro pendiente: no se arrancan servicios ahora."; exit 0; }

oj_log "6/7 Reinicio de servicios"
oj_services_restart || exit 4

oj_log "7/7 Pruebas independientes"
oj_selftest "$PREFIX/evidence/repair_$(date -u +%Y%m%dT%H%M%SZ)"; rc=$?
oj_log "Log completo: $LOG"
exit $rc
