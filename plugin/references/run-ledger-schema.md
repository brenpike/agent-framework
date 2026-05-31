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
- `status` — `running` | `complete` | `blocked` | `cancelled`.
- `mode` — `deterministic` (default) or `intent_fallback` (see below).
- `created_at` / `updated_at` — ISO 8601 UTC timestamps.

### `parent.*`

Identifies the run's relationship to a brood. The `kind` field selects the variant; see [Parent-block variants](#parent-block-variants).

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

- `path` — path to the cerebrate directive, or `null`. Seeded at init by `init-run-ledger --plan-path`.
- `current_step` — the step id currently executing, or `null`.
- `steps` — array reformatted from the cerebrate YAML plan block at the §A boundary (no maintained converter). The WRITER is `init-run-ledger --plan-steps`, which seeds `plan.steps` at init time (validated as a JSON array, bound via `--argjson`); absent the flag it defaults to `[]`. No engine path mutates `plan.steps` after init.

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
    "run_id": "2026-05-30T22-10-00Z-hatchery",
    "brood_id": "2026-05-30T22-10-00Z",
    "strain_id": "api",
    "manifest": "/repo/.hivemind/brood/manifest.yaml"
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
      "id": "2026-05-30T22-10-00Z",
      "manifest": ".hivemind/brood/manifest.yaml"
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

Determinism only ever adds safety and observability; the `intent_fallback` mode guarantees a run is never stranded. See "Intent-driven execution is the universal fallback" in [workflow-state-machine.md](${CLAUDE_PLUGIN_ROOT}/references/workflow-state-machine.md).
