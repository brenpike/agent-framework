# Reconstruction Failure Runbook

## Purpose

Defines fallback, escalation, and recovery procedures when a reconstruction test at a major phase transition determines that the task cannot continue correctly from handoff artifacts and anchors alone.

This runbook is a load-bearing governance artifact referenced by hard enforcement gates.

## Trigger Condition

Fires when: the reconstruction test at a major phase transition returns a binary fail -- the agent cannot reconstruct sufficient context to continue the task from the handoff artifact (`Step delta:` fields) and anchor references alone.

---

## Fallback Mode

When the reconstruction test fails, the agent must:

1. Pause delegation of the next phase. Do not proceed with a degraded context.
2. Identify which required handoff fields or anchor references are missing. Compare the received handoff artifact against the required observation fields defined in `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields).
3. Request targeted rehydration of only the missing fields:
   - **claude-mem present:** invoke `claude-mem:mem-search` with queries scoped to the specific missing fields (e.g., search for the missing `Decisions:` or `Scope in:` content by step ID and field name). Do not request a full session replay.
   - **claude-mem absent:** read the corresponding `.agent-framework/handoffs/STEP-NNN.md` file for the phase that produced the incomplete handoff. If the file is missing or does not contain the required fields, proceed to escalation.
4. After rehydration, merge the recovered fields into the handoff artifact and re-run the reconstruction test.

---

## Escalation Trigger

The agent must stop and surface the failure to the user when any of the following is true:

- The rehydration attempt (step 3 above) does not resolve the missing fields after one retry.
- The missing field is a required scope or objective field (`Objective:`, `Scope in:`, `Scope out:`), not a minor evidence anchor (`Evidence refs:`, `Artifacts:`).
- The handoff artifact is entirely absent (no step-delta was stored for the prior phase).
- The reconstruction test fails on a field that was explicitly marked as resolved in a prior phase's `Decisions:` list.

When escalating, emit the Blocked Report Contract defined in `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Blocked Report Contract) with:

```text
Status: blocked
Stage: implementation
Blocker: reconstruction test failed — missing fields: [list missing field names]
Retry status: retried once | exhausted
Fallback used: targeted rehydration via mem-search | file read | none
Impact: next phase cannot be delegated without [missing field names]
Next action:
- User supplies missing context for: [list missing field names]
```

---

## Recovery Actions

Once the missing fields are supplied (by the user) or rehydrated (via mem-search or file read):

1. Re-run the reconstruction test against the updated handoff artifact.
2. If the reconstruction test passes, proceed to delegate the next phase with the repaired handoff.
3. If the reconstruction test still fails after escalation and user input:
   - Document the failure in the step-delta as an unresolved assumption: `ASM-NNN -- reconstruction failed for [field name]; proceeding with user-supplied context`.
   - Surface the unresolved assumption to the user before proceeding.
   - Proceed to the next phase only after the user acknowledges the gap.

---

## Cross-References

- Required handoff fields: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)
- Step-delta format: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Step Delta)
- Blocked Report Contract: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Blocked Report Contract)
- Phase transition requirements: `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Phase Transition Requirements)
- claude-mem detection: `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (claude-mem Detection)
