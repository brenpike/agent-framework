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
definitions are JSON); §I (engine hard-rejects a non-binding id/version mismatch and exposes
no rebind; the overlord resume gate owns the two version-skew doors — start fresh / proceed
intent-driven).

## Required Inputs

The overlord resolves and passes these; the skill does not invent them.

- `ledger`: path to the run ledger `state.json` (from `init-run-ledger`).
- `workflow`: path to the workflow definition JSON — the `<id>.json` under
  `${CLAUDE_PLUGIN_ROOT}/workflows/`.
- `state`: the state the run is currently in (MUST equal `ledger.state.current`).
- `result`: the named outcome to record (MUST be a legal transition key under that state).
- `summary`: human-readable summary of the outcome — UNTRUSTED, serialized only.
- `outputs` (optional): a JSON object of named outputs — UNTRUSTED, serialized only.
- `plan_steps` (optional): cerebrate's plan `steps` reformatted to a JSON array — UNTRUSTED,
  serialized only. Pass this when recording any cerebrate planning state result (`plan` /
  `review_remediation_plan` / `review_remediation_plan_postpr` / `brood_plan`; see §A below).
- `plan_path` (optional): path to the cerebrate directive — UNTRUSTED, serialized only.

## The §A Plan-Steps Seam

The ledger and workflow definitions are JSON; cerebrate's plan `steps` arrive as YAML in
the plan block, with no maintained converter. The PRIMARY, live persistence path for
`plan.steps` is **record-time, here**: the overlord inits the ledger BEFORE any cerebrate
planning state runs, so an init-time seed would be empty at runtime. When the overlord
records any cerebrate planning state result (`plan` / `review_remediation_plan` /
`review_remediation_plan_postpr` / `brood_plan`, after cerebrate returns), it reformats
cerebrate's YAML plan `steps` into a JSON array and passes `--plan-steps` (and optionally
`--plan-path`); the script sets `.plan.steps = $plan_steps` (and `.plan.path`). When the
flags are ABSENT, `.plan.*` is left UNTOUCHED — never clobbered to `[]`.

`init-run-ledger --plan-steps` remains a writer ONLY for the child/resume SEED path (default
`[]`); it is no longer the primary live writer (see that skill's §A Plan-Steps Seam).

`--outputs` here is the event's free-form `outputs` object — it is NOT a plan-steps writer;
use `--plan-steps` for that.

## Script Flag Interface

```text
--ledger <path>      (required) path to the run ledger state.json
--workflow <path>    (required) path to the workflow definition JSON
--state <state>      (required) state the run is currently in (must match ledger)
--result <outcome>   (required) named outcome to record (must be a legal transition)
--summary <text>     (required) human-readable summary (UNTRUSTED, serialized only)
--outputs <json>     (optional) JSON object of named outputs (UNTRUSTED, serialized only)
--plan-steps <json>  (optional) cerebrate plan steps as a JSON array (sets plan.steps;
                     UNTRUSTED, serialized only via --argjson). Absent -> plan.steps untouched.
--plan-path <text>   (optional) path to the cerebrate directive (sets plan.path; UNTRUSTED,
                     serialized only via --arg). Absent -> plan.path untouched.
```

The script validates, in order, ALL before any write:

1. `--outputs` (if present) must be a JSON object; `--plan-steps` (if present) must be a JSON
   array — both validated up front for a clear blocker before any temp-write.
2. `definition.id == ledger.run.workflow` — BINDING GUARD (engine hard-reject; ledger unchanged).
3. `definition.version == ledger.run.workflow_version` — BINDING GUARD. The engine HARD-REJECTS
   an id/version mismatch and exposes NO rebind; the overlord resume-on-start gate owns the
   TWO version-skew DOORS (start fresh / proceed intent-driven). There is NO deterministic-resume
   door. The engine never reconciles skew — it rejects a non-binding definition outright.
4. `ledger.state.current == --state`.
5. `--state` exists in `definition.states` (state-existence — a renamed/removed state never
   guesses; this is NOT version-skew).
6. `--result` is a key under `states.<state>.transitions`; resolves `next_state`.
7. PLAN-WRITE AUTHORIZATION — if `--plan-steps` or `--plan-path` was supplied, the recording
   state MUST be a cerebrate planning state (`states.<state>.agent == "hivemind:cerebrate"`,
   i.e. `plan` / `review_remediation_plan` / `review_remediation_plan_postpr` / `brood_plan`);
   otherwise the engine rejects (exit 1,
   ledger byte-unchanged). Flag presence alone does NOT authorize a plan write — only a cerebrate
   agent state may persist `plan.steps` / `plan.path`.

Then it appends the event; updates `state.previous`/`state.current`/`state.status`,
`run.updated_at`, (if `next_state` is terminal) `run.status`, and — when `--plan-steps` /
`--plan-path` are present — `plan.steps` / `plan.path`. Every write is temp-write + atomic
rename; on ANY validation failure the on-disk ledger is byte-unchanged.

## Procedure

1. **Gather the Required Inputs** from the overlord's run context. When recording any cerebrate
   planning state result (`plan` / `review_remediation_plan` / `review_remediation_plan_postpr`
   / `brood_plan`), reformat cerebrate's YAML plan `steps` into a JSON array per the §A seam and
   pass it via `--plan-steps` (and `--plan-path` if known) — this is the primary, live writer of
   `ledger.plan.steps`.
2. **(Conditional) Write the reformatted outputs** via the Write tool only if they must be
   materialized to a file before the script call — otherwise pass them inline via
   `--outputs` / `--plan-steps`. This is a permitted NON-FINAL tool call.
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
