# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-05-02

### Changed

- `watch-pr-feedback` skill: added empty-body comment filter — review threads with no body text are skipped before classification, preventing noisy no-op remediation passes.
- `watch-pr-feedback` skill: added self-author filter using a `SELF_LOGIN` environment variable — comments authored by the bot or the acting GitHub login are excluded from the actionable thread list.
- `watch-pr-feedback` skill: `SELF_LOGIN` is exported before Monitor startup to eliminate a first-poll race condition; PowerShell and Bash assignment variants are documented in the shared reference.
- `watch-pr-feedback` skill: narrowed tool allowlist entry to the exact `SELF_LOGIN` assignment command; added a note on paginated thread filtering.
- `github-pr-review-graphql.md` (shared reference): expanded with filter-step documentation covering empty-body and self-author exclusion logic used by `watch-pr-feedback`.
- `pr-review-remediation-loop.md`: added reference to detection filtering step that runs before comment classification.

## [0.3.1] - baseline

Initial published version. Includes orchestrator, planner, coder, and designer agents; `watch-pr-feedback`, `address-pr-feedback`, `checkpoint-commit`, `create-working-branch`, `open-plan-pr`, `request-codex-review`, and `setup-project` skills; and the full governance module suite.
