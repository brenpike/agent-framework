# AGENTS.md

## Purpose

Repository-level guidance for external AI reviewers such as Codex.

This repository is the source for the `agent-framework` Claude Code plugin and its marketplace manifest. External reviewers consult this file when reviewing pull requests in this repo.

Codex is an external pull request reviewer, not an internal Claude Code subagent. It must not push commits, change branches, open or close PRs, request re-review, resolve review threads, or modify files. It must leave review comments only.

## Repository Context

Read `CLAUDE.md` before reviewing. It contains the repo-specific layout, validation commands, versioning source, and common pitfalls.

Important layout facts:

- `.claude-plugin/marketplace.json` is the marketplace manifest at the repo root and must keep `source` pointed at `./plugin`.
- `plugin/` is the installed plugin payload. Runtime agents, skills, plugin metadata, and active governance live there.
- `plugin/.claude-plugin/plugin.json` is the canonical plugin version source.
- `plugin/governance/` contains runtime governance loaded by agents. New governance files are dead unless referenced by an agent or skill.
- `docs/planning/` is human-only planning material. Do not treat it as active plugin governance.

## Review Focus

Review PRs for:

- correctness
- regressions in plugin installability or runtime behavior
- broken `${CLAUDE_PLUGIN_ROOT}/...` references
- stale agent, skill, or governance references
- unsupported Claude Code plugin frontmatter fields
- security issues
- public/plugin compatibility issues
- package or marketplace behavior regressions
- missing or weak validation for changed behavior
- accidental inclusion of planning/dev-only files in the plugin payload

## Severity

- P0: introduces a security vulnerability, breaks installation of the plugin, breaks the marketplace source path, breaks main-branch validation, corrupts the canonical plugin manifest, or makes the next plugin release unshippable.
- P1: likely runtime behavior regression, broken agent/skill/governance reference, invalid plugin or marketplace JSON, missing validation for a changed runtime path, incorrect versioning behavior, or unsupported plugin frontmatter added to an agent.
- P2: maintainability, documentation, reviewability, or coverage gap that does not affect plugin runtime behavior or release correctness.

## Review Behavior

Each comment must include all of:

- file path and line range
- observed problem
- proposed fix or fix direction
- severity from the table above

Do not comment on naming, formatting, import ordering, or stylistic choices unless `CLAUDE.md`, `README.md`, or an active governance document under `plugin/governance/` defines the rule being violated.

Do not treat `docs/planning/` content as normative runtime policy. Review it for internal consistency and repository hygiene only.

## Validation Expectations

For changes that touch plugin runtime files, check whether the PR validates the items named in `CLAUDE.md`, including:

- `plugin/.claude-plugin/plugin.json` parses as JSON
- `.claude-plugin/marketplace.json` parses as JSON
- plugin-internal path references use `${CLAUDE_PLUGIN_ROOT}/...` where required
- no unsupported agent frontmatter fields are introduced
- marketplace `source` remains `./plugin`

If validation is missing for a runtime-affecting change, comment as P1 unless the PR clearly explains why validation was not applicable.

## Versioning Expectations

The canonical version source is `plugin/.claude-plugin/plugin.json`.

Do not require a version bump for human-only planning docs, tests, or tooling outside `plugin/` unless the PR also changes plugin runtime behavior, packaged output, or consumer-facing plugin semantics.

Require a versioning review when a PR changes:

- `plugin/.claude-plugin/plugin.json`
- agent definitions under `plugin/agents/`
- skill definitions under `plugin/skills/`
- active governance under `plugin/governance/`
- marketplace behavior under `.claude-plugin/marketplace.json`

## Hard Constraints

- Do not push commits directly.
- Do not resolve review threads.
- Do not request re-review.
- Do not approve PRs as a substitute for required human review.
- Do not suggest moving runtime plugin files out of `plugin/`.
- Do not suggest moving human-only planning files into `plugin/` unless they are intentionally being promoted to runtime governance and agent/skill references are added in the same PR.
