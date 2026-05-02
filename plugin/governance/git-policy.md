# Git Policy

## Purpose

Defines git workflow enforcement rules that apply to all agents working in this repository.

## Git Workflow Enforcement

`branching-pr-workflow.md` is mandatory. See `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`.

Before implementation begins, the orchestrator must explicitly establish:

- work classification: `feature|bugfix|hotfix|refactor|chore|docs|test|ci`
- base branch
- working branch name
- branch exists vs create
- worktree decision
- checkpoint commit policy
- PR target

If any are undefined, do not begin implementation. Full preflight detail: `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Required Git Preflight).

Workers must stop and report `blocked` if required git context is missing, inconsistent, or unsafe.

No agent may commit or push directly to the resolved trunk branch.
