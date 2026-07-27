import hudson.model.Node
import hudson.slaves.DumbSlave
import hudson.slaves.JNLPLauncher
import hudson.slaves.RetentionStrategy
import jenkins.model.Jenkins

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermissions

def jenkins = Jenkins.get()
def agentDefinitions = [
    [name: "backend-agent",  label: "backend"],
    [name: "frontend-agent", label: "frontend"],
    [name: "iot-agent",      label: "iot"],
    [name: "ai-agent",       label: "ai"],
    [name: "deploy-agent",   label: "deploy"],
]

// 빌드는 Controller가 아니라 전용 Agent에서만 실행한다.
jenkins.setNumExecutors(0)

agentDefinitions.each { definition ->
    def agent = jenkins.getNode(definition.name)

    if (agent == null) {
        agent = new DumbSlave(
            definition.name,
            "${definition.label} 전용 Docker Agent",
            "/home/jenkins/agent",
            "1",
            Node.Mode.EXCLUSIVE,
            definition.label,
            new JNLPLauncher(),
            new RetentionStrategy.Always(),
            []
        )
        jenkins.addNode(agent)
    } else {
        agent.setLabelString(definition.label)
        agent.setNumExecutors(1)
        agent.setMode(Node.Mode.EXCLUSIVE)
        agent.setLauncher(new JNLPLauncher())
        agent.setRetentionStrategy(new RetentionStrategy.Always())
    }
}

jenkins.save()

Path secretDirectory = Paths.get("/var/jenkins_agent_secrets")
Files.createDirectories(secretDirectory)
Files.setPosixFilePermissions(secretDirectory, PosixFilePermissions.fromString("rwx------"))

agentDefinitions.each { definition ->
    def computer = jenkins.getComputer(definition.name)
    if (computer == null) {
        throw new IllegalStateException("${definition.name} computer was not created")
    }

    Path secretFile = secretDirectory.resolve(definition.name)
    Files.write(
        secretFile,
        (computer.getJnlpMac() + System.lineSeparator()).getBytes(StandardCharsets.UTF_8)
    )
    Files.setPosixFilePermissions(secretFile, PosixFilePermissions.fromString("rw-------"))
}

println("Configured domain agents: ${agentDefinitions*.name.join(', ')}")
