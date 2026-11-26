<#
.SYNOPSIS
  Instala OpenJarvis en una distro WSL2 DEDICADA y AISLADA ("OpenJarvisLab") y ejecuta las pruebas T01-T12.
.DESCRIPTION
  1. Ejecuta Test-OpenJarvisReadiness.ps1 y se detiene si el veredicto es NO-GO.
  2. Descarga la imagen oficial Ubuntu 24.04 para WSL (cloud-images.ubuntu.com) y verifica su SHA256.
  3. La importa como distro nueva "OpenJarvisLab" (no toca otras distros, Docker ni Ollama de Windows).
  4. Aísla la distro: sin montar C:\ ni otras unidades, sin ejecutar programas de Windows, con systemd para límites de RAM/CPU.
  5. Copia los entregables LOCALES (esta carpeta, descargada en ZIP) a la distro, sin red ni credenciales,
     verifica su integridad (BUNDLE_MANIFEST.sha256) y ejecuta setup_lab.sh y run_acceptance.sh.
  6. Copia RESULTS.md a la carpeta de este script.
  No usa credenciales, no abre puertos externos (los servicios escuchan solo en 127.0.0.1), costo USD 0.
  No requiere administrador SI WSL ya está instalado. Si falta WSL, indica el único comando de administrador necesario.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-OpenJarvisLab.ps1
  powershell -ExecutionPolicy Bypass -File .\Install-OpenJarvisLab.ps1 -Minutes 30 -InstallDir D:\OpenJarvisLab
#>
[CmdletBinding()] param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenJarvisLab'),
  [int]$Minutes = 30,
  [string]$Model = '',
  [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'
$RootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
$RootfsSha = '8251e27ffff381a4af5f41dcb94d867de3e0d9774a9241908ab34555d99315ea'   # SHA256SUMS oficial 2026-11-25
$Bundle = Split-Path $PSScriptRoot -Parent          # raíz de los entregables locales (carpeta del ZIP)
$BundleFiles = @('windows/wsl', 'windows/BUNDLE_MANIFEST.sha256', 'patches', 'deploy/phase2-72h', 'mock', 'scripts/voice_test.py')
foreach ($f in $BundleFiles) { if (-not (Test-Path (Join-Path $Bundle $f))) { throw "Falta '$f' en $Bundle. Descomprima el ZIP completo de los entregables y ejecute este script desde su carpeta 'windows'." } }
function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function W([string[]]$a) { $old=[Console]::OutputEncoding; [Console]::OutputEncoding=[Text.Encoding]::Unicode; try { (& wsl.exe @a 2>&1 | Out-String).Replace("`0",'') } finally { [Console]::OutputEncoding=$old } }
function InDistro([string]$cmd) { if ($cmd.Contains('"')) { throw 'InDistro: no usar comillas dobles' }; & wsl.exe -d $Distro -u root --exec bash -lc $cmd; if ($LASTEXITCODE -ne 0) { throw "Falló dentro de la distro (código $LASTEXITCODE): $cmd" } }

# 1. Diagnóstico
Log 'Paso 1/6: diagnóstico del equipo (solo lectura)'
& (Join-Path $PSScriptRoot 'Test-OpenJarvisReadiness.ps1') -InstallDrive ([IO.Path]::GetPathRoot($InstallDir))
$rd = Get-Content (Join-Path $PSScriptRoot 'openjarvis_readiness.json') -Raw | ConvertFrom-Json
if ($rd.summary.verdict -like 'NO-GO*') { throw "El equipo no cumple los requisitos (ver openjarvis_readiness.txt). No se instaló nada." }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue) -or ($rd.checks | Where-Object { $_.Check -eq 'WSL2' -and $_.Status -eq 'ACCION' })) {
  Write-Host "`nACCIÓN ÚNICA REQUERIDA (administrador): abra PowerShell como administrador y ejecute:`n    wsl --install --no-distribution`nReinicie Windows y vuelva a ejecutar este script." -ForegroundColor Yellow; exit 10 }
if (-not $Model) { $Model = $rd.summary.recommended_model }

# 2. Imagen oficial verificada
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$tar = Join-Path $InstallDir 'ubuntu-24.04-wsl.rootfs.tar.gz'
$exists = (W @('-l','-q')) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $Distro }
if (-not $exists) {
  Log 'Paso 2/6: descarga de Ubuntu 24.04 oficial para WSL (~350 MB) y verificación SHA256'
  if (-not (Test-Path $tar) -or (Get-FileHash $tar -Algorithm SHA256).Hash -ne $RootfsSha.ToUpper()) {
    $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri $RootfsUrl -OutFile $tar -UseBasicParsing }
  $h = (Get-FileHash $tar -Algorithm SHA256).Hash
  if ($h -ne $RootfsSha.ToUpper()) { Remove-Item $tar -Force; throw "SHA256 no coincide ($h). Descarga descartada." }
  # 3. Distro dedicada
  Log "Paso 3/6: creación de la distro dedicada '$Distro' en $InstallDir"
  & wsl.exe --import $Distro (Join-Path $InstallDir 'vhd') $tar --version 2; if ($LASTEXITCODE) { throw 'wsl --import falló' }
} else { Log "Pasos 2-3/6: la distro '$Distro' ya existe; se reutiliza" }

# 4. Aislamiento de la distro
Log 'Paso 4/6: aislamiento (sin unidades de Windows, sin interop, systemd activo)'
$wslconf = @"
[boot]
systemd=true
[automount]
enabled=false
mountFsTab=false
[interop]
enabled=false
appendWindowsPath=false
[user]
default=root
[network]
generateHosts=true
generateResolvConf=true
"@
$wslconf | & wsl.exe -d $Distro -u root --exec bash -c "tr -d '\r' > /etc/wsl.conf"
& wsl.exe --terminate $Distro | Out-Null; Start-Sleep 3
InDistro 'echo PID1=$(ps -p 1 -o comm=); test ! -d /mnt/c/Windows && echo C-no-montado-aislado'

# 5. Instalación + pruebas dentro de la distro
Log "Paso 5/6: instalación de OpenJarvis (modelo $Model; ~15-30 min según conexión)"
# 5a. Entregables locales -> distro (sin red, sin credenciales). tar.exe viene con Windows 10 1803+ / 11.
$tarFile = Join-Path $InstallDir 'oj-bundle.tar'
Remove-Item $tarFile -ErrorAction SilentlyContinue
& "$env:SystemRoot\System32\tar.exe" -cf $tarFile -C $Bundle @BundleFiles; if ($LASTEXITCODE) { throw 'tar.exe no pudo empaquetar los entregables' }
InDistro 'rm -rf /root/oj-bundle && install -d -m 700 /root/oj-bundle'
# Redirección de cmd: binaria y segura (la canalización de PowerShell 5.1 corrompería el .tar)
& cmd.exe /d /c "wsl.exe -d $Distro -u root --exec tar -xf - -C /root/oj-bundle < `"$tarFile`""
if ($LASTEXITCODE) {
  Log 'tar por stdin no disponible; copia por \\wsl.localhost'
  $unc = @("\\wsl.localhost\$Distro\root\oj-bundle", "\\wsl$\$Distro\root\oj-bundle") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $unc) { throw 'No se pudo copiar los entregables a la distro' }
  foreach ($f in $BundleFiles) { $dst = Join-Path $unc $f; New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null; Copy-Item -Recurse -Force (Join-Path $Bundle $f) $dst }
}
Remove-Item $tarFile -ErrorAction SilentlyContinue
# 5b. Normaliza finales de línea (ZIP/git en Windows pueden convertir a CRLF) y verifica integridad
InDistro "cd /root/oj-bundle && find . -type f -exec sed -i 's/\r$//' {} + && sha256sum --quiet -c windows/BUNDLE_MANIFEST.sha256 && echo 'entregables verificados (SHA256)'"
InDistro "bash /root/oj-bundle/windows/wsl/setup_lab.sh --prefix /opt/oj --user jarvis --model '$Model' --gpu auto"
if (-not $SkipTests) {
  Log "Paso 6/6: pruebas de aceptación T01-T12 (incluye $Minutes min de estabilidad)"
  InDistro "bash /root/oj-bundle/windows/wsl/run_acceptance.sh --prefix /opt/oj --user jarvis --minutes $Minutes --model '$Model'"
  $res = & wsl.exe -d $Distro -u root --exec bash -c 'cat $(ls -dt /opt/oj/evidence/acceptance_*/ | head -1)RESULTS.md'
  $dest = Join-Path $PSScriptRoot "RESULTS_$(Get-Date -Format yyyyMMdd_HHmm).md"; $res | Set-Content $dest -Encoding UTF8
  Write-Host "`nResultados: $dest" -ForegroundColor Green; $res
}
Write-Host @"

Listo. Uso diario (desde PowerShell, sin administrador):
  HABLAR CON JARVIS (voz):  .\Talk-Jarvis.ps1          (Enter = hablar / Enter = terminar)
  Pregunta escrita, respuesta en voz:  .\Talk-Jarvis.ps1 -Text "Hola Jarvis"
  Estado:   wsl -d $Distro -u root -- /opt/oj/bin/ojctl.sh status
  Detener:  wsl -d $Distro -u root -- /opt/oj/bin/ojctl.sh stop      (o: wsl --terminate $Distro)
  Iniciar:  wsl -d $Distro -u root -- /opt/oj/bin/ojctl.sh start
  API local (solo este equipo): http://127.0.0.1:8000/health
  Desinstalar todo: .\Uninstall-OpenJarvisLab.ps1
"@
