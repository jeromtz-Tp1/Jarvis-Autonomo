<#
.SYNOPSIS
  Repara la instalación EXISTENTE de OpenJarvisLab con un solo comando, sin reinstalar ni volver a descargar modelos.
.DESCRIPTION
  1. Diagnóstico automático de Windows/WSL (RAM, CPU, .wslconfig, distro, disco).
  2. Recursos persistentes: asegura que la VM de WSL tenga memoria suficiente para el presupuesto de JARVIS
     (hasta 10 GB y 6 CPU, adaptado al equipo) y lo fija en un drop-in systemd que sobrevive reinicios.
  3. Copia local verificada (SHA256) de los scripts corregidos a la distro (sin red ni credenciales).
  4. Reparación dentro de la distro (repair_lab.sh): aislamiento, componentes, scripts, servicios.
  5. WSL siempre activo: tarea programada de usuario "OpenJarvisLab-KeepAlive" (al iniciar sesión, oculta, se relanza sola).
  6. Pruebas independientes: inferencia, STT, TTS, voz extremo a extremo, memoria y seguridad. Errores HTTP visibles.
  Conserva todas las restricciones de seguridad. No conecta BIND ni producción. Sin gastos. No requiere administrador.
.PARAMETER AllowModelDownload  Permite descargar un modelo SOLO si falta (por defecto: nunca descarga).
.PARAMETER AllowWslShutdown    Permite "wsl --shutdown" para aplicar más memoria aunque haya otras distros en uso (p. ej. Docker).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Repair-OpenJarvisLab.ps1
#>
[CmdletBinding()] param([switch]$AllowModelDownload, [switch]$AllowWslShutdown,
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenJarvisLab'))
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'; $TaskName = 'OpenJarvisLab-KeepAlive'
$Bundle = Split-Path $PSScriptRoot -Parent
$BundleFiles = @('windows/wsl', 'windows/BUNDLE_MANIFEST.sha256', 'patches', 'deploy/phase2-72h', 'mock', 'scripts/voice_test.py')
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$Report = Join-Path $PSScriptRoot "REPAIR_REPORT_$stamp.md"
$results = New-Object System.Collections.ArrayList
function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Res($area, $ok, $detail) { [void]$results.Add([pscustomobject]@{Area=$area; Estado=$(if ($ok -eq $true) {'OK'} elseif ($ok -eq $false) {'FALLO'} else {'AVISO'}); Detalle=$detail})
  $c = if ($ok -eq $true) {'Green'} elseif ($ok -eq $false) {'Red'} else {'Yellow'}; Write-Host "  [$($results[-1].Estado)] $area - $detail" -ForegroundColor $c }
function W([string[]]$a) { $o=[Console]::OutputEncoding; [Console]::OutputEncoding=[Text.Encoding]::Unicode; try { (& wsl.exe @a 2>&1 | Out-String).Replace("`0",'') } finally { [Console]::OutputEncoding=$o } }
function InDistroOut([string]$cmd) {   # salida UTF-8 de Linux, visible en pantalla y capturada
  if ($cmd.Contains('"')) { throw 'InDistro: no usar comillas dobles' }
  $o=[Console]::OutputEncoding; [Console]::OutputEncoding=[Text.Encoding]::UTF8
  try { $lines = & wsl.exe -d $Distro -u root --exec bash -c $cmd 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $s }; $script:rc = $LASTEXITCODE } finally { [Console]::OutputEncoding=$o }
  return ,@($lines) }
function Running { ((W @('-l','--running','-q')) -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $Distro }
function Finish([int]$code) {
  $okN = @($results | Where-Object Estado -eq 'OK').Count; $failN = @($results | Where-Object Estado -eq 'FALLO').Count
  $verdict = if ($failN -eq 0) { 'JARVIS REPARADO Y OPERATIVO' } else { "REPARACIÓN INCOMPLETA: $failN fallo(s)" }
  $md = @("# Reparación OpenJarvisLab — $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '', "**Resultado:** $verdict", '', '| Área | Estado | Detalle |', '|---|---|---|')
  $md += $results | ForEach-Object { "| $($_.Area) | **$($_.Estado)** | $($_.Detalle -replace '\|','/') |" }
  $md | Set-Content $Report -Encoding UTF8
  Write-Host "`n$verdict ($okN OK, $failN fallos). Informe: $Report" -ForegroundColor $(if ($failN -eq 0) {'Green'} else {'Red'})
  if ($failN -eq 0) { Write-Host 'Hablar con JARVIS:  .\Talk-Jarvis.ps1' -ForegroundColor Green }
  exit $code }

# ---------------- 1. Diagnóstico de Windows / WSL ----------------
Log '1/6 Diagnóstico de Windows y WSL'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { Res 'WSL' $false 'wsl.exe no encontrado: ejecute Install-OpenJarvisLab.ps1'; Finish 2 }
$distros = (W @('-l','-q')) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($distros -notcontains $Distro) { Res 'Distro' $false "No existe '$Distro'. Ejecute Install-OpenJarvisLab.ps1"; Finish 2 }
Res 'Distro' $true "$Distro presente"
$cs = Get-CimInstance Win32_ComputerSystem
$hostGB = [math]::Floor($cs.TotalPhysicalMemory / 1GB); $hostCpu = $cs.NumberOfLogicalProcessors
Res 'Equipo' $true "$hostGB GB RAM, $hostCpu CPU lógicas"
foreach ($f in $BundleFiles) { if (-not (Test-Path (Join-Path $Bundle $f))) { Res 'Paquete' $false "Falta '$f' en $Bundle (descomprima el ZIP completo)"; Finish 2 } }

# ---------------- 2. Recursos persistentes (.wslconfig) ----------------
Log '2/6 Recursos de la VM de WSL'
$wslcfg = Join-Path $env:USERPROFILE '.wslconfig'
try { $vmMB = [int](((InDistroOut 'awk ''/MemTotal/{print int($2/1024)}'' /proc/meminfo') | Select-Object -Last 1).Trim()) } catch { $vmMB = 0 }
$targetGB = [math]::Min(12, $hostGB - 4)          # 10 GB para JARVIS + 1.5 GB sistema de la distro; deja >=4 GB a Windows
$wantCpu = [math]::Min(6, $hostCpu)
if ($targetGB -lt 9) { Res 'Recursos' $null "Equipo con $hostGB GB: la VM solo puede tener ~$targetGB GB; JARVIS usará menos memoria (más lento con el modelo 4B)" }
$changed = $false
if ($vmMB -lt ($targetGB * 1024 - 768)) {
  $lines = if (Test-Path $wslcfg) { Copy-Item $wslcfg "$wslcfg.bak-$stamp"; @(Get-Content $wslcfg) } else { @() }
  if (-not ($lines -match '^\s*\[wsl2\]')) { $lines += '[wsl2]' }
  $out = New-Object System.Collections.ArrayList; $inWsl2 = $false; $setMem = $false; $setCpu = $false
  foreach ($l in $lines) {
    if ($l -match '^\s*\[') { if ($inWsl2 -and -not $setMem) { [void]$out.Add("memory=${targetGB}GB"); $setMem = $true }; $inWsl2 = ($l -match '^\s*\[wsl2\]') ; [void]$out.Add($l); continue }
    if ($inWsl2 -and $l -match '^\s*memory\s*=') { [void]$out.Add("memory=${targetGB}GB"); $setMem = $true; continue }
    if ($inWsl2 -and $l -match '^\s*processors\s*=\s*(\d+)') { $p = [int]$Matches[1]; [void]$out.Add("processors=$([math]::Max($p,$wantCpu))"); $setCpu = $true; continue }
    [void]$out.Add($l) }
  if ($inWsl2 -and -not $setMem) { [void]$out.Add("memory=${targetGB}GB") }
  [IO.File]::WriteAllLines($wslcfg, [string[]]$out, (New-Object Text.UTF8Encoding $false)); $changed = $true
  Res 'Recursos' $true "VM con $vmMB MB < objetivo; .wslconfig: memory=${targetGB}GB (copia de seguridad: .wslconfig.bak-$stamp)"
} else { Res 'Recursos' $true "VM WSL con $vmMB MB y CPU suficientes para el presupuesto de JARVIS" }
if ($changed) {
  $others = ((W @('-l','--running','-q')) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne $Distro })
  if ($others -and -not $AllowWslShutdown) { Res 'Recursos' $null "Hay otras distros en uso ($($others -join ', ')); la nueva memoria se aplicará en el próximo reinicio de WSL o repitiendo con -AllowWslShutdown" }
  else { Log 'Reiniciando WSL para aplicar la memoria (wsl --shutdown)'; & wsl.exe --shutdown; Start-Sleep 8 }
}

# ---------------- 3. Scripts corregidos -> distro (copia local verificada) ----------------
Log '3/6 Copia local verificada de los scripts corregidos'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$tarFile = Join-Path $InstallDir 'oj-bundle.tar'; Remove-Item $tarFile -ErrorAction SilentlyContinue
& "$env:SystemRoot\System32\tar.exe" -cf $tarFile -C $Bundle @BundleFiles; if ($LASTEXITCODE) { Res 'Paquete' $false 'tar.exe falló'; Finish 3 }
[void](InDistroOut 'rm -rf /root/oj-bundle && install -d -m 700 /root/oj-bundle')
& cmd.exe /d /c "wsl.exe -d $Distro -u root --exec tar -xf - -C /root/oj-bundle < `"$tarFile`""
if ($LASTEXITCODE) {
  $unc = @("\\wsl.localhost\$Distro\root\oj-bundle", "\\wsl$\$Distro\root\oj-bundle") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $unc) { Res 'Paquete' $false 'no se pudo copiar a la distro'; Finish 3 }
  foreach ($f in $BundleFiles) { $dst = Join-Path $unc $f; New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null; Copy-Item -Recurse -Force (Join-Path $Bundle $f) $dst } }
Remove-Item $tarFile -ErrorAction SilentlyContinue
[void](InDistroOut 'cd /root/oj-bundle && find . -type f ! -name ''*.wav'' -exec sed -i ''s/\r$//'' {} + && sha256sum --quiet -c windows/BUNDLE_MANIFEST.sha256')
if ($script:rc) { Res 'Paquete' $false 'verificación SHA256 fallida: archivos alterados o incompletos'; Finish 3 }
Res 'Paquete' $true 'scripts copiados y verificados (SHA256)'

# ---------------- 4. Reparación dentro de la distro ----------------
Log '4/6 Reparación dentro de la distro (puede tardar 2-5 min: arranque y pruebas)'
$args4 = '--prefix /opt/oj --user jarvis' + $(if ($AllowModelDownload) { ' --allow-model-download' } else { '' })
$out = InDistroOut "bash /root/oj-bundle/windows/wsl/repair_lab.sh $args4"
if ($out -match 'WSLCONF_CHANGED=1') {
  Log 'Reiniciando la distro para activar systemd/aislamiento'; & wsl.exe --terminate $Distro | Out-Null; Start-Sleep 4
  $out = InDistroOut "bash /root/oj-bundle/windows/wsl/repair_lab.sh $args4" }
$rcRepair = $script:rc
foreach ($l in $out) { if ($l -match '^\s*\[(OK|FALLO|AVISO)\]\s+(.*)$') { $st = @{OK=$true; FALLO=$false; AVISO=$null}[$Matches[1]]; [void]$results.Add([pscustomobject]@{Area='Distro'; Estado=$Matches[1]; Detalle=$Matches[2]}) } }
if ($rcRepair -eq 3) { Res 'Instalación' $false 'incompleta: ver [FALLO] arriba (si falta un modelo: -AllowModelDownload)'; Finish 4 }
if ($rcRepair -eq 4) { Res 'Servicios' $false 'no arrancan: ver registro mostrado arriba'; Finish 4 }

# ---------------- 5. WSL siempre activo ----------------
Log '5/6 Mantener WSL activo (tarea programada de usuario)'
$vbs = Join-Path $InstallDir 'keepalive.vbs'
@('Set sh = CreateObject("WScript.Shell")', 'Do', "  sh.Run ""wsl.exe -d $Distro -u root --exec /bin/sleep infinity"", 0, True", '  WScript.Sleep 15000', 'Loop') | Set-Content $vbs -Encoding ASCII
$keep = 'ninguno'
try {
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "//B //NoLogo `"$vbs`""
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $user
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
  $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName; $keep = "tarea programada '$TaskName'"
} catch {
  $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'OpenJarvisLab-KeepAlive.vbs'
  Copy-Item $vbs $startup -Force; Start-Process "$env:SystemRoot\System32\wscript.exe" -ArgumentList "//B //NoLogo `"$startup`""
  $keep = "acceso directo en Inicio ($($_.Exception.Message))" }
Start-Sleep 20   # sin ninguna sesión wsl.exe propia abierta: debe seguir activa gracias al keep-alive
if (Running) { Res 'WSL activo' $true "la distro sigue en ejecución sin sesiones abiertas ($keep; se relanza al iniciar sesión)" }
else { Res 'WSL activo' $false "la distro se detuvo pese a $keep" }

# ---------------- 6. Estado final ----------------
Log '6/6 Comprobación final de servicios'
$st = InDistroOut '/opt/oj/bin/ojctl.sh status'
Res 'Servicios' ($script:rc -eq 0) (($st | Where-Object { $_ -match 'server:|ojl-' }) -join '; ')
if ($rcRepair -eq 1) { Res 'Pruebas' $false 'alguna prueba independiente falló (ver tabla)' } elseif ($rcRepair -eq 0) { Res 'Pruebas' $true 'inferencia, STT, TTS, voz, memoria y seguridad superadas' }
Finish $(if (@($results | Where-Object Estado -eq 'FALLO').Count) { 1 } else { 0 })
