---
name: init-run-ledger
description: Initialize the run ledger for the current overlord instance — creates .hivemind/runs/<run-id>/ and writes the initial state.json. Trigger: "init run ledger", "initialize ledger", "create run ledger", "start a run".
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh *)
  - Read
  - Write   # inert inputs-file only: authors fixed-path .hivemind/runs/.init-inputs.json; see security-policy.md "Inert Inputs-File Navigator Pattern" + ADR-0017/0018
shell: bash
---

# Init Run Ledger

Create the run ledger for the current overlord instance. The deterministic engine is the
committed script
`${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh`; this body is a
navigator that builds the inputs file and runs the script once. The
ledger is JSON (`<checkout-root>/.hivemind/runs/<run-id>/state.json`, anchored to the git
checkout root) per ADR-0018 §A and
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
  the `brood` variant. `parent_brood_id` is the CANONICAL brood id (the manifest's
  colon-bearing ISO-8601 timestamp) — it is persisted VERBATIM into `.parent.brood_id` so the
  child ledger reconciles with the manifest, and is sanitized internally (colons -> dashes)
  only to derive the filesystem-safe run id. `parent_strain_id` must match `[A-Za-z0-9._-]`.
- `suggested_run_id`: caller-suggested run id, used verbatim only if it matches
  `[A-Za-z0-9._-]`, else a derived id is used.
- `plan_steps`: cerebrate's plan `steps` reformatted to a JSON array — child/resume SEED for
  `ledger.plan.steps` (NOT the primary live writer; see §A). UNTRUSTED, serialized only. Default `[]`.
- `plan_path`: path to the cerebrate directive — child/resume seed for `ledger.plan.path`. Default `null`.

### The §A Plan-Steps Seam

The ledger and workflow definitions are JSON; cerebrate's plan `steps` arrive as YAML in the
plan block, with no maintained converter. `plan_steps` / `plan_path` here are the
child/resume SEED path, NOT the primary live writer: the overlord inits the ledger BEFORE
the `plan` (cerebrate) state runs, so an init-time seed would be empty on a fresh root run.
The PRIMARY, live persistence of `plan.steps` happens at record-time, when the overlord
records the `plan` state result via `hivemind:record-state-result --plan-steps` (see that
skill's §A Plan-Steps Seam). Init-time `plan_steps` exists ONLY to seed `plan.steps` for a
child/resume run that already has the steps in hand; absent the field it defaults to `[]`.

## Inputs JSON

The script owns deterministic create-and-write; the navigator authors a single JSON
inputs file and passes its path as the one positional argument. Every value is inert
data — the script reads each field with `jq` into a shell variable and never
interpolates it into shell source or the jq program source. Shape:

```json
{
  "workflow": "<required> selected workflow id (matches <id>.json under workflows/)",
  "workflow_version": 1,
  "start_state": "<required> the workflow's start state",
  "user_request": "<required> raw user request (UNTRUSTED, serialized only)",
  "normalized": "<required> overlord's normalized summary",
  "parent": {
    "kind": "none | brood",
    "run_id": "<required when kind=brood> parent run id",
    "brood_id": "<required when kind=brood> CANONICAL brood id; persisted verbatim, sanitized internally (colons->dashes) for the run id",
    "strain_id": "<required when kind=brood> strain id",
    "manifest": "<required when kind=brood> manifest path"
  },
  "suggested_run_id": "<optional> caller-suggested run id; verbatim only if it matches [A-Za-z0-9._-]",
  "plan_steps": [],
  "plan_path": "<optional> path to the cerebrate directive (seeds plan.path)"
}
```

Field rules:
- `workflow`, `start_state`, `user_request`, `normalized` are required non-empty strings.
- `workflow_version` is a required JSON number (non-negative integer).
- `parent` is optional; `parent.kind` defaults to `none` when the block is absent.
  When `parent.kind` is `brood`, `parent.run_id`, `parent.brood_id`, `parent.strain_id`,
  and `parent.manifest` are all required.
- `plan_steps` is an optional JSON array (the child/resume SEED for `plan.steps`; see §A);
  defaults to `[]` when omitted.
- `plan_path` is optional; defaults to `null` when omitted.
- Every value is data. None is interpolated into generated shell command source.

Run-id derivation: `brood` -> `<sanitized-brood-id>--<strain-id>` (the canonical brood id's
colons mapped to dashes for a filesystem-safe component; `.parent.brood_id` keeps the
canonical value); else a safe `suggested_run_id` verbatim; else derived
`<utc-timestamp>-<workflow-id>`.

## Procedure

1. **Build the inputs object** in your reasoning from the Required Inputs. Each untrusted
   value (`user_request`, `normalized`, any `plan_steps` text) is structured JSON data,
   never spliced into command source. `start_state` MUST be the `start` value declared in
   the chosen workflow definition (`<id>.json` under `${CLAUDE_PLUGIN_ROOT}/workflows/`) —
   derive it from that file.

2. **Write the inputs file** via the Write tool to the fixed gitignored path
   `.hivemind/runs/.init-inputs.json`. `file_path` = `.hivemind/runs/.init-inputs.json`,
   `content` = the JSON object from step 1. The leading-dot filename keeps it OUT of the
   `runs/<run-id>/` glob (it is a sibling of the run dirs, not one of them), and
   `.hivemind/` is gitignored. Write performs no shell parsing of the values, so untrusted
   `user_request` / `normalized` / `plan_steps` text is inert.

3. **Execute the script** with one Bash call, passing the inputs file path:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh .hivemind/runs/.init-inputs.json
   ```
   EXECUTE (do not Read) the script — it owns dependency check, input validation,
   packaged-definition validation, run-id derivation, directory creation, and the atomic
   temp-write + rename of `state.json`. BEFORE creating the run dir, the script validates the
   packaged workflow definition against the script's self-located `workflows/` dir
   (`workflows/<workflow>.json` must EXIST, its `.version` must equal `workflow_version`, and
   its `.start` must equal `start_state`) and fails early with a blocker on any mismatch, so a
   bad `workflow`/`workflow_version`/`start_state` never leaves an orphan run dir. The caller
   supplies NO definition path — it is derived from the workflow id against the packaged dir.

4. **Interpret the result.** Exit 0: the script printed YAML routing lines on stdout —
   ```yaml
   run_id: <id>
   ledger: <checkout-root>/.hivemind/runs/<id>/state.json
   ```
   the run dir is anchored to the git checkout root (`git rev-parse --show-toplevel`), not the
   CWD, so resume-on-start finds it regardless of which subdir init ran from; init requires being
   inside a git checkout. the overlord proceeds with that ledger. Exit 1: the script printed `blocker: <reason>`
   on stderr and wrote no ledger — surface it and stop.

## Pointers

- EXECUTE (do not read) the engine:
  `${CLAUDE_PLUGIN_ROOT}/skills/init-run-ledger/scripts/init-run-ledger.sh`.
- Ledger schema: `${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md`.

## Silence Discipline

This is a pipeline skill:

- Produce zero chat text during execution. Outputs are tool calls only.
- The Write tool (step 2) is a permitted NON-FINAL tool call — it emits no chat text and
  authors ONLY the inputs file. The final action is the Bash script call (step 3).
- Exit 0 = overlord proceeds; routing data (`run_id:`, `ledger:`) is on stdout.
  Exit 1 = blocked; the reason is on stderr.

## Do Not

- invent values for `workflow`, `workflow_version`, `start_state`, `user_request`, or
  `normalized` — the script exits 1 with a blocker if any required input is missing.
- write the ledger by hand or with any tool other than the script.
- use the Write tool for anything other than the `.hivemind/runs/.init-inputs.json`
  inputs file.
- commit, push, or open a PR.
- Read or reconstruct the script body — invoke it with the documented inputs file path.
