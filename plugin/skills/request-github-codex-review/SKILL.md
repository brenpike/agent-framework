---
name: request-github-codex-review
description: Request Codex review on the current GitHub pull request. For explicit ad-hoc requests only — normal flow uses push-triggered auto-review.
allowed-tools:
  - Bash(gh pr view *)
  - Bash(gh pr comment *)
  - Bash(printf *)
shell: bash
---

## Quick Reference

Rules: None

Before:
- [ ] PR exists and is open
- [ ] Current branch is the PR head branch
- [ ] PR branch has been pushed

After:
- [ ] Review request comment posted on PR
- [ ] Final action is a Bash tool call (exit 0 = succeeded, exit 1 = blocked)

Request Codex review on the current pull request. This skill is for explicit ad-hoc review requests only — normal flow uses push-triggered auto-review via the `github-reviewer` agent's watch mode.

Codex is an external reviewer, not a Claude Code subagent.

## Required Inputs

At minimum one of:

- PR number or PR URL, OR
- a current git branch with exactly one open PR on the configured remote (the skill resolves the PR via `gh pr view --json number,state` against the current branch)

If neither is available, emit `printf 'blocker: no PR identified' >&2; exit 1`.

## Requirements

1. Confirm the PR exists.
2. Confirm the current branch is the PR head branch.
3. Confirm the PR branch has been pushed.
4. Post this PR comment:

```text
@codex review for regressions, missing tests, public API compatibility issues, security issues, package/release behavior, versioning issues, and risky behavior changes.
```

5. After the `gh pr comment` command in step 4 succeeds (suppress its output with `>/dev/null 2>&1`), emit explicit YAML as the final Bash tool call: `printf 'review_requested: true\npr: %s\n' "$pr_number"`. This YAML output is the routing data. If any prerequisite check fails, emit blocker to stderr and exit 1.

## Silence Discipline

This is a pipeline skill. Per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Skill Output Convention):

- Produce zero text output at any point during execution. Your only outputs are tool calls.
- Your final action must be a Bash tool call.
- Exit 0 = orchestrator proceeds. Routing data (if any) is in stdout.
- Exit 1 = blocked. Emit reason: `printf 'blocker: <reason>' >&2; exit 1`
- Never include a `status:` field in any output.

## Do Not

- modify files
- commit
- push
- resolve review threads
- request review if no PR exists
