import hudson.plugins.git.GitStatus

// 익명 요청은 저장소 Polling만 허용한다.
// sha1 파라미터를 이용한 직접 빌드 요청에는 계속 access token이 필요하다.
GitStatus.NOTIFY_COMMIT_ACCESS_CONTROL = "disabled-for-polling"

println("Configured Git notifyCommit for polling-only access")
