# Context Management Improvement Plan

## Document Purpose

This document is a self-contained implementation plan for improving context management in the `agent-framework` plugin workflow. It is intended for team review without requiring additional external discussion context.

It covers:

- Why we are changing context management.
- What we will implement and in what order.
- How each item should be integrated into agent behavior.
- How each item should be baked into governance/policy.
- Dependencies across items.
- Risks, guardrails, and rollout validation.

---

## Problem Statement

Long-running agent workflows currently risk:

- Context bloat from repeatedly carrying stale or low-signal history.
- Precision drift when key decisions are buried in large transcripts.
- Inconsistent execution behavior when plans and execution records are not tightly coupled.
- Rework due to missing handoff structure and weak checkpointing discipline.

Goal: reduce context load and improve consistency **without degrading quality or precision**.

---

## Design Principles

1. **Structure over transcript replay**: summarize and persist state as structured artifacts.
2. **Single execution flow**: use a canonical plan/step lifecycle.
3. **Evidence-linked decisions**: decisions should be recoverable without full thread replay.
4. **Guardrails before automation**: enforce quality checks before aggressive context clearing.
5. **Phased rollout**: deliver high-ROI, low-risk capabilities first.

---

## Scope and Non-Goals

### In Scope

- Agent workflow behavior (planning, execution, handoffs, memory lifecycle).
- Governance additions/updates to enforce standards.
- Validation/linting/telemetry required to safely operate reduced-context flows.

### Out of Scope

- Replacing existing governance wholesale.
- Changing plugin packaging layout.
- Introducing hard runtime dependencies on optional external plugins.

---

## Recommended Implementation Order

### Phase 0 — Foundation (High ROI, Low Risk)

1. Structured phase handoffs.
2. Canonical `make-plan` + `do` execution flow.
3. Retrieval anchors (decision/risk/evidence IDs).
4. Reconstruction test.

### Phase 1 — Safety and Policy Hardening

5. Quality guardrails (invariants/assumptions/contradiction checks).
6. Two-tier memory model (durable vs ephemeral).
7. Context budget policy by task type.

### Phase 2 — Automation and Advanced Optimization

8. Trigger-based auto-clear rules.
9. Progressive evidence loading.
10. Branch-and-merge reasoning (advanced/conditional).

---

## Why #1 and #2 Are Both Needed

They overlap but solve different layers:

- **Structured handoffs (#1)**: controls the **payload** that crosses phase boundaries.
- **`make-plan` + `do` (#2)**: controls the **process** by which work is executed.

They should not be parallel systems. The recommended model is:

- `make-plan` establishes canonical step structure.
- each `do(step)` emits structured delta artifacts.
- phase closure compacts deltas into the handoff artifact.

This merges #1 and #2 into a unified flow: process + payload.

---

## Governance Positioning

These improvements **augment** existing governance and communication templates; they do **not** replace governance.

- Keep existing role definitions, safety requirements, and communication standards.
- Add execution contracts, memory lifecycle rules, and validation gates.
- Use schema versioning and gradual enforcement to avoid migration disruption.

Recommended approach:

1. Add governance schema version (`v2` target).
2. Introduce new required fields in soft mode (warn).
3. Add lint/audit checks.
4. Promote to hard enforcement after adoption metrics stabilize.

---

## Detailed Itemization (Integration + Policy + Dependencies)

## 1) Structured Phase Handoffs

### Intent
Replace ad hoc phase transitions with compact, standardized state transfer.

### Agent Integration
- Use fixed lifecycle: Discover → Plan → Execute → Verify → Summarize.
- At each phase boundary, emit a handoff artifact.
- Next phase consumes artifact-first context (not full transcript by default).

### Policy Embedding
- Require handoff artifact for non-trivial phase transition.
- Define mandatory fields and field-level size limits.
- Disallow large raw logs directly in handoff; require references.

### Recommended Handoff Schema
- `objective`
- `scope_in`
- `scope_out`
- `decisions[]`
- `assumptions[]`
- `open_questions[]`
- `artifacts[]`
- `evidence_refs[]`
- `next_actions[]`
- `risk_level`

### Dependencies
- Foundation for #2, #4, #9, #10.

---

## 2) Canonical `make-plan` + `do` Flow

### Intent
Standardize execution lifecycle so work is consistently decomposed and tracked.

### Agent Integration
- Task-capable agents must create/consume an active plan ID.
- One step in progress at a time.
- Every `do(step)` writes expected outcome + completion evidence + delta summary.
- Trivial exceptions allowed only with explicit `bypass_reason`.

### Policy Embedding
- "No execution without plan" rule for applicable task classes.
- "No orphan `do`" rule (must link to step ID).
- Required completion criteria per step.

### Applicability by Agent Role
- Orchestrator/planner: owns plan creation and sequencing.
- Specialist agents (coding/testing/docs/design): execute assigned steps via `do`.
- Reviewer/validator role: verifies step completion criteria and evidence.

### Dependencies
- Requires handoff schema from #1.
- Enables #10 automation with lower risk.

---

## 3) Retrieval Anchors and Stable IDs

### Intent
Replace verbose history replay with precise references.

### Agent Integration
- Assign stable IDs: `DEC-*`, `RISK-*`, `ASM-*`, `EVD-*`.
- Reference IDs in handoffs and step deltas.
- Retrieve by ID when rehydration is needed.

### Policy Embedding
- Minimum anchor requirements for non-trivial step completion.
- ID format and uniqueness constraints.
- Evidence anchor must point to resolvable artifact.

### Dependencies
- Amplifies #1 and #2.
- Supports #8 progressive loading.

---

## 4) Reconstruction Test

### Intent
Verify that artifact-only context is sufficient after reset.

### Agent Integration
- On major phase transition, run reconstruction check:
  - Can task continue correctly from handoff + anchors only?
- If not, request targeted rehydration by ID.

### Policy Embedding
- Block Execute phase if reconstruction fails below threshold.
- Record failure reason/missing fields for telemetry.

### Dependencies
- Relies on #1 handoffs and #3 anchors.

---

## 5) Quality Guardrails

### Intent
Prevent quality loss while clearing context more aggressively.

### Agent Integration
- Run invariant checklist before execution.
- Validate assumption state after execution.
- Run contradiction detection before finalization.

### Policy Embedding
- Define invariant categories:
  - correctness
  - safety/security
  - compatibility
  - validation completeness
- Block finalization on unresolved contradiction.

### Dependencies
- Strongly recommended before aggressive auto-clear in #10.

---

## 6) Two-Tier Memory Model

### Intent
Separate long-lived high-signal memory from transient exploration noise.

### Agent Integration
- Durable memory: accepted requirements/constraints/decisions.
- Ephemeral memory: scratch analysis, discarded options, transient logs.
- Default purge of ephemeral memory at reset boundaries.

### Policy Embedding
- Promotion rules from ephemeral → durable (must include evidence/decision link).
- TTL/retention defaults for ephemeral entries.

### Dependencies
- Improved by #3 anchors.
- Supports #5 budgeting and #8 loading.

---

## 7) Context Budget Policy by Task Type

### Intent
Apply right-sized context limits based on work class.

### Agent Integration
- Classify task type at start (bugfix/refactor/feature/incident/etc.).
- Load matching budget profile:
  - max active context size
  - max artifacts loaded per step
  - target compression ratio

### Policy Embedding
- Governance table mapping task type → budget profile.
- Budget breach triggers forced checkpoint/compression.

### Dependencies
- Works best after #6 memory tiering.

---

## 8) Trigger-Based Auto-Clear

### Intent
Automate context reset at safe, predictable boundaries.

### Agent Integration
- Trigger candidates:
  - token threshold
  - phase completion
  - N tool calls
  - scope pivot
- On trigger: emit checkpoint, clear ephemeral context, continue from compact state.

### Policy Embedding
- Central threshold definitions.
- Cooldown rules to prevent thrashing.
- Rehydration logging requirement.

### Dependencies
- Requires #1/#2/#5 guardrails and budget policy for safe operation.

---

## 9) Progressive Evidence Loading

### Intent
Keep large artifacts out of active context unless needed.

### Agent Integration
- Default: include synopsis + anchor only.
- Lazy-load full evidence only for verification/disambiguation.
- Unload evidence after step completion.

### Policy Embedding
- Inline evidence size caps.
- Mandatory externalization of large logs/output.

### Dependencies
- Depends on #3 anchor discipline.

---

## 10) Branch-and-Merge Reasoning (Advanced)

### Intent
Support controlled multi-path exploration for complex tasks.

### Agent Integration
- Spawn isolated branches for alternatives.
- Each branch emits decision card with evidence and risks.
- Merge selects winner and archives non-selected branches as ephemeral.

### Policy Embedding
- Only enable above complexity threshold.
- Cap branch count and branch-specific budget.
- Require merge rationale linked to chosen decision ID.

### Dependencies
- Needs #1/#3/#5 to prevent uncontrolled token growth.

---

## Dependency Map (Summary)

- #1 → #2 → #8
- #1 → #3 → #4
- #1/#2 → #5
- #3 → #6 → #7
- #3/#6 → #9
- #1/#3/#5 → #10

---

## Rollout Plan and Gates

## Stage A (Pilot)

Implement #1, #2, #3, #4 in soft-enforcement mode.

Exit criteria:
- High completion rate for required handoff fields.
- Plan/step lifecycle consistently used for applicable tasks.
- Reconstruction pass rate acceptable.

## Stage B (Safety Hardening)

Implement #5, #6, #7 with mixed warn/block gates.

Exit criteria:
- Contradiction detection catches issues without high false-positive burden.
- Durable/ephemeral separation adopted by agents.
- Budget breaches handled predictably.

## Stage C (Automation)

Implement #8 and #9; evaluate #10 only for proven need.

Exit criteria:
- Auto-clear reduces context footprint without increased quality regressions.
- Evidence loading decreases large-context incidence.
- Advanced branching only used on tasks above complexity threshold.

---

## Validation and Measurement Framework

Use a baseline-vs-treatment evaluation on representative tasks.

### Track per Task/Session
- Total prompt tokens.
- Total completion tokens.
- Tokens per successful completion.
- Retry/rework count.
- Precision/quality regression rate.
- Time to completion.

### Key Diagnostics
- Reconstruction failure causes.
- Rehydration frequency and payload size.
- Budget breach frequency.
- Contradiction check interventions.

### Decision Rule
Proceed from one stage to the next only if token efficiency improves **without measurable precision degradation**.

---

## Risks and Mitigations

### Risk: Over-compression drops critical detail
Mitigation: reconstruction gate + evidence anchors + contradiction checks.

### Risk: Agent friction due to stricter workflow
Mitigation: staged enforcement and clear trivial-task bypass path.

### Risk: Auto-clear thrashing
Mitigation: cooldown, targeted rehydration, and threshold tuning.

### Risk: Policy sprawl
Mitigation: central schema, versioning, and unified linting.

---

## Policy Artifacts to Produce

1. **Execution Policy**
   - plan/step lifecycle
   - phase transition requirements
2. **Memory Policy**
   - durable vs ephemeral
   - promotion and TTL rules
3. **Quality Policy**
   - invariants
   - contradiction handling
4. **Budget Policy**
   - task classes and budget profiles
   - trigger rules

All four should be versioned and cross-referenced in agent runtime governance.

---

## Team Review Checklist

- Are #1 and #2 merged into a single canonical artifact flow (not duplicate systems)?
- Are governance changes additive and migration-safe?
- Are hard-fail gates introduced only after measurable adoption?
- Are optional advanced features (#10) deferred until justified by task complexity?
- Are success criteria explicitly tied to both token reduction and quality preservation?

---

## Immediate Next Actions

1. Approve the phased order and dependency structure.
2. Finalize handoff schema and `make-plan`/`do` step-delta schema.
3. Define governance v2 migration strategy (warn → enforce).
4. Define pilot metrics dashboard and baseline cohort.
5. Start Stage A implementation.
