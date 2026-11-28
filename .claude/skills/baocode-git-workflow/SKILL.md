---
name: baocode-git-workflow
description: >-
  Use when creating or switching branches, committing changes, merging branches back to
  personal/main or personal/ui, syncing an official upstream BaoCode release tag, or
  cleaning up merged branches in this fork (payAgain/baocode tracking baocode-dev/baocode).
---

# BaoCode Fork Git & Branch Workflow

Follow this procedure when managing branches, upstream syncs, commits, or merges in `payAgain/baocode`. Full reference: [../../docs/dev-workflow.md](../../docs/dev-workflow.md).

## Safety Guardrails
- **NEVER** `git push`, merge into main lines, bump versions, or create tags without explicit user instruction.
- **NEVER** push anything to `upstream` (`baocode-dev/baocode`) under any circumstances.
- Before any branch/merge/commit action, inspect state with `git branch` and `git status`.

## Branch Roles
- `personal/main` — personal development and release mainline (`origin/personal/main`).
- `personal/ui` — long-term desktop UI maintenance branch (`origin/personal/ui`). Keep UI refactorings isolated here until the user asks to merge.
- `main` — strictly for pulling/syncing `upstream/main`; never our personal mainline and never commit personal work onto `main`.
- `feat/*`, `fix/*`, `work/*` — short-lived isolated branches cut from the target mainline.
- `personal/package-*`, `personal/build-*`, `recovery/*` — snapshot/recovery branches; never auto-delete.

## Procedures

### 1. Daily Feature / Fix Flow
1. Confirm target mainline (`personal/ui` for UI work, `personal/main` for personal features/fixes).
2. Create short-lived branch if isolating work: `git checkout -b feat/<topic>` (or commit small fixes directly if requested).
3. Before committing:
   - Run `dart format <changed_files>` and `dart analyze <changed_paths>` (or `flutter analyze --fatal-infos`).
   - Run only targeted tests (`flutter test test/<area>`).
   - Commit with Conventional Commits style: `type(scope): summary` (e.g., `fix(ide): ...`, `feat(bots): ...`).
4. When user instructs to merge back: merge verified branch into target mainline (fast-forward when clean, normal merge commit if diverged).

### 2. Syncing Official Upstream Release Tag
1. Fetch tag from `upstream`: `git fetch upstream tag v<x.y.z>`.
2. Merge tag into the target personal branch. On conflicts in `pubspec.yaml` or `lib/update/version.dart`, keep the existing personal version until the merge commit is recorded.
3. Align personal version baseline:
   ```sh
   dart run tool/bump_version.dart --personal v<x.y.z>
   ```
   Verify it resets versions to `<x.y.z>+0`, then re-run static analysis and key tests.

### 3. Post-Push Branch Cleanup (Only After Confirmed Merge & Push)
1. Prune remote refs: `git fetch --prune origin`
2. Check merged local and remote branches against `origin/personal/main`:
   ```sh
   git branch --merged origin/personal/main
   git branch -r --merged origin/personal/main
   ```
3. Only delete confirmed merged short-lived work branches (`git branch -d <branch>` and `git push origin --delete <branch>`). Preserve `main`, `personal/main`, `personal/ui`, and snapshot/recovery branches.
