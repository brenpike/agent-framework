# Brood Ledger Model

Read this file to understand how the brood manifest bridges to per-strain run ledgers: the additive `manifest_version: 2` extension, the injected child-task metadata, hatchery read-only monitoring with status-derivation priority, and the reconciliation concept.

## Format split: manifest JSON, child ledgers JSON

The brood manifest is **JSON** — `ADR-0018 §A format-follows-consumer` now applies to the manifest too, because `brood-status` projects it via `jq` (a machine consumer). A real parser cannot confuse attacker content for structure, which is why the manifest is JSON: this closes the hand-parse injection class (the sed/awk block-scalar/nested-mapping/multiline-description spoofing class that YAML hand-parsing admitted). The per-strain **run ledgers** it points to are also JSON, for the same reason — the deterministic engine reads and writes those with `jq` (see [run-ledger-schema.md](${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md)).

The child-task `task.md` preamble and the inter-agent contract embedded in it **stay YAML** — that is an agent-to-agent document, not a machine-parsed artifact, and `ADR-0018 §A` continues to govern it separately. Only the manifest artifact flipped; not all brood YAML flipped.

The manifest is the registry and coordination artifact. It is NOT the source of truth for child workflow state — that lives in each child's run ledger.

## Manifest extension (`manifest_version: 3`)

The manifest is JSON (`manifest_version: 3`, integer). The shape carries a top-level `hatchery` block (the dispatching coordinator's run metadata) and a per-strain `run` block (suggested run id, suggested ledger path, and workflow hint). All values are emitted via `jq -nc`/`jq -s` with every untrusted value bound as a `--arg`, so attacker content is structurally confined to string values — it cannot become sibling keys or alter manifest topology.

```json
{
  "manifest_version": 3,
  "brood_id": "2026-05-30T22-10-00Z",
  "base": "main",
  "hatchery": {
    "run_id": "2026-05-30T22-10-00Z-hatchery",
    "ledger": ".hivemind/runs/2026-05-30T22-10-00Z-hatchery/state.json",
    "workflow": "hatchery-dispatch"
  },
  "overlap_risk": "low",
  "overlap_details": "No shared file scopes detected.",
  "strains": [
    {
      "name": "api",
      "description": "Implement the API slice.",
      "worktree_path": "/repo/.claude/worktrees/api",
      "branch": "feature/api-slice",
      "tmux_session": "brood-api",
      "status": "running",
      "pr": null,
      "merged": false,
      "rebased_after": [],
      "run": {
        "suggested_id": "2026-05-30T22-10-00Z--api",
        "suggested_ledger": "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json",
        "workflow_hint": "standard-delivery"
      }
    }
  ],
  "merge_order": []
}
```

The two blocks are `hatchery` (the dispatching coordinator's run metadata) and the per-strain `run` block (suggested run id, suggested ledger path, and workflow hint). The `run.suggested_ledger` path ends in `state.json` — the child ledger is also JSON.

Field derivation (emitted by `spawn-brood.sh` via `jq -nc` per strain then `jq -s` to fold the array, all untrusted values bound as `--arg`):

- `hatchery.run_id` — overlord-supplied, or defaults to `<brood_id>-hatchery`.
- `hatchery.ledger` — `.hivemind/runs/<hatchery.run_id>/state.json`, anchored to the coordinator checkout root.
- `hatchery.workflow` — overlord-supplied, or defaults to `hatchery-dispatch`.
- `run.suggested_id` — `<brood_id>--<short>`, where `<short>` is the strain name sanitized to `[a-z0-9-]`.
- `run.suggested_ledger` — `<worktree_path>/.hivemind/runs/<suggested_id>/state.json` (inside the child worktree).
- `run.workflow_hint` — an OPTIONAL, NON-BINDING suggestion (overlord-supplied per strain, default `standard-delivery`); the child's own `hivemind:route-workflow` makes the actual selection.

None of these fields point at a ledger the hatchery creates — they are pointers only. The child creates its own ledger; the hatchery creates only its own.

## Injected child-task metadata

The task injected into each child strain carries the data-boundary preamble FIRST, then a YAML metadata block whose `task.description` field carries the task description. This is an inter-agent contract, so it is YAML.

```yaml
parent:
  kind: brood
  brood_id: "2026-05-30T22-10-00Z"
  hatchery_run_id: "2026-05-30T22-10-00Z-hatchery"
  hatchery_manifest: "/repo/.hivemind/brood/manifest.json"

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

`brood-status` derives each strain's status from **external observables + the manifest's static fields + the child run ledger (informational)**. Reading child-ledger workflow-state is **LIVE** as of issue #161, implemented in `plugin/skills/brood-status/scripts/brood-status-project.sh`. The helper sources four single-responsibility libs: `_shared/allowlist.sh` (safe-token gate), `_shared/manifest-json.sh` (jq-based JSON field extraction), `_shared/ledger-project.sh` (jq scalar projection + validation), and `_shared/containment.sh` (path confinement). It projects exactly two scalars per strain: `run.status` (validated against the exact enum `running|complete|blocked|cancelled`) and `state.current` (validated against `^[a-z0-9_]+$`, length ≤ 64). Values that are absent yield the fixed token `MISSING`; values that are present but out-of-allowlist or unparseable yield `MALFORMED` — raw bytes are never emitted. The ledger path is confined beneath the strain's own `worktree_path` as `.hivemind/runs/<safe-id>/state.json`; a symlinked leaf or out-of-worktree pointer is rejected and never read. This projection is **informational only**: it populates the `Workflow State` / `run.status` display columns but never overrides the observable-derived `Status` (external observables remain ground truth — ADR-0007).

The hatchery may read:

```text
.hivemind/brood/manifest.json
tmux session state
git branch existence
PR state
child run ledger (brood-status-project.sh — informational, bounded projection)
```

### Status-derivation priority

When deriving a strain's status, prefer sources in this order:

```text
1. external observables: tmux session, branch existence, PR state
2. manifest static fields
3. child run ledger: run.status / state.current (informational — never overrides tier 1 or 2 Status)
```

External observables win because they reflect ground truth. Manifest static fields are the fallback. The child run ledger (tier 3, live as of #161) populates the `Workflow State` and `run.status` display columns via `brood-status-project.sh`'s bounded projection, but it is strictly informational — a hostile child cannot hide a runaway session or alter the observable-derived `Status` through its ledger.

## Reconciliation concept

Before resuming work that touches a brood, the overlord reconciles state against external observables + the manifest's static fields + the child run ledger (informational) — brood manifest presence, tmux sessions alive or dead, worktrees and branches existing, PRs existing, and the bounded `run.status` / `state.current` projection from `brood-status-project.sh`. Child-ledger reading is **live** (#161 implemented). The projection is informational only: it informs the display but does not override observable-derived state. Reconciliation is a concept the docs define, not a v1 skill.

A dedicated `reconcile-run` skill is DEFERRED — it is NOT part of v1. In v1, reconciliation is performed by the overlord's resume-on-start judgment using the status-derivation priority above.
