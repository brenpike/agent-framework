---
name: create-working-branch
description: Create or confirm the compliant working branch for the current approved plan before implementation begins.
disable-model-invocation: false
allowed-tools:
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git rev-parse *)
  - Bash(git checkout *)
  - Bash(git switch *)
  - Bash(git fetch *)
shell: powershell
---

## Quick Reference

Rules: `GIT-01` (no trunk commits), `GIT-02` (required git preflight), `REPORT-01` (blocked report contract)

Before:
- [ ] Orchestrator provided `base`, `working_branch`, and `classification`
- [ ] `base` branch exists locally or can be fetched
- [ ] No uncommitted changes that make switching unsafe
- [ ] `working_branch` name follows branch taxonomy

After:
- [ ] Current branch is `working_branch`
- [ ] Branch created from or confirmed on `base`
- [ ] Output uses skill output contract

Create or confirm the working branch for the current approved plan.

Follow `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`.

## Required Inputs

The orchestrator resolves and passes these per `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Resolution Order). The skill does not resolve them on its own.

- `base`: base branch the working branch is created from (typically the resolved trunk; may differ for stacked work).
- `working_branch`: requested working branch name (must follow branch taxonomy and naming rules).
- `classification`: work classification (`feature|bugfix|hotfix|refactor|chore|docs|test|ci`).

## Requirements

1. Confirm current branch.
2. Confirm `base` exists locally or fetch it.
3. Confirm `working_branch` follows the branch taxonomy and naming rules.
4. Confirm there are no unexpected unstaged/uncommitted changes that make switching unsafe.
5. Create or switch to `working_branch` from `base`.

## Do Not

- create or modify product files
- commit
- push
- open a PR
- continue when branch state is unsafe or ambiguous
- invent values for `base`, `working_branch`, or `classification` — return blocked if any are missing

## Output

```text
Status: complete | blocked
Classification:
Base branch:
Previous branch:
Working branch:
Created: yes | no
Warnings:
- [warning]
- None
```
