---
name: open-plan-pr
description: Open a pull request for a successfully completed approved plan after final verification.
disable-model-invocation: false
allowed-tools:
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git log *)
  - Bash(git diff *)
  - Bash(git rev-parse *)
  - Bash(git push *)
  - Bash(gh pr create *)
  - Bash(gh pr view *)
shell: powershell
---

Open a pull request for the completed approved plan.

Follow `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` and `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`.

## Required Inputs

The orchestrator resolves and passes these per `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Resolution Order). The skill does not resolve them on its own.

- `base`: resolved trunk branch (PR target).
- `head`: working branch (current branch).
- `push_remote`: optional explicit remote name. Omit unless the user named one.

## Requirements

1. Confirm current branch matches `head` and is not `base`.
2. Confirm no unexpected unstaged changes.
3. Confirm required validation has passed.
4. Confirm required version/release metadata is included or not required.
5. Capture local HEAD SHA: `git rev-parse HEAD`.
6. Place the working branch on a remote that `gh pr create` can target:
   - if `push_remote` is provided: `git push -u <push_remote> <head>`. On failure, stop blocked.
   - else if upstream tracking is set: run `git push`.
     - on success: continue with that remote.
     - on **non-fast-forward** failure: stop blocked. Local HEAD is behind remote; PR would be stale or wrong.
     - on **auth / read-only / protected branch** failure: record warning and continue. `gh pr create` may route to a fork or alternate remote.
   - else (no upstream, no `push_remote`): defer to `gh pr create` in step 7. It prompts for push target and can fork the base repo.
7. Run `gh pr create --base <base> --head <head> ...` with title, summary, validation notes, version/release notes, and unresolved issues.
8. Verify the PR head SHA matches local HEAD captured in step 5: `gh pr view <pr> --json headRefOid --jq .headRefOid`. If mismatch, stop blocked — the PR points at a stale or wrong commit.

## Do Not

- open PR for partial plan unless workflow explicitly allows it
- open PR if validation is incomplete
- open PR if required version/release metadata is missing
- continue past step 6 with an unverified push state
- invent missing validation
- include generated-content signatures

## Output

```text
Status: complete | blocked
Base:
Head:
Local HEAD:
Pushed: yes (git push) | yes (via gh pr create) | no
Push remote:
PR head SHA:
Head verified: yes | no
PR title:
PR URL:
Warnings:
- [warning]
- None
```
