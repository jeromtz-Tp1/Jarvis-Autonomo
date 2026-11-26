<#
.SYNOPSIS
  Habla con JARVIS por voz (micrófono y altavoces de esta PC). Todo se procesa localmente en la distro OpenJarvisLab.
.DESCRIPTION
  Enter = empezar a hablar, Enter = terminar. JARVIS transcribe (Whisper), responde con memoria persistente y contesta en voz (Kokoro).
  No instala nada: graba con la API nativa de Windows (winmm) y reproduce con System.Media.SoundPlayer.
  El audio viaja a la distro por stdin/stdout (wsl.exe); no se expone ningún puerto.
.EXAMPLE
  .\Talk-Jarvis.ps1                 # conversación por voz
  .\Talk-Jarvis.ps1 -Text "Hola"    # una pregunta escrita, respuesta hablada
#>
[CmdletBinding()] param([string]$Text = '', [int]$MaxSeconds = 30)
$ErrorActionPreference = 'Stop'
$Distro = 'OpenJarvisLab'
$work = Join-Path $env:TEMP 'OpenJarvisVoice'; New-Item -ItemType Directory -Force -Path $work | Out-Null
$inWav = Join-Path $work 'in.wav'; $outWav = Join-Path $work 'out.wav'; $outTxt = Join-Path $work 'out.txt'
Add-Type -Namespace OJ -Name Mci -MemberDefinition '[DllImport("winmm.dll", CharSet = CharSet.Unicode)] public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int len, System.IntPtr cb);'
function Mci([string]$c) { $rc = [OJ.Mci]::mciSendString($c, $null, 0, [IntPtr]::Zero); if ($rc -ne 0) { throw "Error de grabación MCI ($rc) en: $c. ¿Hay micrófono y permiso de micrófono para aplicaciones de escritorio?" } }
function Ensure-Running {
  $st = (& wsl.exe -d $Distro -u root --exec /opt/oj/bin/ojctl.sh status 2>$null | Out-String)
  if ($st -notmatch '"status":"ok"') { Write-Host 'Arrancando JARVIS...' -ForegroundColor Yellow; & (Join-Path $PSScriptRoot 'Start-OpenJarvisLab.ps1') | Out-Null } }
function Invoke-Turn([string]$mode) {
  Remove-Item $outWav, $outTxt -ErrorAction SilentlyContinue
  if ($mode -eq 'text') {
    $t = $Text -replace '[^\p{L}\p{N}\s\.,;:¿\?¡!\-]', ''   # sin comillas ni metacaracteres
    & cmd.exe /d /c "wsl.exe -d $Distro -u jarvis --exec /opt/oj/bin/ojvoice.sh --text `"$t`" > `"$outWav`" 2> `"$outTxt`""
  } else {
    & cmd.exe /d /c "wsl.exe -d $Distro -u jarvis --exec /opt/oj/bin/ojvoice.sh < `"$inWav`" > `"$outWav`" 2> `"$outTxt`""
  }
  if (Test-Path $outTxt) { Get-Content $outTxt -Encoding UTF8 | ForEach-Object { if ($_ -like 'TÚ:*') { Write-Host $_ -ForegroundColor Gray } elseif ($_ -like 'JARVIS:*') { Write-Host $_ -ForegroundColor Cyan } else { Write-Host $_ -ForegroundColor Red } } }
  if ((Test-Path $outWav) -and (Get-Item $outWav).Length -gt 1000) { (New-Object System.Media.SoundPlayer $outWav).PlaySync() }
}
Ensure-Running
if ($Text) { Invoke-Turn 'text'; return }
Write-Host "JARVIS local. Enter = hablar / Enter = terminar. Escribe q y Enter para salir." -ForegroundColor Green
while ($true) {
  $k = Read-Host 'Listo'
  if ($k -eq 'q') { break }
  Mci 'open new type waveaudio alias ojrec'
  Mci 'set ojrec time format ms bitspersample 16 channels 1 samplespersec 16000 bytespersec 32000 alignment 2'
  Mci 'record ojrec'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Write-Host 'Escuchando... (Enter para terminar)' -ForegroundColor Yellow
  while (-not [Console]::KeyAvailable -and $sw.Elapsed.TotalSeconds -lt $MaxSeconds) { Start-Sleep -Milliseconds 100 }
  if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
  Mci 'stop ojrec'; Mci ('save ojrec "' + $inWav + '"'); Mci 'close ojrec'
  Write-Host 'Pensando...' -ForegroundColor DarkGray
  Invoke-Turn 'voice'
}
