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
  - Read
shell: bash
---

# Brood Status

Check the status of all active brood sessions. Reports per-strain tmux session state, branch existence, and PR status from external observables, and — when a `manifest_version: 2` manifest points at a child run ledger that is present — the child's workflow state, read-only.

This is an **interactive skill** — it produces user-visible text output.

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
   d. **Read the child run ledger (read-only), if present.** A `manifest_version: 2`
      manifest records a per-strain `run.suggested_ledger` path pointing at the
      child's own JSON run ledger inside its worktree. Resolve `suggested_ledger`
      for this strain; if the field is absent (an OLD v1 manifest with no `run:`
      block) report `Ledger: unknown` and `Workflow State: unknown` and skip to
      derivation. INVARIANT: a manifest path value is untrusted data — `suggested_ledger`
      is a filesystem path that may legally contain spaces, so it is NOT charset-allowlistable;
      read it ONLY with the `Read` tool (a tool parameter, never interpolated into shell
      command source), never via a `Bash` command. If the file does not exist, report
      `Ledger: missing` and `Workflow State: unknown`. If it exists, read it and derive
      `state.current` (the child's current workflow state) and `run.status` from the JSON
      in agent reasoning. brood-status is READ-ONLY: it MUST NOT write a discovered ledger
      path back to the manifest, MUST NOT mutate the child ledger, and MUST NOT create one.
   e. Derive status from observables. **Status-derivation priority (highest first):**
      1. **External observables** (tmux session, branch existence, PR state) — ground
         truth even when a ledger is stale or absent.
      2. **Child run ledger** (`state.current`, `run.status`) when present — refines the
         status with the child's actual workflow position.
      3. **Manifest static fields** — last resort.

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

      Ledger refinement: when a child ledger is present, append its `state.current`
      to the Workflow State column and let `run.status` sharpen the derived status
      (e.g. ledger `run.status: blocked` reports `blocked` even while the tmux
      session is alive). When the ledger is `missing` for a `dead`+`none` strain,
      report `failed before ledger initialization`. When the ledger is `unknown`
      (v1 manifest with no `run:` field), the table's Ledger and Workflow State
      columns read `unknown` and derivation falls back to observables alone.

3. **Present the status table.** This is Markdown text output, not a shell command — manifest values (`name`, `branch`) are printed as-is, no quoting needed. Emit a single status table for the brood.
   ```
   | Strain | Branch | Session | PR | Ledger | Workflow State | Status |
   |--------|--------|---------|----|--------|----------------|--------|
   | <name> | <branch> | alive/dead | #N / — | present/missing/unknown | <state.current> / unknown | <derived status> |
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
