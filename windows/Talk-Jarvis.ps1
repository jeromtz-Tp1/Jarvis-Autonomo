<#
.SYNOPSIS
  Habla con JARVIS por voz (micrófono y altavoces). Todo se procesa localmente en la distro OpenJarvisLab.
.DESCRIPTION
  Enter = empezar a hablar, Enter = terminar, q = salir. La respuesta se reproduce por frases: la primera suena
  mientras JARVIS sigue generando las siguientes (Fase 2C). Muestra los tiempos de cada etapa y los errores reales;
  nunca dice "Listo" si el turno anterior falló. Sin instalaciones: winmm para grabar, SoundPlayer para reproducir.
.EXAMPLE
  .\Talk-Jarvis.ps1
  .\Talk-Jarvis.ps1 -Text "Hola Jarvis"
#>
[CmdletBinding()] param([string]$Text = '', [int]$MaxSeconds = 30, [switch]$NoTimings)
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'
$work = Join-Path $env:TEMP 'OpenJarvisVoice'; New-Item -ItemType Directory -Force -Path $work | Out-Null
$inWav = Join-Path $work 'in.wav'
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
    if (-not $ok) { Write-Host "JARVIS no arrancó:`n$st`nEjecute .\Repair-OpenJarvisLab.ps1" -ForegroundColor Red } }
  return $ok }
function Read-Exact($stream, [int]$n) {
  $buf = New-Object byte[] $n; $off = 0
  while ($off -lt $n) { $r = $stream.Read($buf, $off, $n - $off); if ($r -le 0) { break }; $off += $r }
  if ($off -lt $n) { return $null }; return $buf }
function Invoke-Turn([string]$mode) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.Arguments = "-d $Distro -u jarvis --exec /opt/oj/bin/ojvoice.sh --frames"
  if ($mode -eq 'text') { $t = ($Text -replace '[^\p{L}\p{N}\s\.,;:¿\?¡!\-]', ''); $psi.Arguments += " --text `"$t`"" }
  $q = New-Object 'System.Collections.Concurrent.BlockingCollection[byte[]]'
  $player = [powershell]::Create().AddScript({ param($q)
      foreach ($b in $q.GetConsumingEnumerable()) { $ms = New-Object IO.MemoryStream (,$b); (New-Object System.Media.SoundPlayer $ms).PlaySync() } }).AddArgument($q)
  $handle = $player.BeginInvoke()
  $sw = [Diagnostics.Stopwatch]::StartNew(); $firstAudio = $null; $nChunks = 0
  $p = [Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  if ($mode -ne 'text') { $bytes = [IO.File]::ReadAllBytes($inWav); $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length) }
  $p.StandardInput.Close()
  $out = $p.StandardOutput.BaseStream
  try {
    while ($true) {
      $hdr = Read-Exact $out 8; if ($null -eq $hdr) { break }
      $magic = [Text.Encoding]::ASCII.GetString($hdr, 0, 4)
      if ($magic -eq 'OJWE') { break }
      if ($magic -eq 'RIFF') {   # versión anterior de ojvoice: un único WAV
        $ms = New-Object IO.MemoryStream; $ms.Write($hdr, 0, 8); $out.CopyTo($ms); $q.Add($ms.ToArray()); $firstAudio = $sw.ElapsedMilliseconds; $nChunks = 1; break }
      if ($magic -ne 'OJWV') { break }
      $len = [BitConverter]::ToUInt32($hdr, 4); $wav = Read-Exact $out ([int]$len); if ($null -eq $wav) { break }
      if ($null -eq $firstAudio) { $firstAudio = $sw.ElapsedMilliseconds }
      $q.Add($wav); $nChunks++ }
  } finally { $q.CompleteAdding() }
  $p.WaitForExit(); $rc = $p.ExitCode; $err = $errTask.Result
  foreach ($line in ($err -split "`r?`n")) {
    if ($line -like 'TÚ:*') { Write-Host $line -ForegroundColor Gray } elseif ($line -like 'JARVIS:*') { Write-Host $line -ForegroundColor Cyan }
    elseif ($line -like 'TIEMPOS:*') { if (-not $NoTimings) { Write-Host $line -ForegroundColor DarkGray } }
    elseif ($line -like 'AVISO:*') { Write-Host $line -ForegroundColor Yellow } elseif ($line.Trim()) { Write-Host $line -ForegroundColor Red } }
  $player.EndInvoke($handle); $player.Dispose()
  if ($rc -ne 0) { $why = if ($Reasons.ContainsKey($rc)) { $Reasons[$rc] } else { "Error inesperado (código $rc)." }; Write-Host "FALLO del turno: $why" -ForegroundColor Red; return $false }
  if ($nChunks -eq 0) { Write-Host 'FALLO: la respuesta de voz llegó vacía.' -ForegroundColor Red; return $false }
  if (-not $NoTimings) { Write-Host ("Primera voz en {0:N1} s (desde el final de la grabación); {1} fragmento(s)." -f ($firstAudio / 1000), $nChunks) -ForegroundColor DarkGray }
  return $true }

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
    while (-not [Console]::KeyAvailable -and $sw.Elapsed.TotalSeconds -lt $MaxSeconds) { Start-Sleep -Milliseconds 50 }
    if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    Mci 'stop ojrec'; Mci ('save ojrec "' + $inWav + '"'); Mci 'close ojrec'
  } catch { Write-Host $_.Exception.Message -ForegroundColor Red; $prompt = 'Fallo de micrófono. Enter para reintentar'; continue }
  Write-Host 'Pensando...' -ForegroundColor DarkGray
  try { $ok = Invoke-Turn 'voice' } catch { Write-Host "FALLO del turno: $($_.Exception.Message)" -ForegroundColor Red; $ok = $false }
  if ($ok) { $prompt = 'Listo para hablar' } else { $prompt = 'El turno falló (ver arriba). Enter para reintentar'; [void](Test-Jarvis) }
}
