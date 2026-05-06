# Context Management Policy

## Purpose

This policy augments existing agent-framework governance. It does not replace role definitions, safety requirements, or communication standards. All existing governance remains in effect.

**Activation condition:** Load this module when the workflow includes more than one execution phase, OR when the plan contains `STEP-NNN` identifiers.

**Slice scope:** This file covers Slice 1 and Slice 2 content. Quality Policy hard enforcement gates are active (Slice 2). Full per-task budget profiles and reconstruction test blocking are deferred to a later slice.

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
- Before delegating the next phase: emit checkpoint (if commit policy allows), store step-delta as durable artifact, clear ephemeral context, rehydrate from compact step-delta only.
- The next phase receives the compact step-delta — not the full prior phase report or tool outputs.

### Runtime Artifact Storage

Fallback storage paths (used when claude-mem is absent):

- `.agent-framework/plans/` — active plan artifacts
- `.agent-framework/handoffs/` — step-delta handoff artifacts (named `STEP-NNN.md`)
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

- **Present:** store step-deltas as claude-mem observations; rehydrate via `mem-search`.
- **Absent:** store step-deltas as files under `.agent-framework/handoffs/`; rehydrate by reading files.

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

Ephemeral purge is tightly coupled to the auto-clear trigger (see Budget Policy — Phase-Boundary Auto-Clear). The Memory Policy defines *what* to keep; the Budget Policy defines *when* the purge executes.

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

## Budget Policy

> **Slice 1 scope:** One trigger only — phase-boundary auto-clear. No per-task-class budget profile table. Full trigger policy and profile table deferred to a later slice after baseline data is available.

### Phase-Boundary Auto-Clear

**Trigger:** phase completion (the only Slice 1 trigger).

**Procedure:**

1. Phase verification passes.
2. Extract `Step delta:` section from the worker's report.
3. Store step-delta as durable artifact (claude-mem observation or `.agent-framework/handoffs/STEP-NNN.md`).
4. Emit checkpoint commit (if commit policy allows).
5. Clear ephemeral context (prior phase transcript, tool outputs, raw diffs drop out of active context).
6. Rehydrate: retrieve stored step-deltas for the current task via `mem-search` (or read from `.agent-framework/handoffs/`).
7. Delegate next phase with compact step-delta context only.

**Cooldown:** Do not fire more than one clear+rehydrate cycle per phase on average. If a phase boundary triggers a second clear before the next phase begins, log and skip the redundant clear.

### Observable Proxies (Slice 1)

These proxies govern when a mandatory checkpoint fires, independent of the phase-boundary trigger:

| Proxy | Threshold | Enforcement |
|---|---|---|
| Tool calls before mandatory checkpoint | 50 | Warn; checkpoint recommended but not blocking in Slice 1 |
| Prior artifacts auto-included per delegation (replay depth) | 1 | Warn if > 1 prior phase report is injected into a delegation |

Both thresholds are subject to calibration after Slice 1 baseline data is available.

### Deferred Items

The following are deferred to a later slice after baseline data is collected:
- Per-task-class budget profiles (bugfix / refactor / feature / incident)
- Reconstruction test blocking (hard gate on rehydration fidelity)
- N-tool-call hard trigger
- Scope-pivot trigger
- User-reset trigger

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
