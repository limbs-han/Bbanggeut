# Windows 노트북을 기기 역할로 세울 때 쓰는 실행 래퍼.
#
# Jetson과 Pi에서는 systemd가 EnvironmentFile로 device-agent.env를 읽어
# 프로세스 환경에 넣어준다. Windows에는 그 단계가 없어서 그냥
# `python -m wj_device_agent`를 돌리면 DEVICE_ID부터 없다고 죽는다.
# 이 스크립트가 같은 파일을 읽어 환경에 넣고 에이전트를 실행한다.
#
# 사용법:
#   ./run-agent.ps1                       # ./device-agent.env 사용
#   ./run-agent.ps1 -EnvFile other.env

param(
    [string]$EnvFile = "./device-agent.env",
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "환경 파일이 없습니다: $EnvFile (provision.py enroll을 먼저 실행하세요)"
}

$loaded = 0
foreach ($raw in Get-Content -LiteralPath $EnvFile -Encoding UTF8) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith("#") -or ($line -notmatch "=")) { continue }

    $key, $value = $line -split "=", 2
    $key = $key.Trim()
    $value = $value.Trim()

    # provision.py의 read_environment와 같은 규칙이다. systemd 스타일로 감싼
    # 바깥 따옴표만 벗긴다. JSON 배열 값이 그 안에 그대로 남아야 한다.
    if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and
        ($value[0] -eq "'" -or $value[0] -eq '"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    Set-Item -Path "Env:$key" -Value $value
    $loaded++
}

if (-not $env:DEVICE_ID) {
    throw "$EnvFile 에 DEVICE_ID가 없습니다. enroll이 끝났는지 확인하세요."
}

Write-Host "환경 변수 $loaded 개를 불러왔습니다. device=$env:DEVICE_ID"
if ($env:TALKBACK_ENABLED -eq "true") {
    Write-Host "양방향 오디오 활성화됨."
} else {
    Write-Host "TALKBACK_ENABLED가 꺼져 있어 발화는 SPEAKER_UNAVAILABLE로 거절됩니다."
}

& $Python -m wj_device_agent
exit $LASTEXITCODE
