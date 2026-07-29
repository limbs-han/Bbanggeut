# S15P11E201 repository instructions

These instructions apply to the entire repository.

## Branch policy

- The default branch is `master`. Do not use a branch named `main`.
- Long-lived branches are:
  - `master`: final integration and Backend production deployment baseline
  - `develop/frontend`: Flutter integration
  - `develop/backend`: Spring Boot integration
  - `develop/device`: IoT, Raspberry Pi, Jetson, and AI integration
- Never push directly to `master` or a `develop/*` branch. Use a Merge Request.
- Never delete `master`, `develop/frontend`, `develop/backend`, or
  `develop/device`.

Create feature branches from the matching up-to-date develop branch:

- Frontend: `feat/frontend/<feature>` from `develop/frontend`
- Backend: `feat/backend/<feature>` from `develop/backend`
- Device and AI: `feat/device/<feature>` from `develop/device`
- Jenkins and CI/CD: `feat/jenkins-<feature>`; target `master` unless instructed
  otherwise

Do not use `codex`, a person's name, or meaningless numbers in a branch name.

Merge Request targets must match the role:

- `feat/frontend/*` -> `develop/frontend`
- `feat/backend/*` -> `develop/backend`
- `feat/device/*` -> `develop/device`
- `feat/jenkins-*` -> `master` unless instructed otherwise

Do not merge a normal feature branch directly into `master` or another role's
develop branch. Delete feature branches after a successful merge. When merging
a develop branch into `master`, keep the develop branch.

## Required workflow

Before changing code:

1. Run `git status` and confirm the current branch.
2. Run `git fetch origin --prune`.
3. Update the matching develop branch.
4. Create a correctly named feature branch from that develop branch.

Before pushing:

1. Run the relevant local tests and syntax checks.
2. Review the changed files and complete diff.
3. Commit and push only to the feature branch.
4. Create an MR targeting the matching develop branch.
5. Do not merge when CI fails. Fix the same feature branch and rerun CI.
6. Report each result clearly in Korean.

## CI expectations

- Frontend: `flutter pub get`, `flutter analyze`, and `flutter test`. Do not
  build APK or AAB artifacts. There is no Frontend CD.
- Backend: build, unit tests, and PostgreSQL integration tests.
- Device and AI: Device Agent tests, AI Python tests, and Python/Shell syntax
  checks.

## Deployment restrictions

- Frontend runs on a developer machine with `flutter run`; do not automate APK,
  AAB, or app-store deployment.
- Device and AI stop at CI; do not automatically deploy to devices or EC2.
- Backend production deployment requires successful `master` CI and explicit
  user approval. Never approve a production deployment without the user's
  request. Abort unnecessary deployment jobs.

The complete Korean policy is stored in `ai/GIT_BRANCH_RULES.txt`.
