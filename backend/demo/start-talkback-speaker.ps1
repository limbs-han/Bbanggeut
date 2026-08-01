# 기기가 도착할 때까지 이 노트북이 홈캠 스피커 역할을 대신한다.
#
# 실기기에서는 wj_device_agent.TalkbackManager가 MQTT START_TALKBACK을 받고
# 같은 일을 한다. 데모는 DEMO_MODE_ENABLED로 돌아가 MQTT를 건너뛰므로 명령이
# 오지 않는다. 그래서 MediaMTX API로 talkback 경로가 열리는지 직접 감시한다.
#
# 사용법: 데모를 띄운 뒤 별도 창에서
#   ./backend/demo/start-talkback-speaker.ps1
# 앱에서 마이크 버튼을 누르고 있으면 이 창이 재생을 시작한다. Ctrl+C로 종료.

param(
    [string]$MediaMtxApi = "http://127.0.0.1:9997",
    [string]$RtspHost = "127.0.0.1:8554",
    [int]$PollIntervalMs = 500
)

$ErrorActionPreference = "Stop"

$ffplay = (Get-Command ffplay -ErrorAction SilentlyContinue).Source
if (-not $ffplay) {
    $candidates = @(
        "C:\Users\SSAFY\miniforge3\envs\computer_vision\Library\bin\ffplay.exe",
        "C:\Users\SSAFY\miniforge3\Library\bin\ffplay.exe"
    )
    $ffplay = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ffplay) {
    throw "ffplay를 찾지 못했습니다. ffmpeg 설치 경로를 PATH에 넣거나 이 스크립트의 candidates를 고치세요."
}

try {
    Invoke-RestMethod -Uri "$MediaMtxApi/v3/paths/list" -TimeoutSec 3 | Out-Null
} catch {
    throw "MediaMTX API($MediaMtxApi)에 닿지 못했습니다. docker compose가 떠 있는지 확인하세요."
}

Write-Host "발화 대기 중입니다. 앱에서 마이크 버튼을 길게 누르세요. (Ctrl+C 종료)"

$player = $null
$playingPath = $null

try {
    while ($true) {
        $activePath = $null
        try {
            $paths = Invoke-RestMethod -Uri "$MediaMtxApi/v3/paths/list" -TimeoutSec 3
            $activePath = $paths.items |
                Where-Object { $_.name -like "talkback/*" -and $_.ready } |
                Select-Object -First 1 -ExpandProperty name
        } catch {
            # MediaMTX 재시작 중일 수 있다. 다음 주기에 다시 본다.
        }

        # 재생 중이던 프로세스가 스스로 끝났으면 상태를 정리한다.
        if ($null -ne $player -and $player.HasExited) {
            $player = $null
            $playingPath = $null
        }

        if ($activePath -and $activePath -ne $playingPath) {
            if ($null -ne $player -and -not $player.HasExited) {
                Stop-Process -Id $player.Id -Force -ErrorAction SilentlyContinue
            }
            Write-Host "발화 수신: $activePath"
            $player = Start-Process -FilePath $ffplay -PassThru -WindowStyle Hidden -ArgumentList @(
                "-hide_banner", "-loglevel", "warning",
                "-nodisp", "-autoexit",
                "-fflags", "nobuffer", "-flags", "low_delay",
                "-rtsp_transport", "tcp",
                "rtsp://$RtspHost/$activePath"
            )
            $playingPath = $activePath
        } elseif (-not $activePath -and $null -ne $player) {
            # 발화가 끝나면 경로가 사라진다. 기기의 STOP_TALKBACK에 해당한다.
            Write-Host "발화 종료: $playingPath"
            if (-not $player.HasExited) {
                Stop-Process -Id $player.Id -Force -ErrorAction SilentlyContinue
            }
            $player = $null
            $playingPath = $null
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }
} finally {
    if ($null -ne $player -and -not $player.HasExited) {
        Stop-Process -Id $player.Id -Force -ErrorAction SilentlyContinue
    }
}
