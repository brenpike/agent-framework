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
- Requiring optional companion plugins as hard runtime prerequisites.

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
Replace ad hoc phase transitions with compact, standardized state transfer by extending the existing Shared Worker Report Contract rather than running a parallel contract system.

### Agent Integration
- Use fixed lifecycle: Discover → Plan → Execute → Verify → Summarize.
- At each phase boundary, emit a handoff artifact.
- Next phase consumes artifact-first context (not full transcript by default).

### Policy Embedding
- Require handoff artifact for non-trivial phase transition.
- Define mandatory fields and field-level size limits.
- Disallow large raw logs directly in handoff; require references.
- Extend `plugin/governance/communication-policy.md` Shared Worker Report Contract with the additional context-management fields below (or define a versioned successor contract), then deprecate legacy-only usage after migration.

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

Contract compatibility note:
- Existing required report fields (`Status`, `Changed`, `Validated`, `Need scope change`, `Issues`) remain required.
- New context fields are additive in migration phase; hard requirement can be enforced after adoption metrics stabilize.

### Dependencies
- Foundation for #2, #4, #9, #10.

---

## 2) Canonical `make-plan` + `do` Flow

### Intent
Standardize execution lifecycle so work is consistently decomposed and tracked.

Implementation note:
- `make-plan` and `do` are **conceptual framework primitives** in this plan, not hard bindings to optional `claude-mem` skills.
- When `claude-mem` is installed and approved, its capabilities may implement or accelerate these primitives.
- When `claude-mem` is absent, agents follow the same lifecycle with native report/state artifacts.
- Native fallback artifact shape (claude-mem absent):
  - Plan: a numbered step list in the orchestrator's delegation preamble or a fenced block in a committed `docs/` file, each step with a unique `STEP-NNN` ID, owner, and completion criteria.
  - Step delta: a `Step delta:` section appended to the Shared Worker Report Contract at each `do(step)` completion, containing step ID, outcome, evidence refs, and unresolved assumptions.
  - Phase closure: orchestrator compacts all step deltas from the phase into a single handoff artifact before the next delegation — prior phase reports are not re-injected.

### Agent Integration
- Task-capable agents must create/consume an active plan ID.
- One step in progress at a time.
- Every `do(step)` writes expected outcome + completion evidence + delta summary.
- Trivial exceptions allowed only with explicit `bypass_reason`.

### Policy Embedding
- "No execution without plan artifact" rule for applicable task classes.
- "No orphan step execution record" rule (must link to step ID).
- Required completion criteria per step.

### Applicability by Agent Role
- Orchestrator/planner: owns plan creation and sequencing.
- Specialist agents (coding/testing/docs/design): execute assigned steps via `do`.
- Reviewer/validator role: verifies step completion criteria and evidence.

### Dependencies
- Requires handoff schema from #1.
- Enables #8 automation with lower risk.

### Token Efficiency Impact
- Highest single-item token ROI in this plan.
- Current framework carries full plan + all prior phase delegation context in orchestrator throughout the workflow. By phase 4 of a 6-phase plan, orchestrator context includes: plan, phases 1–3 full delegations + reports, validation outputs, git state. This is the primary context bloat driver.
- Step-delta artifacts with phase-closure compaction eliminate this: prior phases drop out of active context after closure; only the compact handoff artifact carries forward.
- Estimated impact: 40–60% reduction in orchestrator context for workflows with 5+ phases.
- Recommendation: accept the framework change. The orchestrator and planner already decompose work into phases/steps — adding STEP-NNN IDs and mandatory step-delta reports to the Shared Worker Report Contract is incremental, not a rewrite.

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
- Storage substrate must be explicit:
  - baseline: in-session report artifacts + `Session facts:` block extensions in `communication-policy.md`
  - optional persistence: `claude-mem` observations (when installed)
  - cross-session retrieval is only guaranteed when a persistent memory substrate is available

### Phase 0 Simplification
In Phase 0 (in-session only), DEC-*, RISK-*, ASM-*, EVD-* IDs are embedded directly in handoff artifacts — the handoff IS the store. No separate retrieval infrastructure is needed. "Retrieve by ID" becomes non-trivial only for cross-phase or cross-session use cases, which require claude-mem or an equivalent persistent substrate. Avoid over-engineering Phase 0 anchor storage: ID discipline (naming and referencing decisions consistently) is the Phase 0 value, not retrieval infrastructure.

### Dependencies
- Amplifies #1 and #2.
- Supports #9 progressive loading.

---

## 4) Reconstruction Test

### Intent
Verify that artifact-only context is sufficient after reset.

### Agent Integration
- On major phase transition, run reconstruction check:
  - Can task continue correctly from handoff + anchors only?
- If not, request targeted rehydration by ID.

### Policy Embedding
- Phase 0/Stage A: define test schema and telemetry only (warn mode). Pass/fail is binary: can the agent continue correctly from handoff + anchors alone? Yes = pass, No = fail. No percentage threshold in Phase 0.
- Phase 1/Stage B onward: enable blocking gate on binary fail. Percentage-based thresholds may be introduced after Phase 0 telemetry establishes a calibration baseline.
- Record failure reason/missing fields for telemetry in all phases.

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
- Strongly recommended before aggressive auto-clear in #8.

---

## 6) Two-Tier Memory Model

### Intent
Separate long-lived high-signal memory from transient exploration noise.

### Agent Integration
- Durable memory: accepted requirements/constraints/decisions.
- Ephemeral memory: scratch analysis, discarded options, transient logs.
- Default purge of ephemeral memory at reset boundaries.
- Claude-mem-absent fallback:
  - durable = handoff/report artifacts + `Session facts:` cache extensions
  - ephemeral = current-phase scratch sections and transient tool output not promoted into artifacts
  - purge = clear ephemeral sections at phase boundary; retain durable artifacts
- Important: "purge ephemeral memory" in Claude Code means a full context clear followed by selective rehydration of durable artifacts only — it is not selective removal within a running session. Ephemeral purge is therefore tightly coupled to the #8 auto-clear trigger. #6 defines *what* to keep; #8 is *how* the purge executes. These two items work together, not independently.

### Policy Embedding
- Promotion rules from ephemeral → durable (must include evidence/decision link).
- TTL/retention defaults for ephemeral entries.
- Reference and extend existing `Session Fact Cache` guidance in `plugin/governance/communication-policy.md` rather than creating a separate cache mechanism from scratch.

### Dependencies
- Improved by #3 anchors.
- Supports #7 budgeting and #9 loading.

---

## 7) Context Budget Policy by Task Type

### Intent
Apply right-sized context limits based on work class.

### Agent Integration
- Classify task type at start (bugfix/refactor/feature/incident/etc.).
- Load matching budget profile:
  - max artifact count per phase
  - max replay depth (number of prior artifacts auto-included)
  - max tool calls before mandatory checkpoint
  - max artifacts loaded per step
  - target summary size limits by field

### Policy Embedding
- Governance table mapping task type → budget profile.
- Budget breach triggers forced checkpoint/compression using observable proxies (artifact count, replay depth, tool-call count), not token introspection.
- Most actionable Phase 1 proxies (implement first):
  - "max tool calls before mandatory checkpoint" — fully observable; agents track call count natively.
  - "max replay depth (number of prior artifacts auto-included per delegation)" — directly governs how many prior phase reports are injected; most direct lever on orchestrator context size.
  - Artifact count and summary size limits are secondary; defer until primary proxies are calibrated.

### Dependencies
- Works best after #6 memory tiering.

---

## 8) Trigger-Based Auto-Clear

### Intent
Automate context reset at safe, predictable boundaries.

### Agent Integration
- Trigger candidates:
  - phase completion
  - N tool calls
  - scope pivot
  - explicit user reset request
- On trigger: emit checkpoint, clear ephemeral context, continue from compact state.

### Policy Embedding
- Central threshold definitions using observable proxies (phase completion, N tool calls, scope pivot, user reset).
- Cooldown rules to prevent thrashing.
- Rehydration logging requirement.

### Dependencies
- Requires #1/#2/#5 guardrails and #7 budget policy for safe operation.

---

## 9) Progressive Evidence Loading

### Intent
Keep large artifacts out of active context unless needed.

### Agent Integration
- Default: include synopsis + anchor only.
- Lazy-load full evidence only for verification/disambiguation.
- Do not pre-load evidence that is not yet needed — this is the primary mechanism.
- Note: selective mid-session unloading is not supported in Claude Code (context is append-only within a session). "Unloading" only occurs via full context clear + selective durable-artifact rehydration — this is the #8 auto-clear mechanism. Progressive evidence loading and #8 are complementary: #9 prevents loading unnecessary evidence; #8 clears it when a reset boundary is hit.

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
- Needs #1/#3/#7 to prevent uncontrolled token growth.

---

## Dependency Map (Summary)

- #1 → #2 → #8
- #1 → #3 → #4
- #1/#2 → #5
- #3 → #6 → #7
- #5 → #8
- #3/#6 → #9
- #1/#3/#7 → #10

---

## Rollout Plan and Gates

## Stage A (Pilot)

Implement #1, #2, #3, #4 in soft-enforcement mode.

Exit criteria:
- High completion rate for required handoff fields.
- Plan/step lifecycle consistently used for applicable tasks.
- Reconstruction pass rate acceptable.

Note: specific numeric thresholds (e.g., completion rate ≥ X%, reconstruction pass rate ≥ Y%) are defined during pilot calibration at Stage A entry using the baseline cohort, not pre-specified here.

## Stage B (Safety Hardening)

Implement #5, #6, #7 with mixed warn/block gates.

Exit criteria:
- Contradiction detection catches issues without high false-positive burden.
- Durable/ephemeral separation adopted by agents.
- Budget breaches handled predictably.

Note: specific numeric thresholds for false-positive rate and budget-breach frequency are calibrated from Stage A data before Stage B gates are enforced.

## Stage C (Automation)

Implement #8 and #9; evaluate #10 only for proven need.

Exit criteria:
- Auto-clear reduces context footprint without increased quality regressions.
- Evidence loading decreases large-context incidence.
- Advanced branching only used on tasks above complexity threshold.

Note: specific numeric thresholds for context footprint reduction and quality regression rate are calibrated from Stage B data before Stage C gates are enforced.

---

## Validation and Measurement Framework

Use a baseline-vs-treatment evaluation on representative tasks.

Baseline note:
- Baseline data collection begins at Stage A entry before enabling hard enforcement gates.
- If historical baseline is unavailable, run a short baseline-only window first, then start treatment comparison.

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
