---
name: request-github-codex-review
description: Request Codex review on the current GitHub pull request.
allowed-tools:
  - Bash(gh pr view *)
  - Bash(gh pr comment *)
shell: bash
---

## Quick Reference

Rules: `REPORT-01` (blocked report contract)

Before:
- [ ] PR exists and is open
- [ ] Current branch is the PR head branch
- [ ] PR branch has been pushed

After:
- [ ] Review request comment posted on PR
- [ ] Output uses skill output contract

Request Codex review on the current pull request.

Codex is an external reviewer, not a Claude Code subagent.

## Required Inputs

At minimum one of:

- PR number or PR URL, OR
- a current git branch with exactly one open PR on the configured remote (the skill resolves the PR via `gh pr view --json number,state` against the current branch)

If neither is available, return the Worker Report — Blocked with `Stage: fetch` and `Blocker: no PR identified`.

## Requirements

1. Confirm the PR exists.
2. Confirm the current branch is the PR head branch.
3. Confirm the PR branch has been pushed.
4. Post this PR comment:

```text
@codex review for regressions, missing tests, public API compatibility issues, security issues, package/release behavior, versioning issues, and risky behavior changes.
```

## Do Not

- modify files
- commit
- push
- resolve review threads
- request review if no PR exists

## Output

```text
Status: complete | blocked
PR number:
PR URL:
Branch:
Review request posted: yes | no
Warnings:
- [warning]
- None
```
