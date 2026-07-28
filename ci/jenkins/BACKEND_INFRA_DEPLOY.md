# Backend application and infrastructure deployment

The production deployment job deploys one release composed of:

- the Spring Boot JAR;
- PostgreSQL 16;
- MinIO and the idempotent bucket initializer;
- Eclipse Mosquitto and `mosquitto.conf`;
- MediaMTX and `mediamtx.yml`.

The four infrastructure services remain defined by
`backend/deploy/docker-compose.yml`. PostgreSQL, MinIO, and Mosquitto data stay
in their existing named volumes. A deployment never runs `docker compose down`
or removes a volume.

## Pipeline

Backend CI creates `backend-deploy.tar.gz` from the three version-controlled
Compose inputs and archives it beside the JAR. After `master` CI succeeds, the
trusted Production job:

1. waits for explicit deployment approval;
2. copies the JAR and infrastructure artifact from the same CI build;
3. uploads both artifacts using the dedicated `jenkins-deploy` SSH account;
4. invokes only `sudo /usr/local/sbin/wj-deploy-backend`.

The server-side command validates the JAR, validates the exact archive file
list, and runs `docker compose config` against the server-owned
`/home/ubuntu/william-james/infra/.env`. It then backs up the current JAR and
Compose inputs, applies the candidate configuration, starts all four services,
runs their health checks and the MinIO initializer, and finally restarts Spring
Boot. A failed infrastructure or application health check restores the previous
configuration and JAR.

Only an image that is missing for the configured image reference is pulled.
Changing an image reference in the Compose file therefore deploys that image,
while an unchanged floating tag is not silently upgraded on every JAR release.

## Docker permission boundary

The Jenkins controller and agents do not mount `/var/run/docker.sock`. A Docker
socket mount would give arbitrary Jenkins build steps root-equivalent control
over the host. The deploy agent instead has only SSH access as `jenkins-deploy`,
and sudoers permits exactly one root-owned command:

```text
jenkins-deploy ALL=(root) NOPASSWD: /usr/local/sbin/wj-deploy-backend
```

The root-owned command uses the host Docker socket through the Docker CLI. This
provides the Docker permission required for deployment without exposing the
socket to ordinary CI jobs or feature branches.

## One-time server installation

Install the reviewed wrapper and sudoers rule as root on the production host:

```bash
sudo install -o root -g root -m 0755 \
  ci/jenkins/server/deploy/wj-deploy-backend \
  /usr/local/sbin/wj-deploy-backend
sudo install -o root -g root -m 0440 \
  ci/jenkins/server/deploy/jenkins-deploy.sudoers \
  /etc/sudoers.d/jenkins-deploy
sudo visudo --check --file=/etc/sudoers.d/jenkins-deploy
sudo install -d -o jenkins-deploy -g jenkins-deploy -m 0750 \
  /home/jenkins-deploy/incoming
```

The server must already have Docker Engine, the Docker Compose v2 plugin,
`curl`, `tar`, `timeout`, Java's `jar` command, and the root-only infrastructure
`.env` and TLS/KES certificate directories. Secrets and certificates are never
included in the Jenkins artifact.
