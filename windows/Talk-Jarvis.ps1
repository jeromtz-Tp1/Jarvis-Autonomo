<#
.SYNOPSIS
  Habla con JARVIS por voz (micrófono y altavoces). Todo se procesa localmente en la distro OpenJarvisLab.
.DESCRIPTION
  Enter = empezar a hablar, Enter = terminar, q = salir. Muestra errores reales (código HTTP y motivo); nunca dice
  "Listo" si el turno anterior falló. Sin instalaciones: graba con winmm y reproduce con System.Media.SoundPlayer.
  El audio viaja a la distro por stdin/stdout de wsl.exe; no se expone ningún puerto.
.EXAMPLE
  .\Talk-Jarvis.ps1
  .\Talk-Jarvis.ps1 -Text "Hola Jarvis"
#>
[CmdletBinding()] param([string]$Text = '', [int]$MaxSeconds = 30)
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'
$work = Join-Path $env:TEMP 'OpenJarvisVoice'; New-Item -ItemType Directory -Force -Path $work | Out-Null
$inWav = Join-Path $work 'in.wav'; $outWav = Join-Path $work 'out.wav'; $outTxt = Join-Path $work 'out.txt'
$Reasons = @{ 2 = 'No llegó audio: revise el micrófono y Configuración > Privacidad > Micrófono > "Permitir que las aplicaciones de escritorio accedan".'
              10 = 'El servidor JARVIS no responde. Ejecute .\Repair-OpenJarvisLab.ps1'
              11 = 'Falló la transcripción (STT). Detalle arriba. Si persiste: .\Repair-OpenJarvisLab.ps1'
              12 = 'Falló la inferencia (modelo). Detalle arriba. Si persiste: .\Repair-OpenJarvisLab.ps1'
              13 = 'Falló la síntesis de voz (TTS). Detalle arriba. Si persiste: .\Repair-OpenJarvisLab.ps1' }
Add-Type -Namespace OJ -Name Mci -MemberDefinition '[DllImport("winmm.dll", CharSet = CharSet.Unicode)] public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int len, System.IntPtr cb);' -ErrorAction SilentlyContinue
function Mci([string]$c) { $rc = [OJ.Mci]::mciSendString($c, $null, 0, [IntPtr]::Zero); if ($rc -ne 0) { [void][OJ.Mci]::mciSendString('close ojrec', $null, 0, [IntPtr]::Zero); throw "Error de grabación (MCI $rc) en '$c'. ¿Hay micrófono conectado y permitido para aplicaciones de escritorio?" } }
function Test-Jarvis {
  $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8
  try { $st = (& wsl.exe -d $Distro -u root --exec /opt/oj/bin/ojctl.sh status 2>&1 | Out-String); $ok = ($LASTEXITCODE -eq 0) } finally { [Console]::OutputEncoding = $old }
  if (-not $ok) {
    Write-Host 'JARVIS no está activo; arrancando...' -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Start-OpenJarvisLab.ps1') | Out-Null
    $st = (& wsl.exe -d $Distro -u root --exec /opt/oj/bin/ojctl.sh status 2>&1 | Out-String); $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok) { Write-Host "JARVIS no arrancó:`n$st`nEjecute .\Repair-OpenJarvisLab.ps1" -ForegroundColor Red }
  }
  return $ok
}
function Invoke-Turn([string]$mode) {
  Remove-Item $outWav, $outTxt -ErrorAction SilentlyContinue
  if ($mode -eq 'text') {
    $t = $Text -replace '[^\p{L}\p{N}\s\.,;:¿\?¡!\-]', ''
    & cmd.exe /d /c "wsl.exe -d $Distro -u jarvis --exec /opt/oj/bin/ojvoice.sh --text `"$t`" > `"$outWav`" 2> `"$outTxt`""
  } else {
    & cmd.exe /d /c "wsl.exe -d $Distro -u jarvis --exec /opt/oj/bin/ojvoice.sh < `"$inWav`" > `"$outWav`" 2> `"$outTxt`""
  }
  $rc = $LASTEXITCODE
  if (Test-Path $outTxt) { Get-Content $outTxt -Encoding UTF8 | ForEach-Object {
      if ($_ -like 'TÚ:*') { Write-Host $_ -ForegroundColor Gray } elseif ($_ -like 'JARVIS:*') { Write-Host $_ -ForegroundColor Cyan }
      elseif ($_ -like 'AVISO:*') { Write-Host $_ -ForegroundColor Yellow } elseif ($_.Trim()) { Write-Host $_ -ForegroundColor Red } } }
  if ($rc -ne 0) {
    $why = if ($Reasons.ContainsKey($rc)) { $Reasons[$rc] } else { "Error inesperado (código $rc)." }
    Write-Host "FALLO del turno: $why" -ForegroundColor Red; return $false }
  if (-not (Test-Path $outWav) -or (Get-Item $outWav).Length -lt 1000) { Write-Host 'FALLO: la respuesta de voz llegó vacía.' -ForegroundColor Red; return $false }
  try { (New-Object System.Media.SoundPlayer $outWav).PlaySync() } catch { Write-Host "No se pudo reproducir el audio: $($_.Exception.Message)" -ForegroundColor Red; return $false }
  return $true
}
if (-not (Test-Jarvis)) { exit 1 }
if ($Text) { if (Invoke-Turn 'text') { exit 0 } else { exit 1 } }
Write-Host 'JARVIS local por voz. Enter = hablar / Enter = terminar. q + Enter = salir.' -ForegroundColor Green
$prompt = 'Listo para hablar'
while ($true) {
  $k = Read-Host $prompt
  if ($k -eq 'q') { break }
  try {
    Mci 'open new type waveaudio alias ojrec'
    Mci 'set ojrec time format ms bitspersample 16 channels 1 samplespersec 16000 bytespersec 32000 alignment 2'
    Mci 'record ojrec'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host 'Escuchando... (Enter para terminar)' -ForegroundColor Yellow
    while (-not [Console]::KeyAvailable -and $sw.Elapsed.TotalSeconds -lt $MaxSeconds) { Start-Sleep -Milliseconds 100 }
    if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    Mci 'stop ojrec'; Mci ('save ojrec "' + $inWav + '"'); Mci 'close ojrec'
  } catch { Write-Host $_.Exception.Message -ForegroundColor Red; $prompt = 'Fallo de micrófono. Enter para reintentar'; continue }
  Write-Host 'Pensando...' -ForegroundColor DarkGray
  if (Invoke-Turn 'voice') { $prompt = 'Listo para hablar' }
  else { $prompt = 'El turno falló (ver arriba). Enter para reintentar'; [void](Test-Jarvis) }
}
