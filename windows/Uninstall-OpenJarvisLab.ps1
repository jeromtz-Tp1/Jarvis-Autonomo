<#
.SYNOPSIS  Elimina COMPLETAMENTE el laboratorio: la distro "OpenJarvisLab", su carpeta y la tarea de mantenimiento activo.
.DESCRIPTION No toca otras distros WSL, Docker, Ollama de Windows. Restaura .wslconfig solo si se pasa -RestoreWslConfig.
#>
[CmdletBinding(SupportsShouldProcess)] param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenJarvisLab'), [switch]$RestoreWslConfig)
$Distro = 'OpenJarvisLab'; $TaskName = 'OpenJarvisLab-KeepAlive'
if ($PSCmdlet.ShouldProcess($Distro, 'wsl --unregister (borra la distro y todos sus datos)')) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'OpenJarvisLab-KeepAlive.vbs') -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" | Where-Object { $_.CommandLine -match 'OpenJarvisLab-KeepAlive|keepalive\.vbs' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  & wsl.exe --terminate $Distro 2>$null | Out-Null
  & wsl.exe --unregister $Distro
  if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
  if ($RestoreWslConfig) { $b = Get-ChildItem "$env:USERPROFILE\.wslconfig.bak-*" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if ($b) { Copy-Item $b.FullName "$env:USERPROFILE\.wslconfig" -Force; Write-Host "Restaurado .wslconfig original ($($b.Name))" } }
  Write-Host 'Laboratorio eliminado. Otras distros y programas no se modificaron.' -ForegroundColor Green }
