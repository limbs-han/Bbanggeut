# Jenkins CI structure

The Jenkins controller schedules work but does not build code. Four separately
registered agents provide the tools for each domain:

| Agent label | Required tools | Repository scope |
|---|---|---|
| `backend` | JDK 17, Bash | `backend/` |
| `frontend` | Flutter with Dart 3.12 or newer, Bash | `frontend/` |
| `iot` | Python 3, `venv`, Bash | `ai/device_agent/` |
| `ai` | Python 3, Bash | hardware-independent files in `ai/yolo/` |

Agents receive a temporary checkout from GitLab. Workspaces are deleted after
each stage and are not deployment copies or backups.

## Branch routing

Jenkins is expected to use a Multibranch Pipeline. The root `Jenkinsfile`
routes work as follows:

| Branch | CI stages |
|---|---|
| `master` | Backend, Frontend, IoT, AI |
| `develop` | Backend, Frontend, IoT, AI |
| `develop/backend`, `feat/backend/**` | Backend |
| `develop/frontend`, `feat/frontend/**` | Frontend |
| `develop/iot`, `feat/iot/**` | IoT |
| `develop/ai`, `feat/ai/**` | AI |

The temporary bootstrap branch `feat/jenkins-pipeline` runs every stage so the
initial agent and pipeline configuration can be verified before integration.

No branch is created by the `Jenkinsfile`. Branch creation and protection are
separate GitLab administration steps.

## AI test boundary

The generic `ai` agent runs event-fusion and clip-metadata unit tests, Python
syntax checks, and shell syntax checks. The YOLO auto-framing test imports
Jetson-specific Torch, OpenCV, and Ultralytics dependencies, so it remains a
Jetson hardware validation until a pinned CPU-compatible CI image is provided.
