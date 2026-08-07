import com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger
import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.common.StandardCredentials
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
import hudson.security.ACL
import jenkins.branch.BranchSource
import jenkins.model.Jenkins
import jenkins.plugins.git.GitSCMSource
import org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths

def jenkins = Jenkins.get()
def credentialId = "gitlab-readonly-https"
def repositoryUrl = "https://lab.ssafy.com/s15-webmobile3-sub1/S15P11E201.git"
def usernameFile = Paths.get("/var/jenkins_agent_secrets/gitlab-deploy-username")
def tokenFile = Paths.get("/var/jenkins_agent_secrets/gitlab-deploy-token")

if (!Files.isRegularFile(usernameFile) || !Files.isRegularFile(tokenFile)) {
    println("GitLab Deploy Token files are not ready; skipping multibranch setup")
    return
}

def username = Files.readString(usernameFile, StandardCharsets.UTF_8).trim()
def token = Files.readString(tokenFile, StandardCharsets.UTF_8).trim()
if (username.isEmpty() || token.isEmpty()) {
    println("GitLab Deploy Token files are empty; skipping multibranch setup")
    return
}

def credential = new UsernamePasswordCredentialsImpl(
    CredentialsScope.GLOBAL,
    credentialId,
    "S15P11E201 GitLab 읽기 전용 Deploy Token",
    username,
    token
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

def projectName = "S15P11E201"
def project = jenkins.getItem(projectName)
if (project == null) {
    project = jenkins.createProject(WorkflowMultiBranchProject, projectName)
} else if (!(project instanceof WorkflowMultiBranchProject)) {
    throw new IllegalStateException("${projectName} exists but is not a multibranch project")
}

def gitSource = new GitSCMSource(
    "s15p11e201-gitlab",
    repositoryUrl,
    credentialId,
    "*",
    "",
    false
)

project.getSourcesList().replaceBy([new BranchSource(gitSource)])
project.getProjectFactory().setScriptPath("Jenkinsfile")

if (!project.getTriggers().values().any { it instanceof PeriodicFolderTrigger }) {
    project.addTrigger(new PeriodicFolderTrigger("5m"))
}

project.save()
project.scheduleBuild2(0)

println("Configured GitLab multibranch project: ${projectName}")
