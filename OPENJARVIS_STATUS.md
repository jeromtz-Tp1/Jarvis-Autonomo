# OPENJARVIS STATUS — Resumen ejecutivo

**Fecha:** 2026-11-25 · **Responsable técnico:** Claude Code · **Para:** Jerónimo Martínez / Jarvis

## Veredicto

**OpenJarvis quedó instalado y ejecutándose realmente: SÍ**, en un entorno de pruebas aislado y efímero.
**Recomendación: GO condicionado** — continuar con OpenJarvis como *motor local* (inferencia, voz, memoria, agentes programados) **dentro** de una capa de control propia. **NO-GO** para conectarlo directamente a BIND/ERP o para uso autónomo con herramientas de escritura/shell en esta revisión.

## Versión probada

| | |
|---|---|
| Repositorio | `open-jarvis/OpenJarvis`, rama `main`, licencia Apache-2.0 |
| Commit | `ae36ac97e9adcd55e8cf6e98b6274948ab28134c` (2026-11-24) — `jarvis 1.0.5.dev242+gae36ac97` |
| Motor / modelos | Ollama 0.40.18 (CPU) · `qwen3.5:2b` y `qwen3.5:4b` |
| Voz | faster-whisper 1.2.1 (STT) · Kokoro 0.9.4 (TTS) |

## Infraestructura

- Contenedor cloud efímero de Claude Code: Ubuntu 24.04, 4 vCPU, 15 GiB RAM, sin GPU, sin Docker.
- Instalación en `/opt/oj`, usuario sin privilegios `jarvis`, servicios solo en `127.0.0.1` (API :8000, Ollama :11434).
- Entorno de red personal "Jarvis-Autonomo" con allowlist mínima para descargar modelos. Sin puertos públicos.
- **Servidor OpenClaw: BLOCKED** — no hay host, credenciales ni equipo conectado accesible desde esta sesión; no se tocó.

## Resultados (12 pruebas de aceptación)

| PASS | PASS con condición | NOT SUPPORTED | BLOCKED |
|---|---|---|---|
| T01 instalación, T02 inferencia local real, T03 memoria tras reinicio, T04 herramientas, T05 MCP simulado, T06 STT, T07 TTS, T12 estabilidad 31.5 min | T08 programación (solo vía agentes gestionados; `jarvis scheduler` = dry-run → FAIL), T09 recuperación (requiere supervisor externo), T10 permisos (archivos sí; shell no aislado), T11 inyección (PASS endurecido; FAIL si se concede `shell_exec`) | OAuth 2.1 + PKCE en el cliente MCP | OpenClaw (sin acceso); sandbox Docker (sin daemon) |

Pruebas oficiales: 5577 pasan, 16 fallan (4 por defecto real BM25; 12 por entorno). Detalle en `TEST_RESULTS.md`.

## Hallazgos que condicionan la decisión

1. `jarvis ask` auto-aprueba herramientas peligrosas y `--tools` anula la configuración → con `shell_exec` el modelo ejecutó código arbitrario bajo inyección (R1–R3).
2. El cliente MCP no soporta OAuth 2.1/PKCE → BIND necesita un broker OAuth intermedio (R5).
3. La lista de herramientas de un agente no limita las herramientas MCP (R4).
4. Sin supervisor/límites de memoria nativos en Linux sin systemd: OOM y runner huérfano observados (R7).
5. Positivo: inferencia, voz y memoria 100 % locales, sin costo por token; estabilidad de 31.5 min sin errores ni fugas; límite de tokens por agente funciona (`budget_exceeded`).

## Costos y recursos

- **Costo generado: USD 0** (contenedor incluido en la suscripción; sin APIs de pago, sin servicios contratados).
- Recursos: ~15 GB de disco; RAM en uso estable ~4.4–4.9 GB (modelo 2B); CPU 4 vCPU; ~6 GB de descargas (modelos + dependencias).

## Cumplimiento de límites

- Producción modificada: **NO**. BIND, Supabase, Vercel, DNS, redes y repositorios de TP1: **no tocados**.
- Credenciales reales: **NO** usadas. Sin `HF_TOKEN`, sin claves de API. Tokens del simulador son ficticios.
- Privilegios: root solo para crear el usuario `jarvis`/directorios e instalar `zstd` y `bc` en el contenedor efímero. Analítica externa desactivada.

## Siguiente paso concreto

Desplegar un piloto en un servidor propio (o el de OpenClaw si tiene ≥16 GB RAM libres y ~15 GB disco) con systemd (`MemoryMax`, reinicio, `KillMode=control-group`), y construir el **broker MCP OAuth 2.1/PKCE de solo lectura** para BIND; validar primero contra el entorno de pruebas de BIND (no producción) el reporte de cobranza/CxP/gastos con aprobación humana antes de cualquier envío.

## Entregables

`OPENJARVIS_STATUS.md` · `INSTALLATION.md` · `TEST_RESULTS.md` · `SECURITY_REVIEW.md` · `ARCHITECTURE.md` · `config/` (ejemplo sin secretos) · `scripts/` (entorno, control, watchdog, pruebas) · `mock/` (servidor MCP simulado) · `evidence/` (registros sanitizados, audio, T12).
