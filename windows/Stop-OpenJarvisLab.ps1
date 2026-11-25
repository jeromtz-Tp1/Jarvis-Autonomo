<#  .SYNOPSIS Kill-switch: detiene OpenJarvis y apaga la distro dedicada (los datos se conservan). #>
$Distro = 'OpenJarvisLab'
& wsl.exe -d $Distro -u root -- /opt/oj/bin/ojctl.sh stop 2>$null
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -match "$Distro.*sleep infinity" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
& wsl.exe --terminate $Distro
Write-Host "OpenJarvisLab detenido."
