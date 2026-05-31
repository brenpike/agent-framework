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

## Injected child-task metadata

The task injected into each child strain carries metadata above the task description. This is an inter-agent contract, so it is YAML.

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

The child reads this, routes via `hivemind:route-workflow`, initializes its own JSON run ledger (with `parent.kind: brood` populated from this metadata — see run-ledger-schema.md), and executes the selected workflow normally. The child owns its ledger; it does not write the hatchery manifest or hatchery ledger.

## Hatchery monitoring (read-only)

The hatchery monitors a brood by reading only. It never mutates child ledgers, and `brood-status` never writes discovered ledger paths back to the manifest in v1.

The hatchery may read:

```text
.hivemind/brood/manifest.yaml
child .hivemind/runs/<run-id>/state.json
tmux session state
git branch existence
PR state
```

### Status-derivation priority

When deriving a strain's status, prefer sources in this order:

```text
1. external observables: tmux session, branch existence, PR state
2. child run ledger (state.current, run.status) if present
3. manifest static fields
```

External observables win because they reflect ground truth even when a child ledger is stale or absent. The ledger refines status when present; manifest static fields are the last resort. A strain whose ledger is missing reports `unknown` workflow state but can still be classified `failed before ledger initialization` from observables.

## Reconciliation concept

Before resuming work that touches a brood, the overlord reconciles ledger state against external observables — brood manifest presence, tmux sessions alive or dead, worktrees and branches existing, PRs existing, child ledgers present or missing and their current states. Reconciliation is a concept the docs define, not a v1 skill.

A dedicated `reconcile-run` skill is DEFERRED — it is NOT part of v1. In v1, reconciliation is performed by the overlord's resume-on-start judgment using the status-derivation priority above.
