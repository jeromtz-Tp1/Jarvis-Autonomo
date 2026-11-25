<#
.SYNOPSIS  Arranca el laboratorio y lo mantiene activo en segundo plano (para pruebas largas / agentes programados).
.DESCRIPTION WSL apaga una distro poco después de cerrar su última sesión. Este script deja una sesión oculta
  ("sleep infinity") que la mantiene viva hasta que se ejecute Stop-OpenJarvisLab.ps1 o se apague Windows.
#>
$Distro = 'OpenJarvisLab'
& wsl.exe -d $Distro -u root -- /opt/oj/bin/ojctl.sh start
$alive = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -match "$Distro.*sleep infinity" }
if (-not $alive) { Start-Process wsl.exe -ArgumentList "-d $Distro -u root -- sleep infinity" -WindowStyle Hidden }
Write-Host "OpenJarvisLab activo. API local: http://127.0.0.1:8000/health  — Detener: .\Stop-OpenJarvisLab.ps1"
