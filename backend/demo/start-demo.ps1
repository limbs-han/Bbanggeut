param(
    [string]$SourceVideo = "C:\Users\SSAFY\Downloads\YTDown.com_YouTube_Media_6Ycn9qZK09I_001_1080p.mp4",
    [string]$AdminPassword = "WjDemo!2026",
    [string]$DemoLiveHlsUrl = "http://10.0.2.2:8888/demo-live/index.m3u8",
    [switch]$RebuildClips
)

$ErrorActionPreference = "Stop"
$demoDirectory = $PSScriptRoot
$backendDirectory = Split-Path $demoDirectory -Parent
$repositoryDirectory = Split-Path $backendDirectory -Parent
$runtimeDirectory = Join-Path $repositoryDirectory "runtime\demo"
$clipDirectory = Join-Path $demoDirectory "generated-clips"
$seedFile = Join-Path $demoDirectory "seed.sql"

if (-not (Test-Path -LiteralPath $SourceVideo)) {
    throw "Source video not found: $SourceVideo"
}

New-Item -ItemType Directory -Force -Path $runtimeDirectory, $clipDirectory | Out-Null

$ffmpegCandidates = @(
    "C:\Users\SSAFY\miniforge3\envs\computer_vision\Library\bin\ffmpeg.exe",
    "C:\Users\SSAFY\miniforge3\Library\bin\ffmpeg.exe"
)
$ffmpeg = $ffmpegCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ffmpeg) {
    $ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
}
if (-not $ffmpeg) {
    throw "ffmpeg was not found. Install ffmpeg or update ffmpegCandidates in this script."
}
$ffprobe = Join-Path (Split-Path $ffmpeg -Parent) "ffprobe.exe"
if (-not (Test-Path -LiteralPath $ffprobe)) {
    throw "ffprobe was not found next to ffmpeg: $ffprobe"
}

$clips = @(
    @{ Name = "demo-clip-01.mp4"; Start = "0" },
    @{ Name = "demo-clip-02.mp4"; Start = "45" },
    @{ Name = "demo-clip-03.mp4"; Start = "91.2" }
)

foreach ($clip in $clips) {
    $target = Join-Path $clipDirectory $clip.Name
    if ($RebuildClips -or -not (Test-Path -LiteralPath $target)) {
        Write-Host "Creating $($clip.Name) from $($clip.Start)s..."
        & $ffmpeg -hide_banner -loglevel error -y -ss $clip.Start -i $SourceVideo `
            -t 120 -map 0:v:0 -map "0:a:0?" -c copy -avoid_negative_ts make_zero `
            -movflags +faststart $target
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed while creating $($clip.Name)" }
    }
}

Push-Location $backendDirectory
try {
    # Compose interpolates every service even when Mosquitto is not selected.
    # This value is only a parser placeholder; the demo does not start Mosquitto.
    if (-not $env:MQTT_PASSWORD) {
        $env:MQTT_PASSWORD = "demo-mqtt-service-not-started-2026"
    }
    Write-Host "Starting PostgreSQL, MinIO and MediaMTX..."
    & docker compose up -d postgres minio minio-init mediamtx
    if ($LASTEXITCODE -ne 0) { throw "docker compose startup failed" }

    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 1
        $postgresReady = (& docker compose exec -T postgres pg_isready -U wj -d wj 2>$null) -match "accepting connections"
    } until ($postgresReady -or (Get-Date) -gt $deadline)
    if (-not $postgresReady) { throw "PostgreSQL did not become ready" }

    try {
        Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/actuator/health" -TimeoutSec 1 | Out-Null
        throw "Port 8080 already has a backend process. Stop it before starting demo mode."
    } catch {
        if ($_.Exception.Message -like "Port 8080 already*") { throw }
    }

    $jdk = Get-ChildItem "C:\Users\SSAFY\.jdks" -Directory -Filter "ms-17*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $jdk) { throw "JDK 17 was not found under C:\Users\SSAFY\.jdks" }

    $env:JAVA_HOME = $jdk.FullName
    $env:Path = "$($jdk.FullName)\bin;$env:Path"
    $env:DB_URL = "jdbc:postgresql://localhost:5432/wj"
    $env:DB_USER = "wj"
    $env:DB_PASSWORD = "wj-dev-only"
    $env:S3_ENDPOINT = "http://localhost:9000"
    $env:S3_ACCESS_KEY = "minioadmin"
    $env:S3_SECRET_KEY = "minioadmin"
    $env:S3_BUCKET = "wj-videos"
    $env:DEMO_MODE_ENABLED = "true"
    $env:DEMO_LIVE_HLS_URL = $DemoLiveHlsUrl
    $env:MQTT_BROKER_URL = "tcp://127.0.0.1:1"

    $backendLog = Join-Path $runtimeDirectory "backend.log"
    $backendErrorLog = Join-Path $runtimeDirectory "backend-error.log"
    $backend = Start-Process -FilePath (Join-Path $backendDirectory "server\gradlew.bat") `
        -ArgumentList "bootRun" -WorkingDirectory (Join-Path $backendDirectory "server") `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $backendLog -RedirectStandardError $backendErrorLog
    Set-Content -LiteralPath (Join-Path $runtimeDirectory "backend.pid") -Value $backend.Id

    $deadline = (Get-Date).AddSeconds(90)
    $backendReady = $false
    do {
        Start-Sleep -Seconds 1
        if ($backend.HasExited) { throw "Backend exited. Check $backendErrorLog" }
        try {
            $health = Invoke-RestMethod -Uri "http://localhost:8080/actuator/health" -TimeoutSec 2
            $backendReady = $health.status -eq "UP"
        } catch { }
    } until ($backendReady -or (Get-Date) -gt $deadline)
    if (-not $backendReady) { throw "Backend did not become ready. Check $backendLog" }
    $serverProcess = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "java.exe" -and
        $_.CommandLine -like "*com.wj.server.ServerApplication*" -and
        $_.CommandLine -like "*$repositoryDirectory*"
    } | Select-Object -First 1
    if ($serverProcess) {
        Set-Content -LiteralPath (Join-Path $runtimeDirectory "backend.pid") -Value $serverProcess.ProcessId
    }

    $clipMetadata = @()
    foreach ($clip in $clips) {
        $path = Join-Path $clipDirectory $clip.Name
        $durationSeconds = [double](& $ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $path)
        $clipMetadata += @{
            Path = $path
            Size = (Get-Item -LiteralPath $path).Length
            Sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Duration = [long][Math]::Round($durationSeconds * 1000)
        }
    }

    Write-Host "Uploading demo clips to MinIO..."
    $uploadScript = @'
mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mc cp /clips/demo-clip-01.mp4 local/wj-videos/private/10000000-0000-0000-0000-000000000001/events/demo-clip-01.mp4
mc cp /clips/demo-clip-02.mp4 local/wj-videos/private/10000000-0000-0000-0000-000000000001/events/demo-clip-02.mp4
mc cp /clips/demo-clip-03.mp4 local/wj-videos/private/10000000-0000-0000-0000-000000000001/events/demo-clip-03.mp4
'@
    & docker compose run --rm --no-deps `
        -v "${clipDirectory}:/clips:ro" `
        --entrypoint /bin/sh minio-init -ec $uploadScript
    if ($LASTEXITCODE -ne 0) { throw "MinIO clip upload failed" }

    Write-Host "Seeding accounts, devices, registration code and frontend fixtures..."
    & docker compose cp $seedFile postgres:/tmp/wj-demo-seed.sql | Out-Null
    & docker compose exec -T postgres psql -U wj -d wj `
        -v "admin_password=$AdminPassword" `
        -v "family_password=WjFamily!2026" `
        -v "request_password=WjRequest!2026" `
        -v "clip1_size=$($clipMetadata[0].Size)" -v "clip1_sha=$($clipMetadata[0].Sha)" -v "clip1_duration=$($clipMetadata[0].Duration)" `
        -v "clip2_size=$($clipMetadata[1].Size)" -v "clip2_sha=$($clipMetadata[1].Sha)" -v "clip2_duration=$($clipMetadata[1].Duration)" `
        -v "clip3_size=$($clipMetadata[2].Size)" -v "clip3_sha=$($clipMetadata[2].Sha)" -v "clip3_duration=$($clipMetadata[2].Duration)" `
        -f /tmp/wj-demo-seed.sql
    if ($LASTEXITCODE -ne 0) { throw "Demo database seed failed" }

    $streamPidFile = Join-Path $runtimeDirectory "stream.pid"
    if (Test-Path -LiteralPath $streamPidFile) {
        $oldPid = [int](Get-Content -LiteralPath $streamPidFile)
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
    }
    $streamLog = Join-Path $runtimeDirectory "stream-error.log"
    $streamArguments = @(
        "-hide_banner", "-loglevel", "warning", "-re", "-stream_loop", "-1",
        "-i", "`"$SourceVideo`"", "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
        "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:8554/demo-live"
    )
    $stream = Start-Process -FilePath $ffmpeg -ArgumentList $streamArguments -WindowStyle Hidden `
        -PassThru -RedirectStandardError $streamLog
    Set-Content -LiteralPath $streamPidFile -Value $stream.Id

    Write-Host ""
    Write-Host "Demo is ready."
    Write-Host "  Admin login : admin@wj.local / $AdminPassword"
    Write-Host "  Fixed code  : WJDE-2026 (claims the second camera)"
    Write-Host "  API         : http://localhost:8080"
    Write-Host "  Live HLS    : $DemoLiveHlsUrl"
    Write-Host "  Clips       : $clipDirectory"
    Write-Host ""
    Write-Host "Flutter Android emulator:"
    Write-Host "  flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080"
} finally {
    Pop-Location
}
