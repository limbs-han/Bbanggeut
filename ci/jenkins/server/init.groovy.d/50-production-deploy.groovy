import com.cloudbees.hudson.plugins.folder.Folder
import com.cloudbees.hudson.plugins.folder.properties.FolderCredentialsProvider.FolderCredentialsProperty
import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.common.StandardCredentials
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import hudson.model.Result
import hudson.security.ACL
import jenkins.model.Jenkins
import jenkins.triggers.ReverseBuildTrigger
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths

def jenkins = Jenkins.get()
def folderName = "Production"
def jobName = "S15P11E201-backend-deploy"
def credentialId = "production-backend-ssh"
def privateKeyFile = Paths.get("/var/jenkins_agent_secrets/production-deploy-private-key")

def folder = jenkins.getItem(folderName)
if (folder == null) {
    folder = jenkins.createProject(Folder, folderName)
} else if (!(folder instanceof Folder)) {
    throw new IllegalStateException("${folderName} exists but is not a Folder")
}

if (Files.isRegularFile(privateKeyFile)) {
    def privateKey = Files.readString(privateKeyFile, StandardCharsets.UTF_8)
    def credential = new BasicSSHUserPrivateKey(
        CredentialsScope.GLOBAL,
        credentialId,
        "jenkins-deploy",
        new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(privateKey),
        "",
        "S15P11E201 Backend 운영 배포 전용 SSH 키"
    )

    def credentialsProperty = folder.getProperties().get(FolderCredentialsProperty)
    if (credentialsProperty == null) {
        credentialsProperty = new FolderCredentialsProperty([])
        folder.addProperty(credentialsProperty)
    }

    def credentialStore = credentialsProperty.getStore()
    def existingCredential = CredentialsProvider.lookupCredentialsInItemGroup(
        StandardCredentials,
        folder,
        ACL.SYSTEM2,
        []
    ).find { it.id == credentialId }

    if (existingCredential == null) {
        credentialStore.addCredentials(Domain.global(), credential)
    } else {
        credentialStore.updateCredentials(Domain.global(), existingCredential, credential)
    }
} else {
    println("Production deploy private key is not ready; deploy job will not have credentials")
}

def pipelineScript = '''
pipeline {
    agent none

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
    }

    stages {
        stage('Validate master CI') {
            steps {
                script {
                    def cause = currentBuild.rawBuild.getCause(hudson.model.Cause.UpstreamCause)
                    if (cause == null || cause.upstreamProject != 'S15P11E201/master') {
                        error('S15P11E201/master CI 성공으로 시작된 작업만 배포할 수 있습니다.')
                    }
                    env.SOURCE_BUILD = cause.upstreamBuild.toString()
                    currentBuild.description = "master #${env.SOURCE_BUILD}"
                }
            }
        }

        stage('Production approval') {
            input {
                message 'master CI 결과물을 운영 EC2에 배포할까요?'
                ok 'Backend 배포 승인'
                submitterParameter 'APPROVED_BY'
            }
        }

        stage('Deploy Backend') {
            agent {
                label 'deploy'
            }
            steps {
                deleteDir()
                copyArtifacts(
                    projectName: '/S15P11E201/master',
                    selector: specific("${env.SOURCE_BUILD}"),
                    filter: 'backend/server/build/libs/server-*.jar',
                    flatten: true,
                    fingerprintArtifacts: true
                )
                sshagent(credentials: ['production-backend-ssh']) {
                    sh """
                        set -eu
                        jar_file="\$(find . -maxdepth 1 -type f -name 'server-*.jar' -print -quit)"
                        test -n "\${jar_file}"
                        scp \
                          -o BatchMode=yes \
                          -o StrictHostKeyChecking=yes \
                          -o UserKnownHostsFile=/run/secrets/production-known-hosts \
                          "\${jar_file}" \
                          jenkins-deploy@host.docker.internal:/home/jenkins-deploy/incoming/server.jar.next
                        ssh \
                          -o BatchMode=yes \
                          -o StrictHostKeyChecking=yes \
                          -o UserKnownHostsFile=/run/secrets/production-known-hosts \
                          jenkins-deploy@host.docker.internal \
                          sudo /usr/local/sbin/wj-deploy-backend
                    """
                }
            }
            post {
                cleanup {
                    cleanWs(deleteDirs: true, disableDeferredWipeout: true)
                }
            }
        }
    }
}
'''

def job = folder.getItem(jobName)
if (job == null) {
    job = folder.createProject(WorkflowJob, jobName)
} else if (!(job instanceof WorkflowJob)) {
    throw new IllegalStateException("${folderName}/${jobName} exists but is not a Pipeline job")
}

job.setDefinition(new CpsFlowDefinition(pipelineScript, false))
def retainedTriggers = job.getTriggers().values()
    .findAll { !(it instanceof ReverseBuildTrigger) }
retainedTriggers.add(new ReverseBuildTrigger("S15P11E201/master", Result.SUCCESS))
job.setTriggers(retainedTriggers)
job.setDisabled(false)
job.save()
folder.save()

println("Configured trusted production deployment job: ${folderName}/${jobName}")
