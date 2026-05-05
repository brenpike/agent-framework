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
5. **Two-slice rollout**: ship savings first, harden second.

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

### Slice 1 — Ship the Savings (MVP)

1. Structured phase handoffs.
2. Canonical `make-plan` + `do` execution flow.
6. Two-tier memory model (durable vs ephemeral, lightweight).
7. Context budget policy by task type (phase-boundary trigger only).
5. Quality guardrails (soft/warn mode only).
8. Trigger-based auto-clear rules.

### Slice 2 — Harden

3. Retrieval anchors (decision/risk/evidence IDs).
4. Reconstruction test.
5. Quality guardrails (hard enforcement).
7. Context budget policy (full profiles).
9. Progressive evidence loading.
10. Branch-and-merge reasoning (advanced/conditional — evaluate for proven need only).

---

## Why #1 and #2 Are Both Needed

They solve four distinct concerns — none redundant:

- **#1 answers: what fields must be preserved?** (payload schema — decisions, assumptions, artifacts, next actions)
- **#2 answers: how is work decomposed and tracked?** (step lifecycle — STEP-NNN IDs, step-delta reports)
- **claude-mem answers: where are those fields stored?** (storage substrate — observations retrieved via mem-search on rehydration)
- **#8 answers: when does context reset and rehydration fire?** (the actual token-savings mechanism)

#1 and #2 are not storage systems and are not redundant with each other or with claude-mem. #2 generates the artifacts that #1 defines the schema for. claude-mem is the storage substrate for #1's fields. #8 is the mechanism that makes the savings real.

The recommended model remains:
- #2 step lifecycle produces step-delta artifacts at each phase close.
- #1 schema defines which fields must be in those artifacts.
- claude-mem stores the artifacts as observations.
- #8 clears context at phase boundary and orchestrator rehydrates via mem-search.

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

With claude-mem installed, #1's implementation is a **required observation fields** spec — not a separate in-session artifact format. The handoff artifact IS the claude-mem observation set, stored at phase close and retrieved via `mem-search` on rehydration. #1 still required even with claude-mem because it defines schema discipline: which fields agents must capture. Without it, agents emit inconsistent or incomplete observations and rehydration is lossy.

Without claude-mem, the handoff artifact lives as in-session text or a committed file under `docs/`.

### Required Observation Fields (Handoff Schema)

These fields must be captured at phase close — as claude-mem observations when available, or as an in-session artifact when claude-mem is absent:
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
> **Note:** `do` in this item refers to the orchestrator's delegation template acting as the execution primitive — NOT the `claude-mem:do` skill. See Agent Responsibility table below.

Standardize execution lifecycle so work is consistently decomposed and tracked.

Implementation note:
- `make-plan` and `do` are **conceptual framework primitives** in this plan, not hard bindings to optional `claude-mem` skills.
- When `claude-mem` is installed and approved, its capabilities may implement or accelerate these primitives.
- When `claude-mem` is absent, agents follow the same lifecycle with native report/state artifacts.
- Native fallback artifact shape (claude-mem absent):
  - Plan: a numbered step list in the orchestrator's delegation preamble or a structured plan artifact under `.agent-framework/plans/` (not `docs/`), each step with a unique `STEP-NNN` ID, owner, and completion criteria.
  - Step delta: a `Step delta:` section appended to the Shared Worker Report Contract at each `do(step)` completion, containing step ID, outcome, evidence refs, and unresolved assumptions.
  - Phase closure: orchestrator compacts all step deltas from the phase into a single handoff artifact under `.agent-framework/handoffs/` before the next delegation — prior phase reports are not re-injected.

Fallback storage hygiene:
- Runtime orchestration artifacts (`.agent-framework/plans/`, `.agent-framework/handoffs/`, optional `.agent-framework/checkpoints/`) are operational state, not human documentation.
- Do not mix these runtime artifacts into `docs/` by default.
- Treat runtime artifacts as ephemeral by default (gitignored unless intentionally promoted for audit/repro).
- Cleanup/retention defaults to prevent noise:
  - Keep only the active plan + latest handoff during normal execution.
  - Auto-archive or delete superseded phase artifacts at phase close.
  - Keep a short rolling window (for example, latest 3 handoffs/checkpoints) for recovery/debug.
  - Promote only intentionally selected artifacts into durable docs when needed for audit, postmortem, or reusable runbooks.

### Agent Integration
- Task-capable agents must create/consume an active plan ID.
- One step in progress at a time.
- Every `do(step)` writes expected outcome + completion evidence + delta summary.
- Trivial exceptions allowed only with a bypass reason drawn from the following allowlist:
  - `TRIVIAL_CHANGE` — single-statement or mechanical edit meeting all Trivial Change conditions.
  - `NO_PRIOR_PHASE` — first step in a workflow with no prior phase to hand off from.
  - `SINGLE_STEP_TASK` — entire task fits in one step with no phase boundary.
  - `USER_OVERRIDE` — user explicitly directed bypass with a stated reason.
  
  Each bypass must include audit metadata in the delegation preamble: reason code + step/task ID.

### Policy Embedding
- "No execution without plan artifact" rule for applicable task classes.
- "No orphan step execution record" rule (must link to step ID).
- Required completion criteria per step.

### Applicability by Agent Role
- Orchestrator/planner: owns plan creation and sequencing.
- Specialist agents (coding/testing/docs/design): execute assigned steps via `do`.
- Reviewer/validator role: verifies step completion criteria and evidence.

### Mechanical Changes to Existing Framework

#2 does NOT replace the orchestrator's delegation machinery. It adds three fields to existing templates:

**Change 1 — Delegation preamble:** Orchestrator adds `Step: STEP-NNN` to every delegation sent to a worker.

**Change 2 — Shared Worker Report Contract:** Workers must append a mandatory `Step delta:` section to every phase-closing report:

  Step delta:
    Step: STEP-NNN
    Outcome: [what was accomplished]
    Decisions: DEC-NNN — [decision and rationale]
    Assumptions unresolved: ASM-NNN — [assumption and impact]
    Evidence: EVD-NNN — [test output / commit SHA / artifact ref]

**Change 3 — Post-verification extraction:** After phase verification, orchestrator extracts the `Step delta:` section, stores it as a claude-mem observation (or in-session artifact when claude-mem absent), then delegates the next phase with only the compact step-delta — not the full prior phase report or tool outputs.

This is the mechanism by which prior phase transcripts drop out of active context. Phase N+1 receives 10–20 lines of structured delta instead of hundreds of lines of Phase N transcript.

### Agent Responsibility

| Primitive | Caller | Notes |
|---|---|---|
| `make-plan` | Planner agent | Called as part of planner's output; emits structured plan with STEP-NNN IDs as observations |
| `do` | Orchestrator (existing delegation machinery) | `claude-mem:do` is NOT used directly — conflicts with orchestrator governance (orchestrator owns delegation, git preflight, phase verification, commit policy). Orchestrator's delegation template IS the `do` primitive. |
| `mem-search` | Orchestrator + Planner | Orchestrator: rehydration after #8 context clear. Planner: codebase research (existing behavior). |

### Dependencies
- Requires handoff schema from #1.
- Enables #8 automation with lower risk.

### Token Efficiency Impact
- Highest single-item token ROI in this plan.
- Current framework carries full plan + all prior phase delegation context in orchestrator throughout the workflow. By phase 4 of a 6-phase plan, orchestrator context includes: plan, phases 1–3 full delegations + reports, validation outputs, git state. This is the primary context bloat driver.
- Step-delta artifacts with phase-closure compaction eliminate this: prior phases drop out of active context after closure; only the compact handoff artifact carries forward.
- Hypothesis: 40–60% reduction in orchestrator context for workflows with 5+ phases. This is a pre-implementation hypothesis, not a measured outcome. Validation is tied to pre-declared measurement slices — task type, phase count (5+ phases), and the baseline window defined at Slice 1 entry — per the Validation and Measurement Framework section.
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
- Minimum anchor quality requirements:
  - ID format: `<TYPE>-<NNN>` where TYPE ∈ {DEC, RISK, ASM, EVD} and NNN is a zero-padded 3-digit integer unique within the session (e.g., `DEC-001`, `EVD-012`).
  - Required metadata per anchor: type, one-sentence description, source artifact reference (commit SHA, file path, or step ID).
  - Stale reference handling: if a referenced artifact is no longer resolvable, mark the anchor `[STALE]` and exclude it from rehydration until re-resolved. Stale anchors must be logged but do not block step completion.

### Slice 2 Note
In Slice 1 (in-session only), DEC-*, RISK-*, ASM-*, EVD-* IDs are embedded directly in handoff artifacts — the handoff IS the store. No separate retrieval infrastructure is needed. "Retrieve by ID" becomes non-trivial only for cross-phase or cross-session use cases, which require claude-mem or an equivalent persistent substrate. Avoid over-engineering Slice 1 anchor storage: ID discipline (naming and referencing decisions consistently) is the Slice 1 value, not retrieval infrastructure. Full retrieval anchor infrastructure is a Slice 2 item.

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
- Slice 1: define test schema and telemetry only (warn mode). Pass/fail is binary: can the agent continue correctly from handoff + anchors alone? Yes = pass, No = fail. No percentage threshold in Slice 1.
- Slice 2 onward: enable blocking gate on binary fail. Percentage-based thresholds may be introduced after Slice 1 telemetry establishes a calibration baseline.
- Record failure reason/missing fields for telemetry in all slices.

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
- Most actionable Slice 1 proxies (implement first):
  - "max tool calls before mandatory checkpoint" — fully observable; agents track call count natively.
  - "max replay depth (number of prior artifacts auto-included per delegation)" — directly governs how many prior phase reports are injected; most direct lever on orchestrator context size.
  - Artifact count and summary size limits are secondary; defer until primary proxies are calibrated.

### Dependencies
- Works best after #6 memory tiering.

### Slice 1 Simplification

In Slice 1, #7 has one trigger only: **phase boundary auto-clear**. No full governance budget-profile table. No per-task-class profiles. Full trigger policy (N tool calls, scope pivot, user reset) and the complete profile table are deferred to Slice 2 after Slice 1 baseline data is available.

### Slice 2 Preparation: Classification Rubric

Required before the full Slice 2 budget profile table can be implemented. Task-type taxonomy with examples:

- **bugfix**: isolated defect fix in a known location with bounded scope.
- **refactor**: structural change without observable behavior change.
- **feature**: new capability with partially or fully unknown scope.
- **incident**: time-boxed investigation combined with a targeted fix.

Tie-break rule: when a task fits multiple labels, use the label with the most restrictive budget profile. When in doubt, prefer `feature` (broadest scope assumption).

---

## 8) Trigger-Based Auto-Clear

### Intent
Automate context reset at safe, predictable boundaries.

### Agent Integration
- Trigger candidates:
  - phase completion *(Slice 1)*
  - N tool calls *(Slice 2)*
  - scope pivot *(Slice 2)*
  - explicit user reset request *(Slice 2)*
- On trigger: emit checkpoint, clear ephemeral context, continue from compact state.

### Policy Embedding
- Central threshold definitions using observable proxies (phase completion in Slice 1; N tool calls, scope pivot, user reset in Slice 2).
- Cooldown rules to prevent thrashing.
- Rehydration logging requirement.

### Dependencies
- Requires #1/#2/#5 guardrails and #7 budget policy for safe operation.

### Coupling with #1 and #2

#8 requires #1 and #2 to be safe. The rehydration flow:

1. #8 trigger fires at phase boundary.
2. Context cleared.
3. Orchestrator runs `mem-search` for current task's step-delta observations.
4. Compact step-delta artifacts rehydrated — no prior phase transcripts, tool outputs, or raw diffs.
5. Next phase proceeds with clean context.

Without #1 (schema discipline), rehydrated observations are incomplete. Without #2 (step-delta emission), there is nothing structured to rehydrate from. Both are prerequisites for safe #8 operation.

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
- #6 → #7
- #3 ↗ #6 (enhancement, not prerequisite — #3 is Slice 2; #6 ships in Slice 1 without it)
- #5 → #8
- #3/#6 → #9
- #1/#3/#7 → #10

---

## Rollout Plan

### Slice 1 — Ship the Savings (MVP)

Implement #1, #2, #6 (lightweight), #7 (phase-boundary trigger only), #8. #5 in soft/warn mode only.

Rationale: The original Stage A–C structure delivered scaffolding without token savings. Token savings only land when #8 (auto-clear) is operational. Slice 1 ships the minimum viable stack required to make #8 safe and operational.

Exit criteria:
- Handoff schema fields (per #1) emitted consistently by workers.
- STEP-NNN IDs and Step delta sections present in worker reports (per #2).
- Context clear fires at phase boundary and rehydrates from compact step-delta observations only (per #8).
- No measurable quality regression vs. pre-Slice-1 baseline.

### Slice 2 — Harden

Implement #3, #4, #5 (hard enforcement), full #7 budget profiles, #9. Evaluate #10 only for proven need.

Note: The following runbooks are required artifacts before hard enforcement gates for #4 and #5 are enabled in Slice 2: (a) reconstruction failure runbook, (b) unresolved contradiction runbook, (c) auto-clear thrash runbook. Each runbook must define: fallback mode, escalation trigger, and recovery actions. Runbooks are governance artifacts produced during Slice 2 implementation — not prerequisites for Slice 1.

Exit criteria:
- Retrieval anchors (DEC-*, RISK-*, ASM-*, EVD-*) used consistently across handoffs.
- Reconstruction test passes on major phase transitions.
- Contradiction detection catches issues without high false-positive burden.
- Budget breach handled predictably per full profile table.
- Evidence loading decreases large-context incidence.

### Exit Gate Definitions

Operational definitions for subjective terms used in slice exit criteria:

- **Budget breach**: any step where artifact count or tool-call count exceeds the declared maximum for its task-type profile.
- **False positive (contradiction detection)**: a contradiction flag raised on a non-conflicting field change, resolved without requiring any code or documentation change.
- **Quality regression**: a task outcome requiring rework attributable to missing context that was present before Slice 1 adoption.
- **Rehydrates predictably**: the next phase begins with all prior step-delta observations retrievable via `mem-search` without manual recovery intervention.

### Demotion Triggers

If any of the following signals are observed after Slice 1 or Slice 2 promotion, revert to the prior slice's enforcement mode and re-evaluate before re-promoting:

- **Quality regression**: rework rate increases vs. pre-adoption baseline.
- **Rehydration failure spike**: step-delta observations missing or incomplete on successive phase boundaries.
- **Contradiction false-positive surge**: contradiction flags raised on non-conflicting changes at a rate that interrupts normal workflow.
- **Auto-clear thrash**: context clear + rehydration cycle firing more than once per phase on average.

Required rollback actions: disable hard enforcement gates, revert to warn mode, collect failure telemetry for root cause analysis before re-promoting.

---

## Validation and Measurement Framework

Use a baseline-vs-treatment evaluation on representative tasks.

Baseline note:
- Baseline data collection begins at Slice 1 entry before enabling hard enforcement gates.
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
Proceed from one slice to the next only if token efficiency improves **without measurable precision degradation**.

---

## Risks and Mitigations

### Risk: Over-compression drops critical detail
Mitigation: reconstruction gate + evidence anchors + contradiction checks.

### Risk: Agent friction due to stricter workflow
Mitigation: staged enforcement and clear trivial-task bypass path.

### Risk: Auto-clear thrashing
Mitigation: cooldown, targeted rehydration, and threshold tuning.

### Risk: Policy sprawl
Mitigation: central schema, versioning, and unified linting. Ownership and review cadence must be defined before Slice 2 governance expansion — at minimum, a designated policy owner per artifact and a change-control gate for schema modifications. **Gate: Slice 2 kickoff is blocked until ownership is assigned.**

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

1. Approve the slice order and dependency structure.
2. Finalize handoff schema and `make-plan`/`do` step-delta schema.
3. Define governance v2 migration strategy (warn → enforce).
4. Define pilot metrics dashboard and baseline cohort (at Slice 1 entry, before enabling enforcement gates).
5. Start Slice 1 implementation.
