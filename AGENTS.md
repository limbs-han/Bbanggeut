# S15P11E201 repository instructions

These instructions apply to the entire repository. Read this file before making
any change.

## Branch policy

- The default branch is `master`. Do not use a branch named `main`.
- Long-lived branches are:
  - `master`: final integration and Backend production deployment baseline
  - `develop/frontend`: Flutter integration
  - `develop/backend`: Spring Boot integration
  - `develop/device`: IoT, Raspberry Pi, Jetson, and AI integration
- Never push directly to `master` or a `develop/*` branch. Use a Merge Request.
  This holds even when the user asks for a direct merge into `master`; explain
  the feature-branch and develop route instead.
- Never delete `master`, `develop/frontend`, `develop/backend`, or
  `develop/device`.
- A `develop/*` branch is created from `master` only. Never create one from
  another `develop/*` branch: it drags that branch's commits into your history,
  and the next merge to `master` carries changes your role never made.

Create feature branches from the matching up-to-date develop branch:

- Frontend: `feat/frontend/<feature>` from `develop/frontend`
- Backend: `feat/backend/<feature>` from `develop/backend`
- Device and AI: `feat/device/<feature>` from `develop/device`
- Jenkins and CI/CD: `feat/jenkins-<feature>`; target `master` unless instructed
  otherwise
- Repository-wide docs and policy (`AGENTS.md`, branch rules, root README):
  `docs/<topic>`; target `master`

Do not use `codex`, a person's name, or meaningless numbers in a branch name.

Merge Request targets must match the role:

- `feat/frontend/*` -> `develop/frontend`
- `feat/backend/*` -> `develop/backend`
- `feat/device/*` -> `develop/device`
- `feat/jenkins-*` -> `master` unless instructed otherwise
- `docs/*` -> `master`

Do not merge a normal feature branch directly into `master` or another role's
develop branch. Delete feature branches after a successful merge. When merging
a develop branch into `master`, keep the develop branch.

## Back-merge master after every integration

After a `develop/*` -> `master` merge, merge `master` back into all three
develop branches. Do not skip this.

Develop branches are also protected, so a back-merge is an MR too:

```
git fetch origin --prune
git switch -c chore/sync-<role>-from-master origin/develop/<role>
git merge origin/master
git push -u origin chore/sync-<role>-from-master
```

Without the back-merge each develop stays unaware of what the other roles
changed, and the next merge to `master` reopens the same conflicts on the same
lines. Before starting a feature, confirm the target develop is not behind
`master`; if it is, back-merge first.

## Shared files and conflicts

All three roles edit these:

- `자료/docs/**`
- `자료/api/openapi.yaml`

`master` holds every role's edits; each develop holds only its own. That
mismatch is what produces the conflicts.

Never resolve these by taking one side wholesale — each side carries facts the
other lacks, so a wholesale choice silently deletes content. Instead: read both
sides, decide per item which one matches the actual code, keep both lines when
both are valid, then re-check the result against the code.

Keep one fact per line. A table row or bullet that packs several facts together
turns unrelated edits by different roles into a conflict.

## When a develop -> master MR cannot be merged

`master` is protected and the GitLab MR UI cannot always resolve conflicts.
Resolve locally and open an MR from an integration branch:

```
git fetch origin --prune
git switch -c chore/integrate-<topic> origin/master
git merge origin/develop/backend
git merge origin/develop/frontend
git merge origin/develop/device
git push -u origin chore/integrate-<topic>
```

Commit each merge after resolving its conflicts, and run the local checks before
pushing. Merge in the order backend, frontend, device so the API contract is
settled before the other roles' documentation builds on it. The branch sits on
top of `master`, so the MR itself is conflict-free. Back-merge afterwards.

## Required workflow

Before changing code:

1. Read this file.
2. Run `git status` and confirm the current branch.
3. Run `git fetch origin --prune`.
4. Confirm the matching develop branch is not behind `master`; back-merge first
   if it is.
5. Create a correctly named feature branch from that develop branch.

Before pushing:

1. Run the relevant local tests and syntax checks.
2. Update the `자료/docs` documents that describe what you changed, in the same
   branch and MR as the code. Do not push or open an MR when a change needs a
   document update that has not been made. Do not delete another role's lines.
3. Confirm the code and the documents agree.
4. Review the changed files and complete diff.
5. Commit and push only to the feature branch.
6. Create an MR targeting the matching develop branch.
7. Do not merge when CI fails. Fix the same feature branch and rerun CI.
8. Report each result clearly in Korean.

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
