# Context Management Policy

## Purpose

This policy augments existing agent-framework governance. It does not replace role definitions, safety requirements, or communication standards. All existing governance remains in effect.

**Loading:** This module is mandatory and always loaded for every workflow (per `${CLAUDE_PLUGIN_ROOT}/governance/core-contract.md` (Mandatory Modules)). Task-type classification (intake) and per-task budget profile enforcement apply to every task, including the trivial fast path. Phase-handoff, retrieval-anchor, reconstruction-test, contradiction-detection, auto-clear, and progressive-evidence-loading rules additionally apply when the workflow includes more than one execution phase or the plan contains `STEP-NNN` identifiers.

**Slice scope:** This file covers Slice 1 through Slice 2 content. All sections are fully active: Quality Policy hard enforcement gates, reconstruction test blocking, and per-task budget profiles.

---

## Execution Policy

### Plan/Step Lifecycle

- Non-trivial tasks require a plan artifact before execution begins ("No execution without plan artifact").
- Every step is identified by a unique `STEP-NNN` identifier (zero-padded 3-digit integer, e.g., `STEP-001`). Numbering restarts at `STEP-001` for each new plan instance.
- Every `do(step)` writes: expected outcome, completion evidence, and a step-delta summary.
- One step in progress at a time per plan.

### Bypass Allowlist

The plan artifact and step-delta requirements may be bypassed only with an explicit reason code from this list, included as audit metadata in the delegation preamble:

| Code | Condition |
|---|---|
| `TRIVIAL_CHANGE` | Single-statement or mechanical edit meeting all Trivial Change conditions |
| `NO_PRIOR_PHASE` | First step in a workflow with no prior phase to hand off from. Waives the requirement to consume a prior handoff artifact only — the step must still produce a `Step delta:` output for subsequent phases to rehydrate from. |
| `SINGLE_STEP_TASK` | Entire task fits in one step with no phase boundary |
| `USER_OVERRIDE` | User explicitly directed bypass with a stated reason |

Each bypass must include: reason code + step/task ID in the delegation preamble.

### Phase Transition Requirements

- Handoff artifact required for non-trivial phase transitions.
- Before delegating the next phase: emit checkpoint (if commit policy allows), store full candidate handoff as durable artifact (step-delta + mandatory Context Management Fields), clear ephemeral context, rehydrate from stored candidate handoffs.
- The next phase receives the full candidate handoff (step-delta + mandatory Context Management Fields) — not the full prior phase report or tool outputs.

### Runtime Artifact Storage

Fallback storage paths (used when claude-mem is absent):

- `.agent-framework/plans/` — active plan artifacts
- `.agent-framework/handoffs/` — candidate handoff artifacts (step-delta + mandatory Context Management Fields, named `STEP-NNN.md`)
- `.agent-framework/checkpoints/` — optional checkpoint state

These paths are ephemeral by default (gitignored). Do not mix runtime artifacts into `docs/`.

Retention defaults:
- Keep only the active plan + latest handoff during normal execution.
- Auto-archive superseded phase artifacts at phase close.
- Keep a rolling window of the latest 3 handoffs/checkpoints for recovery.
- Promote only intentionally selected artifacts into durable docs (audit, postmortem, runbooks).

### claude-mem Detection

At session start, check for `"claude-mem@thedotmack": true` under `enabledPlugins` in either:
- `~/.claude/settings.json` (global settings), OR
- `<project root>/.claude/settings.json` (project-local settings, where project root is resolved via `git rev-parse --show-toplevel`)

If either file contains `"claude-mem@thedotmack": true`, treat claude-mem as **Present**.

- **Present:** store full candidate handoffs (step-delta + mandatory Context Management Fields per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)) as claude-mem observations; rehydrate via `mem-search`.
- **Absent:** store full candidate handoffs (step-delta + mandatory Context Management Fields per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)) as files under `.agent-framework/handoffs/`; rehydrate by reading files.

---

## Retrieval Anchors

### Anchor ID Format

Every retrieval anchor is identified by a tag of the form `<TYPE>-<NNN>`, where:

- `TYPE` is one of: `DEC` (decision), `RISK` (risk), `ASM` (assumption), `EVD` (evidence).
- `NNN` is a zero-padded 3-digit integer (e.g., `001`, `012`), unique within the current session.

Examples: `DEC-001`, `RISK-003`, `ASM-002`, `EVD-014`.

### Required Metadata

Each anchor must carry the following metadata at the point of creation:

| Field | Description |
|---|---|
| Type | One of `DEC`, `RISK`, `ASM`, `EVD` |
| Description | One-sentence summary of the anchored item |
| Source | Artifact reference: commit SHA, file path, or `STEP-NNN` identifier |

### Uniqueness Constraints

- Anchor IDs must be unique within a session. Do not reuse an ID after the anchored item is superseded or invalidated.
- The `NNN` counter increments monotonically per type within the session (e.g., `DEC-001`, `DEC-002`, ...).
- If two anchors share the same type and description, merge them under one ID and record the merge in the step-delta.

### Stale Reference Handling

An anchor becomes stale when its source artifact is superseded, reverted, or deleted. When a stale anchor is detected:

1. Mark the anchor `[STALE]` in the current step-delta and any report that references it.
2. Exclude stale anchors from rehydration — do not inject stale anchor content into future delegations.
3. Log the stale anchor (ID, reason) in the step-delta. Do not block step completion on a stale anchor.

### Minimum Anchor Requirements

Non-trivial step completion (any step that does not qualify as `TRIVIAL_CHANGE` per the bypass allowlist) must produce at least one retrieval anchor. Steps that produce decisions, identify risks, or validate assumptions should tag each with the appropriate anchor type.

### Storage Substrate

- **Baseline (claude-mem absent):** anchors are recorded in the in-session report artifacts (step-deltas, handoffs) stored under `.agent-framework/handoffs/`.
- **When claude-mem is installed:** anchors are additionally stored as claude-mem observations, enabling cross-session retrieval via `mem-search`.

---

## Memory Policy

### Two-Tier Distinction

**Durable memory** — survives phase boundaries; must be preserved across context resets:
- Accepted requirements, constraints, and decisions (tagged `DEC-NNN` per Retrieval Anchors)
- Handoff/report artifacts
- Session Fact Cache entries (see `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Session Fact Cache))
- Step-delta observations stored via claude-mem or `.agent-framework/handoffs/`

**Ephemeral memory** — transient; discarded at phase boundary:
- Scratch analysis and discarded option evaluations
- Transient tool output not promoted to artifacts
- Current-phase working notes not included in the handoff artifact

### Promotion Rules

Ephemeral content may be promoted to durable only when it carries:
- An evidence link (commit SHA, file path, test output reference), OR
- A decision ID (`DEC-NNN` per Retrieval Anchors)

### Purge Semantics

"Purge ephemeral memory" in Claude Code means: full context clear followed by selective rehydration of durable artifacts only. It is not selective removal within a running session (Claude Code context is append-only within a session).

Ephemeral purge is tightly coupled to the auto-clear trigger (see Budget Policy — Auto-Clear Procedure). The Memory Policy defines *what* to keep; the Budget Policy defines *when* the purge executes.

### claude-mem-Absent Fallback

- Durable = handoff/report artifacts + Session Fact Cache extensions
- Ephemeral = current-phase scratch sections + transient tool output not promoted
- Purge = clear ephemeral sections at phase boundary; retain durable artifacts

---

## Quality Policy

> **Slice 2 enforcement: hard/block.** All checks in this section are blocking. Failures prevent execution, phase acceptance, or finalization as specified in each subsection.

### Invariant Categories

The following invariant categories must be checked before and after execution:

| Category | What to check |
|---|---|
| Correctness | Output matches stated step completion criteria |
| Safety/Security | No credentials, secrets, or unsafe operations introduced |
| Compatibility | No existing required contract fields removed; changes are additive |
| Validation completeness | Validation per `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions → Validation procedure) was run or explicitly skipped with reason |

### Pre-Execution Checklist

Before executing a step, verify. If any check fails, block execution — do not proceed:
- Active plan artifact exists or bypass reason is recorded. If this check fails, follow `${CLAUDE_PLUGIN_ROOT}/governance/reconstruction-failure-runbook.md`.
- Step ID is assigned (`STEP-NNN`)
- Completion criteria are stated

### Post-Execution Assumption Validation

After executing a step, verify. Unresolved assumptions without explicit carry-forward notation block phase acceptance — do not finalize the phase:
- All stated assumptions from the step-delta are either resolved or explicitly carried forward with `[CARRY-FORWARD]` notation as open questions in the next step-delta
- Completion evidence is referenced (commit SHA, test output, or artifact path)

### Contradiction Detection

Before finalizing a phase:
- Flag any output that contradicts a prior decision recorded in the handoff artifact
- Log the contradiction with: field name, prior value, new value, and step ID
- Block finalization until the contradiction is resolved. Follow `${CLAUDE_PLUGIN_ROOT}/governance/unresolved-contradiction-runbook.md` when a contradiction is detected.

---

## Reconstruction Test

### Purpose

Hard enforcement gate on major phase transitions. Before delegating the next phase, the agent must verify that the task can continue correctly from the handoff artifact and retrieval anchors alone — without access to the prior phase's full transcript or tool outputs.

### Test Procedure

At every major phase transition (before delegation of the next phase), run the following binary test:

1. Assemble the candidate handoff: the `Step delta:` section from the completing phase, all mandatory Context Management Fields (per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)) from the worker's phase-closing report, plus all non-stale retrieval anchors produced during the task so far.
2. Evaluate: can the next phase's stated objective, scope, and completion criteria be determined from the candidate handoff alone?
3. Result is binary:
   - **Pass** — the handoff and anchors contain sufficient context. Proceed to delegate the next phase.
   - **Fail** — one or more required fields or anchor references are missing or incomplete. Follow `${CLAUDE_PLUGIN_ROOT}/governance/reconstruction-failure-runbook.md`.

### Failure Handling

On reconstruction test failure:

1. Record the failure reason and each missing field in the step-delta as an unresolved assumption: `ASM-NNN — reconstruction failed for [field name]`.
2. Follow the fallback mode defined in `${CLAUDE_PLUGIN_ROOT}/governance/reconstruction-failure-runbook.md` (Fallback Mode) — attempt targeted rehydration of missing fields before escalating.
3. Surface the failure to the user before proceeding if the escalation trigger fires (per `${CLAUDE_PLUGIN_ROOT}/governance/reconstruction-failure-runbook.md` (Escalation Trigger)).
4. Do not delegate the next phase until the reconstruction test passes or the user explicitly acknowledges the gap.

---

## Budget Policy

### Task-Type Classification

Every task receives exactly one classification label. The label determines which budget profile governs resource limits for the task.

| Label | Definition |
|---|---|
| `bugfix` | Isolated defect fix in known location, bounded scope |
| `refactor` | Structural change without observable behavior change |
| `feature` | New capability with partially or fully unknown scope |
| `incident` | Time-boxed investigation combined with targeted fix |

**Tie-break rule:** when a task fits multiple labels, use the most restrictive budget profile (lowest limits). When in doubt, use `bugfix` (most restrictive profile).

### Budget Profiles

Each task type maps to a budget profile that governs per-phase resource limits:

| Task type | Max artifacts/phase | Max replay depth | Max tool calls/checkpoint | Max inline evidence |
|---|---|---|---|---|
| `bugfix` | 5 | 1 | 15 | 50 lines |
| `refactor` | 8 | 2 | 20 | 50 lines |
| `feature` | 12 | 3 | 30 | 50 lines |
| `incident` | 6 | 1 | 20 | 50 lines |

Column definitions:

- **Max artifacts/phase** — maximum number of durable artifacts (handoffs, evidence files, plan updates) produced in a single phase.
- **Max replay depth** — maximum number of prior phase reports auto-included in a delegation. Prior phases beyond this depth are available only via targeted retrieval (mem-search or file read), not auto-injected.
- **Max tool calls/checkpoint** — maximum tool calls before a mandatory checkpoint fires within a phase.
- **Max inline evidence** — hard cap on evidence lines inlined in a delegation, report, or handoff. Fixed at 50 lines for all task types (matches the Progressive Evidence Loading cap).

### Budget Breach Handling

When any profile limit is hit mid-phase:

1. Route to Path B (N-tool-call threshold trigger): emit a mid-phase partial checkpoint per Path B step 2 (record step ID, tool-call count, DEC/ASM/EVD anchors, active delegation fields, and a budget breach annotation).
2. Log the breach in the partial checkpoint as an evidence entry: `EVD-NNN — budget breach: [limit name] exceeded ([actual] > [max]) for task type [label]`.
3. Do not block execution. Continue the current phase after rehydration (per Path B step 6).

### Auto-Clear Triggers

The following triggers fire the clear+rehydrate cycle defined in Auto-Clear Procedure below:

| Trigger | Condition | Path |
|---|---|---|
| Phase completion | A phase passes verification and is ready for handoff | Path A |
| N-tool-call threshold | Tool-call count within the current phase reaches the profile's max tool calls/checkpoint limit | Path B |
| Scope pivot | Task classification changes mid-execution (e.g., a `bugfix` is reclassified as `feature` after investigation reveals broader scope) | Path B |
| Explicit user reset | User explicitly requests a context reset or fresh start | Path B |

For cooldown and thrash handling when triggers fire too frequently, see `${CLAUDE_PLUGIN_ROOT}/governance/auto-clear-thrash-runbook.md`.

### Auto-Clear Procedure

#### Path A — Phase-completion trigger

1. Phase verification passes.
2. Extract the `Step delta:` section and all mandatory Context Management Fields (per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)) from the worker's report, forming the candidate handoff.
3. Store the full candidate handoff (step-delta + all mandatory Context Management Fields per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)) as a durable artifact (claude-mem observation or `.agent-framework/handoffs/STEP-NNN.md`) — only after both contradiction detection and reconstruction test pass (see orchestrator Phase Verification). If either gate fails, discard the extracted handoff; do not store.
4. Emit checkpoint commit (if commit policy allows).
5. Clear ephemeral context (prior phase transcript, tool outputs, raw diffs drop out of active context).
6. Rehydrate: retrieve stored candidate handoffs for the current task via `mem-search` (or read from `.agent-framework/handoffs/`), respecting the replay depth limit from the active budget profile.
7. Delegate next phase with the compact candidate handoff (step-delta + all mandatory Context Management Fields per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)).

#### Path B — Mid-phase threshold triggers (N-tool-call, scope-pivot, explicit user reset)

1. Trigger condition met: tool-call count reached the active budget profile's max tool calls/checkpoint limit, scope pivot detected (task reclassified mid-execution), or user explicitly requested a reset.
2. Emit mid-phase partial checkpoint: record current step ID, tool-call count at trigger, any DEC/ASM/EVD anchors accumulated so far in the phase, a scope annotation if the trigger is a scope pivot, and the active delegation fields (task objective, file scope in/out, completion criteria, and constraints) so the phase can resume within its original contract after rehydration.
3. Store partial checkpoint as `.agent-framework/checkpoints/STEP-NNN-partial-NNN.md` (or claude-mem observation tagged `partial-checkpoint` when claude-mem is installed).
4. Clear ephemeral context (current phase transcript, tool outputs drop out of active context).
5. Rehydrate: retrieve stored candidate handoffs (step-delta + mandatory Context Management Fields per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)) from prior completed phases plus the partial checkpoint, respecting the replay depth limit from the active budget profile.
6. Continue current phase — do NOT delegate next phase; the current step is still in progress.

**Cooldown:** Do not fire more than one clear+rehydrate cycle per phase on average. If a trigger fires a second clear before the next phase begins (Path A) or before the current step completes (Path B), log and skip the redundant clear. See `${CLAUDE_PLUGIN_ROOT}/governance/auto-clear-thrash-runbook.md` for escalation when cooldown is violated.

---

## Progressive Evidence Loading

### Default Load Mode

When rehydrating context across phase boundaries, load evidence in **synopsis mode** by default: include the anchor ID and the one-sentence description only. Do not inline the full evidence body.

### Lazy-Load Trigger

Full evidence content is loaded only when one of the following conditions is met:

- A verification step requires inspecting the evidence to confirm a completion criterion.
- A disambiguation is needed — two or more anchors appear to conflict or overlap, and the synopsis alone is insufficient to resolve the conflict.

### Inline Evidence Size Cap

Evidence inlined directly into a delegation, report, or handoff artifact must not exceed **50 lines**. This cap applies to all evidence types (diffs, logs, test output, tool output, file excerpts).

### Mandatory Externalization

Evidence exceeding the 50-line cap must be externalized:

1. Write the full evidence body to `.agent-framework/evidence/` (filename: `<ANCHOR-ID>.md`, e.g., `EVD-001.md`).
2. Reference the evidence in the delegation or report by anchor ID only (e.g., `see EVD-001`).
3. Do not inline any portion of the externalized evidence beyond the synopsis.

The following evidence types must always be externalized regardless of size:

- Test output (unit, integration, end-to-end)
- Build logs
- Large diffs (any diff exceeding 50 lines)
- Command output exceeding 50 lines
