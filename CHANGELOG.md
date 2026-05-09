# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

## [0.6.0] - 2026-05-08

### Added

- **`local-codex-review` skill.** New skill that runs a pre-PR local Codex review on the current branch diff without requiring a pushed PR or GitHub interaction.
- **`review-loop-controller` skill.** New skill that drives the pre-PR local Codex review loop: up to 5 iterations with break-fix-break detection, routing each iteration to `local-codex-review` and `agent-framework:coder` for fix passes.
- **Pre-PR local Codex review loop.** Orchestrator now supports a local review-and-fix loop (up to 5 iterations) before opening a PR. Loop terminates early on break-fix-break cycle detection to prevent thrash.
- **`Break-fix-break cycle` definition in `agent-system-policy.md`.** Canonical definition for a review iteration where a prior fix introduces a new finding of the same category as the finding it resolved — triggers early loop exit.

### Changed

- `request-codex-review` renamed to `request-github-codex-review`. Consumers referencing these skills by name in CLAUDE.md or project config must update to the new `-github-` prefixed names.
- `address-pr-feedback` renamed to `address-github-pr-feedback`. Consumers referencing these skills by name in CLAUDE.md or project config must update to the new `-github-` prefixed names.
- `watch-pr-feedback` renamed to `watch-github-pr-feedback`. Consumers referencing these skills by name in CLAUDE.md or project config must update to the new `-github-` prefixed names.

## [0.5.3] - 2026-05-08

### Fixed

- **Orchestrator intake label restored.** Re-added "(intake)" suffix to task-type classification sub-bullet in step 0; fixes safety-budget-profiles CI fixture.

## [0.5.2] - 2026-05-08

### Fixed

- **Orchestrator claude-mem detection moved to task intake.** Orchestrator now owns claude-mem detection at task intake (Execution Algorithm step 0) and invokes `claude-mem:mem-search` before delegating to the planner. Result cached as session fact `claude-mem: present|absent`. Memory context passed to planner as `Memory context:` field.
- **Planner Memory-First Planning restructured into two modes.** Primary mode consumes the orchestrator-provided `Memory context:` field directly. Fallback mode self-invokes detection when the planner is invoked without an orchestrator.
- **Clarified detection timing.** claude-mem detection runs at task intake (not "at session start") per `context-management-policy.md`.

## [0.5.1] - 2026-05-08

### Fixed

- **jq `\s` escape in shared GraphQL helper.** Replaced `gsub("\\s+"; "")` with `gsub("[[:space:]]+"; "")` at all three occurrences in `plugin/skills/_shared/github-pr-review-graphql.md` (Fetch Unresolved Thread Summary Lines, Fetch Top-Level PR Comments, Detection Filtering). Agents were emitting `\s` as an invalid jq escape sequence, causing skill execution to fail with "invalid escape sequence" errors.
- **Standalone `jq` binary prohibition.** Added explicit rules to the "Shell and Parsing Rules" section of `plugin/skills/_shared/github-pr-review-graphql.md` prohibiting use of the standalone `jq` binary (unavailable on Windows) and `/tmp/` paths (Linux-only). Agents must use only `gh … --jq …` for JSON processing.

## [0.5.0] - 2026-05-07

### Added

- **Context management — Slice 2 hardening.** Promotes the context management module from conditional to **mandatory governance**: task-type classification (intake), per-task budget profile enforcement, and progressive-evidence-loading (inline-evidence caps + always-externalize categories) now apply to every task, including the trivial fast path. Phase-handoff, retrieval-anchor, reconstruction-test, contradiction-detection, and auto-clear rules continue to apply when the workflow includes more than one execution phase or the plan contains `STEP-NNN` identifiers.
- Reconstruction test as a hard blocking gate at every major phase transition (`context-management-policy.md` (Reconstruction Test); `reconstruction-failure-runbook.md`).
- Quality guardrails promoted to hard enforcement (Pre-Execution Checklist, Post-Execution Assumption Validation, Contradiction Detection — all blocking).
- Full Budget Profiles table per task type (`bugfix`, `refactor`, `feature`, `incident`) with per-phase artifact, replay-depth, tool-call, and inline-evidence limits.
- Auto-Clear Triggers and Procedure split into **Path A** (phase-completion) and **Path B** (mid-phase N-tool-call / scope-pivot / explicit user reset), with partial-checkpoint storage for mid-phase clears.
- Synthetic `TASK-NNN` task checkpoint identifier for `STEP-NNN`-bypass tasks (TFP / `TRIVIAL_CHANGE` / `SINGLE_STEP_TASK` / single-step `NO_PRIOR_PHASE`); propagated as the new `active-task` Session Fact and consumed by Path B partial checkpoints (`.agent-framework/checkpoints/TASK-NNN-partial-NNN.md`) and the auto-clear thrash log.
- Mandatory `Bypass:` field in every delegation template that allows `Step:` to be omitted, carrying the explicit Bypass Allowlist reason code.
- Minimum-anchor blocking gate: non-trivial step completion fails phase verification if the candidate handoff carries zero `DEC`/`RISK`/`ASM`/`EVD` retrieval anchors.
- Three load-bearing governance runbooks: `reconstruction-failure-runbook.md`, `unresolved-contradiction-runbook.md`, `auto-clear-thrash-runbook.md`.
- Five new safety regression fixtures covering reconstruction gate, contradiction blocking, anchor format, budget profiles, and progressive loading (17/17 safety fixtures pass).

### Changed

- Phase Verification (orchestrator + canonical Path A) now requires the **minimum-anchor check, contradiction detection, and reconstruction test** to all pass before storing or delegating the candidate handoff. The handoff persisted now carries the full `Step delta:` plus all mandatory Context Management Fields (per `communication-policy.md` (Context Management Fields)) — not the compact step-delta alone.
- Contradiction Detection scope expanded from "prior decision" to all mandatory Context Management Fields (`Decisions`, `Scope in/out`, `Assumptions`, `Open questions`, `Artifacts`, `Evidence refs`, `Risk level`) and every retrieval-anchor type (`DEC`, `RISK`, `ASM`, `EVD`).
- Path B partial-checkpoint anchor list records all retrieval anchor types (`DEC/RISK/ASM/EVD`), the active delegation fields (task objective, file scope, completion criteria, constraints), and the active step or task identifier.
- Budget Breach Handling splits inline-evidence breaches into a **blocking** path (must externalize before continuing) separate from the non-blocking handling for `Max artifacts/phase`, `Max replay depth`, and `Max tool calls/checkpoint`.
- Pre-Execution Checklist accepts `STEP-NNN` **or** `TASK-NNN` (with the bypass reason code recorded in the delegation preamble).
- Communication policy: `task-type` and `active-task` cacheable Session Facts added; `task-type` and (when `Step:` is omitted) `active-task` are mandatory in every delegation, including the first.
- Worker docs (`coder.md`, `designer.md`): every non-trivial phase-closing report must include all mandatory Context Management Fields; Progressive Evidence Loading section lists always-externalize categories (test output, build logs, large diffs, command output >50 lines) ahead of the 50-line cap; Contradiction Detection scope mirrors the canonical gate.

### Fixed

- Contradiction-detection / reconstruction / handoff storage gates aligned end-to-end so a phase that emits a contradictory decision or an unreconstructable handoff cannot persist a tainted artifact or delegate downstream work.
- claude-mem Detection (Present and Absent paths) and Path B rehydration now retrieve the full candidate handoff (step-delta + mandatory Context Management Fields), matching what Path A storage persists.
- Stale conditional-loading references removed from `agent-system-policy.md` and `context-management-policy.md` so all four canonical references (core-contract, agent-system-policy, context-management-policy Loading note, coder/designer summaries) agree on the mandatory status.
- UTF-8 BOM stripped from `context-management-policy.md` and `auto-clear-thrash-runbook.md`.

## [0.4.0] - 2026-05-06

### Added

- **Context management — Slice 1.** Initial context management governance module (`context-management-policy.md`) covering execution policy (plan/step lifecycle, phase transitions, runtime artifact storage), retrieval anchors (`DEC`/`RISK`/`ASM`/`EVD` IDs), memory tiering, baseline quality policy (warn-mode pre/post-execution checks and contradiction detection), phase-boundary auto-clear, and runtime artifact storage paths (`.agent-framework/plans/`, `.agent-framework/handoffs/`, `.agent-framework/checkpoints/`).
- Mandatory governance fields in delegation templates and worker reports (`Step delta:` section, anchor IDs).

## [0.3.2] - 2026-05-02

### Changed

- `watch-pr-feedback [now: watch-github-pr-feedback]` skill: added empty-body comment filter — review threads with no body text are skipped before classification, preventing noisy no-op remediation passes.
- `watch-pr-feedback [now: watch-github-pr-feedback]` skill: added self-author filter using a `SELF_LOGIN` environment variable — comments authored by the bot or the acting GitHub login are excluded from the actionable thread list.
- `watch-pr-feedback [now: watch-github-pr-feedback]` skill: `SELF_LOGIN` is exported before Monitor startup to eliminate a first-poll race condition; PowerShell and Bash assignment variants are documented in the shared reference.
- `watch-pr-feedback [now: watch-github-pr-feedback]` skill: narrowed tool allowlist entry to the exact `SELF_LOGIN` assignment command; added a note on paginated thread filtering.
- `github-pr-review-graphql.md` (shared reference): expanded with filter-step documentation covering empty-body and self-author exclusion logic used by `watch-pr-feedback [now: watch-github-pr-feedback]`.
- `pr-review-remediation-loop.md`: added reference to detection filtering step that runs before comment classification.

## [0.3.1] - baseline

Initial published version. Includes orchestrator, planner, coder, and designer agents; `watch-pr-feedback [now: watch-github-pr-feedback]`, `address-pr-feedback [now: address-github-pr-feedback]`, `checkpoint-commit`, `create-working-branch`, `open-plan-pr`, `request-codex-review [now: request-github-codex-review]`, and `setup-project` skills; and the full governance module suite.
