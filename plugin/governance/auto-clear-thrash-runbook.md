# Auto-Clear Thrash Runbook

## Purpose

Defines fallback, escalation, and recovery procedures when the context clear and rehydration cycle fires more than once per phase on average, indicating the auto-clear trigger threshold is miscalibrated.

This runbook is a load-bearing governance artifact referenced by hard enforcement gates.

## Trigger Condition

Fires when: the auto-clear and rehydration cycle (per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Auto-Clear Procedure)) fires more than once per phase on average across the current task. This violates the cooldown rule defined in that section and indicates threshold miscalibration.

---

## Fallback Mode

When auto-clear thrash is detected, the agent must:

1. Suspend the auto-clear trigger for the current phase. No further auto-clear cycles may fire until the next phase boundary.
2. Complete the current phase without further auto-clear. The agent continues execution with the context accumulated since the last clear, accepting the larger context window for the remainder of the phase.
3. Log the thrash event in the current phase's step-delta as an evidence entry:

```text
Evidence: EVD-NNN — auto-clear thrash detected
  Phase: [STEP-NNN | TASK-NNN]   (use TASK-NNN for STEP-NNN-bypass tasks per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Bypass Allowlist))
  Trigger type: [phase-boundary | N-tool-call | scope-pivot]
  Cycle count: [number of clear+rehydrate cycles in this phase]
  Average cycles per phase: [total cycles / total completed phases]
```

---

## Escalation Trigger

The agent must stop and surface the thrash condition to the user when any of the following is true:

- Thrash occurs on two consecutive phases (the current phase and the immediately preceding phase both exceeded one clear+rehydrate cycle).
- A single phase triggers more than three auto-clear cycles before the thrash detection suspends further clears.
- The thrash condition persists after a threshold adjustment was applied in a prior phase within the same task.

When escalating, emit the Blocked Report Contract defined in `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Blocked Report Contract) with:

```text
Status: blocked
Stage: implementation
Blocker: auto-clear thrash — [cycle count] cycles in [phase ID]; threshold miscalibrated
Retry status: not attempted
Fallback used: auto-clear suspended for current phase
Impact: context management degraded; phase completing without auto-clear
Next action:
- Review trigger thresholds for task type [task class if known]
- Adjust N-tool-call threshold or clarify phase boundary definition
```

---

## Recovery Actions

At phase close, the orchestrator performs the following recovery steps:

1. **Review trigger thresholds against actual phase complexity:**
   - Compare the configured N-tool-call threshold (see `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Budget Profiles)) against the actual tool-call count for the thrashing phase.
   - Compare the configured phase-boundary trigger against the actual phase boundaries encountered.

2. **If the N-tool-call trigger fired:**
   - Recommend raising the tool-call threshold for the current task type. The recommendation is logged in the step-delta as a decision: `DEC-NNN -- recommend raising N-tool-call threshold from [current] to [proposed] for [task type]`.
   - The threshold adjustment takes effect at the next phase boundary.

3. **If the phase-boundary trigger fired spuriously** (e.g., a sub-task was mistaken for a phase boundary):
   - Clarify the phase boundary definition in the active plan. Identify which sub-task was misidentified as a phase boundary and annotate it in the plan as a non-boundary step.
   - Log the clarification as a decision: `DEC-NNN -- [sub-task description] is not a phase boundary; phase-boundary trigger adjusted`.

4. **Re-enable auto-clear at the next phase boundary** after the threshold adjustment is recorded. Do not re-enable auto-clear mid-phase.

5. **If escalation was triggered** (consecutive phases or >3 cycles), the user must acknowledge the threshold adjustment before the orchestrator re-enables auto-clear for subsequent phases.

---

## Cross-References

- Phase-boundary auto-clear: `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Auto-Clear Procedure)
- Observable proxies and thresholds: `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Budget Profiles)
- Step-delta format: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Step Delta)
- Blocked Report Contract: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Blocked Report Contract)
- Handoff fields: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)
