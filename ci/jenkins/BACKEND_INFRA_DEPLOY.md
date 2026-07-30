# Backend application and infrastructure deployment

The production deployment job deploys one release composed of:

- the Spring Boot JAR;
- PostgreSQL 16;
- MinIO and the idempotent bucket initializer;
- Eclipse Mosquitto and `mosquitto.conf`;
- MediaMTX and `mediamtx.yml`;
- the production Nginx HLS/WHEP proxy configuration.

The four infrastructure services remain defined by
`backend/deploy/docker-compose.yml`. PostgreSQL, MinIO, and Mosquitto data stay
in their existing named volumes. A deployment never runs `docker compose down`
or removes a volume.

## Pipeline

Backend CI creates `backend-deploy.tar.gz` from the four version-controlled
deployment inputs and archives it beside the JAR. After `master` CI succeeds, the
trusted Production job:

1. waits for explicit deployment approval;
2. copies the JAR and infrastructure artifact from the same CI build;
3. uploads both artifacts using the dedicated `jenkins-deploy` SSH account;
4. invokes only `sudo /usr/local/sbin/wj-deploy-backend`.

The server-side command validates the JAR, validates the exact archive file
list, and runs `docker compose config` against the server-owned
`/home/ubuntu/william-james/infra/.env`. It then backs up the current JAR and
Compose inputs, applies the candidate configuration, validates and reloads
Nginx, starts all four services, runs their health checks and the MinIO
initializer, and finally restarts Spring Boot. Existing application
environments receive the public `WEBRTC_BASE_URL` without rotating any secret.
A failed infrastructure, Nginx, or application health check restores the
previous configuration and JAR.

MediaMTX and Mosquitto use bind-mounted configuration files. When either file
changes, the wrapper explicitly recreates the matching container so an atomic
host-file replacement cannot leave the old process on stale configuration.

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

## Reinstall the wrapper whenever it changes

`/usr/local/sbin/wj-deploy-backend` is a copy. Jenkins never updates it — the
deploy job runs only `sudo /usr/local/sbin/wj-deploy-backend`, and the artifact
it uploads contains the infrastructure files, not the wrapper. Editing
`ci/jenkins/server/deploy/wj-deploy-backend` in the repository therefore has no
effect on production until someone reinstalls it by hand.

This has already caused one silent outage. The Redis service was added to the
wrapper and to `backend/deploy/docker-compose.yml`, but only the Compose file
reached the server, so every deployment kept starting `postgres minio` without
`redis`. Login rate limiting fails open when Redis is unreachable, and device
presence stops working, while the deployment still reports success.

After merging any change to the wrapper, rerun the install command below and
confirm the result:

```bash
sudo install -o root -g root -m 0755 \
  ci/jenkins/server/deploy/wj-deploy-backend \
  /usr/local/sbin/wj-deploy-backend
sudo diff ci/jenkins/server/deploy/wj-deploy-backend /usr/local/sbin/wj-deploy-backend \
  && echo '설치본이 저장소와 일치합니다.'
```

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
