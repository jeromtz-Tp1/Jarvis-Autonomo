#!/usr/bin/env bash
# setup_lab.sh — Instalación aislada de OpenJarvis dentro de una distro WSL2 DEDICADA (o cualquier Ubuntu 24.04).
# Reproduce la instalación validada en Fase 1 + endurecimiento de Fase 2 (patches/0001, allowlist, loopback).
#
# Ejecutar como root DENTRO de la distro dedicada "OpenJarvisLab" (root de esa distro, no de Windows):
#   bash windows/wsl/setup_lab.sh [--prefix /opt/oj] [--user jarvis] [--model qwen3.5:2b] [--gpu auto|cpu|cuda]
# Idempotente: se puede relanzar. Todo queda bajo PREFIX; desinstalar = borrar la distro (wsl --unregister).
# Orígenes de red usados (solo durante la instalación): archive.ubuntu.com, pypi.org, static.rust-lang.org,
#   crates.io, github.com (+release-assets), ollama.com, registry.ollama.ai, huggingface.co (+CDN).
set -euo pipefail

PREFIX=/opt/oj; OJUSER=jarvis; MODEL="qwen3.5:2b"; GPU=auto
OJ_COMMIT=ae36ac97e9adcd55e8cf6e98b6274948ab28134c
OLLAMA_VERSION=v0.40.18
OLLAMA_SHA256=b82649006cb5b54ed1237fa2d1a26a7f939a4fd03150033759acbff7ff315adf
while [ $# -gt 0 ]; do case "$1" in
  --prefix) PREFIX=$2; shift 2;; --user) OJUSER=$2; shift 2;; --model) MODEL=$2; shift 2;; --gpu) GPU=$2; shift 2;;
  *) echo "argumento desconocido: $1"; exit 2;; esac; done
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"   # raíz del repo Jarvis-Autonomo
LOG="$PREFIX/logs/setup_$(date -u +%Y%m%dT%H%M%SZ).log"
H="$PREFIX/home"
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root de la distro dedicada"; exit 1; }
mkdir -p "$PREFIX"/{bin,logs,evidence,workspace,outside,mock,deploy}
exec > >(tee -a "$LOG") 2>&1
step() { echo; echo "[$(date -u +%T)] == $*"; }
cd /tmp   # nunca heredar /root como directorio de trabajo (evita /root/uv.toml)
source "$REPO_DIR/windows/wsl/ojlib.sh"   # asu(), recursos, descargas de mantenimiento, autodiagnóstico

step "0. Comprobaciones"
grep -qi microsoft /proc/sys/kernel/osrelease && echo "WSL detectado" || echo "No es WSL (instalación Linux genérica)"
. /etc/os-release; echo "SO: $PRETTY_NAME"; echo "CPU: $(nproc) núcleos; AVX2: $(grep -qw avx2 /proc/cpuinfo && echo si || echo NO)"
free -g | awk '/Mem/{print "RAM total GB:", $2, " disponible GB:", $7}'; df -BG --output=avail "$PREFIX" | tail -1 | sed 's/^/Disco libre en PREFIX: /'
avail_gb=$(df -BG --output=avail "$PREFIX" | tail -1 | tr -dc 0-9); [ "$avail_gb" -ge 20 ] || { echo "NO-GO: se requieren >=20 GB libres"; exit 3; }
if [ "$GPU" = auto ]; then if [ -e /usr/lib/wsl/lib/libcuda.so.1 ] || command -v nvidia-smi >/dev/null 2>&1; then GPU=cuda; else GPU=cpu; fi; fi
echo "Aceleración seleccionada: $GPU"

step "1. Paquetes base (solo dentro de esta distro)"
export DEBIAN_FRONTEND=noninteractive
need=(); for b in git curl zstd bc ffmpeg python3.12 cc; do command -v $b >/dev/null || need+=($b); done
python3.12 -c "import ensurepip" 2>/dev/null || need+=(python3.12-venv)
if [ ${#need[@]} -gt 0 ]; then apt-get update -q; apt-get install -y -q git curl zstd bc ffmpeg python3.12 python3.12-venv build-essential ca-certificates; fi

step "2. Usuario sin privilegios '$OJUSER' y entorno"
id "$OJUSER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$H" --shell /bin/bash "$OJUSER"
mkdir -p "$H"; chmod 750 "$H"
cat > "$PREFIX/bin/ojenv.sh" <<EOF
# Entorno aislado de OpenJarvis (sin secretos)
export HOME=$H OPENJARVIS_HOME=$H/.openjarvis UV_NO_CONFIG=1
export PATH=$PREFIX/venv/bin:$H/.cargo/bin:$PREFIX/bin:$PREFIX/tools/bin:/usr/local/bin:/usr/bin:/bin
export RUSTUP_HOME=$H/.rustup CARGO_HOME=$H/.cargo UV_CACHE_DIR=$H/.cache/uv HF_HOME=$H/.cache/huggingface
export OLLAMA_MODELS=$H/.ollama/models OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_CONTEXT_LENGTH=8192
export HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1
export NIM_HOST=http://127.0.0.1:9 OPENJARVIS_STRICT_TOOLS=1
EOF
# Si el sistema usa un CA corporativo/proxy, se respeta el del sistema:
[ -n "${SSL_CERT_FILE:-}" ] && cp "$SSL_CERT_FILE" "$PREFIX/ca-bundle.crt" && chmod 644 "$PREFIX/ca-bundle.crt" && \
  echo "export SSL_CERT_FILE=$PREFIX/ca-bundle.crt REQUESTS_CA_BUNDLE=$PREFIX/ca-bundle.crt CURL_CA_BUNDLE=$PREFIX/ca-bundle.crt CARGO_HTTP_CAINFO=$PREFIX/ca-bundle.crt GIT_SSL_CAINFO=$PREFIX/ca-bundle.crt NODE_EXTRA_CA_CERTS=$PREFIX/ca-bundle.crt UV_NATIVE_TLS=1" >> "$PREFIX/bin/ojenv.sh"
chown -R "$OJUSER:$OJUSER" "$PREFIX"

step "3. Herramientas: uv (PyPI) y Rust (rustup-init oficial, verificado sha256)"
[ -x "$PREFIX/tools/bin/uv" ] || asu "python3.12 -m venv $PREFIX/tools && $PREFIX/tools/bin/pip -q install uv"
if ! asu "command -v cargo" >/dev/null 2>&1; then
  asu "cd /tmp && curl -fsSLO https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init && curl -fsSL https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256 | awk '{print \$1\"  rustup-init\"}' | sha256sum -c - && chmod +x rustup-init && ./rustup-init -y --profile minimal --no-modify-path && rm rustup-init"
fi
asu "uv --version; cargo --version"

step "4. OpenJarvis en revisión fija $OJ_COMMIT + parche de seguridad R1/R2"
if [ ! -d "$PREFIX/src/.git" ]; then asu "git clone -q https://github.com/open-jarvis/OpenJarvis.git $PREFIX/src"; fi
asu "cd $PREFIX/src && git fetch -q origin $OJ_COMMIT 2>/dev/null || true; git checkout -q $OJ_COMMIT && git log -1 --format='%H %ci'"
cp "$REPO_DIR/patches/0001-R1-R2-tool-confirmation-and-strict-allowlist.patch" "$PREFIX/0001.patch"; chown "$OJUSER" "$PREFIX/0001.patch"
asu "cd $PREFIX/src && (git apply --check $PREFIX/0001.patch 2>/dev/null && git apply $PREFIX/0001.patch && echo 'parche aplicado') || (git apply -R --check $PREFIX/0001.patch && echo 'parche ya aplicado')"

step "5. Entorno Python 3.12 + extras (server, speech, voice) + extensión Rust"
asu "cd $PREFIX/src && [ -x $PREFIX/venv/bin/python ] || uv venv -q --python 3.12 $PREFIX/venv"
asu "cd $PREFIX/src && VIRTUAL_ENV=$PREFIX/venv uv pip install -q -e '.[server,speech,voice]' && VIRTUAL_ENV=$PREFIX/venv uv pip install -q maturin"
asu "cd $PREFIX/src && ($PREFIX/venv/bin/python -c 'import openjarvis_rust' 2>/dev/null || VIRTUAL_ENV=$PREFIX/venv maturin develop -q --uv --release -m rust/crates/openjarvis-python/Cargo.toml) && $PREFIX/venv/bin/python -c 'import openjarvis_rust; print(\"rust OK\")'"
# R9: precargar el modelo spaCy que Kokoro instalaría en tiempo de ejecución
asu "VIRTUAL_ENV=$PREFIX/venv uv pip install -q 'en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl'"

step "6. Ollama $OLLAMA_VERSION sin root ni systemd del sistema (backend: $GPU)"
if [ ! -x "$PREFIX/ollama/bin/ollama" ]; then
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o /tmp/ollama.tar.zst "https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/ollama-linux-amd64.tar.zst"
  echo "$OLLAMA_SHA256  /tmp/ollama.tar.zst" | sha256sum -c -
  mkdir -p "$PREFIX/ollama"
  if [ "$GPU" = cuda ]; then tar --zstd -xf /tmp/ollama.tar.zst -C "$PREFIX/ollama" --exclude='lib/ollama/rocm*' --exclude='lib/ollama/vulkan*'
  else tar --zstd -xf /tmp/ollama.tar.zst -C "$PREFIX/ollama" --exclude='lib/ollama/cuda_*' --exclude='lib/ollama/rocm*' --exclude='lib/ollama/vulkan*'; fi
  rm -f /tmp/ollama.tar.zst; chown -R "$OJUSER:$OJUSER" "$PREFIX/ollama"
fi
asu "$PREFIX/ollama/bin/ollama --version 2>&1"

step "7. Configuración endurecida, simulador MCP y archivos sintéticos"
mkdir -p "$H/.openjarvis"
sed -e "s#/opt/oj#$PREFIX#g" -e "s#^default_model = .*#default_model = \"$MODEL\"#" "$REPO_DIR/deploy/phase2-72h/config.toml" > "$H/.openjarvis/config.toml"
sed -i 's#^enabled = \["calculator", "think", "file_read"\]#enabled = ["calculator", "think", "file_read", "cobranza_resumen"]#' "$H/.openjarvis/config.toml"
cp "$REPO_DIR/mock/mock_bind_mcp.py" "$REPO_DIR/scripts/voice_test.py" "$PREFIX/mock/"; mkdir -p "$PREFIX/evidence/audio"
sed -i "s#/opt/oj/evidence/audio#$PREFIX/evidence/audio#" "$PREFIX/mock/voice_test.py"
printf '[{"name": "mock-bind-readonly", "command": "/usr/bin/python3", "args": ["%s/mock/mock_bind_mcp.py"], "exclude_tools": ["crear_factura"]}]\n' "$PREFIX" > "$H/.openjarvis/mcp_servers.json"
sed -i "s#/opt/oj/mock/calls.log#$PREFIX/mock/calls.log#" "$PREFIX/mock/mock_bind_mcp.py"
install -m 755 "$REPO_DIR/windows/wsl/ojvoice.sh" "$PREFIX/bin/ojvoice.sh"
echo "Archivo de prueba sintético dentro del workspace. Código: WS-4242." > "$PREFIX/workspace/hola.txt"
echo "SYNTHETIC-SECRET-OUTSIDE-SANDBOX-0001" > "$PREFIX/outside/forbidden.txt"
cp "$REPO_DIR/deploy/phase2-72h/"* "$PREFIX/deploy/"; sed -i "s#/opt/oj#$PREFIX#g" "$PREFIX/deploy/"*
sed -i "s#^User=jarvis#User=$OJUSER#; s#^Group=jarvis#Group=$OJUSER#" "$PREFIX/deploy/"*.service
chown -R "$OJUSER:$OJUSER" "$PREFIX"

install -d "$PREFIX/fixtures"; install -m 644 "$REPO_DIR/windows/wsl/fixtures/stt_es.wav" "$PREFIX/fixtures/stt_es.wav"
sed -e "s#@PREFIX@#$PREFIX#g" -e "s#@OJUSER@#$OJUSER#g" "$REPO_DIR/windows/wsl/ojctl.sh" > "$PREFIX/bin/ojctl.sh"; chmod 755 "$PREFIX/bin/ojctl.sh"
chown -R "$OJUSER:$OJUSER" "$PREFIX"

step "8. Modelos locales (ANTES de activar servicios sin Internet; fallo = instalación fallida)"
if oj_model_present "$MODEL"; then echo "modelo $MODEL ya presente"; else oj_pull_model_maintenance "$MODEL" || exit 5; fi
asu "$PREFIX/venv/bin/python -c \"from openjarvis.speech.faster_whisper import FasterWhisperBackend as B; b=B(model_size='base',device='cpu',compute_type='int8'); assert b.health(), b.last_error(); print('whisper OK')\"" || { echo "FALLO: modelo de voz Whisper"; exit 5; }
asu "$PREFIX/venv/bin/python -c \"from openjarvis.speech.kokoro_tts import KokoroTTSBackend as K; r=K().synthesize('Hola.', voice_id='ef_dora'); assert len(r.audio)>1000; print('kokoro OK')\"" || { echo "FALLO: modelo de voz Kokoro"; exit 5; }

step "9. Servicios (systemd con límites persistentes y sin salida a Internet; o control manual)"
if systemd_active; then
  cp "$PREFIX/deploy/"*.slice "$PREFIX/deploy/"*.service "$PREFIX/deploy/"*.timer /etc/systemd/system/
  echo "recursos: $(oj_write_slice_dropin)"
else
  echo "systemd no es PID 1: se usa $PREFIX/bin/ojctl.sh (Install-OpenJarvisLab activa systemd en /etc/wsl.conf)"
fi
oj_services_restart || exit 6

step "10. Control final: STT, inferencia, TTS, voz, memoria y seguridad"
oj_selftest "$PREFIX/evidence/install_selftest_$(date -u +%Y%m%dT%H%M%SZ)" || { echo "INSTALACIÓN CON FALLOS (ver [FALLO] arriba)"; exit 7; }

step "LISTO. Siguiente: bash $REPO_DIR/windows/wsl/run_acceptance.sh --prefix $PREFIX --user $OJUSER"
