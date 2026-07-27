import hudson.security.GlobalMatrixAuthorizationStrategy
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.csrf.DefaultCrumbIssuer
import jenkins.install.InstallState
import jenkins.model.Jenkins

def jenkins = Jenkins.get()
def adminId = "admin"
def passwordFile = new File("/var/jenkins_agent_secrets/jenkins-admin-bootstrap-password")

def realm = jenkins.securityRealm
if (!(realm instanceof HudsonPrivateSecurityRealm)) {
    realm = new HudsonPrivateSecurityRealm(false)
}

def admin = hudson.model.User.getById(adminId, false)
if (passwordFile.isFile()) {
    def password = passwordFile.getText("UTF-8").trim()
    if (password.isEmpty()) {
        throw new IllegalStateException("Jenkins 관리자 초기 비밀번호 파일이 비어 있습니다.")
    }

    if (admin == null) {
        admin = realm.createAccount(adminId, password)
    } else {
        admin.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(password))
        admin.save()
    }
} else if (admin == null) {
    throw new IllegalStateException(
        "관리자 계정과 초기 비밀번호 파일이 모두 없어 보안 초기화를 완료할 수 없습니다."
    )
}

def authorization = new GlobalMatrixAuthorizationStrategy()
authorization.add(Jenkins.ADMINISTER, adminId)

jenkins.setSecurityRealm(realm)
jenkins.setAuthorizationStrategy(authorization)
jenkins.setCrumbIssuer(new DefaultCrumbIssuer(true))
jenkins.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
jenkins.save()

println("Configured Jenkins local admin, matrix authorization, and completed setup state")
