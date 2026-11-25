# PHASE 2 PLAN — Prueba continua de 72 h y corrección de R1–R12

**Fecha:** 2026-11-25 · **Estado:** listo para ejecutar en cuanto se cumpla la condición de acceso/capacidad de `INFRASTRUCTURE_ASSESSMENT.md`. BIND no se conecta en esta fase. Gasto: USD 0 si se usa el servidor existente.

## 1. Fases

| Fase | Contenido | Precondición | Estado |
|---|---|---|---|
| 2A | Inspección de solo lectura del servidor OpenClaw | Acceso (opción A o B) | **BLOCKED** (sin acceso); herramientas listas |
| 2B | Instalación aislada + prueba de 72 h en el host elegido | GO de la regla de capacidad + autorización de instalación | Configuración lista y validada en la medida posible |
| 2C | Broker MCP OAuth 2.1/PKCE de solo lectura contra un entorno de **pruebas** de BIND | 2B superada + autorización explícita | Diseño (ARCHITECTURE §4) |

## 2. Configuración propuesta para la prueba de 72 h (`deploy/phase2-72h/`)

| Archivo | Función |
|---|---|
| `openjarvis.slice` | Presupuesto total: `MemoryHigh=6G`, `MemoryMax=7G`, sin swap, `CPUQuota=200%`, peso CPU/IO 50 |
| `ojl-ollama.service` | Ollama como `jarvis`, solo loopback, `Restart=always`, `KillMode=control-group`, endurecimiento systemd, egreso solo localhost |
| `ojl-server.service` | `jarvis serve` en `127.0.0.1:8000` con agentes gestionados, mismo endurecimiento |
| `ojl-monitor.service` + `.timer` | Cada 60 s: salud y latencia de `/health`, RAM/CPU de la slice, `MemAvailable` del host, PSI, reinicios, agentes en error, disco libre → `/opt/oj/logs/trial72h.csv` |
| `ojl_monitor.sh` | Script del monitor (solo lectura + append) |
| `ojl.env` | Variables sin secretos: Ollama limitado (`NUM_PARALLEL=1`, `MAX_LOADED_MODELS=1`, ctx 8192), `HF_HUB_OFFLINE=1`, `NIM_HOST` local, `OPENJARVIS_STRICT_TOOLS=1` |
| `config.toml` | Modelo 2B, agente `orchestrator`, herramientas mínimas, `mode=block`, `allowed_dirs`, TaskScheduler desactivado, analítica off (validado con `load_config` de OpenJarvis) |
| `agents_72h.json` | 2 agentes gestionados: `trial-heartbeat` (cada 15 min, sin MCP) y `trial-mock-cobranza` (cron cada 4 h, MCP **simulado**), con `max_total_tokens` |
| `../../patches/0001-…patch` | R1 + R2 (validado) |

### Procedimiento (resumen; requiere autorización de instalación en el host)
1. Crear usuario `jarvis` y `/opt/oj`; instalar según `INSTALLATION.md` con la revisión `ae36ac97` + `patches/0001`.
2. Precargar modelos (`qwen3.5:2b`, Whisper `base`, Kokoro y `en-core-web-sm`) **antes** de cortar el egreso.
3. Copiar `deploy/phase2-72h/*` a `/opt/oj/deploy/`, las unidades a `/etc/systemd/system/`, `systemctl daemon-reload`, `systemctl enable --now ojl-ollama ojl-server ojl-monitor.timer`.
4. Crear los agentes: `POST /v1/managed-agents` con cada objeto de `agents_72h.json`.
5. Línea base de OpenClaw (inventario) antes, a las 24 h y al final.

### Parada inmediata (kill-switch) y reversión
- Parada: `systemctl stop openjarvis.slice` (detiene todo el árbol de procesos de golpe) o `POST /v1/managed-agents/{id}/pause`.
- Reversión: `systemctl disable --now ojl-ollama ojl-server ojl-monitor.timer`, borrar las unidades, `userdel jarvis`, `rm -rf /opt/oj`. OpenClaw no se toca en ningún paso.

### Criterios de aceptación de las 72 h

| Métrica | Criterio PASS |
|---|---|
| Disponibilidad `/health` (muestras cada 60 s) | ≥ 99.5 % (≤ 21 muestras fallidas de 4 320) |
| Ejecuciones de `trial-heartbeat` | ≥ 280 de 288 esperadas, 100 % con `HEARTBEAT=42` |
| Ejecuciones de `trial-mock-cobranza` | 18 de 18, totales iguales a los del simulador |
| Memoria de la slice | Nunca alcanza `MemoryMax` (0 OOM kills); tendencia sin crecimiento > 10 % entre hora 6 y hora 72 |
| Impacto en OpenClaw | Sin reinicios ni errores nuevos de OpenClaw; `MemAvailable` del host ≥ 3 GB en todo momento; PSI memoria `avg60` < 5 % |
| Seguridad | 0 conexiones salientes fuera de loopback (bloqueadas por systemd y registradas); 0 herramientas fuera de la allowlist |
| Recuperación | Una prueba de `kill -9` controlada a las ~36 h: servicio sano en < 60 s, sin procesos huérfanos |

Nota: 72 h de PASS sustentan un piloto, **no** demuestran disponibilidad 24/7 en producción.

## 3. Resolución de hallazgos R1–R12

Estado: **Validado** = corrección probada en el entorno de pruebas con evidencia · **Configurado** = control incluido en la configuración de 72 h, no probado en ejecución · **Diseño** = requiere construcción o upstream.

| ID | Hallazgo | Resolución | Estado | Evidencia |
|---|---|---|---|---|
| R1 | `jarvis ask` auto-aprueba herramientas sensibles | `patches/0001`: `ask.py` respeta `enforce_tool_confirmation`; TTY → pregunta al humano; sin TTY → deniega. Reportar upstream | **Validado**: `shell_exec` → "execution denied by user" ×3, 0 ejecuciones | `evidence/phase2/P2_R1_full.json` |
| R2 | `--tools` anula la allowlist | `patches/0001`: con `OPENJARVIS_STRICT_TOOLS=1` la CLI solo puede reducir la lista de `config.toml` | **Validado**: `--tools shell_exec,calculator` → solo `calculator` | `P2_R1_R2_R8_validation.log` |
| R3 | `shell_exec` sin aislamiento | No habilitar shell/code/`file_write`/`git`/`http_request` en agentes. Si algún día se necesita: contenedor efímero sin red y sin montajes, solo tras aprobación | **Configurado** (allowlist + R1/R2) | `config.toml` |
| R4 | Lista de herramientas de agente no limita MCP | `"mcp_tools": false` en agentes sin necesidad de MCP; en los que sí, `include_tools` en `mcp_servers.json` | **Validado**: 0 llamadas MCP (antes 3/4) | `P2_R4_validation.log` |
| R5 | Cliente MCP sin OAuth 2.1/PKCE | Broker MCP propio (Fase 2C) que hace OAuth+PKCE, guarda/refresca tokens en un almacén de secretos y expone a OpenJarvis solo lectura en loopback con token local de corta vida | **Diseño** | ARCHITECTURE §4 |
| R6 | El escáner no detecta inyección indirecta | Defensa estructural (sin herramientas de escritura), `mode=block`, aprobación humana para cualquier acción, delimitar contenido no confiable en prompts; medir con un set de inyecciones en la prueba de 72 h | **Configurado** | — |
| R7 | Sin límites de RAM; runner huérfano | Slice con `MemoryMax`, `KillMode=control-group`, Ollama `NUM_PARALLEL=1`/`MAX_LOADED_MODELS=1` | **Configurado** (dimensionado con medición real) | `P2_ollama_ctx_sizing.log` |
| R8 | Sondeo a `integrate.api.nvidia.com` | `NIM_HOST=http://127.0.0.1:9` + egreso solo localhost | **Validado**: sin intentos de conexión al host externo tras el cambio (el proxy no registró ninguno) | `P2_R1_R2_R8_validation.log` |
| R9 | Kokoro instala spaCy en runtime | Precargar `en-core-web-sm` en la instalación; venv no escribible por el servicio; `HF_HUB_OFFLINE=1` | **Configurado** | `ojl-server.service` |
| R10 | `jarvis scheduler` registra dry-run como éxito | No usar TaskScheduler (`[scheduler] enabled=false`); usar agentes gestionados; reportar upstream | **Validado** en Fase 1 (los agentes gestionados ejecutan realmente) | T08 |
| R11 | Hechos de memoria espurios | Revisión periódica de `jarvis memory list`; para datos empresariales, solo hechos promovidos manualmente (`memory trust`); almacenes separados por identidad | **Diseño** | — |
| R12 | API sin autenticación | Mantener `127.0.0.1`; si se expone, solo detrás del gateway con `jarvis auth` + TLS | **Configurado** | `config.toml` |

## 4. Riesgos de la fase 2

- El servidor de OpenClaw puede no tener 10 GB libres → plan B: VPS dedicado (requiere autorización de gasto) o un equipo de Jerónimo.
- `IPAddressDeny` y el resto del endurecimiento de systemd no se pudieron probar en ejecución (sin systemd PID 1 en el contenedor); se verificarán en el host en las primeras 2 h de la prueba.
- Los parches son locales; una actualización de OpenJarvis los revertiría → mantener la revisión fijada y proponer los cambios upstream.
