# ARCHITECTURE — JARVIS Personal & Business (propuesta basada en resultados reales)

Base empírica: pruebas T01–T12 sobre OpenJarvis `ae36ac97` (ver `TEST_RESULTS.md`). Lo que aquí se marca como "probado" se ejecutó; lo demás es diseño.

## 1. Principio rector

OpenJarvis demostró ser un **buen motor local** (inferencia local, memoria persistente, MCP cliente, STT/TTS locales, agentes programados) pero **no** un plano de control seguro para un ERP: auto-aprobación de herramientas en CLI (R1), sin OAuth/PKCE en MCP (R5), listas de herramientas por agente que no limitan MCP (R4). Por tanto: **OpenJarvis como componente de ejecución dentro de una caja, con el control de identidad, permisos, aprobación y auditoría fuera de él.**

## 2. Vista de componentes

```
                ┌───────────────────────── Interfaces ─────────────────────────┐
 Usuario ──►    │ Texto: API OpenAI-compatible / web UI / (canal Telegram/Slack)│
 (voz)  ──►     │ Voz: STT faster-whisper (local) ─► texto ─► TTS Kokoro (local)│  [T06/T07 probado]
                └──────────────────────────────┬───────────────────────────────┘
                                               ▼
                ┌──────────── Gateway de control JARVIS (a construir) ─────────┐
                │ AuthN (identidad: Jerónimo / staff / servicio)                │
                │ Política por identidad: herramientas permitidas, tope de      │
                │   tokens/costo, horario, "solo lectura" por defecto           │
                │ Cola de aprobaciones humanas para toda escritura/envío        │
                │ Kill-switch global (bandera que detiene agentes y colas)      │
                │ Auditoría inmutable (append-only, hash encadenado)            │
                └──────────────┬──────────────────────────────┬────────────────┘
                               ▼                              ▼
     ┌──────── Motor de agentes (OpenJarvis) ───────┐  ┌──── Programador ────────────────┐
     │ agent=orchestrator (tool-calling nativo)      │  │ Agentes gestionados de           │
     │ Modelos: local qwen3.5:2b/4b vía Ollama       │  │ `jarvis serve` (interval/cron)   │ [T08 probado]
     │   [T02 probado]; nube opcional por política   │  │ + capa externa: cola persistente,│
     │ Memoria: hechos JSONL + SQLite [T03/T09]      │  │   reintentos con backoff, dedupe │
     │ Sin shell/code/web en modo autónomo           │  │   por (tarea, ventana), alertas  │
     └──────────────┬───────────────────────────────┘  └──────────────────────────────────┘
                    ▼  MCP (stdio/HTTP local, Bearer de corta vida emitido por el gateway)
     ┌──────────────── Gateway MCP / broker OAuth (a construir) ────────────────┐
     │ Cliente OAuth 2.1 + PKCE frente a portal.tp1logistics.com/api/mcp         │
     │ Guarda/refresca tokens en almacén de secretos; expone a OpenJarvis solo  │
     │ herramientas de LECTURA allowlisted; registra cada llamada               │
     └───────────────┬──────────────────────────────────────────────────────────┘
                     ▼
              BIND ERP (lectura) · Supabase (lectura, esquema reporting) · otros MCP
```

## 3. Decisiones por capa

| Capa | Decisión | Evidencia / motivo |
|---|---|---|
| Texto | API `/v1/chat/completions` de `jarvis serve` en loopback detrás del gateway | T01, T03 probados vía API |
| Voz | STT `faster-whisper` `base` int8 CPU (1–8 s por frase), TTS Kokoro (≈1.6 s por frase tras carga; 1ª carga ~2 min) | T06/T07: transcripción fiel ida y vuelta EN/ES |
| Modelos | Local `qwen3.5:4b` para herramientas (más fiable), `2b` para charla; nube (Claude/GPT) **solo** por política explícita y con datos no sensibles | T05: `native_react` falló con 2B; `orchestrator` OK con ambos |
| Memoria | Separar almacenes por identidad y dominio: `personal/` vs `tp1/` (un `OPENJARVIS_HOME` por inquilino o instancia). Hechos empresariales con revisión (nivel `trusted` manual) | T03; R11 (hecho espurio) |
| Herramientas MCP | Solo lectura; `include_tools` explícito; tokens nunca en JSON plano | T05, R4, R5 |
| Programación | Usar agentes gestionados de `jarvis serve`, **no** `jarvis scheduler start` (dry-run). Añadir supervisor (systemd) y watchdog de salud | T08, T09, R10 |
| Auditoría | Además de `audit.db`/`traces.db` internos, log externo append-only del gateway | — |
| Límites | `max_total_tokens`/`max_cost` por agente (soportado por el ejecutor), `MemoryMax` por servicio, rate limit | T12, R7 |
| Parada | Kill-switch del gateway + `POST /v1/managed-agents/{id}/pause` + `ojctl.sh stop` | API probada al crear agentes |

## 4. Compatibilidad MCP con el conector BIND (OAuth 2.1 + PKCE)

**Resultado: NO compatible de forma nativa** (probado con servidor simulado que responde `401` + `WWW-Authenticate: Bearer resource_metadata=…`). El cliente no realiza descubrimiento (RFC 9728/8414), registro dinámico ni flujo PKCE; descarta el servidor. Con un Bearer pre-obtenido sí funciona (caso B). Opciones:

1. **Recomendada:** broker/gateway MCP propio (pequeño servicio) que haga OAuth 2.1+PKCE con BIND, refresque tokens y re-exponga solo herramientas de lectura en `127.0.0.1` con un token local de corta vida.
2. Usar un proxy MCP genérico con soporte OAuth (evaluar en fase siguiente; no probado aquí).
3. Contribuir OAuth al cliente de OpenJarvis (upstream) — mayor esfuerzo, dependencia de revisión externa.

## 5. Primer caso empresarial: reporte ejecutivo de cobranza / CxP / gastos (solo lectura)

1. Programación: agente gestionado `cron` (p. ej. lunes 07:40 America/Mexico_City), `max_total_tokens` acotado.
2. Herramientas: `bind.cxc_resumen`, `bind.cxp_resumen`, `bind.gastos_periodo` (lectura) vía broker; `calculator`.
3. Salida: Markdown/HTML guardado localmente + borrador de envío en **cola de aprobación** (ningún envío externo automático).
4. Verificación: el gateway recalcula totales directamente desde las respuestas MCP y marca discrepancias con el texto del modelo (los modelos 2–4B pueden alucinar; ver R6/R11).
5. Validado aquí solo con `mock/mock_bind_mcp.py` (datos ficticios).

## 6. Comparativa y qué no duplicar

| Capacidad | OpenJarvis (probado) | OpenClaw (doc. pública, no probado aquí) | ChatGPT / Claude (servicios) |
|---|---|---|---|
| Inferencia local / privacidad | **Sí** (Ollama, CPU) | Normalmente usa modelos en nube vía API | No (nube) |
| Calidad de razonamiento | Limitada con 2–4B locales | Depende del modelo conectado | **Alta** |
| Memoria persistente | Sí (hechos + SQLite) | Sí (archivos Markdown) | Sí (memoria de producto / proyectos) |
| Cliente MCP | Sí, sin OAuth | Vía skills/plugins | **Sí, con OAuth** (conectores remotos) |
| Voz local | **Sí** (Whisper + Kokoro) | Vía integraciones | Sí (nube) |
| Autonomía programada | Sí (agentes gestionados) | Sí (cron/heartbeat) | Tareas programadas limitadas; Claude Code remoto con tareas programadas |
| Canales de mensajería | Muchos (Telegram, Slack, WhatsApp…) — no probados | Fuerte en canales | Limitado |
| Controles de seguridad empresariales | Débiles (R1–R5) | Riesgos conocidos con skills de terceros | Gestionados por proveedor |

**Qué aporta OpenJarvis:** ejecución local barata y privada, voz local, memoria propia, agentes 24/7 sin costo por token.
**Qué no conviene duplicar:** el razonamiento complejo y redacción ejecutiva (mejor en Claude/ChatGPT), el conector BIND con OAuth (ya existe y funciona en clientes con OAuth), y los canales de mensajería si OpenClaw ya los resuelve. Usar OpenJarvis como **nodo local** para tareas privadas/recurrentes y escalar a Claude solo con datos permitidos.

## 7. Recursos y costos estimados (estimaciones, no medidas de facturación)

| Escenario | Recursos | Costo estimado |
|---|---|---|
| Pruebas actuales | Contenedor efímero Claude Code (incluido en la suscripción) | **USD 0 adicional** |
| Piloto 24/7 CPU | VPS/servidor 8 vCPU, 16–32 GB RAM, 60 GB SSD (modelos 2B/4B + Whisper + Kokoro) | ~USD 40–120/mes según proveedor (a cotizar) |
| Reutilizar servidor OpenClaw | Requiere ≥16 GB RAM libres y ~15 GB disco (medido T12/INSTALLATION) | USD 0 si hay capacidad; **no verificado** (sin acceso) |
| Modelo en nube opcional | Llamadas a Claude/GPT por política | Variable por tokens; aplicar `max_cost` |

Medido en este entorno: runner del modelo 2B ≈ 3.9–4.3 GB RSS; servidor ≈ 0.5 GB; latencia 5–30 s por consulta con herramientas en 4 vCPU.
