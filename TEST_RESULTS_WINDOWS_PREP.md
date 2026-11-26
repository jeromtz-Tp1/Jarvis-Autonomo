# TEST RESULTS — Validación del instalador local (preparación Windows/WSL2)

**Fecha:** 2026-11-25 (UTC) · **Qué se probó:** `windows/wsl/setup_lab.sh` y `windows/wsl/run_acceptance.sh`, que son exactamente lo que `Install-OpenJarvisLab.ps1` ejecuta dentro de la distro WSL. Se usó una instalación **desde cero** en Ubuntu 24.04 (la misma base que la distro WSL) con prefijo nuevo `/opt/ojlab` y usuario nuevo `ojlab`.
**Qué NO se probó:** la PC de Jerónimo (sin acceso desde esta sesión) ni los `.ps1` en Windows.

## Instalador `setup_lab.sh`

| Ejecución | Resultado | Causa / corrección |
|---|---|---|
| 1 | Error en el paso 4 (`git clone`, certificado) | Propio de este contenedor (CA del proxy ilegible para el usuario sin privilegios). Corregido: si existe un CA de sistema/corporativo, se propaga también a `GIT_SSL_CAINFO`. |
| 2 | Error en el paso 6 (corte de conexión al descargar Ollama, 1.6 GB) | Fallo de red transitorio. Corregido: `curl --retry 5 --retry-all-errors -C -` (reintenta y reanuda). |
| 3 | OK, pero la precarga de voz falló sin que el script lo advirtiera | Orden del `PATH` (el Python de herramientas iba antes que el del venv). Corregido, y la precarga de voz ahora falla de forma visible. |
| 4 | **OK (exit 0)**: `rust OK`, `whisper OK`, `kokoro OK`, servicios sanos | Instalación completa en ~6 min con caché; idempotente (relanzarlo salta lo ya hecho). |

Comprobado también:
- el parche R1/R2 se aplica sobre la revisión fija `ae36ac97`;
- Rust se instala con `rustup-init` verificado por SHA256;
- Ollama v0.40.18 se descarga verificado por SHA256;
- el modelo spaCy queda precargado (R9).

## Aceptación `run_acceptance.sh` (veredicto automático)

Ejecución definitiva: 2026-11-25 19:46:31 → 20:23:08 UTC. Evidencia: `evidence/windows_prep/`.

| ID | Resultado | Evidencia |
|---|---|---|
| T01 | **PASS** | `/health` ok; `jarvis doctor`: 14 OK, 0 fallos |
| T02 | **PASS** | Inferencia local real: `PARIS` |
| T03 | **PASS** | Dato sintético recordado tras reiniciar los servicios: `ZX-9931` |
| T04 | **PASS** | `calculator` 12345×6789 = 83810205 |
| T05 | **PASS** | MCP simulado de solo lectura: total 173300.5; `crear_factura` nunca invocada |
| T06 | **PASS** | STT: "Hola Harbys, el reporte de cobranza de prueba está listo." (único error: el nombre propio) |
| T07 | **PASS** | 2 WAV generados por Kokoro; inteligibilidad verificada por STT |
| T08 | **PASS** | 2 ejecuciones autónomas (19:49:54, 19:50:54), ambas con resultado de herramienta 42 y texto HEARTBEAT |
| T09 | **PASS** | `kill -9` del servidor → recuperado, memoria intacta, 0 runners huérfanos |
| T10 | **PASS** | Lectura fuera de `allowed_dirs` denegada |
| T11 | **PASS** | Inyección indirecta sin acciones; `shell_exec` bloqueado (allowlist estricta + confirmación) |
| T12 | **PASS** | 30 min: 28/28 respuestas correctas; latencia media ~7 s; servidor 943→944 MB (estable) |

### Incidencias de la ejecución previa (registradas, no ocultadas)

- **T08 FAIL en la primera ejecución**: el agente se ejecutó solo 2 veces y la calculadora devolvió 42.0, pero el modelo respondió `HEARTBEAT=<42.0>` y en otra ejecución agotó los turnos. El fallo estaba en mi criterio, que comparaba texto exacto. Se cambió a un criterio objetivo (resultado de la herramienta + ejecuciones con marca de tiempo) y se reformuló la instrucción. Evidencia: `evidence/windows_prep/first_run_T01-T11_before_T08_fix.log`.
- **La primera batería terminó con error de sintaxis tras T12** porque edité el script mientras corría (bash lee el archivo por partes). Además, el agente de T08 quedó sin pausar y contaminó las métricas de T12. Corregido: el script pausa el agente justo después de T08, y la ejecución definitiva se lanzó desde una copia congelada.

### Observación de memoria (para la prueba larga)

RAM del runner del modelo: 4177 → 4645 MB en 30 min (+470 MB); el servidor se mantuvo plano (943 → 944 MB). Lo más probable es que sea la caché de contexto de llama.cpp, acotada por `OLLAMA_CONTEXT_LENGTH=8192`. No se pudo confirmar que se estabilice en 30 min. En la PC queda acotado por la slice (`MemoryMax=7G`), y la prueba de 72 h debe confirmar la meseta.

## 2026-11-26 — Instalación desde copia local (sin clonar nuestro repositorio) + voz conversacional

Corrección pedida por Jarvis: `Install-OpenJarvisLab.ps1` ya no ejecuta `git clone` de `Jarvis-Autonomo` desde WSL.
- Empaqueta los entregables locales (ZIP descomprimido) con `tar.exe` de Windows y los pasa a la distro por stdin (redirección binaria de `cmd`). Si eso falla, copia por `\\wsl.localhost`.
- Normaliza los finales de línea y verifica los 15 archivos contra `windows/BUNDLE_MANIFEST.sha256`.
- Sin credenciales en WSL. La única descarga de GitHub es OpenJarvis oficial (público) y sus dependencias públicas.

Simulación del peor caso de Windows (todos los archivos convertidos a CRLF, transferidos como `.tar` por stdin):

| Comprobación | Resultado |
|---|---|
| Verificación SHA256 antes de normalizar | Falla (14 de 14 sumas no coinciden): el control detecta el CRLF |
| Tras normalizar (comando exacto del `.ps1`) | **15/15 OK** — "entregables verificados (SHA256)" |
| Archivo manipulado | Detectado ("1 computed checksum did NOT match") |
| Dependencia de nuestro repo en los scripts | Ninguna (`grep` sin coincidencias) |

Batería desde la copia local (`/root/oj-bundle`), 2026-11-26 01:01–01:12 UTC. Evidencia: `evidence/windows_local_bundle/`.

| ID | Resultado | Evidencia |
|---|---|---|
| T01–T11 | **PASS** (11/11) | Igual que la ejecución del 25-nov; T08: 2 ejecuciones autónomas con resultado 42 |
| T12 | **PASS** | 3 min, 3/3 (los 30 min ya se validaron el 25-nov: 28/28) |
| **T13 (nuevo)** | **PASS** | Conversación por voz de extremo a extremo con la misma ruta que `Talk-Jarvis.ps1`. Pregunta hablada → transcripción "¿cuál es el código interno de mi proyecto ficticio al con 7?" → JARVIS: "El código interno de tu proyecto ficticio Halcon-7 es ZX-9931." (memoria persistente) → respuesta sintetizada y retranscrita: "…Al-Consiete Seta X 9.931" |

Hallazgos:
- **Whisper `base` deforma los nombres propios** ("Jarvis"→"Harbys", "Halcón siete"→"al con 7"), aunque la memoria compensó en este caso. Opción si molesta en uso real: modelo `small` (más preciso, más RAM y más lento).
- **Kokoro pronuncia "ZX-9931" de forma poco clara** al leer códigos alfanuméricos.
- **Memoria con voz activa: ~6.1 GB** (servidor 1.8 GB con Whisper+Kokoro cargados). Se subió la slice a `MemoryHigh=7G` / `MemoryMax=7.5G`. En una PC de 16 GB, WSL dispone de 8 GB por defecto: suficiente, pero conviene cerrar aplicaciones pesadas.
- `Talk-Jarvis.ps1` (grabación con `winmm` y reproducción con `SoundPlayer`) **no se ejecutó** en Windows. La ruta Linux que usa (`ojvoice.sh`) sí está validada por T13.

## 2026-11-26 — Validación de la reparación consolidada (Repair-OpenJarvisLab)

Evidencia: `evidence/repair_validation/`. Parte Linux ejecutada en Ubuntu 24.04 (base de la distro WSL); los `.ps1` revisados línea a línea y con codificación verificada (BOM UTF-8, CRLF), **no ejecutados** en Windows.

| Defecto reproducido | Antes | Después |
|---|---|---|
| `/root/uv.toml` (cwd `/root`) | `error: failed to open file /root/uv.toml: Permission denied` | `asu` nuevo: `uv pip list` correcto |
| Descarga fallida con `\| tail -1` | **código 0** (éxito falso) | `[FALLO] descarga… (código 1)`; Ollama temporal apagado |
| Descarga real por la vía de mantenimiento | — | `qwen3:0.6b` descargado y verificado por manifiesto (luego borrado) |
| Instalador con descarga fallida | informaba éxito | **sale con código 5** |
| Errores HTTP en `ojvoice.sh` (servidor falso) | `JSONDecodeError` | servidor caído → 10; STT 500 → 11 con cuerpo; chat 502 HTML → 12 con cuerpo; TTS 501 → 13; sin audio → 2 |
| Instalación degradada (servicios caídos, scripts antiguos, `mode=warn`, sin `wsl.conf`) | — | Pasada 1: corrige `wsl.conf` y `mode=block` y espera el reinicio; pasada 2: servicios activos y **autodiagnóstico 0 fallos** |
| Configuración con modelo inexistente | — | Detectado; vuelve al modelo instalado sin descargar; **0 fallos** |

Autodiagnóstico final:
- inferencia 42 en 16 s;
- STT "…el reporte de cobranza de prueba está listo";
- TTS WAV de 88 KB;
- voz de extremo a extremo con memoria (ZX-9931);
- 80 hechos de memoria en disco;
- solo loopback, allowlist estricta y modo `block`.

No verificable en este contenedor (sin systemd como PID 1): el arranque de las unidades con la slice, `IPAddressDeny` en ejecución y la tarea programada de Windows. La sintaxis de las unidades y del drop-in de recursos sí se validó con `systemd-analyze verify`. Todo eso lo comprueba `Repair-OpenJarvisLab.ps1` en la PC, y aparecerá como `[FALLO]` si no funciona.
