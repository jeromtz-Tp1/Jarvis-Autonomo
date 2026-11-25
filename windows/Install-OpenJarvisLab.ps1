<#
.SYNOPSIS
  Instala OpenJarvis en una distro WSL2 DEDICADA y AISLADA ("OpenJarvisLab") y ejecuta las pruebas T01-T12.
.DESCRIPTION
  1. Ejecuta Test-OpenJarvisReadiness.ps1 y se detiene si el veredicto es NO-GO.
  2. Descarga la imagen oficial Ubuntu 24.04 para WSL (cloud-images.ubuntu.com) y verifica su SHA256.
  3. La importa como distro nueva "OpenJarvisLab" (no toca otras distros, Docker ni Ollama de Windows).
  4. Aísla la distro: sin montar C:\ ni otras unidades, sin ejecutar programas de Windows, con systemd para límites de RAM/CPU.
  5. Dentro de la distro: clona el repo Jarvis-Autonomo (rama de entregables) y ejecuta setup_lab.sh y run_acceptance.sh.
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
  [string]$Branch = 'claude/openjarvis-setup-validation-n0vk5x',
  [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'
$RootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
$RootfsSha = '8251e27ffff381a4af5f41dcb94d867de3e0d9774a9241908ab34555d99315ea'   # SHA256SUMS oficial 2026-11-25
$Repo = 'https://github.com/jeromtz-Tp1/Jarvis-Autonomo.git'
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
InDistro "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get install -y -q git ca-certificates >/dev/null; rm -rf /root/Jarvis-Autonomo; git clone -q --depth 1 -b '$Branch' $Repo /root/Jarvis-Autonomo"
InDistro "bash /root/Jarvis-Autonomo/windows/wsl/setup_lab.sh --prefix /opt/oj --user jarvis --model '$Model' --gpu auto"
if (-not $SkipTests) {
  Log "Paso 6/6: pruebas de aceptación T01-T12 (incluye $Minutes min de estabilidad)"
  InDistro "bash /root/Jarvis-Autonomo/windows/wsl/run_acceptance.sh --prefix /opt/oj --user jarvis --minutes $Minutes --model '$Model'"
  $res = & wsl.exe -d $Distro -u root --exec bash -c 'cat $(ls -dt /opt/oj/evidence/acceptance_*/ | head -1)RESULTS.md'
  $dest = Join-Path $PSScriptRoot "RESULTS_$(Get-Date -Format yyyyMMdd_HHmm).md"; $res | Set-Content $dest -Encoding UTF8
  Write-Host "`nResultados: $dest" -ForegroundColor Green; $res
}
Write-Host @"

Listo. Uso diario (desde PowerShell, sin administrador):
  Estado:   wsl -d $Distro -u root -- /opt/oj/bin/ojctl.sh status
  Detener:  wsl -d $Distro -u root -- /opt/oj/bin/ojctl.sh stop      (o: wsl --terminate $Distro)
  Iniciar:  wsl -d $Distro -u root -- /opt/oj/bin/ojctl.sh start
  API local (solo este equipo): http://127.0.0.1:8000/health
  Desinstalar todo: .\Uninstall-OpenJarvisLab.ps1
"@
