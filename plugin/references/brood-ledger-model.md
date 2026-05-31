# Brood Ledger Model

Read this file to understand how the brood manifest bridges to per-strain run ledgers: the additive `manifest_version: 2` extension, the injected child-task metadata, hatchery read-only monitoring with status-derivation priority, and the reconciliation concept.

## Format split: manifest YAML, child ledgers JSON

The brood manifest STAYS YAML — it is a coordination artifact written by the hatchery and read by humans and `brood-status`, and it is emitted with block scalars (`|-`) for multi-line description text. Only the per-strain **run ledgers** it points to are JSON, because the deterministic engine reads and writes those with `jq`. This is the format-follows-consumer rule (ADR-0018): the manifest is human/coordination-read, so it stays YAML; the ledgers are engine-parsed, so they are JSON (see [run-ledger-schema.md](${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md)).

The manifest is the registry and coordination artifact. It is NOT the source of truth for child workflow state — that lives in each child's run ledger.

## Manifest extension (`manifest_version: 2`)

The PR 154 manifest shape is extended additively. Existing consumers ignore unknown fields. The extension adds hatchery run metadata and per-strain suggested run metadata; it does not remove or rename any PR 154 field.

```yaml
manifest_version: 2
brood_id: "2026-05-30T22-10-00Z"
base: "main"

hatchery:
  run_id: "2026-05-30T22-10-00Z-hatchery"
  ledger: ".hivemind/runs/2026-05-30T22-10-00Z-hatchery/state.json"
  workflow: "hatchery-dispatch"

overlap_risk: low
overlap_details: |-
  No shared file scopes detected.

strains:
  - name: "api"
    description: |-
      Implement the API slice.
    worktree_path: "/repo/.claude/worktrees/api"
    branch: "feature/api-slice"
    tmux_session: "brood-api"
    status: running
    pr: null
    merged: false
    rebased_after: []
    run:
      suggested_id: "2026-05-30T22-10-00Z--api"
      suggested_ledger: "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json"
      workflow_hint: "standard-delivery"

merge_order: []
```

The two additive blocks are `hatchery:` (the dispatching coordinator's run metadata) and the per-strain `run:` block (suggested run id, suggested ledger path, and workflow hint). The `run.suggested_ledger` path ends in `state.json` — the child ledger is JSON even though the manifest carrying the pointer is YAML.

Field derivation (emitted by `spawn-brood.sh` through the existing `emit_block` block-scalar discipline, all exact-value `|-` fields except free-text `overlap_details`/`description` which use `|`):

- `hatchery.run_id` — overlord-supplied, or defaults to `<brood_id>-hatchery`.
- `hatchery.ledger` — `.hivemind/runs/<hatchery.run_id>/state.json`, anchored to the coordinator checkout root.
- `hatchery.workflow` — overlord-supplied, or defaults to `hatchery-dispatch`.
- `run.suggested_id` — `<brood_id>--<short>`, where `<short>` is the strain name sanitized to `[a-z0-9-]`.
- `run.suggested_ledger` — `<worktree_path>/.hivemind/runs/<suggested_id>/state.json` (inside the child worktree).
- `run.workflow_hint` — an OPTIONAL, NON-BINDING suggestion (overlord-supplied per strain, default `standard-delivery`); the child's own `hivemind:route-workflow` makes the actual selection.

None of these fields point at a ledger the hatchery creates — they are pointers only. The child creates its own ledger; the hatchery creates only its own.

## Injected child-task metadata

The task injected into each child strain carries, below the data-boundary preamble, a YAML metadata block above the task description. This is an inter-agent contract, so it is YAML.

```yaml
parent:
  kind: brood
  brood_id: "2026-05-30T22-10-00Z"
  hatchery_run_id: "2026-05-30T22-10-00Z-hatchery"
  hatchery_manifest: "/repo/.hivemind/brood/manifest.yaml"

strain:
  id: "api"
  name: "api"
  branch: "feature/api-slice"
  worktree_path: "/repo/.claude/worktrees/api"

run:
  suggested_id: "2026-05-30T22-10-00Z--api"
  suggested_ledger: ".hivemind/runs/2026-05-30T22-10-00Z--api/state.json"
  workflow_hint: "standard-delivery"

instructions:
  - You are a normal hivemind:overlord instance assigned to one strain of a brood.
  - Use the normal workflow router and workflow state machine.
  - Initialize your own run ledger in this worktree.
  - Set parent.kind = brood in your ledger.
  - Do not write the hatchery manifest.
  - Do not write the hatchery run ledger.

task:
  description: |-
    Implement the API slice.
```

`spawn-brood.sh` emits the canonical external-content data-boundary preamble FIRST in the child's injected `task.md`, then this YAML metadata block (whose `task.description` carries the untrusted task description) below it, using the same block-scalar discipline as the manifest emitter (`|-` for exact-value fields, `|` for the free-text `task.description`). The untrusted strain name/branch/worktree-path/description are reproduced at each block-scalar's content indent and stripped of C0 control bytes, so an issue-sourced value cannot break the metadata's YAML validity or the paste boundary.

The child reads this, routes via `hivemind:route-workflow`, initializes its own JSON run ledger (with `parent.kind: brood` populated from this metadata — see run-ledger-schema.md), and executes the selected workflow normally. The child owns its ledger; it does not write the hatchery manifest or hatchery ledger.

## Hatchery monitoring (read-only)

The hatchery monitors a brood by reading only. It never mutates child ledgers, and `brood-status` never writes discovered ledger paths back to the manifest.

`brood-status` derives each strain's status from **external observables + the manifest's static fields**. **Reading the child ledger's workflow-state is DEFERRED to issue #161** — `brood-status` does NOT open, `Read`, or `jq`-project any child `state.json`. The manifest still carries per-strain `run.*` pointers (`suggested_id` / `suggested_ledger` / `workflow_hint`) for that future feature, and children still own and write their own ledgers; the monitor simply does not consume them today.

The hatchery may read:

```text
.hivemind/brood/manifest.yaml
tmux session state
git branch existence
PR state
```

### Status-derivation priority

When deriving a strain's status, prefer sources in this order:

```text
1. external observables: tmux session, branch existence, PR state
2. manifest static fields
```

External observables win because they reflect ground truth. Manifest static fields are the last resort. The child-run-ledger refinement tier (`state.current` / `run.status`) is deferred to issue #161; until then the `Workflow State` column reads `deferred (#161)`.

## Reconciliation concept

Before resuming work that touches a brood, the overlord reconciles state against external observables + the manifest's static fields only — brood manifest presence, tmux sessions alive or dead, worktrees and branches existing, PRs existing. Consistent with the #161 deferral above, reconciliation does NOT open, `Read`, or `jq`-project any child `state.json`; child-ledger workflow-state reading is DEFERRED to issue #161. Reconciliation is a concept the docs define, not a v1 skill.

A dedicated `reconcile-run` skill is DEFERRED — it is NOT part of v1. In v1, reconciliation is performed by the overlord's resume-on-start judgment using the status-derivation priority above.
