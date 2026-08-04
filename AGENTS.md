# S15P11E201 repository instructions

These instructions apply to the entire repository. Read this file before making
any change.

## Branch policy

- The default branch is `master`. Do not use a branch named `main`.
- Long-lived branches are:
  - `develop`: shared integration branch for every role (Backend, Frontend,
    Device/AI)
  - `master`: deployment baseline
- There are no per-role develop branches. Backend, Frontend, and Device all use
  the same `develop`.
- Never push directly to `master` or `develop`. Use a Merge Request.
- Never delete `master` or `develop`.

### Core rule: `master` only ever merges from `develop`

The single merge into `master` is `develop` -> `master`. Never open an MR
targeting `master` from anything else — not a feature, a fix, a doc change, or
a config change. This holds even when the user asks for a direct merge into
`master`; explain the `develop` route instead.

Because of this rule `master` is always a subset of `develop`. No commit can
exist on `master` but not on `develop`, so merging `master` back into `develop`
is never necessary. The old back-merge, `chore/sync-*`, and `chore/integrate-*`
procedures are retired — they existed only to manage three develop branches.

## Feature branches

Prefixes exist so a human can tell which part a branch touches. Every branch is
created from `develop` and merged back into `develop`.

- `feat/backend/<feature>`, `feat/frontend/<feature>`, `feat/device/<feature>`
- `feat/jenkins-<task>` for Jenkins and CI/CD
- `fix/backend/<bug>`, `fix/frontend/<bug>`, `fix/device/<bug>`
- `docs/<topic>` for documentation-only changes
- `chore/<task>` for build, config, and file cleanup

Do not use `codex`, a person's name, or meaningless numbers in a branch name.

Keep feature branches short-lived: merge and delete within one to three days. A
long-lived feature branch drifts from `develop` and creates conflicts.

## Starting work

The commands are identical for every role:

```
git fetch origin --prune
git switch develop
git pull --ff-only origin develop
git switch -c feat/backend/<feature>
```

## Merge Request targets

Every feature branch targets `develop`:

- `feat/*` -> `develop`
- `fix/*` -> `develop`
- `docs/*` -> `develop`
- `chore/*` -> `develop`

The only MR targeting `master` is `develop` -> `master`.

## Merging and deleting

Merge into `develop` only after CI passes. Keep **Delete source branch when
merge request is accepted** enabled so no feature branch is left behind.

**Squash commits** defaults to off. Tick it when the branch is a pile of
trial-and-error commits (wip, test fixes, typos), so the MR lands as one commit
on `develop`. Leave it off when each commit is an independent logical change
worth keeping.

For `develop` -> `master`, never tick Squash — the default (off) is already
correct. Squashing a promotion splits `master`'s history from `develop`'s and
causes conflicts on every later promotion. Untick the delete-source option too;
`develop` is protected and cannot actually be deleted, but leaving the option
off keeps the intent clear.

Nothing needs to happen after a `develop` -> `master` merge. Do not back-merge.

## Urgent fixes

Even for a production emergency, do not MR directly into `master`. Branch
`fix/<role>/<bug>` from `develop`, merge it into `develop`, then immediately
open `develop` -> `master`. `develop` is kept green by required CI, so this path
is not slow. Allowing one exception puts `master` ahead of `develop` and brings
back the retired back-merge procedure.

## Shared files and conflicts

All three roles edit these:

- `자료/docs/**`
- `자료/api/openapi.yaml`

Keep one fact per line. A table row or bullet that packs several facts together
turns unrelated edits by different roles into a conflict.

Never resolve a conflict by taking one side wholesale — each side carries facts
the other lacks, so a wholesale choice silently deletes content. Read both
sides, decide per item which one matches the actual code, keep both lines when
both are valid, then re-check the result against the code.

With a single `develop`, these conflicts surface only when merging a feature
branch into `develop`. Pull `develop` often to keep the conflict surface small.

## Required workflow

Before changing code:

1. Read this file.
2. Run `git status` and confirm the current branch.
3. Run `git fetch origin --prune`.
4. Create a correctly named feature branch from `develop`.

Before pushing:

1. Run the relevant local tests and syntax checks.
2. Update the `자료/docs` documents that describe what you changed, in the same
   branch and MR as the code. Do not push or open an MR when a change needs a
   document update that has not been made. Do not delete another role's lines.
3. Confirm the code and the documents agree.
4. Review the changed files and complete diff.
5. Commit and push only to the feature branch.
6. Create an MR targeting `develop`.
7. Do not merge when CI fails. Fix the same feature branch and rerun CI.
8. Report each result clearly in Korean.

## CI expectations

- Frontend: `flutter pub get`, `flutter analyze`, and `flutter test`. Do not
  build APK or AAB artifacts. There is no Frontend CD.
- Backend: build, unit tests, PostgreSQL integration tests, and editor-api
  (video_editor) Python tests.
- Device and AI: Device Agent tests, AI Python tests, and Python/Shell syntax
  checks.
- API Contract: `자료/api/openapi.yaml` contract checks.

`Jenkinsfile` selects stages by branch name. `master` and `develop` run all
four stages; a `feat/<role>/**` or `fix/<role>/**` branch runs that role's stage
plus API Contract; `docs/**` and `chore/**` run API Contract only.

A missing or wrong role prefix means that role's CI never runs, and the MR shows
green rather than failing. That is why the naming rule matters.

## Deployment restrictions

- Frontend runs on a developer machine with `flutter run`; do not automate APK,
  AAB, or app-store deployment.
- Device and AI stop at CI; do not automatically deploy to devices or EC2.
- Backend production deployment requires successful `master` CI and explicit
  user approval. Never approve a production deployment without the user's
  request. Abort unnecessary deployment jobs.

The complete Korean policy is stored in `llm/GIT_BRANCH_RULES.md`. LLM working
documents (session handoffs, integration reports) belong in `llm/handoff/` —
`ai/` is the Jetson AI product code only.
