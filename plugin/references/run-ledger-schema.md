# Run Ledger Schema

Read this file when initializing, reading, or mutating a run ledger. The run ledger records progress for one overlord instance and is the source of truth for workflow progress — conversation memory is not.

## Path

```text
.hivemind/runs/<run-id>/state.json
```

For a child strain session this path lives inside the child worktree. The ledger is JSON, parsed and written with `jq`. Untrusted fields (`request.raw`, `request.normalized`, child-task text) are written via `jq --arg` for injection-safe serialization. The engine writes via temp-write + atomic rename so a concurrent reader (the hatchery reading a child ledger) never sees a torn file. Ledger ownership is specified under "Run ownership" in [workflow-state-machine.md](${CLAUDE_PLUGIN_ROOT}/references/workflow-state-machine.md).

## Schema

```json
{
  "schema_version": 1,
  "run": {
    "id": "2026-05-30T22-10-00Z-standard-delivery",
    "workflow": "standard-delivery",
    "workflow_version": 1,
    "status": "running",
    "mode": "deterministic",
    "created_at": "2026-05-30T22:10:00Z",
    "updated_at": "2026-05-30T22:10:00Z"
  },
  "parent": {
    "kind": "none",
    "run_id": null,
    "brood_id": null,
    "strain_id": null,
    "manifest": null
  },
  "request": {
    "raw": "",
    "normalized": ""
  },
  "state": {
    "current": "plan",
    "previous": null,
    "status": "running"
  },
  "facts": {
    "branch": null,
    "base": null,
    "pr": null
  },
  "plan": {
    "path": null,
    "current_step": null,
    "steps": []
  },
  "artifacts": {},
  "events": [],
  "blockers": []
}
```

## Field notes

### `schema_version` (integer)

Ledger schema version. Distinct from `run.workflow_version`, which tracks the workflow definition.

### `run.*`

- `id` — run identifier; matches the `<run-id>` directory name.
- `workflow` — selected workflow id (matches a definition under `plugin/workflows/<id>.json`).
- `workflow_version` — the definition `version` at init time. On resume, a mismatch against the on-disk definition triggers the version-skew gate.
- `status` — `running` | `complete` | `blocked` | `cancelled`. Terminal-state mapping when `record-state-result` reaches a declared terminal: `complete`→`complete`, `blocked`→`blocked`, `cancelled`→`cancelled`, the human-intervention terminals (`user_input_required` / `review_rejected` / `review_exhausted`)→`blocked` (stopped, needs attention — never masked as success), and any other done-terminal (e.g. `hatchery_monitor`)→`complete`. The enum is fixed; intervention terminals reuse `blocked` rather than adding a new value.
- `mode` — `deterministic` (default) or `intent_fallback` (see below). The `hivemind:mark-intent-fallback` skill is the sanctioned writer that flips this to `intent_fallback` at a version-skew resume.
- `created_at` / `updated_at` — ISO 8601 UTC timestamps.

### `parent.*`

Identifies the run's relationship to a brood. The `kind` field selects the variant; see [Parent-block variants](#parent-block-variants). For a `brood` child, `brood_id` holds the brood id — the machine-generated GUID `brood-<uuidv4>` (ADR-0021), persisted verbatim so the child ledger reconciles 1:1 with the coordinator manifest's `brood_id`. The `parent.brood_id` field of the INIT inputs JSON object accepts this value and the init engine derives the filesystem-safe run id as `<brood-id>--<strain-id>`. The GUID carries NO colons (the prior brood-id was a colon-bearing ISO-8601 timestamp), so the colon-to-dash sanitization the init engine previously applied to derive a filesystem-safe stem is now INERT/no-op — a uuidv4 is already a safe path component, and `.parent.brood_id` and the run-path stem are identical.

### `request.*`

- `raw` — the original user request (untrusted; written via `jq --arg`).
- `normalized` — the overlord's summary of the request.

### `state.*`

- `current` — the state the run is in now; must exist in the workflow definition.
- `previous` — the state advanced from, or `null` at start.
- `status` — `running` | `complete` | `blocked` | `cancelled`.

### `facts.*`

Reconciliation anchors derived from git observables: `branch`, `base`, `pr`.

### `plan.*`

- `path` — path to the cerebrate directive, or `null`. Written by the same two writers as `steps`, via the `plan_path` field of each writer's inputs object.
- `current_step` — the step id currently executing, or `null`.
- `steps` — array reformatted from the cerebrate YAML plan block at the §A boundary (no maintained converter). Two writers, each carrying the steps in the `plan_steps` field of its inputs JSON object, validated as a JSON array and bound via `--argjson` in each:
  - **PRIMARY (live):** the `plan_steps` field of the RECORD inputs object (`record-state-result`), passed by the overlord when recording the `plan` (cerebrate) state result. The overlord inits the ledger BEFORE the `plan` state runs, so this record-time write is what populates `plan.steps` for the implement loop on a fresh root run. When the field is absent (missing key or `null`) the engine leaves `plan.steps` UNTOUCHED (never clobbered to `[]`). The engine honors the `plan_steps` / `plan_path` fields ONLY when the recording state is a cerebrate planning state (`states.<state>.agent == "hivemind:cerebrate"` — `plan` / `review_remediation_plan` / `brood_plan`); recording any other state with these fields present is rejected (ledger byte-unchanged), so `plan.steps` is record-time-writable only at cerebrate planning states.
  - **SEED (child/resume):** the `plan_steps` field of the INIT inputs object (`init-run-ledger`), which seeds `plan.steps` at init time for a child/resume run that already has the steps in hand; absent the field it defaults to `[]`.

### `artifacts` (object)

Free-form named outputs. The hatchery run stores its brood relationship here rather than in `parent` (see [Hatchery run](#hatchery-run)).

### `events` (array)

Append-only event log. One entry per recorded state result.

### `blockers` (array)

Append-only blocker log.

## Event shape

```json
{
  "at": "2026-05-30T22:10:00Z",
  "state": "plan",
  "result": "single",
  "next_state": "git_preflight",
  "summary": "Cerebrate returned a single-delivery plan.",
  "outputs": {
    "plan_path": ".hivemind/runs/2026-05-30T22-10-00Z-standard-delivery/plan.json"
  }
}
```

`event.outputs` is free-form and recorded verbatim. NO schema change and NO new REQUIRED field is implied by the convention that follows — `event.outputs` stays free-form/optional.

**Convention (proactive-recurrence-origin marker):** on a `root-cluster-suspected` transition, `event.outputs` MAY carry the named origin-marker key (`recurrence_origin`). Its presence distinguishes a proactively-derived zoom-out from a reviewer-returned one. The key's name, values, and absence semantics are defined SOLELY in `${CLAUDE_PLUGIN_ROOT}/governance/remediation-doctrine.md (### Proactive Zoom-Out Ledger Marker)` — that subsection is the single source; this note does not restate them.

**Convention (decision-journal array):** `event.outputs` MAY carry an OPTIONAL, free-form `decisions[]` array, recorded verbatim like `recurrence_origin`. Each entry carries the fields `ts`, `state`, `situation`, `options`, `tradeoffs`, `rec_strength`, `gate`, `disposition`, `decision`, `rationale`, and `reversible`. The semantics single source — the autonomy posture, the 2x2, the promotion gate, the disposition vocabulary, and these fields — is `${CLAUDE_PLUGIN_ROOT}/governance/decision-autonomy.md (## Decision Journal)`; this note does not restate the 2x2 or promotion-gate mechanics. `decisions[]`, `recurrence_origin`, and the `plan.steps` plan-steps writers are DISTINCT keys/paths on or around `event.outputs` and do not collide.

**Non-change clarifications (so a future reader does not "fix" a non-bug):**

- NO `schema_version` bump is implied by the decision-journal convention — `decisions[]` is a free-form `event.outputs` key, not a required ledger field.
- NO new `run.status` value is introduced — the enum stays `running | complete | blocked | cancelled`. The post-merge report's "awaiting" condition is DERIVED at Resume-On-Start (a PR exists, `event.outputs.decisions[]` carries ≥1 `did-now`/`deferred` entry, and the zero-byte `.decision-report-done` marker is absent), NOT stored.
- NO `artifacts.decision_report` ledger marker is used — the post-merge report is CHAT-ONLY (rendered and surfaced to the user, never written to disk). Its idempotency token is the EXISTENCE of a zero-byte `.decision-report-done` marker `touch`ed in the run dir — NOT a `decision-report.md` content file (which no longer exists), and not a ledger field.

## Blocker shape

```json
{
  "at": "2026-05-30T22:18:00Z",
  "state": "git_preflight",
  "reason": "trunk is stale",
  "retry": "not_attempted",
  "next": "Ask user whether to update trunk or proceed at risk."
}
```

## Parent-block variants

### None (normal root run)

A standalone interactive, resumed, or analysis run.

```json
{
  "parent": {
    "kind": "none",
    "run_id": null,
    "brood_id": null,
    "strain_id": null,
    "manifest": null
  }
}
```

### Brood (child strain run)

A spawned strain. Populated from the injected child-task metadata; lives inside the child worktree.

```json
{
  "parent": {
    "kind": "brood",
    "run_id": "brood-7f3c9a2e-1b4d-4c8a-9e6f-2a1b3c4d5e6f-hatchery",
    "brood_id": "brood-7f3c9a2e-1b4d-4c8a-9e6f-2a1b3c4d5e6f",
    "strain_id": "api",
    "manifest": "/repo/.hivemind/broods/brood-7f3c9a2e-1b4d-4c8a-9e6f-2a1b3c4d5e6f/manifest.json"
  }
}
```

### Hatchery (coordinator run)

The hatchery is itself a normal root run, so its `parent.kind` is `none`. Its relationship to the brood it dispatched is stored in `artifacts`, not `parent`.

```json
{
  "parent": {
    "kind": "none",
    "run_id": null,
    "brood_id": null,
    "strain_id": null,
    "manifest": null
  },
  "artifacts": {
    "brood": {
      "id": "brood-7f3c9a2e-1b4d-4c8a-9e6f-2a1b3c4d5e6f",
      "manifest": ".hivemind/broods/brood-7f3c9a2e-1b4d-4c8a-9e6f-2a1b3c4d5e6f/manifest.json"
    }
  }
}
```

## Intent-fallback marker

When the deterministic substrate is invalidated (version skew, torn ledger, missing definition, unresolvable `state.current`), the run degrades to intent-driven completion. Transition gating is suspended; the ledger becomes an append-only observability log. The run records the degradation with `run.mode`:

```json
{
  "run": {
    "id": "2026-05-30T22-10-00Z-standard-delivery",
    "workflow": "standard-delivery",
    "workflow_version": 1,
    "status": "running",
    "mode": "intent_fallback"
  }
}
```

The `hivemind:mark-intent-fallback` skill is the sanctioned writer of this marker. It sets `run.mode: intent_fallback`, appends a fallback event to the `events` log, and — when its `close_status` input is supplied — optionally closes the run by setting `run.status` ∈ {`cancelled`, `complete`}. Closeout applies ONLY to a `running` run — the engine rejects closing out an already-terminal run (ledger byte-unchanged). When `close_status` is omitted the run stays `running` and the ledger continues as an append-only observability log.

`abandoned` is NOT a legal `run.status` value — the enum is fixed at `running` | `complete` | `blocked` | `cancelled`. Stale skew-run closeout therefore reuses `cancelled` rather than introducing a new value.

Determinism only ever adds safety and observability; the `intent_fallback` mode guarantees a run is never stranded. See "Intent-driven execution is the universal fallback" in [workflow-state-machine.md](${CLAUDE_PLUGIN_ROOT}/references/workflow-state-machine.md).
