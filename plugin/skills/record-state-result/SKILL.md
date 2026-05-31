---
name: record-state-result
description: Record the outcome of the current workflow state into the run ledger and advance state.current to the legal next state. Validates the transition against the workflow definition. Trigger: "record state result", "advance workflow state", "record transition", "advance the run".
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/record-state-result/scripts/record-state-result.sh *)
  - Read
  - Write
shell: bash
---

# Record State Result

Record the outcome of the current workflow state into the run ledger, append a ledger
event, validate the transition against the workflow definition, and advance
`state.current` to the legal next state. The deterministic engine is the committed script
`${CLAUDE_PLUGIN_ROOT}/skills/record-state-result/scripts/record-state-result.sh`; this
body is a navigator that builds the flags and runs the script once. The allowed-result
set is read DIRECTLY from the workflow definition by the script — the model NEVER supplies
it (ADR-0018 §C).

Rules: ADR-0018 §C (engine is the committed script, reads the allowed-set); §A (ledger and
definitions are JSON); §I (version-skew engine guard).

## Required Inputs

The overlord resolves and passes these; the skill does not invent them.

- `ledger`: path to the run ledger `state.json` (from `init-run-ledger`).
- `workflow`: path to the workflow definition JSON — the `<id>.json` under
  `${CLAUDE_PLUGIN_ROOT}/workflows/`.
- `state`: the state the run is currently in (MUST equal `ledger.state.current`).
- `result`: the named outcome to record (MUST be a legal transition key under that state).
- `summary`: human-readable summary of the outcome — UNTRUSTED, serialized only.
- `outputs` (optional): a JSON object of named outputs — UNTRUSTED, serialized only.

## The §A Plan-Steps Seam

The ledger and workflow definitions are JSON; cerebrate's plan `steps` arrive as YAML in
the plan block. There is no maintained converter. At this boundary the overlord/skill
**reformats cerebrate's YAML plan `steps` into JSON** for `ledger.plan.steps`, then passes
it as the `--outputs` JSON object (or writes it into the ledger before recording). The
script does NOT parse YAML — it validates JSON structure only and rejects a non-object
`--outputs`. When you must materialize the reformatted JSON before the script call, use the
Write tool (a permitted NON-FINAL step that emits no chat text); the final action remains
the Bash script call.

## Script Flag Interface

```text
--ledger <path>      (required) path to the run ledger state.json
--workflow <path>    (required) path to the workflow definition JSON
--state <state>      (required) state the run is currently in (must match ledger)
--result <outcome>   (required) named outcome to record (must be a legal transition)
--summary <text>     (required) human-readable summary (UNTRUSTED, serialized only)
--outputs <json>     (optional) JSON object of named outputs (UNTRUSTED, serialized only)
```

The script validates, in order, ALL before any write: `ledger.state.current == --state`;
`--state` exists in `definition.states` (§I version-skew guard — a renamed/removed state
never guesses); `--result` is a key under `states.<state>.transitions`; resolves
`next_state`; appends the event; updates `state.previous`/`state.current`/`state.status`,
`run.updated_at`, and (if `next_state` is terminal) `run.status`. Every write is
temp-write + atomic rename; on ANY validation failure the on-disk ledger is byte-unchanged.

## Procedure

1. **Gather the Required Inputs** from the overlord's run context. If recording
   plan-bearing outputs, reformat cerebrate's YAML plan `steps` into JSON per the §A seam.
2. **(Conditional) Write the reformatted outputs** via the Write tool only if they must be
   materialized to a file before the script call — otherwise pass them inline via
   `--outputs`. This is a permitted NON-FINAL tool call.
3. **Execute the script** with one Bash call:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/record-state-result/scripts/record-state-result.sh \
     --ledger .hivemind/runs/<run-id>/state.json \
     --workflow ${CLAUDE_PLUGIN_ROOT}/workflows/standard-delivery.json \
     --state plan \
     --result single \
     --summary "Cerebrate returned a single-delivery plan."
   ```
   EXECUTE (do not Read) the script — it owns the deterministic read -> validate -> mutate
   -> atomic-write and reads the allowed-result set directly from the definition.
4. **Interpret the result.** Exit 0: the script printed YAML routing lines on stdout —
   ```yaml
   previous_state: <state>
   result: <result>
   current_state: <next_state>
   ledger: <path>
   ```
   the overlord advances ONLY to `current_state`. Exit 1: the script printed
   `blocker: <reason>` on stderr and the ledger is byte-unchanged — surface it and stop.

## Pointers

- EXECUTE (do not read) the engine:
  `${CLAUDE_PLUGIN_ROOT}/skills/record-state-result/scripts/record-state-result.sh`.
- Ledger schema: `${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md`.

## Silence Discipline

This is a pipeline skill:

- Produce zero chat text during execution. Outputs are tool calls only.
- The Write tool (step 2) is a permitted NON-FINAL tool call — it emits no chat text. The
  final action is the Bash script call (step 3).
- Exit 0 = overlord advances to `current_state`; routing data is on stdout.
  Exit 1 = blocked; the reason is on stderr and the ledger is unchanged.

## Do Not

- supply or guess the allowed-result set — the script reads it directly from the workflow
  definition.
- advance to any state other than the `current_state` the script returns.
- mutate the ledger by hand or with any tool other than the script.
- commit, push, or open a PR.
- Read or reconstruct the script body — invoke it with the documented flags.
