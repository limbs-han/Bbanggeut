param(
    [string]$CameraName = "Camera Sensor OV02C10",
    [string]$SshKey = "$env:USERPROFILE\Downloads\I15E201T.pem",
    [string]$Server = "ubuntu@i15e201.p.ssafy.io",
    [string]$VideoSize = "1280x720",
    [int]$FrameRate = 30
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$runtimeDirectory = Join-Path $repoRoot "runtime\webcam-live"
$localTunnelPort = 18554
New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null

if (-not (Test-Path -LiteralPath $SshKey -PathType Leaf)) {
    throw "SSH key was not found: $SshKey"
}

$ffmpegCandidates = @(
    "C:\Users\SSAFY\miniforge3\envs\computer_vision\Library\bin\ffmpeg.exe",
    "C:\Users\SSAFY\miniforge3\Library\bin\ffmpeg.exe"
)
$ffmpeg = $ffmpegCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ffmpeg) {
    $ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
}
if (-not $ffmpeg) {
    throw "ffmpeg was not found."
}

function Stop-TrackedProcess([string]$PidFile, [string]$ExpectedName) {
    if (-not (Test-Path -LiteralPath $PidFile)) { return }
    $storedPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue
    if (-not $storedPid) { return }
    $process = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq $ExpectedName) {
        Stop-Process -Id $process.Id
        $process.WaitForExit(5000)
    }
    Set-Content -LiteralPath $PidFile -Value ""
}

Stop-TrackedProcess (Join-Path $runtimeDirectory "publisher.pid") "ffmpeg"
Stop-TrackedProcess (Join-Path $runtimeDirectory "tunnel.pid") "ssh"

& ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=8 $Server `
    "sudo systemctl stop william-james-demo-stream"
if ($LASTEXITCODE -ne 0) {
    throw "Could not stop the server demo publisher."
}

$tunnelLog = Join-Path $runtimeDirectory "tunnel-error.log"
$tunnelArguments = "-N -i `"$SshKey`" -o BatchMode=yes -o ExitOnForwardFailure=yes " +
    "-o ServerAliveInterval=30 -L ${localTunnelPort}:127.0.0.1:8554 $Server"
$tunnel = Start-Process -FilePath "ssh.exe" -ArgumentList $tunnelArguments `
    -WindowStyle Hidden -PassThru -RedirectStandardError $tunnelLog
Set-Content -LiteralPath (Join-Path $runtimeDirectory "tunnel.pid") -Value $tunnel.Id

$tunnelReady = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $tunnel.Refresh()
    if ($tunnel.HasExited) { break }
    $listener = Get-NetTCPConnection -LocalPort $localTunnelPort -State Listen `
        -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $tunnel.Id
    if ($listener) {
        $tunnelReady = $true
        break
    }
    Start-Sleep -Milliseconds 250
}
if (-not $tunnelReady) {
    $details = Get-Content -LiteralPath $tunnelLog -Raw -ErrorAction SilentlyContinue
    throw "SSH tunnel did not start. $details"
}

$publisherLog = Join-Path $runtimeDirectory "publisher-error.log"
$inputName = "video=$CameraName"
$publisherArguments = "-hide_banner -loglevel warning -f dshow -rtbufsize 128M " +
    "-video_size $VideoSize -framerate $FrameRate -pixel_format nv12 " +
    "-i `"$inputName`" -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 " +
    "-map 0:v:0 -map 1:a:0 -c:v libx264 -preset ultrafast -tune zerolatency " +
    "-pix_fmt yuv420p -profile:v baseline -level 3.1 -g $FrameRate " +
    "-keyint_min $FrameRate -sc_threshold 0 -b:v 2500k -maxrate 2500k " +
    "-bufsize 5000k -c:a libopus -b:a 64k -ar 48000 -shortest " +
    "-f rtsp -rtsp_transport tcp rtsp://127.0.0.1:${localTunnelPort}/demo-live"
$publisher = Start-Process -FilePath $ffmpeg -ArgumentList $publisherArguments `
    -WindowStyle Hidden -PassThru -RedirectStandardError $publisherLog
Set-Content -LiteralPath (Join-Path $runtimeDirectory "publisher.pid") -Value $publisher.Id

Start-Sleep -Seconds 4
if ($publisher.HasExited) {
    $details = Get-Content -LiteralPath $publisherLog -Raw -ErrorAction SilentlyContinue
    throw "Webcam publisher exited. $details"
}

Write-Host "Laptop webcam is publishing to the production demo-live stream."
Write-Host "Camera    : $CameraName ($VideoSize at ${FrameRate}fps)"
Write-Host "Publisher : PID $($publisher.Id)"
Write-Host "Tunnel    : PID $($tunnel.Id)"
Write-Host "Stop      : .\backend\demo\stop-webcam-live.ps1"
