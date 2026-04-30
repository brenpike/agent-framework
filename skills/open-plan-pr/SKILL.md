---
name: open-plan-pr
description: Open a pull request for a successfully completed approved plan after final verification.
disable-model-invocation: false
allowed-tools:
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git log *)
  - Bash(git diff *)
  - Bash(git push *)
  - Bash(gh pr create *)
  - Bash(gh pr view *)
  - Bash(gh repo view *)
shell: powershell
---

Open a pull request for the completed approved plan.

Follow `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` and `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`.

## Requirements

1. Confirm current branch and resolved trunk branch (per branching-pr-workflow resolution order).
2. Confirm current branch is not the resolved trunk branch.
3. Confirm no unexpected unstaged changes.
4. Confirm required validation has passed.
5. Confirm required version/release metadata is included or not required.
6. Ensure the current branch is pushed to a remote that `gh pr create` can target:
   - if upstream tracking is already set: run `git push`. On success, record the remote and continue. On failure (non-fast-forward, auth, protected branch, upstream not writable), record a warning and continue — `gh pr create` in step 7 can route to a different remote or fork when the tracked upstream is read-only.
   - if upstream tracking is not set: do not hard-code `origin`. Let `gh pr create` handle the push in step 7. `gh pr create` prompts for the push target when the branch is unpushed and can fork the base repository when the user lacks push access to `origin` (fork-based workflows).
   - if the user has explicitly requested a specific remote, push to that remote with `git push -u <remote> <branch>` and stop blocked on failure.
   - block only when neither `git push` nor `gh pr create` can place the branch on a usable remote.
7. Create PR with:
   - clear title
   - concise summary
   - validation notes
   - version/release notes when relevant
   - unresolved issues when needed

## Do Not

- open PR for partial plan unless workflow explicitly allows it
- open PR if validation is incomplete
- open PR if required version/release metadata is missing
- invent missing validation
- include generated-content signatures

## Output

```text
Status: complete | blocked
Base:
Head:
Pushed: yes (git push) | yes (via gh pr create) | no
Push remote:
PR title:
PR URL:
Warnings:
- [warning]
- None
```
