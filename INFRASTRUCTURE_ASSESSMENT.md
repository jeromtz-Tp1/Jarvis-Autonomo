# INFRASTRUCTURE ASSESSMENT — Servidor OpenClaw (Fase 2A, solo lectura)

**Fecha:** 2026-11-25 · **Modo:** solo lectura · **Resultado global:** **BLOCKED — sin acceso al servidor**. No se pudo inspeccionar el servidor de OpenClaw. Este documento deja (1) la evidencia de qué se buscó y dónde, (2) el acceso exacto que se necesita, (3) la herramienta de inventario lista y probada, y (4) los criterios para decidir con los datos en cuanto se obtengan. No se inventó ningún dato del servidor.

## 1. Proveedor, servidor y mecanismo de acceso — qué se verificó

| Fuente revisada (solo lectura) | Resultado |
|---|---|
| Equipos conectados a esta sesión (Remote Control) | Ninguno (`folders: []`) |
| Entornos de Claude Code del usuario | 4 entornos, todos `anthropic_cloud` (Default, Jarvis-Autonomo, API de prefacturas BIND, TP1-BIND-AUDITORIA.). Ninguno autoalojado (`ccpool_`) ni asociado a OpenClaw |
| Repositorios GitHub del usuario (9) — búsqueda de código | 0 referencias a OpenClaw/Clawdbot/Moltbot fuera de este repo; 0 referencias a Hetzner, DigitalOcean, Lightsail, Contabo, Hostinger, Vultr, Linode, Tailscale, docker-compose, systemctl |
| Google Drive | Solo una guía de terceros ("Guía JARVIS con Hermes Agent", compartida por una consultora); ningún documento del servidor |
| Vercel (equipo "Jeronimo Mtz's projects") | Proyectos `tp-1-wms` y `tp-1-log`; nada de OpenClaw |
| Credenciales locales (`~/.ssh`, variables) | Ninguna. No se buscaron ni leyeron secretos |

**Conclusión:** proveedor, servidor y mecanismo de acceso **no identificables** desde esta sesión. No hay un mecanismo de acceso autorizado configurado.

## 2. Acceso exacto que se necesita (elegir uno)

| Opción | Qué hace Jerónimo | Qué obtiene Claudito | Riesgo | Recomendación |
|---|---|---|---|---|
| **A. Inventario manual** | En el servidor, como usuario normal (sin sudo): ejecutar `bash scripts/openclaw_readonly_inventory.sh`, revisar `/tmp/oc_inventory_*.txt` y pegar su contenido aquí (o subirlo al repo) | Todos los datos de la sección 3 | Mínimo: no se abre ningún acceso nuevo | **Recomendada para 2A** |
| B. Remote Control de Claude Code | En el servidor: `claude remote-control` dentro de una carpeta dedicada vacía (p. ej. `~/jarvis-assessment`), con un usuario sin sudo. La carpeta aparecerá en esta sesión y se aprueba la conexión | Ejecución directa del inventario y verificaciones | Medio: es acceso remoto nuevo (saliente, sin puertos abiertos) con los permisos de ese usuario. La autorización del punto 3 de la misión lo exige explícito | Solo si Jerónimo lo autoriza expresamente |
| C. SSH | No viable: esta sesión no tiene salida SSH a hosts arbitrarios y no deben pegarse claves en el chat | — | — | No usar |

Datos mínimos que Jerónimo puede aportar sin ejecutar nada: proveedor y plan contratado (vCPU/RAM/disco), sistema operativo, si OpenClaw corre en Docker o como servicio systemd, y si el servidor tiene IP pública con puertos abiertos.

## 3. Herramienta de inventario (lista y probada)

`scripts/openclaw_readonly_inventory.sh` — probado en el contenedor de pruebas como usuario sin privilegios (152–159 líneas de salida, ~15 s).
- **No** instala, **no** usa sudo, **no** lee `.env`, configuraciones, claves ni variables de entorno de procesos; no modifica servicios; solo se conecta a `127.0.0.1` para comprobar puertos ya abiertos.
- Redacta patrones `key=`, `token`, `password`, `sk-…`, `ghp_…`, `hf_…`, `AKIA…` en líneas de comando (verificado con una cadena de prueba).
- No depende de `ss`, `netstat` ni `gawk`: lee `/proc/net/tcp*` en bash puro (se corrigieron dos defectos detectados al probarlo: autodetección de `pgrep` e incompatibilidad con `mawk`).
- Recoge: proveedor/virtualización (DMI, `systemd-detect-virt`, `cloud-id`), SO y kernel, CPU y AVX2/AVX-512, carga y `vmstat`, GPU, RAM y swap, presión PSI, disco e inodos, cgroups v1/v2, top de procesos por RAM/CPU, servicios systemd en ejecución/fallidos/de usuario, timers, cron del usuario (redactado), puertos en escucha y su alcance (loopback vs. todas las interfaces), Docker (versión, contenedores, uso), procesos/versión/puertos de OpenClaw (el contenido de `~/.openclaw` **no** se lee), modelos Ollama existentes, opciones clave de `sshd`, fail2ban, actualizaciones automáticas y reinicio pendiente.

## 4. ¿Podemos alojar OpenJarvis sin afectar a OpenClaw? — criterios de decisión

Requisitos **medidos** en Fase 1 (no estimados):

| Recurso | Consumo medido de OpenJarvis | Fuente |
|---|---|---|
| RAM runner modelo 2B | 3.5 GB (contexto 4–8k) – 4.3 GB (contexto 16k por defecto) | `evidence/phase2/P2_ollama_ctx_sizing.log`, T12 |
| RAM servidor `jarvis serve` | 515–519 MB estable en 31.5 min | T12 |
| RAM voz (Whisper base + Kokoro, carga perezosa) | ~0.5–1 GB adicional cuando se usa | T06/T07 (estimación sobre pico observado) |
| CPU | 2 vCPU bastan para 1 petición a la vez (latencia 5–8 s en 4 vCPU; ~doble con cuota 200 %, estimado) | T12 |
| Disco | 15 GB (venv 6.4, modelos 5.6 con 2B+4B; ~12 GB solo con 2B) | INSTALLATION |
| Red | Ninguna salida necesaria en operación (modelos precargados, `HF_HUB_OFFLINE=1`) | Fase 2 |

**Regla GO para alojar en el servidor de OpenClaw** (aplicar a los datos del inventario):

| Criterio | GO | NO-GO |
|---|---|---|
| `MemAvailable` en el momento de menor holgura | ≥ 10 GB (7 GB tope de OpenJarvis + 3 GB de reserva para OpenClaw) | < 8 GB |
| vCPU | ≥ 4 y carga media (`loadavg` 15 min) < 50 % de los núcleos | ≤ 2 vCPU o carga sostenida > 70 % |
| Disco libre en la partición de `/opt` | ≥ 25 GB | < 15 GB |
| Presión de memoria PSI `some avg60` | < 1 % | > 5 % |
| cgroups v2 + systemd | Sí (permite `MemoryMax`/`CPUQuota` por slice) | No → solo Docker con `mem_limit` o NO-GO |
| Swap | Indiferente (la slice usa `MemorySwapMax=0`) | — |
| Puertos 8000 y 11434 | Libres | Ocupados → cambiar puertos |
| Exposición actual | OpenClaw sin puertos públicos innecesarios | Puertos administrativos expuestos sin firewall → corregir antes (fuera de alcance de 2A) |

Si el servidor no cumple, alternativa sin tocar OpenClaw: VPS dedicado de 8 vCPU/16 GB (gasto → requiere autorización) o un equipo propio de Jerónimo conectado por Remote Control.

## 5. Evaluación de aislamiento, persistencia, supervisión, límites y red (diseño para cualquier host Linux con systemd)

| Aspecto | Propuesta (ver `deploy/phase2-72h/`) | Validación realizada |
|---|---|---|
| Aislamiento | Usuario `jarvis` sin sudo; todo en `/opt/oj`; `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp`, `NoNewPrivileges`, `CapabilityBoundingSet=` vacío; `allowed_dirs=/opt/oj/workspace` | Usuario/directorios/allowed_dirs probados en Fase 1; sintaxis de unidades verificada con `systemd-analyze verify` (sin systemd PID 1 en el contenedor: **no** se pudo probar en ejecución) |
| Persistencia | Datos en `/opt/oj/home/.openjarvis` (JSONL + SQLite WAL); sobrevive reinicios | T03, T09 PASS |
| Supervisión | `Restart=always`, `KillMode=control-group` (evita runners huérfanos R7), `StartLimitBurst`; timer de 60 s que registra salud/recursos en CSV | Watchdog equivalente probado en T09 |
| Límites de recursos | `openjarvis.slice`: `MemoryHigh=6G`, `MemoryMax=7G`, `MemorySwapMax=0`, `CPUQuota=200%`, `CPUWeight=50`, `TasksMax=512`; Ollama `NUM_PARALLEL=1`, `MAX_LOADED_MODELS=1` | Medición de RAM por contexto realizada |
| Red | Escucha solo en `127.0.0.1`; egreso limitado a loopback con `IPAddressDeny=any`/`IPAddressAllow=localhost`; `NIM_HOST` local (R8); `HF_HUB_OFFLINE=1` | Loopback verificado (T12 + inventario); mitigación R8 verificada |
| Coexistencia con OpenClaw | Slice con peso CPU/IO bajo (50) para ceder ante OpenClaw; sin puertos compartidos; sin acceso a `~/.openclaw` (otro usuario, `ProtectHome`) | Pendiente de datos del servidor |

## 6. Pendiente para cerrar 2A

1. Obtener el informe del inventario (opción A) o la autorización explícita para la opción B.
2. Aplicar la regla GO/NO-GO de la sección 4 y ajustar `MemoryMax`/`CPUQuota` de `openjarvis.slice` a los valores reales.
3. Confirmar que OpenClaw no usa los puertos 8000/11434 y qué usuario lo ejecuta.
