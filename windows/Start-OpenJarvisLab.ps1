<#
.SYNOPSIS  Arranca JARVIS y lo mantiene activo (tarea programada de usuario "OpenJarvisLab-KeepAlive").
.DESCRIPTION Si la tarea no existe, ejecute .\Repair-OpenJarvisLab.ps1 (la crea). Código de salida 0 = JARVIS sano.
#>
$Distro = 'OpenJarvisLab'; $TaskName = 'OpenJarvisLab-KeepAlive'
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) { if ($t.State -ne 'Running') { Start-ScheduledTask -TaskName $TaskName } }
else {
  $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'OpenJarvisLab-KeepAlive.vbs'
  if (Test-Path $vbs) { Start-Process "$env:SystemRoot\System32\wscript.exe" -ArgumentList "//B //NoLogo `"$vbs`"" }
  else { Write-Host 'Mantenimiento activo no configurado: ejecute .\Repair-OpenJarvisLab.ps1' -ForegroundColor Yellow } }
$old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8
try { & wsl.exe -d $Distro -u root --exec /opt/oj/bin/ojctl.sh start; $rc = $LASTEXITCODE } finally { [Console]::OutputEncoding = $old }
if ($rc -eq 0) { Write-Host 'JARVIS activo. Hablar: .\Talk-Jarvis.ps1   Detener: .\Stop-OpenJarvisLab.ps1' -ForegroundColor Green }
else { Write-Host 'JARVIS no quedó sano: ejecute .\Repair-OpenJarvisLab.ps1' -ForegroundColor Red }
exit $rc
