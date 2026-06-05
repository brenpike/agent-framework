# No workflow-calls-workflow; reviewer composition stays inlined states

**Status:** accepted — 2026-06-05

## Context

During the issue #201 reviewer-prose-rescue brainstorm, avenue C proposed a composable "reviewer workflow" callable by `standard-delivery` (and others) to DRY the review machinery. Today review orchestration is already declarative states, but those states are DUPLICATED across `plugin/workflows/standard-delivery.json` and `plugin/workflows/pr-feedback-remediation.json` (~8 states: `github_review_loop`, `github_reviewer_fix`, `review_remediation_plan`, `implement_step`, `checkpoint`, `validate`, `push_remediation`, plus standard-delivery's `_postpr` variants). A composable sub-workflow would dedup them.

However, the ADR-0018 engine has NO sub-workflow-invocation primitive: state `type` is only `agent|skill|decision|user_gate|terminal` (no `workflow` type); one run ledger maps to exactly one workflow definition; `record-state-result.sh` hard-rejects any definition/ledger id-or-version mismatch and self-derives the definition from the ledger's `run.workflow`; and brood is a TOPOLOGY of independent overlords each owning its own ledger in its own worktree (ADR-0007), not a called sub-workflow. ADR-0018 deliberately keeps composition out of the engine to stay minimal.

## Decision

Do NOT build workflow-calls-workflow as part of #201. Review composition stays as inlined declarative states, accepting the ~8-state duplication across the two workflow definitions. #201's prose-rescue goal is served by deterministic-procedure extraction to scripts (avenue A) plus slimming the `github-review-loop` skill (avenue B1) — NOT by a new composition primitive.

Sub-workflow composition (a `workflow` state type / workflow-calls-workflow) is PARKED as a standalone future decision that, if ever taken, requires its own ADR covering: a new state type, the nested-ledger ownership model, a nested version-skew gate, and engine + CI test rework.

## Considered Options

| Option | Rejected because |
|---|---|
| Build workflow-calls-workflow composition now (avenue C) | Net-new engine primitive that cuts against ADR-0018's deliberate minimalism (brood is topology, not call); high cost (new state type + nested-ledger ownership + nested version-skew + engine/CI rework) for a modest payoff (dedup ~8 states across 2 JSON defs); orthogonal to the prose-stall problem #201 actually targets |
| Live with the duplicated review states (CHOSEN) | The duplication is cheap: ~8 states, JSON, CI-validated, low drift risk — not the dense-prose-stall failure mode #201 addresses |
| Unify the two reviewer agents into one | Out of scope; ADR-0001 keeps two specialist reviewers; sharing is achieved via shared scripts/skills, not agent unification |

## Consequences

- ~8 review states remain duplicated across `standard-delivery.json` and `pr-feedback-remediation.json`. Acceptable: JSON, CI-validated, low-drift.
- #201's reviewer-prose reduction proceeds entirely via avenues A (scripts) + B1 (loop slim) — see `docs/prds/reviewer-prose-rescue.md`.
- If a third or later workflow needs the review states, OR the duplication starts drifting in practice, revisit sub-workflow composition on its own ADR; this decision is a deferral, not a permanent veto.
- Engine minimalism (ADR-0018) is preserved; no new state type is introduced.
