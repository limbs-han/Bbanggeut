param([switch]$StopContainers)

$ErrorActionPreference = "Stop"
$backendDirectory = Split-Path $PSScriptRoot -Parent
$repositoryDirectory = Split-Path $backendDirectory -Parent
$runtimeDirectory = Join-Path $repositoryDirectory "runtime\demo"

foreach ($name in @("stream", "backend")) {
    $pidFile = Join-Path $runtimeDirectory "$name.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $processId = [int](Get-Content -LiteralPath $pidFile)
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pidFile -Force
        Write-Host "Stopped demo $name process ($processId)."
    }
}

# gradlew.bat launches Spring Boot as a child JVM. Clean up that scoped child if
# the wrapper PID exited first or an earlier demo run stopped halfway through.
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "java.exe" -and
    $_.CommandLine -like "*com.wj.server.ServerApplication*" -and
    $_.CommandLine -like "*$repositoryDirectory*"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped demo backend JVM ($($_.ProcessId))."
}

if ($StopContainers) {
    Push-Location $backendDirectory
    try {
        docker compose stop postgres minio mediamtx
    } finally {
        Pop-Location
    }
}
