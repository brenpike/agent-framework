---
name: spawn-brood
description: Dispatches parallel overlord sessions as a brood, spawning N Claude Code instances in separate git worktrees via tmux and writing the brood manifest. Use when spawning a brood or running parallel strains.
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/spawn-brood/scripts/spawn-brood.sh *)
  - Read
  - Write   # inert inputs-file only: authors per-invocation mktemp-unique staging path under .hivemind/; see security-policy.md "Inert Inputs-File Navigator Pattern" + ADR-0017/0018
shell: bash
---

# Spawn Brood

Dispatch parallel overlord sessions as a brood. Spawn N Claude Code instances in
separate git worktrees via tmux, inject task descriptions, and write the brood
manifest. The deterministic engine is the committed script
`${CLAUDE_PLUGIN_ROOT}/skills/spawn-brood/scripts/spawn-brood.sh`; this body is a
navigator that builds the inputs file and runs the script once.

Rules: `GIT-01` (no trunk commits).

## Quick Reference

Before:
- [ ] `strains`, `base`, `overlap_risk`, `overlap_details` provided (no `brood_id` — script generates it).
- [ ] `tmux`, `claude`, and `jq` are installed (the script blocks on any missing).
- [ ] `base` resolves to a real commit (the script verifies this once, up front).
- [ ] No strain branch exists locally/remotely; no tmux session or worktree path
      collides (the script pre-flights all of these; names are brood-id-namespaced,
      so concurrent broods on the same checkout are supported).

After:
- [ ] Script printed `brood_id: <id>` on stdout — the coordinator captures the generated
      brood-id for monitoring (hatchery references its own brood-id).
- [ ] Brood manifest written to `.hivemind/broods/<brood-id>/manifest.json` as
      `manifest_version: 4` (JSON integer) — carrying a top-level `hatchery`
      block (`run_id`, `ledger`, `workflow`) and a per-strain `run` block
      (`suggested_id`, `workflow_hint`) alongside the v1 fields. Parsed
      exclusively by jq (machine consumer); no YAML back-compat.
- [ ] Each strain has a worktree + branch off `base`, a detached tmux session
      `<brood-id>-<short>` running claude, and its injected `task.md` — which
      emits the data-boundary preamble FIRST, THEN the YAML child-task metadata
      block (`parent`, `strain`, `run`, `instructions`), THEN the description.
      The engine submits the task with a settle after the bracketed paste closes
      then a single Enter, so the submit keystroke lands as a submit instead of
      racing the paste. It then polls the child's on-disk run-ledger `state.current`
      for started-evidence within a short per-attempt deadline; if no started-evidence
      is observed it resends Enter (idempotent — task text is already buffered, never
      re-pasted) up to a bounded retry cap. On cap exhaustion the strain is marked
      `failed` (failed-to-launch) in the manifest, distinguishable in
      `hivemind:brood-status` from the transient `starting` state. Verification reads
      the child run-ledger `state.current` as ground truth — capture-pane is not used
      (architectural direction established in #213/#248). Whether a child actually
      completed turn-start is also observed independently by `hivemind:brood-status`
      from run-ledger ground truth (child run `state.current` present => `running`,
      absent => `starting`), not only by spawn-brood.
- [ ] `.claude/worktrees/` is excluded from git (the script self-guards).
- [ ] Final action is the Bash script call (exit 0 = spawned, exit 1 = blocked).

The manifest is a registry/coordination artifact, NOT the source of truth for
child workflow state — that lives in each child's own JSON run ledger. The
`hatchery.ledger` path only POINTS at the hatchery ledger; this skill never
creates a child or hatchery ledger. Full shape and status-derivation rules:
`${CLAUDE_PLUGIN_ROOT}/references/brood-ledger-model.md`.

## Required Inputs

The caller resolves and passes these; the skill does not resolve them.

- `strains`: array of `{name, description}` — one element per cerebrate
  `Strains` plan-artifact entry. Each strain MAY also carry an optional
  `workflow_hint` (a non-binding suggestion for the child's router; defaults to
  `standard-delivery` when omitted). Per-strain `branch` is NOT supplied —
  the script derives it as `strain/<brood-id>/<short>`.
- `base`: resolved trunk/base branch; each strain worktree branches off it.
- `overlap_risk`: `low | medium | high`.
- `overlap_details`: planner overlap-assessment text.
- `hatchery` (OPTIONAL): `{run_id, workflow}` for the coordinator's own run
  ledger. `run_id` defaults to `<brood_id>-hatchery`; `workflow` defaults to
  `hatchery-dispatch`. These only POINT at the hatchery ledger the coordinator
  owns — the script never creates it.

`brood_id` is NOT supplied — the script generates it internally as
`brood-<uuidv4>` and prints it on stdout.

## Procedure

1. **Build the inputs object** in your reasoning from the Required Inputs.
   Exact shape:

   ```json
   {
     "base": "<resolved trunk/base branch>",
     "overlap_risk": "low | medium | high",
     "overlap_details": "<planner overlap-assessment text>",
     "hatchery": {
       "run_id": "<optional; defaults to <brood_id>-hatchery>",
       "workflow": "<optional; defaults to hatchery-dispatch>"
     },
     "strains": [
       {
         "name": "<strain name>",
         "description": "<task description — may be GitHub-issue-sourced>",
         "workflow_hint": "<optional; defaults to standard-delivery>"
       }
     ]
   }
   ```

   Field rules:
   - `strains` MUST be a non-empty array — a zero-strain array is a blocker.
   - `base`, `overlap_risk`, `overlap_details` are required top-level scalars.
   - Do NOT include `brood_id` — the script generates it internally; any
     caller-supplied value is ignored.
   - Each strain requires `name` and `description`; `workflow_hint` is optional.
     Do NOT include a per-strain `branch` — the script derives it as
     `strain/<brood-id>/<short>`; any caller-supplied value is ignored.
   - `hatchery` is optional; both its fields default when omitted.
   - `name` is sanitized to `short` (`[a-z0-9-]`) for the worktree path
     (`.claude/worktrees/<brood-id>/<short>`) and tmux session
     (`<brood-id>-<short>`). Two names that sanitize to the same `short` are an
     in-set collision and a blocker.
   - Every value is data. None is interpolated into generated shell command source.

2. **Write the inputs file** via the Write tool to a per-invocation mktemp-unique
   staging path under `.hivemind/` (e.g. `.hivemind/spawn-inputs.<rand>.json`).
   Use the Write tool's `file_path` parameter for that unique path; set `content`
   to the JSON object from step 1. Write performs no shell parsing of the values,
   so untrusted description text is inert. Do NOT use a fixed singleton path —
   concurrent spawns must not clobber each other's staging file.

3. **Execute the script** with one Bash call, passing the staging path as `$1`:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/spawn-brood/scripts/spawn-brood.sh <staging-path>
   ```
   EXECUTE (do not Read) the script — it owns every deterministic step: dependency
   checks, input validation, pre-flight collision/exclude/base checks, brood-id
   generation, per-brood state-dir creation, staging-file relocation, two-pass
   spawn (create+launch, then ready-poll+inject), manifest emission, and cleanup.

4. **Capture the generated brood-id** from stdout: on exit 0 the script prints
   `brood_id: <id>` then `manifest: <abs path>`. Capture `brood_id` — the
   coordinator needs it to monitor the brood (hatchery references its own brood-id).
   Exit 1: the script printed a `blocker: <reason>` (and, for partial failures,
   a `manifest: <abs path>` and `brood_id: <id>`) on stderr — surface it and stop.

## Pointers

- EXECUTE (do not read) the engine:
  `${CLAUDE_PLUGIN_ROOT}/skills/spawn-brood/scripts/spawn-brood.sh`.

## Silence Discipline

This is a pipeline skill:

- Produce zero chat text during execution. Outputs are tool calls only.
- The Write tool (step 2) is a permitted NON-FINAL tool call — it emits no chat
  text. The final action is the Bash script call (step 3).
- Exit 0 = caller proceeds; routing data (`brood_id:` and `manifest:` lines)
  is on stdout. Exit 1 = blocked; the reason is on stderr.

## Do Not

- do not rely on `claude --worktree` for branch/worktree creation — the script
  creates worktrees explicitly via `git worktree add -b <exact strain branch>`.
- commit, push, or open a PR.
- modify any product files.
- invent values for `strains`, `base`, `overlap_risk`, or `overlap_details` —
  the script exits 1 with a blocker if any are missing.
- supply `brood_id` or per-strain `branch` in the inputs — the script generates
  and derives both internally; caller-supplied values are ignored.
- Read or reconstruct the script body — invoke it with the documented argument.
