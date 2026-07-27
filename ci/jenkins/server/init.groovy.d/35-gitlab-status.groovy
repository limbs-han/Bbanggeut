import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.common.StandardCredentials
import com.cloudbees.plugins.credentials.domains.Domain
import com.dabsquared.gitlabjenkins.connection.GitLabApiTokenImpl
import com.dabsquared.gitlabjenkins.connection.GitLabConnection
import com.dabsquared.gitlabjenkins.connection.GitLabConnectionConfig
import hudson.security.ACL
import hudson.util.Secret
import jenkins.model.Jenkins
import jenkins.model.JenkinsLocationConfiguration

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths

def jenkins = Jenkins.get()
def credentialId = "gitlab-status-api-token"
def connectionName = "s15p11e201-gitlab-api"
def gitlabUrl = "https://lab.ssafy.com"
def jenkinsUrl = "http://i15e201.p.ssafy.io:8080/"
def tokenFile = Paths.get("/var/jenkins_agent_secrets/gitlab-api-token")

if (!Files.isRegularFile(tokenFile)) {
    println("GitLab status API token is not ready; skipping commit-status setup")
    return
}

def token = Files.readString(tokenFile, StandardCharsets.UTF_8).trim()
if (token.isEmpty()) {
    println("GitLab status API token is empty; skipping commit-status setup")
    return
}

def credential = new GitLabApiTokenImpl(
    CredentialsScope.GLOBAL,
    credentialId,
    "S15P11E201 Jenkins commit status API token",
    Secret.fromString(token)
)

def credentialStore = SystemCredentialsProvider.getInstance().getStore()
def existingCredential = CredentialsProvider.lookupCredentialsInItemGroup(
    StandardCredentials,
    jenkins,
    ACL.SYSTEM2,
    []
).find { it.id == credentialId }

if (existingCredential == null) {
    credentialStore.addCredentials(Domain.global(), credential)
} else {
    credentialStore.updateCredentials(Domain.global(), existingCredential, credential)
}

def connection = new GitLabConnection(
    connectionName,
    gitlabUrl,
    credentialId,
    false,
    10,
    20
)
def connectionConfig = GitLabConnectionConfig.get()
def retainedConnections = connectionConfig.getConnections()
    .findAll { it.name != connectionName }
retainedConnections.add(connection)
connectionConfig.setConnections(retainedConnections)
connectionConfig.save()

def locationConfig = JenkinsLocationConfiguration.get()
locationConfig.setUrl(jenkinsUrl)
locationConfig.save()

println("Configured GitLab commit-status connection: ${connectionName}")
