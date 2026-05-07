# Unresolved Contradiction Runbook

## Purpose

Defines fallback, escalation, and recovery procedures when contradiction detection before finalization finds a conflict between a decision, assumption, or artifact in the current phase and a prior phase's accepted state.

This runbook is a load-bearing governance artifact referenced by hard enforcement gates.

## Trigger Condition

Fires when: contradiction detection (per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Contradiction Detection)) identifies a conflict between a field value in the current phase and a field value accepted in a prior phase's handoff artifact. Conflicts may be between decisions (DEC-NNN vs DEC-NNN), assumptions (ASM-NNN vs ASM-NNN), or field-level values (e.g., `Scope in:` in the current phase contradicts `Scope out:` from a prior phase).

---

## Fallback Mode

When a contradiction is detected before finalization, the agent must:

1. Halt finalization of the current phase. Do not commit, store the handoff, or delegate the next phase.
2. Emit a contradiction report containing:
   - The conflicting fields or tagged items (e.g., `DEC-002` vs `DEC-005`, or `Scope in: path/to/file` vs prior `Scope out: path/to/file`).
   - The phase in which each conflicting value originated (e.g., `DEC-002 from STEP-001`, `DEC-005 from STEP-003`).
   - The proposed resolution, if one is deterministic (e.g., later decision supersedes earlier). If no deterministic resolution exists, state that explicitly.
3. Do not auto-resolve the contradiction. Present the contradiction report to the user (or to the orchestrator for routing to the user) and wait for a resolution decision.

Contradiction report format:

```text
Contradiction detected:
  Field: [field name or DEC-NNN / ASM-NNN identifier]
  Current phase: STEP-NNN — [current value]
  Prior phase: STEP-NNN — [prior value]
  Proposed resolution: [deterministic resolution | requires user decision]
```

---

## Escalation Trigger

The agent must stop and surface the contradiction to the user immediately (bypassing orchestrator-level auto-resolution attempts) when any of the following is true:

- The contradiction involves a safety or security invariant (any field flagged under the Safety/Security category in `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Invariant Categories)).
- The contradiction cannot be resolved without changing already-committed artifacts (files that have been included in a checkpoint commit on the working branch).
- The same contradiction recurs after a prior resolution attempt within the same task (same field name or same DEC-NNN/ASM-NNN pair flagged in a previous contradiction report).

When escalating, emit the Blocked Report Contract defined in `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Blocked Report Contract) with:

```text
Status: blocked
Stage: implementation
Blocker: unresolved contradiction — [DEC-NNN vs DEC-NNN | field-level conflict description]
Retry status: not attempted | retried once (prior resolution failed)
Fallback used: none — auto-resolution not permitted
Impact: phase finalization blocked; next phase cannot proceed
Next action:
- User selects which value wins: [current phase value] or [prior phase value]
```

---

## Recovery Actions

Once the user selects a resolution:

1. Record the resolution as a new decision: `DEC-NNN -- [winning value]; rationale: [user-stated reason or "user override"]`.
2. Update the losing anchor to mark it superseded: `[SUPERSEDED by DEC-NNN]`. This annotation is appended to the original DEC-NNN or ASM-NNN entry in the step-delta where it was first recorded.
3. If the superseded value exists in an already-stored handoff artifact (claude-mem observation or `.agent-framework/handoffs/STEP-NNN.md`), annotate the supersession in the current phase's step-delta. Do not retroactively edit prior handoff artifacts.
4. Resume finalization of the current phase with the resolved value in place.
5. Include the resolution in the current phase's `Decisions:` list in the handoff artifact so downstream phases inherit the correct state.

---

## Cross-References

- Contradiction detection: `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Contradiction Detection)
- Invariant categories: `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Invariant Categories)
- Handoff fields: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Context Management Fields)
- Step-delta format: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Step Delta)
- Blocked Report Contract: `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Blocked Report Contract)
