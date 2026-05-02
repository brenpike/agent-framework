---
name: checkpoint-commit
description: Create a checkpoint commit for the current approved plan after a completed phase, milestone, version bump, or review remediation item.
disable-model-invocation: false
allowed-tools:
  - Bash(git status *)
  - Bash(git diff *)
  - Bash(git add *)
  - Bash(git commit *)
  - Bash(git rev-parse *)
  - Bash(git log *)
shell: powershell
---

## Quick Reference

Rules: `GIT-01` (no trunk commits), `VAL-01` (validation gate), `REPORT-01` (blocked report contract)

Before:
- [ ] Current branch is not trunk
- [ ] Git state is not unsafe per Definitions
- [ ] Staged files belong to the completed phase only

After:
- [ ] Commit message uses `<type>(<scope>): <subject>` format
- [ ] No unrelated files included
- [ ] Output uses skill output contract

Create a checkpoint commit for the current approved plan.

Follow `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`.

## Required Inputs

The orchestrator resolves and passes these per `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Resolution Order). The skill does not resolve them on its own.

- `trunk`: resolved trunk branch name (the branch that must not be committed to directly).

## Requirements

1. Confirm current branch is not `trunk` and that git state is not unsafe per the "Unsafe git state" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`.
2. Review staged and unstaged diff.
3. Stage only files that belong to the completed phase, milestone, version bump, or review-remediation item.
4. Create a commit message in the form `<type>(<optional scope>): <subject>`, where:
   - `<type>` is one of: `feat`, `fix`, `hotfix`, `refactor`, `docs`, `test`, `chore`, `ci`
   - `<subject>` is 72 characters or fewer
   - include a body only when one of: (a) the change reverts a prior commit, (b) the change includes a `BREAKING CHANGE:` footer, (c) the planner's delegation contains a `Why:` field, OR (d) the orchestrator passes `commit_body` explicitly. Otherwise omit the body.
   - the message must not contain any of the strings forbidden by `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Pull Requests) generated-content list

## Do Not

- create a branch
- push
- open a PR
- include unrelated files
- commit on `trunk`

## Output

```text
Status: complete | blocked
Branch:
Commit:
Message:
Files included:
- [file]
Warnings:
- [warning]
- None
```
