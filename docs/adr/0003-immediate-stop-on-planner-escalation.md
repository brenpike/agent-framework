# Immediate stop on planner escalation during review loops

> Active end-state: ADR-0006.

**Status:** superseded by ADR-0006 — 2026-05-18; superseded by ADR-0026 — 2026-06-17

Superseded by the intent-based governance rewrite (ADR-0006). Intent-based reviewers judge per-finding whether a finding is too complex to fix themselves. The rigid mechanical rule (always stop immediately on planner-classified finding, even if simpler findings remain) is replaced by model judgment: fix what's simple, escalate what's complex, return when the loop is clean or blocked.

When a reviewer agent encounters a finding classified as `architecture-or-contract-concern` or `version-or-release-concern` (routing: planner), it stops the review loop immediately and returns to the orchestrator — even if other simpler findings remain unprocessed in the current iteration.

The orchestrator then delegates planner → coder (at opus tier) to fix the architectural issue on the same branch, and starts a fresh reviewer loop from iteration 1 afterward.

The alternative — deferring planner findings until the loop's natural terminal, fixing all small issues first, then handling architecture — risks wasted effort. A planner-routed finding typically represents a sizable structural change that may invalidate the smaller fixes. Fixing five typos and then refactoring the module they're in means re-reviewing the typo fixes anyway. Better to fix the big thing first, then let a fresh review loop catch whatever remains (including re-checking the areas touched by smaller prior-iteration fixes that are already committed).

## Considered Options

| Option | Rejected because |
|---|---|
| Defer planner findings to terminal output | Risk of wasted effort — small fixes may be invalidated by the architectural change; reviewer burns iterations on work that gets re-reviewed anyway |
| Return to orchestrator mid-loop, resume from same iteration | Adds re-invocation complexity; prior fix ledger may be invalid after architectural change; fresh loop is simpler and catches everything |

## Consequences

- Planner escalation is the one case where a reviewer returns mid-flow (all other returns are terminal)
- Orchestrator must constrain planner delegation to same branch (no new branch creation) so the reviewer can re-review the combined state
- Fresh loop after planner fix means iteration counter resets — prior fix ledger state is intentionally discarded
- For local-reviewer: C1 continuation (ledger on disk) is available but not used for planner escalation — always fresh
- For github-reviewer: C3 (fresh state) applies naturally
