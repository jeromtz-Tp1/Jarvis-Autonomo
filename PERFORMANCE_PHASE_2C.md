# PERFORMANCE — Fase 2C: optimización de latencia de JARVIS

**Fecha:** 2026-11-26 · **Hardware objetivo:** Intel Core Ultra 7 258V (8 núcleos), 32 GB, Intel Arc 140V, Windows 11 Pro + WSL2 · **Meta:** respuesta sencilla < 5 s · **Costo:** USD 0 · Sin reinstalar OpenJarvis, sin BIND, sin cambiar la seguridad.

## 1. Un solo comando

```powershell
powershell -ExecutionPolicy Bypass -File .\Optimize-OpenJarvisLab.ps1            # medir, optimizar, comparar
powershell -ExecutionPolicy Bypass -File .\Optimize-OpenJarvisLab.ps1 -GpuEval   # + evaluación de la Intel Arc (nativo Windows)
powershell -ExecutionPolicy Bypass -File .\Optimize-OpenJarvisLab.ps1 -Revert    # deshacer todo, exactamente
```

El script:
1. Mide el estado actual («antes»).
2. Aplica la optimización.
3. Elige el modelo (2B o 4B) y los hilos con reglas explícitas.
4. Vuelve a medir («después»).
5. Ejecuta la prueba de memoria real y el autodiagnóstico de seguridad.
6. Compara y escribe `OPTIMIZE_REPORT_<fecha>.md`.

Si la latencia empeora o falla cualquier prueba, **revierte solo**. Las pruebas **no dejan datos en la memoria de Jerónimo**: se guarda una instantánea de los hechos y del historial de voz antes de medir y se restaura al final, aunque algo falle.

## 2. Diagnóstico: dónde se iba el tiempo (medido)

Mediciones en el laboratorio de validación (4 vCPU Xeon, sin GPU; Ubuntu 24.04 igual que la distro WSL). Las cifras absolutas serán mejores en el Core Ultra 7; lo que importa son las proporciones.

| Misma pregunta sencilla («capital de Francia») | 2B | 4B |
|---|---|---|
| Ollama directo, sin razonamiento | **0.47 s** | **1.29 s** |
| Ollama **con** razonamiento extendido | 25.0 s (453 tokens; 1605 caracteres «pensados») | 79.1 s (549 tokens) |
| Camino de la voz antes de optimizar (agente orquestador) | 13.6 s | 42.9 s |

Causas, en orden de impacto:

| # | Causa | Evidencia | Corrección |
|---|---|---|---|
| 1 | Cada turno de voz pasaba por el **agente orquestador**: catálogo de herramientas en el prompt (2711 tokens de entrada) y posibles llamadas encadenadas | Telemetría: 2711 tokens de entrada; 13.6 s frente a 0.47 s | Voz por el camino **directo en streaming** del servidor (`[server] agent = "simple"`); la memoria se sigue inyectando y registrando |
| 2 | **Razonamiento extendido**: activo por defecto en Qwen 3.5, ×50 de latencia | Tabla anterior | El motor ya envía `think:false`; además se retira la herramienta `think`, que hacía «pensar» al agente en llamadas extra |
| 3 | **Extracción de memoria concurrente**: cada respuesta dispara otra llamada al modelo que compite por la CPU con la siguiente pregunta y con la síntesis de voz (`OLLAMA_NUM_PARALLEL=1`) | Telemetría: llamada de 147 tokens simultánea a cada pregunta; TTS de 1.2 s a 5.2 s | Parche 0003: la extracción **se difiere mientras dura un turno de voz** (marcador creado por `ojvoice`) |
| 4 | **Contexto de memoria** de hasta 2048 tokens en cada petición, elegido solo por antigüedad | Prompt capturado con un proxy de registro: 5399 caracteres de hechos | Parche 0003: hechos **ordenados por relevancia** respecto de la pregunta y presupuesto de 512 tokens (se conservan los pertinentes aunque sean antiguos) |
| 5 | El servidor **subía** el `max_tokens` pedido (160 → 1024) por su «análisis de complejidad» | Petición capturada: `num_predict: 1024` | Parche 0004: el `max_tokens` del cliente pasa a ser un tope |
| 6 | `num_ctx=16384` forzado por petición (`JARVIS_NUM_CTX`), que anulaba nuestro 8192 | Código del motor + petición capturada | Contexto 4096 (`JARVIS_NUM_CTX` y `OLLAMA_CONTEXT_LENGTH`) |
| 7 | Carga en frío del modelo, Whisper y Kokoro en la primera pregunta | Carga 2B 3.9 s / 4B 6.1 s | `OLLAMA_KEEP_ALIVE=-1` + servicio `ojl-warmup` (precarga al arrancar) |
| 8 | STT con `beam_size=5` y sin VAD | Código de OpenJarvis | Parche 0002: `beam_size=1`, VAD, sin condicionar al texto previo |
| 9 | TTS en serie: la voz no empezaba hasta terminar toda la respuesta | Diseño anterior de `ojvoice` | `ojvoice.py` sintetiza **cada frase en paralelo** con la generación, y `Talk-Jarvis.ps1` **reproduce la primera frase** mientras llegan las demás |
| 10 | Cuota de CPU (6 de 8) por debajo de los hilos de llama.cpp: el estrangulamiento penaliza mucho a los hilos que esperan | Diseño de cgroups + llama.cpp | Cuota = todas las CPU de la VM; hilos fijados con un modelo derivado `jarvis-voz:<tag>` (mismos pesos, sin descarga) elegido por medición |

## 3. Intel Arc 140V: evaluación de aceleración

| Opción | Estado | Motivo |
|---|---|---|
| GPU dentro de WSL2 | **No viable hoy** | WSL2 expone la GPU por D3D12 (`/dev/dxg`). Ollama para Linux no tiene backend D3D12, y su Vulkan dentro de WSL dependería del controlador experimental Mesa «dzn», que llama.cpp no soporta. El script comprueba `/dev/dxg` y lo informa |
| **Ollama nativo de Windows con Vulkan** (controlador Intel) | **Medido por el script con `-GpuEval`** | Instancia temporal en `127.0.0.1:11500` que usa una copia local de los mismos pesos (sin descargar modelos). Mide tokens/s de generación y de prompt frente a WSL/CPU y registra qué backend y dispositivo usó Ollama. Después borra la copia de pesos |
| OpenVINO (GenAI / Model Server) o IPEX-LLM | No probado | Es la ruta de Intel con mejor rendimiento previsible en Lunar Lake (GPU y NPU), pero exige convertir o descargar los modelos en formato OpenVINO y ejecutar un servidor aparte. Queda como siguiente paso si Vulkan no basta |
| NPU (Intel AI Boost) | No soportada por Ollama | Solo vía OpenVINO |

**Por qué `-GpuEval` mide pero no adopta automáticamente:** usar un Ollama de Windows desde OpenJarvis en WSL obliga a abrir un camino de red de WSL hacia Windows, ya sea con `networkingMode=mirrored` (afecta a todas las distros, Docker incluido) o con la IP del host más una regla de firewall. Hoy los servicios no tienen ninguna salida fuera de loopback. Ese cambio en el modelo de seguridad se decide con las cifras de `gpu_eval.json` en la mano, no por defecto.

## 4. 2B frente a 4B

El script mide en el propio equipo, con 8 preguntas verificables:
- calidad, en aciertos y en brevedad;
- latencia de cada modelo directamente en Ollama;
- el sobrecoste real del servidor.

**Regla de elección** (`ojselect.py`, auditable): se elige el 4B si cumple la meta de 5 s; si no, el más rápido que la cumpla con al menos el 75 % de calidad; y si ninguno la cumple, el más rápido con calidad suficiente, indicando que la meta no se alcanzó.

En el laboratorio ambos sacaron 8/8 de calidad, con el 4B unas 3 veces más lento en generación. Ver §6.

## 5. Memoria persistente: falso positivo corregido

Antes, el autodiagnóstico daba OK si existía `memory_facts.jsonl` **o** `memory.db`, aunque hubiera 0 hechos. Ahora `oj_memtest` exige cinco cosas:
1. Escribir un hecho de verificación con el almacén oficial.
2. Que el archivo exista y lo contenga.
3. Reiniciar el servidor.
4. Que JARVIS lo **recuerde** por el mismo camino que la voz.
5. Que la **extracción automática** guarde un hecho nuevo, con un dato aleatorio en cada ejecución para que repetir la prueba no dé un falso positivo.

Si el archivo no existe, si se registran 0 hechos o si no hay recuerdo, el resultado es **FALLO**.

## 6. Resultados de la validación (laboratorio, 2026-11-26 21:08–21:18 UTC)

Ejecución completa del mismo flujo que `Optimize-OpenJarvisLab.ps1` (antes → aplicar → intermedio → selección → después → memoria → reversión) en el laboratorio: **4 vCPU Xeon 2.1 GHz, sin GPU** (el Core Ultra 7 258V debería ser más rápido). Turnos separados 8 s (tiempo realista de escucha y respuesta). Evidencia: `evidence/phase2c/`.

| Métrica (p50) | Antes | Después | Mejora |
|---|---|---|---|
| **Voz extremo a extremo** (STT → JARVIS → voz completa) | **15.8 s** | **4.96 s** | **3.2×** |
| Primera voz audible | 15.8 s | **4.86 s** | 3.3× |
| Respuesta sencilla por el servidor | 6.2 s (entre 6.2 y 17.8 s) | **1.87 s** | 3.3× |
| Primer token del servidor | — | 1.35 s | — |
| STT (audio de 3.5 s) | 0.95 s | 1.0 s | = |
| TTS (frase de 4 s) | 1.2 s | 1.2 s | = |

Desglose de un turno de voz después de optimizar: STT 1.0 s · primer token 0.13 s · respuesta completa del modelo 1.34 s · síntesis de la frase 2.3 s → **4.65 s en total**.

**Meta < 5 s:** cumplida en el laboratorio con el 2B (4.96 s p50; el peor turno, 7.3 s). En el Core Ultra 7 el script vuelve a medir y elige: si allí el 4B cumple la meta, lo selecciona por su mejor calidad.

**Calidad (8 preguntas verificables, varias pasadas):**
- **2B:** entre 7/8 y 8/8. Falla de forma recurrente en «¿qué día viene después del viernes?», a la que responde «lunes».
- **4B:** 7/8. Escribe «veicuatro» por «veinticuatro», lo que también afecta a la lectura en voz alta.
- **Brevedad:** 8/8 en ambos.
- **Velocidad:** el 4B es 2.5–3 veces más lento por respuesta en este laboratorio (3.4 s frente a 1.3 s).

**Memoria (prueba real):** hecho escrito y presente en el archivo → recordado tras reiniciar el servidor → la extracción automática guardó un hecho nuevo. **Las pruebas no dejaron datos:** misma huella SHA256 del archivo de hechos antes y después (129 hechos).

**Reversibilidad:** `revert` dejó `config.toml`, `ojenv.sh` y `ojvoice.sh` con huellas idénticas a las originales, retiró los parches 0004, 0003 y 0002 (queda solo el 0001 de seguridad) y eliminó el modelo derivado sin tocar los pesos base.

### Hallazgos durante la optimización (lo que no funcionó a la primera)
- El primer diseño reducía la memoria a 512 tokens, pero el primer token seguía en ~4.8 s. Con un **proxy de registro** entre el servidor y Ollama se midió que el servidor tarda 0.01–0.1 s y que el tiempo restante era el procesamiento del prompt: ~3200 caracteres de hechos y la caché de prefijo vaciada por la extracción. Limitar a los **8 hechos más relevantes** bajó el primer token a **1.0–1.2 s**.
- El banco inicial intercalaba 2B y 4B en el servidor y **forzaba intercambios de modelo** en Ollama, con tiempos de 31 s que no reflejan el uso real. Se corrigió: los modelos se comparan en Ollama directo y el servidor se mide solo con su modelo configurado.
- Cambiar `num_thread` obliga a recargar el modelo y distorsionaba la prueba de hilos. Se añadió una llamada de calentamiento descartada.
- Ollama 0.40 guarda los modelos **creados** en `manifests-v2/` y los **descargados** en `manifests/`. La detección de modelos ahora acepta ambos formatos; afectaba también a `Repair`.
- El banco **contaminaba la memoria** con trivialidades, como «el usuario pregunta qué día sigue al viernes». Ahora hay una instantánea y restauración obligatoria (`memsnap`).
- `Repair-OpenJarvisLab.ps1` habría **borrado la optimización** al regenerar `ojenv.sh` y `ojl.env`. Ahora la conserva.

### Lo que no se pudo validar aquí
- **La Intel Arc 140V y el Ollama nativo de Windows (`-GpuEval`):** el laboratorio no tiene Windows ni GPU. La medición la hará el script en la PC y la dejará en `gpu_eval.json`.
- **Los `.ps1`** (`Optimize`, `Talk-Jarvis` con reproducción por fragmentos): revisados línea a línea, con BOM UTF-8 y CRLF, pero **no ejecutados en Windows**. La parte Linux que invocan sí está validada de principio a fin.
- **systemd** (servicio de precarga, cuota de CPU de la slice): la sintaxis está verificada, pero no hay systemd como PID 1 en el contenedor. En la PC lo comprueba el autodiagnóstico del script.
