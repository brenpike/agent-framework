---
name: brood-status
description: Check status of all active brood sessions. Reports per-strain tmux session state, branch existence, and PR status from external observables. Trigger: "brood status", "check brood", "brood-status", "brood progress", "how's the brood", "fleet status".
allowed-tools:
  - Bash(tmux *)
  - Bash(git worktree *)
  - Bash(git branch *)
  - Bash(gh pr *)
  - Bash(git rev-parse *)
  - Bash(cat *)
shell: bash
---

# Brood Status

Check the status of all active brood sessions. Reports per-strain tmux session state, branch existence, and PR status from external observables, plus the manifest's static fields.

This is an **interactive skill** — it produces user-visible text output.

> Child-ledger workflow-state reporting is DEFERRED to issue #161. This skill does NOT open, `Read`, or `jq`-project any child `state.json`; it reports each strain's status ONLY from external observables (tmux/branch/PR) and the manifest's static fields. The manifest still carries `run.*` pointers for that future feature, and children still own and write their own ledgers — brood-status simply does not consume them.

## Procedure

1. **Locate brood manifest.**
   a. Determine if the current checkout is the main checkout or a worktree:
      ```bash
      git rev-parse --git-common-dir
      git rev-parse --git-dir
      ```
      If the values differ, the current checkout is a worktree.
   b. Resolve the current checkout root (the directory containing `.hivemind/`):
      ```bash
      git rev-parse --show-toplevel
      ```
      In a linked worktree `--show-toplevel` returns the child worktree's working-tree
      root directly. (`--git-dir` / `--git-common-dir` point at metadata under the
      main `.git/worktrees/<name>/` tree and must NOT be used here — stripping a
      trailing `/.git` from that path does not yield the child checkout root.)
   c. Check whether the current checkout has its own brood manifest at
      `<current_checkout>/.hivemind/brood/manifest.yaml`. Manifest lookup
      precedence (single manifest selected, not multi-glob):
      - **First:** current checkout's manifest, if present. This handles
        recursive-brood / linked-worktree cases where a spawned child overlord
        launched its own brood; that nested manifest lives under the child's
        worktree, not the outer main checkout.
      - **Fallback:** if the current checkout has no manifest (i.e. the caller
        is the outer coordinator or a non-hatchery worktree), resolve the main
        checkout path:
        ```bash
        git worktree list | head -1 | awk '{print $1}'
        ```
        and read `<main_checkout>/.hivemind/brood/manifest.yaml`.
   d. If neither manifest exists, report "No active brood found." and stop.

2. **Probe each strain.** There is exactly one brood; run the per-strain probe below for each strain in the manifest. INVARIANT: every value read from the manifest is untrusted data — the manifest is a file on disk and brood-status must not trust it even though spawn-brood's Input Validation Gate should have prevented an unsafe value from ever being written (defense in depth). The operative allowlist gate applies to the manifest values actually placed into a shell command — `tmux_session` and `branch`. (`worktree_path`, `name`, and `base` are not currently used in any shell probe, so no gate is performed on them; if a future probe interpolates one of them — e.g. `worktree_path` — it MUST be gated then, under this same rule.) BEFORE the FIRST shell use of EACH such value, the agent re-validates THAT value **in agent reasoning** (NOT via a Bash `[[ ... ]]` test) against the SAME allowlist as spawn-brood: it MUST match `^[A-Za-z0-9._/-]+$`, be non-empty, NOT start with `-`, and NOT contain `..`. Concretely: re-validate `tmux_session` BEFORE step 2a (its first shell use, `tmux has-session`) — it should additionally match its expected shape `^brood-[a-z0-9-]+$` (the producer emits `brood-<short>`) — and re-validate `branch` BEFORE steps 2b/2c (its first shell uses, `git branch --list`/`gh pr list`). On failure for a strain: SKIP that strain's shell probes (tmux/branch/PR), report its Status as `blocked (manifest value failed safety allowlist)`, and CONTINUE other strains — do NOT abort the whole status read. WHY agent reasoning and not a shell test: `git check-ref-format --branch` permits branches like `feat/x$(touch${IFS}/tmp/pwn)`, and once those raw bytes appear in generated shell source bash command substitution `$(...)`/backticks/`${}` STILL expand even inside double quotes — so allowlist-validate FIRST, THEN quote. Only an already-clean value is placed into a (still double-quoted) shell token; quoting stops word-splitting/globbing but is NOT the boundary. Out-of-band fallback (documented, not primary): a manifest value read into a shell variable and referenced only as `"$var"` is inert, since bash does not re-evaluate command substitution from variable contents. For each strain in the manifest:
   a. Check tmux session alive:
      ```bash
      tmux has-session -t "<tmux_session>" 2>/dev/null
      ```
      Exit 0 = alive. Non-zero = dead.
   b. Check branch exists:
      ```bash
      git branch --list "<branch>"
      ```
      Non-empty output = exists.
   c. Check PR state:
      ```bash
      gh pr list --head "<branch>" --state all --json number,state --jq '.[0] // empty'
      ```
      If `gh` fails (not authenticated, rate-limited, etc.), report PR status as "unknown".
   d. **Child-ledger workflow-state reporting is DEFERRED to issue #161.** Do NOT open,
      `Read`, or `jq`-project this strain's `run.suggested_ledger` (or any child `state.json`).
      brood-status reports `Workflow State` as `deferred (#161)` for every strain and derives
      status from external observables + manifest static fields alone. The manifest's `run.*`
      pointers are read-only static fields the skill carries forward but does not consume.
   e. Derive status from observables. **Status-derivation priority (highest first):**
      1. **External observables** (tmux session, branch existence, PR state) — ground
         truth.
      2. **Manifest static fields** — last resort.

      The manifest `status:` field takes precedence over the alive-session inference for
      the `failed` case: a strain recorded as `status: failed` in the manifest is reported
      as `failed` regardless of whether its tmux session is still alive (spawn-brood
      deliberately leaves the session alive on injection failure for debugging).
      Apply in this order:
      1. If manifest `status:` is `failed` → `failed (injection failed; session alive for debug)` when tmux is alive, or `failed (session ended, no PR)` when tmux is dead.
      2. Otherwise derive from tmux + PR observables, then refine with the child ledger:

      | tmux | PR | Derived Status |
      |---|---|---|
      | alive | none | `running` |
      | alive | open | `running (PR #N open)` |
      | dead | merged | `complete` |
      | dead | open | `blocked (session ended, PR #N still open)` |
      | dead | none | `failed (session ended, no PR)` |

      Status is derived from observables alone; the `Workflow State` column always reads
      `deferred (#161)` (child-ledger consumption is deferred — see step 2d).

3. **Present the status table.** This is Markdown text output, not a shell command — manifest values (`name`, `branch`) are printed as-is, no quoting needed. Emit a single status table for the brood.
   ```
   | Strain | Branch | Session | PR | Workflow State | Status |
   |--------|--------|---------|----|----------------|--------|
   | <name> | <branch> | alive/dead | #N / — | deferred (#161) | <derived status> |
   ```

4. **Per-strain summary line.** Emit one summary line directly under the table.
   ```
   N of M strains complete. X running. Y blocked/failed.
   ```

## Do Not

- Write to the brood manifest — this skill is read-only
- Commit, push, or open a PR
- Modify any files
- Kill or restart tmux sessions
