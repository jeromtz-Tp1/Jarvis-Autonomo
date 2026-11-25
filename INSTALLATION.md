# INSTALLATION — OpenJarvis (entorno de pruebas aislado)

Procedimiento **ejecutado y verificado** el 2026-11-25 en un contenedor efímero Claude Code (Ubuntu 24.04.5, x86_64, 4 vCPU, 15 GiB RAM, sin GPU). Todos los comandos de este documento se ejecutaron; los que no se ejecutaron se marcan como tales.

## 1. Revisión fijada

| Elemento | Valor |
|---|---|
| Repositorio | https://github.com/open-jarvis/OpenJarvis (Apache-2.0) |
| Rama | `main` |
| Commit | `ae36ac97e9adcd55e8cf6e98b6274948ab28134c` (2026-11-24 06:11 UTC) |
| `git describe` | `v1.0.5.dev1374-7-gae36ac97` |
| Versión reportada | `jarvis, version 1.0.5.dev242+gae36ac97` |
| Python | 3.13.18 (requisito del proyecto: `>=3.11,<3.14`) |
| Ollama | 0.40.18 (binario oficial `ollama-linux-amd64.tar.zst`, solo backend CPU) |
| Modelos | `qwen3.5:2b` (2.7 GB, por defecto del instalador oficial), `qwen3.5:4b` (3.3 GB, recomendado por `jarvis init` para 15 GB RAM) |
| Voz | faster-whisper 1.2.1 (modelos `tiny`/`base`), kokoro 0.9.4 (`hexgrad/Kokoro-82M`) |
| Otros | torch 2.15.0, fastapi 0.165.0, ctranslate2 4.9.1, Rust 1.97.0 (extensión `openjarvis_rust`) |

## 2. Por qué no se usó el instalador `curl | bash`

Se inspeccionó `scripts/install/install.sh` (847 líneas) antes de ejecutarlo. Se descartó porque:
- ejecuta a su vez `curl -fsSL https://ollama.com/install.sh | sh` (instalación como root + servicio systemd);
- puede usar `sudo` para instalar paquetes del sistema;
- contiene un *beacon* de analítica a PostHog (desactivado por defecto si no hay TTY, pero evitable por completo).

Se siguió en su lugar el **procedimiento manual documentado** en `docs/getting-started/installation.md` (sección CLI: `uv sync` + `maturin develop`), equivalente y sin efectos fuera de `/opt/oj`.

## 3. Requisitos reales observados

| Recurso | Observado |
|---|---|
| Disco total entorno | **15 GB** (`venv` 6.4 GB — torch incluido; modelos Ollama 5.6 GB; Rust toolchain 0.6 GB; caché HF 0.6 GB; fuente 0.9 GB) |
| RAM | Runner `llama-server` con `qwen3.5:2b` ≈ **3.9–4.3 GB RSS**; servidor `jarvis serve` ≈ 0.5 GB; pico total ver T12 |
| CPU | 4 vCPU suficientes para 2B/4B (latencias 5–30 s por consulta con herramientas) |
| GPU | No requerida (no disponible) |
| Red (solo instalación) | PyPI, crates.io, `ollama.com`, `registry.ollama.ai`, `github.com`/`release-assets.githubusercontent.com`, `huggingface.co` + `us.aws.cdn.hf.co` |

## 4. Pasos (como root solo para crear el usuario y directorios; todo lo demás como `jarvis`)

```bash
# 4.1 Usuario sin privilegios y directorios aislados
useradd --system --create-home --home-dir /opt/oj/home --shell /bin/bash jarvis
mkdir -p /opt/oj/{bin,logs,evidence,workspace}
cp "$(command -v uv)" /opt/oj/bin/
cp -a ~/.rustup ~/.cargo /opt/oj/home/          # toolchain Rust para el usuario jarvis
cp <CA-bundle-del-proxy> /opt/oj/ca-bundle.crt   # solo en este entorno con proxy TLS
chown -R jarvis:jarvis /opt/oj && chmod 750 /opt/oj/home
# scripts/ojenv.sh -> /opt/oj/bin/ojenv.sh (HOME, PATH, caches, HF_HUB_DISABLE_XET=1, DO_NOT_TRACK=1)

# 4.2 Código en revisión fija
git clone https://github.com/open-jarvis/OpenJarvis.git /opt/oj/src
git -C /opt/oj/src checkout ae36ac97e9adcd55e8cf6e98b6274948ab28134c

# 4.3 Entorno Python + extras (como jarvis)
runuser -u jarvis -- bash -c 'source /opt/oj/bin/ojenv.sh; cd /opt/oj/src
  uv venv --python 3.13 /opt/oj/venv
  VIRTUAL_ENV=/opt/oj/venv uv pip install -e ".[server,speech,voice,dev,memory-bm25]"
  VIRTUAL_ENV=/opt/oj/venv maturin develop --uv --release -m rust/crates/openjarvis-python/Cargo.toml
  python -c "import openjarvis_rust"'          # ~3 min de compilación; imprescindible para memoria

# 4.4 Ollama sin root ni systemd (solo backend CPU: se excluyen cuda/rocm/vulkan -> 79 MB)
apt-get install -y zstd   # único paquete de sistema añadido (+ bc para el script T12)
curl -fsSL -o ollama.tar.zst https://ollama.com/download/ollama-linux-amd64.tar.zst
#   sha256 b82649006cb5b54ed1237fa2d1a26a7f939a4fd03150033759acbff7ff315adf (v0.40.18)
tar --zstd -xf ollama.tar.zst -C /opt/oj/ollama --exclude='lib/ollama/cuda_*' --exclude='lib/ollama/rocm*' --exclude='lib/ollama/vulkan*'
runuser -u jarvis -- bash -c 'source /opt/oj/bin/ojenv.sh; ollama serve & sleep 3; ollama pull qwen3.5:2b; ollama pull qwen3.5:4b'

# 4.5 Configuración
runuser -u jarvis -- bash -c 'source /opt/oj/bin/ojenv.sh; jarvis init --engine ollama --no-download --no-analytics --force --no-scan'
# luego sustituir por config/config.example.toml y config/mcp_servers.example.json
```

Nota: en la URL `ollama-linux-amd64.tgz` (citada por versiones antiguas de la documentación) ahora responde 404; la versión 0.40.x se distribuye como `.tar.zst`.

## 5. Configuración no sensible

- `config/config.example.toml` — motor Ollama en `127.0.0.1`, modelo `qwen3.5:2b`, agente `orchestrator`, herramientas `calculator, think, file_read, cobranza_resumen`, `security.mode = "block"`, `allowed_dirs = ["/opt/oj/workspace"]`, memoria y voz locales, analítica externa desactivada, skills desactivados.
- `config/mcp_servers.example.json` — servidor MCP **simulado** por stdio (`mock/mock_bind_mcp.py`), con la herramienta de escritura excluida.
- No hay secretos en ningún archivo versionado. No se usó `HF_TOKEN` ni claves de API.

## 6. Iniciar / detener / estado (solo entorno de pruebas)

```bash
/opt/oj/bin/ojctl.sh start      # ollama (127.0.0.1:11434) + jarvis serve (127.0.0.1:8000), como usuario jarvis
/opt/oj/bin/ojctl.sh status     # GET /health -> {"status":"ok"}
/opt/oj/bin/ojctl.sh stop
nohup /opt/oj/bin/ojwatchdog.sh >> /opt/oj/logs/watchdog.log 2>&1 &   # opcional: auto-reinicio
```

Uso: `runuser -u jarvis -- bash -c 'source /opt/oj/bin/ojenv.sh; jarvis ask "Hola"'`.
Importante: las tareas autónomas reales se ejecutan con **agentes gestionados** de `jarvis serve` (`POST /v1/managed-agents` con `schedule_type`), no con `jarvis scheduler start` (ver TEST_RESULTS T08).

## 7. Reversión / desinstalación completa

```bash
kill "$(cat /opt/oj/logs/watchdog.pid)" 2>/dev/null
/opt/oj/bin/ojctl.sh stop
pkill -u jarvis            # incluye runners llama-server huérfanos (ver T09)
userdel jarvis
rm -rf /opt/oj             # código, venv, modelos, datos, logs: todo vive aquí
apt-get remove -y zstd bc  # opcional
```

No se instalaron servicios systemd, cron, reglas de firewall, ni se modificaron archivos fuera de `/opt/oj` salvo los dos paquetes apt citados y el usuario `jarvis`. Además, el contenedor es efímero: se destruye al terminar la sesión.

## 8. Entorno de red de la sesión

Se creó el entorno personal de Claude Code **"Jarvis-Autonomo"** (sin costo) que añade a la lista de hosts permitidos únicamente los orígenes de descarga de modelos: `ollama.com`, `registry.ollama.ai`, el bucket R2 de Ollama, `release-assets/objects.githubusercontent.com`, `huggingface.co`, `us.aws.cdn.hf.co` y CDN LFS/Xet de HF. No se abrió ningún puerto de entrada; todos los servicios escuchan solo en loopback. El entorno "Default" no se modificó.
