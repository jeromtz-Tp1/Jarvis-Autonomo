<#
.SYNOPSIS  Elimina COMPLETAMENTE el laboratorio OpenJarvis: solo la distro "OpenJarvisLab" y su carpeta.
.DESCRIPTION No toca otras distros WSL, Docker, Ollama de Windows ni la configuración global de WSL.
#>
[CmdletBinding(SupportsShouldProcess)] param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenJarvisLab'))
$Distro = 'OpenJarvisLab'
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -match $Distro } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
if ($PSCmdlet.ShouldProcess($Distro, 'wsl --unregister (borra la distro y todos sus datos)')) {
  & wsl.exe --terminate $Distro 2>$null | Out-Null
  & wsl.exe --unregister $Distro
  if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
  Write-Host "Laboratorio eliminado. Otras distros y programas no se modificaron." -ForegroundColor Green }
