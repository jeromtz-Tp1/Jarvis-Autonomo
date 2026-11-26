# REPAIR PROCEDURE — Reparación de OpenJarvisLab en un solo comando

**Para:** la instalación existente en la PC Windows de Jerónimo · **Costo:** USD 0 · **Sin** reinstalar ni volver a descargar modelos · **Sin** BIND ni producción.

## Procedimiento (un solo comando)

1. Descargar de nuevo el ZIP de la rama `claude/openjarvis-setup-validation-n0vk5x` y descomprimirlo **completo**. Contiene los scripts corregidos.
2. En PowerShell normal (sin administrador), dentro de la carpeta `windows`:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Repair-OpenJarvisLab.ps1
   ```
3. Esperar a que aparezca **"JARVIS REPARADO Y OPERATIVO"** (unos 3–6 min). Si el resultado es otro, el script enumera cada `[FALLO]` con su causa y deja `REPAIR_REPORT_<fecha>.md` en la carpeta.
4. Hablar con JARVIS: `.\Talk-Jarvis.ps1`.

Opciones (solo si el informe lo indica):
- `-AllowModelDownload`: si falta algún modelo. Por defecto nunca se descarga nada.
- `-AllowWslShutdown`: aplica más memoria a WSL aunque haya otras distros abiertas, como Docker Desktop.

## Qué hace, en orden

| Fase | Acción | Defecto que corrige |
|---|---|---|
| 1. Diagnóstico | Comprueba WSL, la distro, la RAM y CPU del equipo y que el paquete esté completo | — |
| 2. Recursos persistentes | Si la VM de WSL tiene menos memoria de la necesaria, ajusta `.wslconfig` (`memory=`, con copia de seguridad; sin bajar nunca un valor existente). Dentro de la distro escribe un *drop-in* systemd permanente: **hasta 10 GB y 6 CPU**, adaptado a la VM | Límites de 7.5 GB / 2 CPU demasiado restrictivos |
| 3. Copia local verificada | Copia los scripts corregidos a la distro (por `tar` y stdin, sin red ni credenciales), normaliza CRLF sin tocar los WAV y verifica los 19 archivos por SHA256 | — |
| 4. Reparación en sitio (`repair_lab.sh`) | Restaura el aislamiento de `wsl.conf`; verifica sin red que estén OpenJarvis, Rust, Ollama, el modelo configurado (o usa el instalado), Whisper y Kokoro; regenera `ojenv.sh` (`UV_NO_CONFIG`, `PATH`), `ojctl.sh` y `ojvoice.sh`; restaura `mode=block`; reinstala las unidades systemd; reinicia los servicios y espera `/health` | `/root/uv.toml`; servicios caídos; configuración alterada |
| 5. WSL siempre activo | Tarea programada de usuario `OpenJarvisLab-KeepAlive`: al iniciar sesión, oculta, se relanza si WSL se detiene. Si no se pudiera crear, usa un acceso directo en Inicio. Se verifica que la distro sigue activa 20 s después sin sesiones abiertas | WSL se detiene o reinicia entre ejecuciones |
| 6. Pruebas independientes | Inferencia (17+25 → 42), STT con audio de referencia incluido (independiente del TTS), TTS (WAV válido), voz de extremo a extremo, memoria en disco, seguridad (solo loopback, allowlist, `block`, sin salida a Internet, aislamiento) | Validación sin pasos manuales |

## Correcciones permanentes (también para instalaciones nuevas)

| Defecto reportado | Causa raíz | Corrección |
|---|---|---|
| Permisos `/root/uv.toml` | `asu` heredaba `/root` como directorio de trabajo | `asu` entra siempre en `/opt/oj/workspace` con `UV_NO_CONFIG=1`; los scripts empiezan con `cd /tmp` |
| Descarga de Ollama bloqueada | El modelo se descargaba **después** de activar servicios con `IPAddressDeny=any` | Las descargas usan un Ollama **temporal** de mantenimiento (127.0.0.1:11435, fuera de systemd) que se apaga al terminar. El servicio permanente sigue sin Internet |
| Éxito falso en la instalación | `ollama pull … \| tail -1` sin `pipefail` | `pipefail` en `asu`; el modelo se verifica por su manifiesto; el instalador termina con código 5–7 si falla una descarga, el arranque o el autodiagnóstico |
| 7.5 GB / 2 CPU insuficientes | Valores fijos | Presupuesto adaptativo (≤10 GB, ≤6 CPU) en un drop-in persistente; `.wslconfig` ajustado si hace falta |
| WSL se detiene | Nada mantenía viva la distro | Tarea `OpenJarvisLab-KeepAlive` + servicios systemd habilitados (arrancan con la distro) |
| Errores HTTP ocultos / `JSONDecodeError` | `curl -sf` descartaba el cuerpo del error y Python parseaba una cadena vacía | `ojvoice.sh` muestra el código HTTP y el cuerpo, y sale con 10 (servidor caído), 11 (STT), 12 (inferencia), 13 (TTS) o 2 (sin audio) |
| «Listo» tras un fallo | El indicador era fijo | `Talk-Jarvis.ps1` muestra "FALLO del turno" con la causa y la acción, y solo vuelve a "Listo para hablar" tras un turno correcto; comprueba el servidor antes de reintentar |

## Seguridad conservada
- Servicios solo en `127.0.0.1`, sin salida a Internet (`IPAddressDeny`).
- Allowlist estricta de herramientas, `mode=block` y parche R1/R2.
- Distro sin acceso a `C:\` ni a programas de Windows.
- Sin credenciales y sin conexión a BIND.

La única salida a Internet es la descarga de mantenimiento, y solo con `-AllowModelDownload`.
