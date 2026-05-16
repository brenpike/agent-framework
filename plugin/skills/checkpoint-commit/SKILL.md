---
name: checkpoint-commit
description: Create a checkpoint commit for the current approved plan after a completed phase, milestone, version bump, or review remediation item.
allowed-tools:
  - Bash(git status *)
  - Bash(git diff *)
  - Bash(git add *)
  - Bash(git commit *)
  - Bash(git rev-parse *)
  - Bash(git log *)
  - Bash(printf *)
shell: bash
---

## Quick Reference

Rules: `GIT-01` (no trunk commits), `VAL-01` (validation gate)

Before:
- [ ] Current branch is not trunk
- [ ] Git state is not unsafe per Definitions
- [ ] Staged files belong to the completed phase only

After:
- [ ] Commit message uses `<type>(<scope>): <subject>` format
- [ ] No unrelated files included
- [ ] Final action is a Bash tool call (exit 0 = succeeded, exit 1 = blocked)

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
5. The `git commit` command in step 4 is the final Bash tool call. Its natural stdout (commit SHA and message) is the routing data. If any step fails, emit blocker to stderr and exit 1.

## Silence Discipline

This is a pipeline skill. Per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Skill Output Convention):

- Produce zero text output at any point during execution. Your only outputs are tool calls.
- Your final action must be a Bash tool call.
- Exit 0 = orchestrator proceeds. Routing data (if any) is in stdout.
- Exit 1 = blocked. Emit reason: `printf 'blocker: <reason>' >&2; exit 1`
- Never include a `status:` field in any output.

## Do Not

- create a branch
- push
- open a PR
- include unrelated files
- commit on `trunk`
