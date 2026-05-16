# Pipeline Execution Redesign — Completion Handoff

## Status
PR #87 opened to main. Branch: `refactor/orchestrator-pipeline-transition-table`. Version: 1.6.3 (PATCH bump from 1.6.2, after rebase onto main where PR #86 claimed 1.6.2).

## Problem
73% pipeline stop-failure rate in orchestrator. Prose-based continuation rules ("Proceed without stopping", "Pipeline Execution Mandate") compete against model's response-boundary behavioral prior. Prose cannot override structural tendencies — model stops between steps despite instructions not to.

## Solution
Replace prose rules with three structural mechanisms:

1. **State Transition Table** (55 rows, 18 constrained vocabulary tokens): Lookup table mapping pipeline events to GOTO actions. Every step-completion milestone has a deterministic next action. No ambiguity, no interpretation needed.

2. **Continuation Protocol**: `→ PIPELINE: after=<token> | step=<N> | phase=<M/T> | stop=<yes:reason|no> | goto=<action>` — emitted after every step-completion milestone. Forces explicit state tracking before any other output.

3. **Skeleton Execution Algorithm**: One-liner per step (0-15). Complex steps (0, 11, 13a, 15) reference extracted `execution-algorithm-detail.md`. Reduces orchestrator.md scanning burden while preserving full procedural detail on demand.

## Design Decisions (D1-D15)

| ID | Decision | Rationale |
|---|---|---|
| D1 | Structural table over prose reinforcement | Prose competes with behavioral prior; structure bypasses it |
| D2 | after= constrained vocabulary (18 tokens) | Unambiguous event identification, prevents free-text drift |
| D3 | GOTO actions, not next-step assumptions | Explicit routing handles conditional branching (review loops, remediation) |
| D4 | Protocol line before any output | Forces state computation as first action, prevents premature stops |
| D5 | 11 Stop Conditions preserved unchanged | Stop conditions were correct; continuation rules were the failure point |
| D6 | Extract verbose procedures to separate doc | Reduces per-turn token load; orchestrator.md is re-injected every turn |
| D7 | Keep tool-call error recovery as prose | Error recovery is branching logic poorly suited to flat table rows |
| D8 | Skeleton references via `Per execution-algorithm-detail.md (Step N)` | Consistent pattern, easy to grep, loads only when needed |
| D9 | Patch version bump (1.6.2 → 1.6.3, rebased) | Runtime behavior change; original 1.6.2 claimed by PR #86 on main |
| D10 | No changes to delegation templates | Templates are output format, not pipeline control flow |
| D11 | No changes to Phase Verification | Verification is a checklist, not a pipeline transition |
| D12 | No changes to Context Management | Context policy is independent of pipeline continuation |
| D13 | Table row for unmatched events (row 55) | Fail-safe: STOP:unmatched surfaces unknown states instead of silent failure |
| D14 | Condition column handles branching within same event | Single after= token can route to different GOTOs based on context |
| D15 | Protocol trigger = "step-completion milestone" | Self-referential to vocabulary list — avoids too-broad (every tool call) and too-narrow (skill/agent only) scoping |

## Files Changed

| File | Action | Lines | Purpose |
|---|---|---|---|
| `plugin/governance/execution-algorithm-detail.md` | New | +40 | Extracted verbose procedures for Steps 0, 11, 13a, 15 |
| `plugin/agents/orchestrator.md` | Modified | +140/-55 | State transition table, continuation protocol, skeleton algorithm |
| `plugin/.claude-plugin/plugin.json` | Modified | +1/-1 | Version 1.6.2 → 1.6.3 |

## Commits (6 total)

| SHA | Type | Description |
|---|---|---|
| `5a6880f` | refactor | Extract verbose execution algorithm procedures to dedicated doc |
| `f9689a5` | refactor | Replace prose pipeline rules with state transition table |
| `af5a326` | refactor | Bump version 1.6.1 → 1.6.2 |
| `c797bc2` | fix | Scope protocol to milestone events and add classify transitions |
| `e36ec37` | fix | Add validation not-run paths and split phase-verification recovery |
| `dde80a8` | fix | Widen protocol trigger to step-completion milestones and fix revalidation loop |

## Review Loop Summary

4 iterations of local Codex review. 6 findings across 3 iterations with findings. 3 fix commits. 1 false positive rejected.

### Iteration 1 (2 findings → fix commit c797bc2)
- Protocol trigger "every tool call" too broad — intermediate Bash/Read calls produced STOP:unmatched
- Missing `classify-pr-feedback-returned` token and 4 table rows

### Iteration 2 (2 findings → fix commit e36ec37)
- Repos with no validation commands return "Not run" — no table rows existed for this path
- `phase-verification-failed` single row didn't distinguish recoverable vs unrecoverable failures

### Iteration 3 (2 findings → fix commit dde80a8)
- Protocol trigger "skill result or agent return" too narrow — excluded 7 orchestrator-internal tokens
- Post-review revalidation routed back to step 13a (review loop) instead of step 14 (PR), creating infinite loop

### Iteration 4 (1 finding → rejected, exit clean)
- False positive: Codex claimed step 4 needs a transition token. Step 4 is pure orchestrator reasoning — no tool/skill/agent call, no after= token produced. Protocol doesn't fire. Classified `incorrect-or-rejected`.

## Architecture Notes

### State Transition Table Design
- 55 rows organized by after= token groups
- Condition column provides context-dependent routing (e.g., `validation | passed, main pipeline` vs `validation | passed, within review loop`)
- Rows 30-31 (post-review revalidation) break what would otherwise be an infinite loop between validation → review → validation
- Row 55 (no match) is the fail-safe — unknown events surface to user instead of silently dropping

### Token Budget Impact
- Orchestrator.md is re-injected every turn as system prompt
- Table adds ~55 structured rows but removes ~54 lines of prose ("Proceed without stopping" subsection + "Pipeline Execution Mandate" paragraph)
- Net change: +85 lines (~140 added, ~55 removed) — acceptable given structural benefits
- Verbose procedures extracted to execution-algorithm-detail.md (~40 lines) loaded on demand only when relevant step executes

### What Was NOT Changed
- 11 Stop Conditions — preserved verbatim (correct as-is)
- Tool-call error recovery — kept as prose (branching logic doesn't fit flat table)
- Delegation templates — output format, not pipeline control
- Phase Verification — checklist, not transition
- Context Management — independent policy
- Skill Routing — independent policy
- All appendices — unchanged

## Validation
- JSON manifests: `jq . plugin/.claude-plugin/plugin.json > /dev/null` — passed
- JSON manifests: `jq . .claude-plugin/marketplace.json > /dev/null` — passed
- Bare path grep: no violations
- Local Codex review: 4 iterations, exited clean

## Risks and Follow-up

1. **Empirical validation needed**: Table reduces structural stop-failure rate in theory. Actual improvement requires measuring pipeline completion rate across real tasks post-merge. The 73% failure rate was observed pre-refactor; post-refactor measurement will confirm effectiveness.

2. **Table maintenance**: Adding new skills or pipeline steps requires adding corresponding table rows. Missing rows hit row 55 (STOP:unmatched) — safe but requires manual intervention. Consider adding a table-completeness check to CI if table grows beyond ~70 rows.

3. **Bugfix branch abandoned**: `bugfix/orchestrator-pipeline-continuation-reinforcement` branch (v1.6.2 on that branch) merged as PR #86 (v1.6.2) before this PR. Superseded by structural approach. That branch added prose reinforcement — the exact pattern this refactor replaces. Branch deleted after merge; prose additions overwritten by this refactor.
