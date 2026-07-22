param(
    [string]$SshKey = "$env:USERPROFILE\Downloads\I15E201T.pem",
    [string]$Server = "ubuntu@i15e201.p.ssafy.io",
    [switch]$NoRestoreDemo
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$runtimeDirectory = Join-Path $repoRoot "runtime\webcam-live"

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

if (-not $NoRestoreDemo) {
    if (-not (Test-Path -LiteralPath $SshKey -PathType Leaf)) {
        throw "SSH key was not found: $SshKey"
    }
    & ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=8 $Server `
        "sudo systemctl start william-james-demo-stream"
    if ($LASTEXITCODE -ne 0) {
        throw "Webcam stopped, but the server demo publisher could not be restored."
    }
    Write-Host "Webcam stopped and the looping demo stream was restored."
} else {
    Write-Host "Webcam stopped. The looping demo stream remains disabled."
}

