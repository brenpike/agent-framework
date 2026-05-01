# AGENTS.md

## Purpose

Repository-level guidance for external AI reviewers such as Codex.

External reviewers consult `AGENTS.md` at the repository root.

Codex is an external pull request reviewer, not an internal Claude Code subagent. It must not push commits, change branches, or resolve review threads. It must leave review comments only.

Project-specific build, test, architecture, package, and domain rules live in `CLAUDE.md` and the repository documentation it references.

## Review Focus

Review PRs for:

- correctness
- regressions
- security
- public API compatibility
- backwards compatibility
- package/release behavior
- maintainability
- missing or weak tests
- risky behavior changes

## Severity

- P0: any of (1) introduces a security vulnerability, (2) introduces a data-loss path, (3) breaks main-branch CI, (4) breaks a previously-working public API, (5) makes the next release unshippable per project release criteria
- P1: likely bug, missing test for a code path changed in this PR, public API break, package/release regression, or incorrect behavior
- P2: maintainability, naming, style, documentation, or coverage gap that does not affect a code path changed in this PR

## Review Behavior

Each comment must include all of:

- file path and line range
- observed problem
- proposed fix or fix direction
- severity from the table above

Do not comment on naming, formatting, or stylistic choices unless `CLAUDE.md` or a documented style guide referenced from `CLAUDE.md` defines a different rule.

Do not push commits directly.
