<#
.SYNOPSIS
  Diagnóstico de SOLO LECTURA: ¿puede esta PC con Windows alojar OpenJarvis en WSL2? Emite GO / CONDICIONAL / NO-GO.
.DESCRIPTION
  No instala nada, no cambia configuración, no requiere administrador y no envía datos a ningún sitio.
  Lee: CPU (incl. AVX2), RAM, GPU, discos, versión de Windows, virtualización, WSL, Docker, puertos 8000/11434,
  energía (portátil/batería) y si Ollama para Windows ya está instalado.
  Escribe un informe en .\openjarvis_readiness.txt y .\openjarvis_readiness.json (junto a este script).
  Umbrales derivados de lo medido en las Fases 1 y 2 (modelo qwen3.5:2b: ~4.5 GB RAM en uso; instalación ~15 GB).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Test-OpenJarvisReadiness.ps1
#>
[CmdletBinding()] param([string]$InstallDrive = $env:SystemDrive)
$ErrorActionPreference = 'SilentlyContinue'
$r = [ordered]@{}; $checks = New-Object System.Collections.ArrayList
function Add-Check($name, $status, $detail) { [void]$checks.Add([pscustomobject]@{Check=$name; Status=$status; Detail=$detail}) }
function Invoke-Wsl([string[]]$a) {   # wsl.exe escribe UTF-16; se decodifica correctamente
  $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::Unicode
  try { (& wsl.exe @a 2>&1 | Out-String).Replace("`0", '').Trim() } finally { [Console]::OutputEncoding = $old } }

# --- Sistema operativo
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$r.os = "$($os.Caption) build $build ($($os.OSArchitecture))"
if ($os.OSArchitecture -notmatch '64') { Add-Check 'Windows' 'NO-GO' 'Se requiere Windows de 64 bits' }
elseif ($build -ge 22000) { Add-Check 'Windows' 'GO' $r.os }
elseif ($build -ge 19041) { Add-Check 'Windows' 'GO' "$($r.os) (Windows 10 compatible con WSL2)" }
else { Add-Check 'Windows' 'NO-GO' "$($r.os): WSL2 requiere build 19041 o superior" }

# --- CPU
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$logical = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Add-Type -Namespace OJ -Name K32 -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);' 2>$null
$avx2 = [OJ.K32]::IsProcessorFeaturePresent(40)   # PF_AVX2_INSTRUCTIONS_AVAILABLE
$r.cpu = "$($cpu.Name.Trim()) | $($cpu.NumberOfCores) núcleos / $logical hilos | AVX2: $avx2"
if ($logical -ge 8 -and $avx2) { Add-Check 'CPU' 'GO' $r.cpu }
elseif ($logical -ge 4 -and $avx2) { Add-Check 'CPU' 'GO' "$($r.cpu) (suficiente para modelo 2B; respuestas ~5-15 s)" }
elseif ($logical -ge 4) { Add-Check 'CPU' 'CONDICIONAL' "$($r.cpu): sin AVX2 la inferencia en CPU será muy lenta" }
else { Add-Check 'CPU' 'NO-GO' "$($r.cpu): se requieren al menos 4 hilos" }

# --- RAM (WSL2 usa por defecto hasta el 50 % de la RAM física)
$totGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$freeGB = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
$wslGB = [math]::Round($totGB / 2, 1)
$r.ram = "Total $totGB GB | libre ahora $freeGB GB | límite por defecto de WSL2 ~$wslGB GB"
if ($totGB -ge 31) { Add-Check 'RAM' 'GO' "$($r.ram) (admite modelo 4B)" }
elseif ($totGB -ge 15) { Add-Check 'RAM' 'GO' "$($r.ram) (modelo 2B; cerrar apps pesadas durante pruebas largas)" }
elseif ($totGB -ge 11) { Add-Check 'RAM' 'CONDICIONAL' "$($r.ram): justo para el modelo 2B sin voz simultánea" }
else { Add-Check 'RAM' 'NO-GO' "$($r.ram): se requieren al menos 12 GB físicos (16 GB recomendados)" }
if ($freeGB -lt 6) { Add-Check 'RAM libre ahora' 'CONDICIONAL' "Solo $freeGB GB libres: cerrar aplicaciones antes de instalar/probar" }

# --- GPU (opcional; acelera si es NVIDIA)
$gpus = Get-CimInstance Win32_VideoController
$gpuTxt = @(); $nvidia = $false
foreach ($g in $gpus) { $gpuTxt += "$($g.Name) (driver $($g.DriverVersion))"; if ($g.Name -match 'NVIDIA') { $nvidia = $true } }
$vram = ''
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { $vram = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null | Out-String).Trim() }
$r.gpu = ($gpuTxt -join '; ') + $(if ($vram) { " | nvidia-smi: $vram" } else { '' })
if ($nvidia -and $vram) { Add-Check 'GPU' 'GO' "$($r.gpu) — se usará CUDA en WSL2" } else { Add-Check 'GPU' 'INFO' "$($r.gpu) — no requerida; se usará CPU" }

# --- Disco
$drv = $InstallDrive.TrimEnd('\').TrimEnd(':')
$vol = Get-Volume -DriveLetter $drv
$freeDisk = [math]::Round($vol.SizeRemaining / 1GB, 1)
$r.disk = "Unidad ${drv}: libre $freeDisk GB de $([math]::Round($vol.Size/1GB,1)) GB ($($vol.FileSystem))"
if ($freeDisk -ge 40) { Add-Check 'Disco' 'GO' $r.disk } elseif ($freeDisk -ge 25) { Add-Check 'Disco' 'CONDICIONAL' "$($r.disk): suficiente, con poco margen (instalación ~15-20 GB)" } else { Add-Check 'Disco' 'NO-GO' "$($r.disk): se requieren al menos 25 GB libres" }
$disk = Get-PhysicalDisk | Select-Object -First 1 FriendlyName, MediaType
$r.diskType = "$($disk.FriendlyName) $($disk.MediaType)"

# --- Virtualización
$cs = Get-CimInstance Win32_ComputerSystem
$virtFw = $cpu.VirtualizationFirmwareEnabled; $hyp = $cs.HypervisorPresent
$r.virtualization = "Firmware: $virtFw | Hipervisor activo: $hyp"
if ($hyp -or $virtFw) { Add-Check 'Virtualización' 'GO' $r.virtualization } else { Add-Check 'Virtualización' 'NO-GO' "$($r.virtualization): activar VT-x/AMD-V en BIOS/UEFI" }

# --- WSL
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslExe) { $r.wsl = 'wsl.exe no encontrado'; Add-Check 'WSL2' 'ACCION' 'WSL no instalado: requiere "wsl --install --no-distribution" como administrador y reiniciar (una vez)' }
else {
  $ver = Invoke-Wsl @('--version'); $st = Invoke-Wsl @('--status'); $list = Invoke-Wsl @('-l', '-v')
  $r.wsl = "version: $($ver -replace '\s+',' ') | status: $($st -replace '\s+',' ') | distros: $($list -replace '\s+',' ')"
  if ($ver -match 'WSL[^\d]*(\d+\.\d+\.\d+)') { Add-Check 'WSL2' 'GO' "WSL $($Matches[1]) instalado" }
  elseif ($st -match '2') { Add-Check 'WSL2' 'GO' "WSL instalado (versión predeterminada 2)" }
  else { Add-Check 'WSL2' 'ACCION' "WSL presente pero sin componente actualizado: ejecutar 'wsl --update' (sin reinicio normalmente)" }
  if ($list -match 'OpenJarvisLab') { Add-Check 'Distro OpenJarvisLab' 'INFO' 'Ya existe (el instalador la reutiliza)' }
}

# --- Docker (no se usa; solo inventario)
$dk = Get-Command docker -ErrorAction SilentlyContinue
$r.docker = if ($dk) { (& docker version --format '{{.Client.Version}} / server {{.Server.Version}}' 2>&1 | Out-String).Trim() } else { 'no instalado' }
Add-Check 'Docker' 'INFO' "$($r.docker) — no es necesario: OpenJarvis irá en una distro WSL dedicada"

# --- Puertos y Ollama existente
$busy = @(Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 8000, 11434 } | ForEach-Object { "$($_.LocalPort) (PID $($_.OwningProcess) $((Get-Process -Id $_.OwningProcess).ProcessName))" })
$r.ports = if ($busy) { $busy -join ', ' } else { '8000 y 11434 libres' }
if ($busy) { Add-Check 'Puertos' 'CONDICIONAL' "Ocupados: $($r.ports). El laboratorio usará otros puertos o hay que cerrar ese programa" } else { Add-Check 'Puertos' 'GO' $r.ports }
$ollamaWin = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaWin) { Add-Check 'Ollama Windows' 'INFO' "Instalado en $($ollamaWin.Source): no se usará ni modificará" }

# --- Energía (relevante para pruebas largas)
$bat = Get-CimInstance Win32_Battery
$r.power = if ($bat) { "Portátil, batería $($bat.EstimatedChargeRemaining)% $(if ($bat.BatteryStatus -eq 2) {'(conectado)'} else {'(EN BATERÍA)'})" } else { 'Equipo de escritorio / sin batería' }
if ($bat) { Add-Check 'Energía' 'INFO' "$($r.power): mantener conectado y evitar suspensión durante la prueba de 30-72 h" }

# --- Gestión corporativa (informativo)
$r.domain = if ($cs.PartOfDomain) { "Unido a dominio $($cs.Domain)" } else { 'No unido a dominio' }

# --- Veredicto
$verdict = if ($checks.Status -contains 'NO-GO') { 'NO-GO' } elseif ($checks.Status -contains 'ACCION') { 'GO tras acción única (ver ACCION)' } elseif ($checks.Status -contains 'CONDICIONAL') { 'CONDICIONAL' } else { 'GO' }
$model = if ($totGB -ge 31 -and $avx2) { 'qwen3.5:4b' } else { 'qwen3.5:2b' }
$r.verdict = $verdict; $r.recommended_model = $model; $r.generated_utc = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
$out = Join-Path $PSScriptRoot 'openjarvis_readiness'
$checks | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Set-Content "$out.txt" -Encoding UTF8
("`nVEREDICTO: $verdict  |  Modelo recomendado: $model`n" + ($r.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "`n") | Add-Content "$out.txt" -Encoding UTF8
[pscustomobject]@{ summary = $r; checks = $checks } | ConvertTo-Json -Depth 4 | Set-Content "$out.json" -Encoding UTF8
$checks | Format-Table -AutoSize -Wrap
Write-Host "`nVEREDICTO: $verdict   Modelo recomendado: $model" -ForegroundColor $(if ($verdict -eq 'GO') {'Green'} elseif ($verdict -like 'NO-GO*') {'Red'} else {'Yellow'})
Write-Host "Informe: $out.txt / $out.json (no contiene contraseñas ni claves)"
