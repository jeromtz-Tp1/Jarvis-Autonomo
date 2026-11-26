<#  .SYNOPSIS Kill-switch: detiene JARVIS y apaga la distro dedicada (los datos y modelos se conservan).
    .DESCRIPTION Detiene primero la tarea de mantenimiento activo para que no vuelva a arrancar la distro. #>
$Distro = 'OpenJarvisLab'; $TaskName = 'OpenJarvisLab-KeepAlive'
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" | Where-Object { $_.CommandLine -match 'OpenJarvisLab-KeepAlive|keepalive\.vbs' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
& wsl.exe -d $Distro -u root --exec /opt/oj/bin/ojctl.sh stop 2>$null | Out-Null
& wsl.exe --terminate $Distro | Out-Null
Write-Host 'JARVIS detenido. Volver a arrancar: .\Start-OpenJarvisLab.ps1 (o al iniciar sesión en Windows).'
