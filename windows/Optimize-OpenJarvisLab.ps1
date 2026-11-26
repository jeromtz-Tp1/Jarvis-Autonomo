<#
.SYNOPSIS
  Fase 2C: optimización de rendimiento de JARVIS, REVERSIBLE, con pruebas comparativas antes y después. Un solo comando.
.DESCRIPTION
  1. Diagnóstico (equipo, GPU, WSL, servicios).
  2. Banco "ANTES": latencia separada de STT, inferencia (con y sin razonamiento, por hilos) y TTS; calidad 2B vs 4B;
     voz de extremo a extremo.
  3. Evaluación de aceleración Intel Arc: GPU en WSL (/dev/dxg) y, si -GpuEval, Ollama NATIVO de Windows con Vulkan
     (temporal, solo 127.0.0.1:11500, usando una copia local de los mismos pesos: sin descargar modelos).
  4. Aplica la optimización (camino directo, contexto 4k, modelo residente, STT rápido, precarga, TTS por frase).
  5. Banco intermedio, elige modelo (2B/4B) e hilos con reglas explícitas (ojselect.py) y lo fija.
  6. Banco "DESPUÉS" + prueba de memoria persistente real + autodiagnóstico de seguridad.
  7. Compara. Si empeora la latencia o falla alguna prueba, REVIERTE automáticamente.
  Sin gastos, sin BIND, sin cambiar la seguridad (loopback, sin Internet, allowlist, modo block).
.PARAMETER Revert     Deshace toda la optimización y vuelve exactamente al estado anterior.
.PARAMETER GpuEval    Además evalúa Ollama nativo de Windows con Vulkan en la Intel Arc (descarga ~2 GB de Ollama para Windows, temporal).
.PARAMETER TargetMs   Meta de latencia (ms) para una respuesta sencilla. Por defecto 5000.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Optimize-OpenJarvisLab.ps1
  powershell -ExecutionPolicy Bypass -File .\Optimize-OpenJarvisLab.ps1 -GpuEval
  powershell -ExecutionPolicy Bypass -File .\Optimize-OpenJarvisLab.ps1 -Revert
#>
[CmdletBinding()] param([switch]$Revert, [switch]$GpuEval, [int]$TargetMs = 5000, [int]$Runs = 3,
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenJarvisLab'))
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'; $Bundle = Split-Path $PSScriptRoot -Parent
$BundleFiles = @('windows/wsl', 'windows/BUNDLE_MANIFEST.sha256', 'patches', 'deploy/phase2-72h', 'mock', 'scripts/voice_test.py')
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'; $OutDir = Join-Path $PSScriptRoot "OPTIMIZE_$stamp"; New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$O = '/opt/oj/optimize'; $OPT = '/root/oj-bundle/windows/wsl/optimize_lab.sh --prefix /opt/oj --user jarvis'
function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function W([string[]]$a) { $o=[Console]::OutputEncoding; [Console]::OutputEncoding=[Text.Encoding]::Unicode; try { (& wsl.exe @a 2>&1 | Out-String).Replace("`0",'') } finally { [Console]::OutputEncoding=$o } }
function X([string]$cmd, [string]$user = 'root') {   # ejecuta en la distro; salida UTF-8 visible y capturada; $script:rc
  if ($cmd.Contains('"')) { throw 'X: no usar comillas dobles' }
  $o=[Console]::OutputEncoding; [Console]::OutputEncoding=[Text.Encoding]::UTF8
  try { $lines = & wsl.exe -d $Distro -u $user --exec bash -c $cmd 2>&1 | ForEach-Object { $s = "$_"; Write-Host "  $s"; $s }; $script:rc = $LASTEXITCODE } finally { [Console]::OutputEncoding=$o }
  return ,@($lines) }
function Get-Json([string]$path) { $o=[Console]::OutputEncoding; [Console]::OutputEncoding=[Text.Encoding]::UTF8
  try { (& wsl.exe -d $Distro -u root --exec cat $path 2>$null | Out-String) | ConvertFrom-Json } finally { [Console]::OutputEncoding=$o } }
function Copy-Bundle {
  $tarFile = Join-Path $InstallDir 'oj-bundle.tar'; Remove-Item $tarFile -ErrorAction SilentlyContinue
  & "$env:SystemRoot\System32\tar.exe" -cf $tarFile -C $Bundle @BundleFiles; if ($LASTEXITCODE) { throw 'tar.exe falló' }
  [void](X 'rm -rf /root/oj-bundle && install -d -m 700 /root/oj-bundle')
  & cmd.exe /d /c "wsl.exe -d $Distro -u root --exec tar -xf - -C /root/oj-bundle < `"$tarFile`""; if ($LASTEXITCODE) { throw 'no se pudo copiar el paquete a la distro' }
  Remove-Item $tarFile -ErrorAction SilentlyContinue
  [void](X 'cd /root/oj-bundle && find . -type f ! -name ''*.wav'' -exec sed -i ''s/\r$//'' {} + && sha256sum --quiet -c windows/BUNDLE_MANIFEST.sha256 && echo paquete-verificado')
  if ($script:rc) { throw 'verificación SHA256 del paquete fallida' } }
function Bench([string]$label, [string]$models, [string]$mode, [string]$serverModel, [string]$threads = '', [switch]$Voice, [switch]$Think) {
  $t = if ($threads) { "--threads $threads" } else { '' }
  $k = if ($Think) { '' } else { '--skip-think' }
  $v = if ($Voice) { '--voice-cmd /opt/oj/bin/ojvoice.sh' } else { '' }
  [void](X "install -d -o jarvis $O && install -m 755 /root/oj-bundle/windows/wsl/ojbench.py $O/ojbench.py")
  [void](X "cd /tmp && source /opt/oj/bin/ojenv.sh && python3 $O/ojbench.py --label $label --models $models --runs $Runs --server-mode $mode --server-model $serverModel $t $k --fixture /opt/oj/fixtures/stt_es.wav $v --out $O/bench_$label.json" 'jarvis')
  if ($script:rc) { throw "el banco '$label' falló" }
  $j = Get-Json "$O/bench_$label.json"; $j | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutDir "bench_$label.json") -Encoding UTF8; return $j }

# ---------------- Reversión explícita ----------------
if ($Revert) {
  Log 'Revirtiendo la optimización (estado exacto anterior)'; Copy-Bundle
  [void](X "bash $OPT revert"); if ($script:rc) { Write-Host 'La reversión informó problemas (ver arriba).' -ForegroundColor Red; exit 1 }
  Write-Host 'Optimización revertida.' -ForegroundColor Green; exit 0 }

# ---------------- 1. Diagnóstico ----------------
Log '1/7 Diagnóstico'
$cs = Get-CimInstance Win32_ComputerSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpu = (Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" }) -join '; '
Write-Host "  Equipo: $($cpu.Name.Trim()), $($cs.NumberOfLogicalProcessors) CPU, $([math]::Round($cs.TotalPhysicalMemory/1GB)) GB; GPU: $gpu"
$st = X '/opt/oj/bin/ojctl.sh status'; if ($script:rc) { Write-Host 'JARVIS no está sano: ejecute primero .\Repair-OpenJarvisLab.ps1' -ForegroundColor Red; exit 2 }
Copy-Bundle
$models = ((X 'cd /tmp && PREFIX=/opt/oj OJUSER=jarvis && source /root/oj-bundle/windows/wsl/ojlib.sh && oj_models_installed') | Where-Object { $_ -match '^\s*qwen3\.5:\d+b\s*$' } | ForEach-Object { $_.Trim() }) -join ','
if (-not $models) { Write-Host 'No hay modelos qwen3.5 instalados.' -ForegroundColor Red; exit 2 }
$vmCpu = [int]((X 'nproc') | Select-Object -Last 1).Trim()
$threadSet = (@(4, 6, $vmCpu) | Where-Object { $_ -le $vmCpu } | Sort-Object -Unique) -join ','
Write-Host "  Modelos locales: $models | CPU de la VM: $vmCpu | hilos a probar: $threadSet"
[void](X "bash $OPT status")

# Las pruebas no deben dejar datos en la memoria real de Jerónimo: instantánea ahora, restauración al final (siempre)
[void](X "bash $OPT memsnap save")
try {
# ---------------- 2. Banco ANTES ----------------
Log '2/7 Banco ANTES (configuración actual; varios minutos)'
$current0 = ((X "sed -n 's/^default_model = .\(.*\).$/\1/p' /opt/oj/home/.openjarvis/config.toml | head -1") | Select-Object -Last 1).Trim()
$before = Bench 'antes' $models 'agent' $current0 $threadSet -Voice -Think

# ---------------- 3. Aceleración Intel Arc ----------------
Log '3/7 Evaluación de aceleración Intel Arc'
$gpuReport = [ordered]@{}
$dxg = (X 'test -e /dev/dxg && echo presente || echo ausente') | Select-Object -Last 1
$gpuReport.wsl = "GPU paravirtualizada en WSL (/dev/dxg): $($dxg.Trim()). Ollama para Linux no tiene backend D3D12 y Vulkan en WSL depende del controlador experimental Mesa 'dzn' (no soportado por llama.cpp): no se adopta GPU dentro de WSL."
if ($GpuEval) {
  try {
    $ge = Join-Path $InstallDir 'gpu-eval'; New-Item -ItemType Directory -Force -Path $ge | Out-Null
    $ver = (X '/opt/oj/ollama/bin/ollama --version 2>/dev/null | grep -o ''[0-9][0-9.]*'' | tail -1') | Select-Object -Last 1
    $zip = Join-Path $ge 'ollama-windows-amd64.zip'; $base = "https://github.com/ollama/ollama/releases/download/v$($ver.Trim())"
    $ProgressPreference = 'SilentlyContinue'
    if (-not (Test-Path $zip)) { Invoke-WebRequest "$base/ollama-windows-amd64.zip" -OutFile $zip -UseBasicParsing }
    try { $sums = (Invoke-WebRequest "$base/sha256sum.txt" -UseBasicParsing).Content
          $exp = ($sums -split "`n" | Where-Object { $_ -match 'ollama-windows-amd64\.zip' } | ForEach-Object { ($_ -split '\s+')[0] }) | Select-Object -First 1
          if ($exp -and ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $exp.ToUpper())) { throw 'SHA256 del zip de Ollama no coincide' } } catch { if ($_.Exception.Message -like 'SHA256*') { throw } }
    $bin = Join-Path $ge 'ollama'; if (-not (Test-Path (Join-Path $bin 'ollama.exe'))) { Expand-Archive $zip -DestinationPath $bin -Force }
    $evalModel = ($models -split ',')[-1]; $mdir = Join-Path $ge 'models'
    $tag = $evalModel.Split(':')[1]; $mf = Join-Path $mdir "manifests\registry.ollama.ai\library\qwen3.5\$tag"
    $srcMf = ((X "cd /tmp && PREFIX=/opt/oj OJUSER=jarvis && source /root/oj-bundle/windows/wsl/ojlib.sh && oj_model_manifest $evalModel") | Select-Object -Last 1).Trim()
    if (-not (Test-Path $mf)) {
      New-Item -ItemType Directory -Force -Path (Split-Path $mf), (Join-Path $mdir 'blobs') | Out-Null
      & cmd.exe /d /c "wsl.exe -d $Distro -u root --exec cat $srcMf > `"$mf`""
      $man = Get-Content $mf -Raw | ConvertFrom-Json
      foreach ($d in @($man.config.digest) + @($man.layers | ForEach-Object digest)) { $fn = $d.Replace(':', '-'); $dst = Join-Path $mdir "blobs\$fn"
        if (-not (Test-Path $dst)) { & cmd.exe /d /c "wsl.exe -d $Distro -u root --exec cat /opt/oj/home/.ollama/models/blobs/$fn > `"$dst`"" } } }
    $env:OLLAMA_HOST = '127.0.0.1:11500'; $env:OLLAMA_MODELS = $mdir; $env:OLLAMA_VULKAN = '1'; $env:OLLAMA_KEEP_ALIVE = '10m'
    $log = Join-Path $ge 'serve.log'
    $srv = Start-Process (Join-Path $bin 'ollama.exe') -ArgumentList 'serve' -WindowStyle Hidden -PassThru -RedirectStandardError $log
    for ($i = 0; $i -lt 60; $i++) { try { Invoke-RestMethod 'http://127.0.0.1:11500/api/version' -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep 1 } }
    $body = @{ model = $evalModel; stream = $false; think = $false; keep_alive = '10m'; options = @{ num_predict = 160; num_ctx = 4096; temperature = 0.3 }
               messages = @(@{ role = 'system'; content = 'Eres JARVIS. Responde en español, en una o dos frases cortas.' }, @{ role = 'user'; content = '¿Cuál es la capital de Francia?' }) } | ConvertTo-Json -Depth 5
    $load = Measure-Command { $null = Invoke-RestMethod 'http://127.0.0.1:11500/api/chat' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' -TimeoutSec 900 }
    $walls = @(); $last = $null
    for ($i = 0; $i -lt $Runs; $i++) { $sw = [Diagnostics.Stopwatch]::StartNew()
      $last = Invoke-RestMethod 'http://127.0.0.1:11500/api/chat' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' -TimeoutSec 900; $walls += $sw.ElapsedMilliseconds }
    $lib = (Select-String -Path $log -Pattern 'library=(\w+)' -AllMatches | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -Unique) -join ','
    $dev = (Select-String -Path $log -Pattern 'description="?([^"]+)"?' | Select-Object -First 1 | ForEach-Object { $_.Matches.Groups[1].Value })
    $gen = [math]::Round($last.eval_count / ($last.eval_duration / 1e9), 1); $pr = [math]::Round($last.prompt_eval_count / ([math]::Max(1, $last.prompt_eval_duration) / 1e9), 1)
    $wslGen = $before.modelos.$evalModel.sin_razonamiento.muestra.tok_s_generacion; $wslPr = $before.modelos.$evalModel.sin_razonamiento.muestra.tok_s_prompt
    $gpuReport.nativo = [ordered]@{ modelo = $evalModel; backend = $lib; dispositivo = $dev; carga_ms = [int]$load.TotalMilliseconds
      wall_p50_ms = ($walls | Sort-Object)[[int][math]::Floor($walls.Count/2)]; tok_s_generacion = $gen; tok_s_prompt = $pr
      wsl_cpu_tok_s_generacion = $wslGen; wsl_cpu_tok_s_prompt = $wslPr
      aceleracion_generacion = if ($wslGen) { [math]::Round($gen / $wslGen, 2) } else { $null } }
    Write-Host "  Ollama nativo Windows ($lib, $dev): $gen tok/s generación, $pr tok/s prompt (WSL CPU: $wslGen / $wslPr)"
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue; Get-Process ollama*, llama* -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$ge*" } | Stop-Process -Force
    Remove-Item Env:OLLAMA_HOST, Env:OLLAMA_MODELS, Env:OLLAMA_VULKAN, Env:OLLAMA_KEEP_ALIVE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $mdir -ErrorAction SilentlyContinue   # la copia de pesos se elimina; el zip queda para repetir
  } catch { $gpuReport.nativo = "evaluación no completada: $($_.Exception.Message)" ; Write-Host "  $($gpuReport.nativo)" -ForegroundColor Yellow }
} else { $gpuReport.nativo = 'no ejecutada (añada -GpuEval para medir Ollama nativo de Windows con Vulkan en la Intel Arc)' }
$gpuReport | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'gpu_eval.json') -Encoding UTF8

# ---------------- 4-5. Aplicar, medir y elegir modelo/hilos ----------------
Log '4/7 Aplicando optimización (reversible)'
$current = $current0 -replace '^jarvis-voz:', 'qwen3.5:'
[void](X "bash $OPT apply --model $current --threads $vmCpu"); if ($script:rc) { Log 'La aplicación falló: revirtiendo'; [void](X "bash $OPT revert"); exit 3 }
Log '5/7 Banco intermedio y selección de modelo e hilos'
$mid = Bench 'intermedio' $models 'stream' ('jarvis-voz:' + $current.Split(':')[1]) $threadSet
$sel = (X "python3 /root/oj-bundle/windows/wsl/ojselect.py $O/bench_intermedio.json $TargetMs" | Select-Object -Last 1) | ConvertFrom-Json
Write-Host "  Elegido: $($sel.model) con $($sel.threads) hilos — $($sel.motivo) (estimado $($sel.estimado_ms) ms)" -ForegroundColor Green
$sel | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'seleccion.json') -Encoding UTF8
$th = if ($sel.threads) { $sel.threads } else { $vmCpu }
[void](X "bash $OPT apply --model $($sel.model) --threads $th"); if ($script:rc) { Log 'Fallo al fijar el modelo: revirtiendo'; [void](X "bash $OPT revert"); exit 3 }

# ---------------- 6. DESPUÉS + memoria + seguridad ----------------
Log '6/7 Banco DESPUÉS, memoria persistente real y seguridad'
$selDerived = $sel.model -replace '^qwen3.5:', 'jarvis-voz:'
$after = Bench 'despues' $selDerived 'stream' $selDerived -Voice
$self = X 'cd /tmp && PREFIX=/opt/oj OJUSER=jarvis && source /root/oj-bundle/windows/wsl/ojlib.sh && oj_selftest /opt/oj/optimize/selftest_despues'
$selfFails = ($self | Where-Object { $_ -match '\[FALLO\]' }).Count
$self | Set-Content (Join-Path $OutDir 'selftest_despues.txt') -Encoding UTF8

# ---------------- 7. Comparación y decisión ----------------
Log '7/7 Comparación'
function P($o) { if ($o) { $o.p50 } else { $null } }
$bm = $before.modelos.$current; $am = $after.modelos.$selDerived
$rows = @(
  @('STT (audio de 3.5 s)', (P $before.stt_ms), (P $after.stt_ms)),
  @('TTS (frase de 4 s)', (P $before.tts_ms), (P $after.tts_ms)),
  @("Respuesta sencilla por el servidor ($current0 -> $selDerived)", (P $before.servidor.ms), (P $after.servidor.ms)),
  @('Primer token del servidor', (P $before.servidor.ms), (P $after.servidor.primer_token_ms)),
  @("Modelo directo ($current -> $($sel.model))", (P $bm.modelo_ms), (P $am.modelo_ms)),
  @('Voz extremo a extremo: respuesta completa', (P $before.voz_total_ms), (P $after.voz_total_ms)),
  @('Voz extremo a extremo: primera voz', (P $before.voz_total_ms), (P $after.voz_primera_voz_ms)))
$md = @("# Optimización OpenJarvisLab (Fase 2C) — $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '',
  "Equipo: $($cpu.Name.Trim()), $($cs.NumberOfLogicalProcessors) CPU, $([math]::Round($cs.TotalPhysicalMemory/1GB)) GB, GPU: $gpu", '',
  '| Métrica (p50, ms) | Antes | Después | Mejora |', '|---|---|---|---|')
foreach ($r in $rows) { $imp = if ($r[1] -and $r[2]) { '{0:N1}x' -f ($r[1] / [math]::Max(1, $r[2])) } else { '—' }; $md += "| $($r[0]) | $($r[1]) | $($r[2]) | $imp |" }
$md += ''; $md += "**Calidad** (8 preguntas verificables): " + (($mid.modelos.PSObject.Properties | ForEach-Object { "$($_.Name) $($_.Value.calidad) (breves $($_.Value.brevedad))" }) -join ' · ')
$think = ($before.modelos.PSObject.Properties | ForEach-Object { $c = $_.Value.con_razonamiento; $s = $_.Value.sin_razonamiento.muestra; if ($c) { "$($_.Name): con razonamiento $($c.wall_ms) ms ($($c.razonamiento_chars) caracteres pensados) vs sin razonamiento $($s.wall_ms) ms" } }) -join ' · '
$md += "**Razonamiento extendido:** $think. Desactivado en la voz (el motor envía think=false y se retiró la herramienta 'think')."
$md += "**Hilos** ($($sel.model)): " + (($mid.modelos.($sel.model).hilos.PSObject.Properties | ForEach-Object { "$($_.Name) hilos = $($_.Value.wall_ms.p50) ms" }) -join ' · ')
$md += "**Selección:** $($sel.model), $th hilos — $($sel.motivo)."
$md += "**GPU Intel Arc:** $($gpuReport.wsl)"
$md += "**Ollama nativo Windows:** " + $(if ($gpuReport.nativo -is [string]) { $gpuReport.nativo } else { ($gpuReport.nativo.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' })
$first = P $after.voz_primera_voz_ms; $total = P $after.voz_total_ms
$md += "**Meta (< $TargetMs ms):** primera voz $first ms, respuesta completa $total ms → " + $(if ($first -and $first -le $TargetMs) { 'CUMPLIDA (primera voz)' } else { 'NO cumplida en este hardware' })
$md += "**Autodiagnóstico después:** $selfFails fallo(s) (incluye memoria persistente real y seguridad)."
$worse = ($total -and (P $before.voz_total_ms) -and $total -gt (P $before.voz_total_ms))
if ($selfFails -gt 0 -or $worse) {
  $md += ''; $md += "**DECISIÓN: REVERTIDO automáticamente** (" + $(if ($worse) { 'la latencia empeoró' } else { 'fallaron pruebas' }) + '). El sistema quedó como antes.'
  [void](X "bash $OPT revert")
} else { $md += ''; $md += '**DECISIÓN: OPTIMIZACIÓN APLICADA.** Revertir en cualquier momento: `.\Optimize-OpenJarvisLab.ps1 -Revert`' }
} finally { Log 'Restaurando la memoria del usuario (sin datos de prueba)'; [void](X "bash $OPT memsnap restore") }
$rep = Join-Path $PSScriptRoot "OPTIMIZE_REPORT_$stamp.md"; $md | Set-Content $rep -Encoding UTF8
Write-Host "`n$($md -join "`n")`n`nInforme: $rep  · Datos: $OutDir" -ForegroundColor Green
if ($selfFails -gt 0 -or $worse) { exit 1 } else { exit 0 }
