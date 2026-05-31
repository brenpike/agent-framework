---
name: init-run-ledger
description: Initialize the run ledger for the current overlord instance — creates .hivemind/runs/<run-id>/ and writes the initial state.json. Trigger: "init run ledger", "initialize ledger", "create run ledger", "start a run".
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh *)
  - Read
shell: bash
---

# Init Run Ledger

Create the run ledger for the current overlord instance. The deterministic engine is the
committed script
`${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh`; this body is a
navigator that gathers the inputs, builds the script flags, and runs the script once. The
ledger is JSON (`.hivemind/runs/<run-id>/state.json`) per ADR-0018 §A and
`${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md`.

Rules: ADR-0018 §A (ledger is JSON); §C (engine is the committed script).

## Required Inputs

The overlord resolves and passes these; the skill does not invent them.

- `workflow`: the selected workflow id (matches an `<id>.json` under
  `${CLAUDE_PLUGIN_ROOT}/workflows/`).
- `workflow_version`: the definition `version` at init time (non-negative integer).
- `start_state`: the workflow's `start` state (becomes `state.current` at init).
- `user_request`: the raw user request — UNTRUSTED data, serialized only.
- `normalized`: the overlord's normalized summary of the request.

Optional (brood child / id control):

- `parent_kind`: `none | brood` (default `none`).
- `parent_run_id`, `parent_brood_id`, `parent_strain_id`, `parent_manifest`: required for
  the `brood` variant (brood/strain ids must match `[A-Za-z0-9._-]`).
- `suggested_run_id`: caller-suggested run id, used verbatim only if it matches
  `[A-Za-z0-9._-]`, else a derived id is used.
- `plan_steps`: cerebrate's plan `steps` reformatted to a JSON array (seeds
  `ledger.plan.steps`). UNTRUSTED step text — serialized only. Default `[]`.
- `plan_path`: path to the cerebrate directive (seeds `ledger.plan.path`). Default `null`.

### The §A Plan-Steps Seam

The ledger and workflow definitions are JSON; cerebrate's plan `steps` arrive as YAML in the
plan block, with no maintained converter. At the §A boundary the overlord reformats
cerebrate's YAML plan `steps` into a JSON array and passes it via `--plan-steps` at init —
this is the SOLE writer of `plan.steps` (no engine path mutates it after init). The brood/child
path omits the flag, preserving the default `[]`.

## Script Flag Interface

The script owns deterministic create-and-write; pass these flags (every value is inert
data — none is interpolated into shell source):

```text
--workflow <id>            (required) selected workflow id
--workflow-version <int>   (required) definition version at init time
--start-state <state>      (required) the workflow's start state
--user-request <text>      (required) raw user request (UNTRUSTED, serialized only)
--normalized <text>        (required) overlord's normalized summary
--parent-kind <kind>       (optional) none|brood ; default none
--parent-run-id <id>       (optional) parent run id when --parent-kind=brood
--parent-brood-id <id>     (optional) brood id when --parent-kind=brood
--parent-strain-id <id>    (optional) strain id when --parent-kind=brood
--parent-manifest <path>   (optional) manifest path when --parent-kind=brood
--suggested-run-id <id>    (optional) caller-suggested run id; verbatim only if safe
--plan-steps <json-array>  (optional) cerebrate plan steps as a JSON array (seeds plan.steps); default []
--plan-path <text>         (optional) path to the cerebrate directive (seeds plan.path); default null
```

Run-id derivation: `brood` -> `<brood-id>--<strain-id>`; else a safe `suggested_run_id`
verbatim; else derived `<utc-timestamp>-<workflow-id>`.

## Procedure

1. **Gather the Required Inputs** from the overlord's resolved routing decision. Each
   untrusted value (`user_request`, `normalized`) is passed as a flag argument, never
   spliced into command source.
2. **Execute the script** with one Bash call, passing the flags. Example (single run):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh \
     --workflow standard-delivery \
     --workflow-version 1 \
     --start-state intake \
     --user-request "<raw user request>" \
     --normalized "<overlord summary>"
   ```
   EXECUTE (do not Read) the script — it owns dependency check, input validation, run-id
   derivation, directory creation, and the atomic temp-write + rename of `state.json`.
3. **Interpret the result.** Exit 0: the script printed YAML routing lines on stdout —
   ```yaml
   run_id: <id>
   ledger: .hivemind/runs/<id>/state.json
   ```
   the overlord proceeds with that ledger. Exit 1: the script printed `blocker: <reason>`
   on stderr and wrote no ledger — surface it and stop.

## Pointers

- EXECUTE (do not read) the engine:
  `${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh`.
- Ledger schema: `${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md`.

## Silence Discipline

This is a pipeline skill:

- Produce zero chat text during execution. Outputs are tool calls only.
- The final action is the Bash script call.
- Exit 0 = overlord proceeds; routing data (`run_id:`, `ledger:`) is on stdout.
  Exit 1 = blocked; the reason is on stderr.

## Do Not

- invent values for `workflow`, `workflow_version`, `start_state`, `user_request`, or
  `normalized` — the script exits 1 with a blocker if any required input is missing.
- write the ledger by hand or with any tool other than the script.
- commit, push, or open a PR.
- Read or reconstruct the script body — invoke it with the documented flags.
