# Routing Matrix

> **Status:** Planning / advisory material.
> This document is not active governance. Canonical routing rules live in `plugin/agents/orchestrator.md` (Skill Routing, Execution Algorithm) and `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table).

## User Intent to Target Routing

| # | User Intent Pattern | Target | Selection Rule | Source |
|---|---|---|---|---|
| 1 | Any task not meeting all six planner-skip conditions | `agent-framework:planner` | Planner-First Rule | `plugin/agents/orchestrator.md` (Planner-First Rule) |
| 2 | Task meets all six planner-skip conditions (one owner, one known file, trivial change, branch classification stated or unambiguous, version impact = none, no review remediation) | Orchestrator handles directly (Trivial Fast Path) | All six conditions answered "yes" from task input as written, with no inference | `plugin/agents/orchestrator.md` (Planner-First Rule) |
| 3 | Implementation work: source, tests, docs, build, packaging, release metadata, serialization, generation, runtime behavior | `agent-framework:coder` | File type and role boundary | `plugin/governance/agent-system-policy.md` (Authority Matrix) |
| 4 | Implementation work: presentational UI/UX, design tokens, layout, semantic markup, static ARIA, visual states, responsive presentation, presentation accessibility | `agent-framework:designer` | File type and role boundary | `plugin/governance/agent-system-policy.md` (Authority Matrix) |
| 5 | Branch creation or confirmation needed before implementation | `agent-framework:create-working-branch` | First matching skill (most specific first) | `plugin/agents/orchestrator.md` (Skill Routing) |
| 6 | Phase, milestone, version bump, or review-remediation fix complete | `agent-framework:checkpoint-commit` | Second in selection order | `plugin/agents/orchestrator.md` (Skill Routing) |
| 7 | Plan complete, validation passed, versioning done | `agent-framework:open-plan-pr` | Third in selection order | `plugin/agents/orchestrator.md` (Skill Routing) |
| 8 | User request contains `review`, `codex`, or `audit`; OR `CLAUDE.md` sets review-on-PR = true | `agent-framework:request-codex-review` | Fourth in selection order | `plugin/agents/orchestrator.md` (Skill Routing, Execution Algorithm step 15) |
| 9 | PR feedback + user request contains `watch`, `monitor`, `wait`, `poll`, or `loop` | `agent-framework:watch-pr-feedback` | Fifth in selection order; keyword-driven | `plugin/agents/orchestrator.md` (Skill Routing), `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table) |
| 10 | PR feedback + no watch keywords | `agent-framework:address-pr-feedback` | Sixth in selection order (most permissive) | `plugin/agents/orchestrator.md` (Skill Routing), `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table) |
| 11 | Remediation: `actionable-code-change`, `actionable-test-change`, `actionable-doc-change` | `agent-framework:coder` (via `address-pr-feedback` or `watch-pr-feedback`) | Classification match | `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table) |
| 12 | Remediation: `design-or-UX-concern` | `agent-framework:designer` (via `address-pr-feedback` or `watch-pr-feedback`) | Classification match | `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table) |
| 13 | Remediation: `architecture-or-contract-concern`, `version-or-release-concern`, or actionable fix touching files across multiple planner steps | `agent-framework:planner` | Classification match or cross-step scope | `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table) |
| 14 | Remediation: product, public API, architecture, security, compatibility, release, or versioning decision that cannot be safely inferred | User | Cannot be safely inferred | `plugin/governance/pr-review-remediation-loop.md` (Remediation Decision Table) |

## Selection Priority

Skills are selected most-specific-first. Rows 5 through 10 in the table above follow the selection order defined in `plugin/agents/orchestrator.md` (Skill Routing):

1. `agent-framework:create-working-branch`
2. `agent-framework:checkpoint-commit`
3. `agent-framework:open-plan-pr`
4. `agent-framework:request-codex-review`
5. `agent-framework:watch-pr-feedback`
6. `agent-framework:address-pr-feedback`

The orchestrator chooses the first skill whose invocation boundary matches the current context.

Within remediation routing (rows 11 through 14), classification is checked first. If multiple classifications apply to a single review item, the orchestrator escalates to the most conservative target: user > planner > designer > coder.

The Planner-First Rule (row 1) applies before any skill selection. The orchestrator calls `agent-framework:planner` before delegation, branch creation, or implementation work unless every planner-skip condition is satisfied.

## Conflict Resolution

- **Skill-routing row vs. Planner-First Rule:** When a task matches both a skill-routing row and the Planner-First Rule, planner-first wins unless all six skip conditions are met.
- **Multiple remediation rows:** When a task matches multiple remediation rows (rows 11 through 14), escalate to the more conservative target (user > planner > designer > coder).
- **Watch keywords + remediation routing:** When watch keywords and remediation routing both apply, `agent-framework:watch-pr-feedback` is selected for the skill; remediation routing (rows 11 through 14) determines the worker that the skill delegates to.

## Related Documents

- [Execution State Machine](execution-state-machine.md)
