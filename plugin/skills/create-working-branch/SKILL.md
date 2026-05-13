---
name: create-working-branch
description: Create or confirm the compliant working branch for the current approved plan before implementation begins.
allowed-tools:
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git rev-parse *)
  - Bash(git checkout *)
  - Bash(git switch *)
  - Bash(git fetch *)
shell: bash
---

## Quick Reference

Rules: `GIT-01` (no trunk commits), `GIT-02` (required git preflight), `REPORT-01` (blocked report contract)

Before:
- [ ] Orchestrator provided `base`, `working_branch`, and `classification`
- [ ] Orchestrator confirmed trunk freshness, user acknowledged stale trunk, or orchestrator recorded trunk-freshness: skipped
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
- `trunk-freshness`: resolved trunk freshness state from the Required Git Preflight check per `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Trunk Freshness Gate). One of: `fresh`, `stale (N behind)`, `stale (diverged — local N ahead)`, `stale (diverged — local M ahead, N behind)`, or `skipped`. Absent = skill returns `Status: blocked`.

## Requirements

1. Confirm current branch.
2. Confirm `base` exists locally or fetch it.
3. Check the `trunk-freshness` session fact passed by the orchestrator per `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Trunk Freshness Gate).
   - `trunk-freshness: fresh` — proceed normally, no warning.
   - `trunk-freshness: stale (N behind)` — emit a warning that trunk is stale but proceed (user already acknowledged at preflight).
   - `trunk-freshness: stale (diverged — local N ahead)` — emit a warning that local trunk has unpushed commits but proceed (user already acknowledged at preflight).
   - `trunk-freshness: stale (diverged — local M ahead, N behind)` — emit a warning that local trunk has diverged from origin but proceed (user already acknowledged at preflight).
   - `trunk-freshness: skipped` — proceed with a note that freshness was intentionally skipped per documented skip conditions in `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Trunk Freshness Gate).
   - Absent — return `Status: blocked`, `Blocker: trunk-freshness session fact not provided by orchestrator`.
4. Confirm `working_branch` follows the branch taxonomy and naming rules.
5. Confirm there are no unexpected unstaged/uncommitted changes that make switching unsafe.
6. Create or switch to `working_branch` from `base`.

## Do Not

- create or modify product files
- commit
- push
- open a PR
- continue when branch state is unsafe or indeterminate
- invent values for `base`, `working_branch`, or `classification` — return blocked if any are missing

## Output

```text
Status: complete | blocked
Classification:
Base branch:
Previous branch:
Working branch:
Created: yes | no
Trunk freshness: fresh | stale (N behind, user acknowledged) | stale (diverged — local N ahead, user acknowledged) | stale (diverged — local M ahead, N behind, user acknowledged) | skipped (intentional) | blocked (absent)
Warnings:
- [warning]
- None
```
