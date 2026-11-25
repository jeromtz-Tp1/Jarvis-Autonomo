# WINDOWS LOCAL DEPLOYMENT — OpenJarvis en la PC de Jerónimo

**Fecha:** 2026-11-25 · **Decisión de Jarvis:** sin infraestructura en la nube; evaluar e instalar en la computadora Windows local · **Costo:** USD 0.

## 1. Estado

| Paso | Estado |
|---|---|
| Evaluar CPU, RAM, GPU, disco, WSL2 y Docker de la PC | **Pendiente de un único paso de Jerónimo** (ver §2): esta sesión de Claude corre en la nube y no ve la PC. No se inventó ningún dato del equipo. |
| Diagnóstico automático GO / NO-GO | **Listo**: `windows/Test-OpenJarvisReadiness.ps1` (solo lectura, sin administrador) |
| Instalación aislada + pruebas T01–T12 | **Listo**: `windows/Install-OpenJarvisLab.ps1` (un solo comando) |
| Instalador interno (Linux/WSL) | **Probado de punta a punta** en Ubuntu 24.04 limpio (ver §6) |
| Scripts de Windows (`.ps1`) | Revisados línea a línea; **no ejecutados** en Windows (ver §7) |

## 2. Lo único que tiene que hacer Jerónimo (elige A o B)

**A. Recomendada: lo ejecuta él (≈ 2 minutos de su tiempo y luego espera)**
1. Descargar la carpeta `windows/` de este repositorio (rama `claude/openjarvis-setup-validation-n0vk5x`) a la PC; por ejemplo con *Code → Download ZIP* en GitHub y descomprimir.
2. Abrir **PowerShell** (normal, sin administrador) en esa carpeta y ejecutar:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-OpenJarvisLab.ps1
   ```
3. El script primero diagnostica el equipo. Si dice **NO-GO**, se detiene sin instalar nada y explica por qué. Si dice **GO**, instala y prueba todo solo (30–60 min). Al final deja `RESULTS_<fecha>.md` en la misma carpeta: pásamelo y lo analizo.
4. Si aparece **"ACCIÓN ÚNICA REQUERIDA"**, falta WSL: abrir PowerShell **como administrador**, ejecutar `wsl --install --no-distribution`, reiniciar y repetir el paso 2. Es el único momento que puede requerir administrador.

**B. Que Claudito lo haga directamente**: en la app de escritorio de Claude en esa PC, ir a *Settings → Claude Code → Remote Control* y añadir una carpeta vacía (p. ej. `C:\OpenJarvisLab-work`). O, más sencillo, abrir una sesión de Claude Code **local** en la app de escritorio de esa PC y pedir "continúa la misión OpenJarvis Windows". En cualquiera de los dos casos, yo ejecuto el diagnóstico y la instalación.

## 3. Requisitos que comprueba el diagnóstico (Jerónimo no tiene que comprobar nada)

Derivados de lo **medido** en las fases 1 y 2 (modelo `qwen3.5:2b`: 4.4–4.9 GB de RAM en uso estable; instalación ≈ 15 GB).

| Componente | GO | CONDICIONAL | NO-GO |
|---|---|---|---|
| Windows | 10 build ≥ 19041 o 11, de 64 bits | — | Anterior o de 32 bits |
| CPU | ≥ 4 hilos con AVX2 (casi todo Intel/AMD desde 2015) | ≥ 4 hilos sin AVX2 (muy lento) | < 4 hilos |
| RAM física | ≥ 16 GB (≥ 32 GB habilita el modelo 4B) | 12–15 GB | < 12 GB |
| Disco libre | ≥ 40 GB | 25–40 GB | < 25 GB |
| Virtualización | Activa (firmware o hipervisor) | — | Desactivada en BIOS |
| WSL2 | Instalado | No instalado → acción única de administrador | — |
| GPU | No necesaria; con NVIDIA se acelera mediante CUDA en WSL2 | — | — |
| Docker | **No necesario** (no se usa ni se modifica) | — | — |
| Puertos 8000 / 11434 | Libres | Ocupados (p. ej. Ollama para Windows abierto) | — |

## 4. Qué instala y cómo queda aislado

- Una distro WSL **nueva y exclusiva**, `OpenJarvisLab`, creada desde la imagen oficial de Ubuntu 24.04 (cloud-images.ubuntu.com) con **SHA256 verificado**. No toca otras distros de WSL, Docker Desktop ni Ollama para Windows.
- Dentro de la distro:
  - **sin acceso a `C:\`** ni a otras unidades (`automount` desactivado);
  - **no puede lanzar programas de Windows** (`interop` desactivado);
  - systemd activo, con límites de **7 GB de RAM y 2 núcleos** (slice de la Fase 2).
- OpenJarvis en la misma revisión fija (`ae36ac97`), con el parche de seguridad R1/R2, el usuario sin privilegios `jarvis` y la configuración endurecida:
  - herramientas mínimas: sin shell, sin escritura de archivos y sin web;
  - `allowed_dirs` limitado y modo `block`;
  - servidor MCP **simulado** con datos ficticios;
  - analítica externa desactivada y el sondeo a NVIDIA anulado.
- La API solo escucha en `127.0.0.1`: accesible **únicamente desde esa PC**. No se abre ningún puerto en la red.
- Sin credenciales reales, sin BIND, sin sistemas empresariales.

## 5. Uso, parada y desinstalación

| Acción | Comando (PowerShell, sin administrador) |
|---|---|
| Arrancar y mantener activo (agentes programados) | `.\Start-OpenJarvisLab.ps1` |
| Parada inmediata (kill-switch) | `.\Stop-OpenJarvisLab.ps1` |
| Ver estado | `wsl -d OpenJarvisLab -u root -- /opt/oj/bin/ojctl.sh status` |
| Borrar todo sin dejar rastro | `.\Uninstall-OpenJarvisLab.ps1` (elimina solo la distro `OpenJarvisLab` y su carpeta) |

Notas para pruebas largas:
- WSL apaga la distro al cerrar la última sesión; `Start-OpenJarvisLab.ps1` la mantiene viva.
- En una laptop: mantenerla conectada a la corriente y desactivar la suspensión durante la prueba. Una PC personal que se apaga o suspende **no** ofrece disponibilidad 24/7.

## 6. Validación realizada del instalador

Ver `TEST_RESULTS_WINDOWS_PREP.md`.

## 7. Limitaciones honestas

- Los `.ps1` no se pudieron ejecutar en esta sesión (no hay Windows y no se autorizó instalar PowerShell en el contenedor). Se revisaron a mano los problemas típicos de PowerShell 5.1:
  - codificación: guardados con BOM UTF-8;
  - comillas en argumentos nativos: uso de `--exec` y comandos sin comillas dobles;
  - salida UTF-16 de `wsl.exe`;
  - finales de línea CRLF al canalizar `wsl.conf`.

  La primera ejecución real en la PC es la prueba definitiva; si algo falla, el script se detiene con un mensaje claro y no deja cambios fuera de la distro.
- El rendimiento en la PC dependerá de su CPU/GPU: en 4 vCPU de servidor la latencia fue de 6.5–8 s por respuesta.
