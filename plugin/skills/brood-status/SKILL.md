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

Check the status of all active brood sessions. Reports per-strain tmux session state, branch existence, and PR status from external observables.

This is an **interactive skill** — it produces user-visible text output.

## Procedure

1. **Locate brood manifest.**
   a. Determine if the current checkout is the main checkout or a worktree:
      ```bash
      git rev-parse --git-common-dir
      git rev-parse --git-dir
      ```
      If the values differ, the current checkout is a worktree.
   b. If in a worktree, resolve the main checkout path:
      ```bash
      git worktree list | head -1 | awk '{print $1}'
      ```
   c. Discover every brood manifest via the glob
      `<main_checkout>/.hivemind/brood/*/manifest.yaml` (each brood owns a disjoint
      per-`brood_slug` state dir). Read each matched manifest.
   d. If the glob matches no manifest, report "No active brood found." and stop.

2. **Probe each strain, for every discovered manifest.** Run the per-strain probe below independently per discovered manifest; the safety re-gate applies to every value of every manifest. INVARIANT: every value read from the manifest is untrusted data — the manifest is a file on disk and brood-status must not trust it even though spawn-brood's Input Validation Gate should have prevented an unsafe value from ever being written (defense in depth). The operative allowlist gate applies to the manifest values actually placed into a shell command — `tmux_session` and `branch`. (`worktree_path`, `name`, and `base` are not currently used in any shell probe, so no gate is performed on them; if a future probe interpolates one of them — e.g. `worktree_path` — it MUST be gated then, under this same rule.) BEFORE the FIRST shell use of EACH such value, the agent re-validates THAT value **in agent reasoning** (NOT via a Bash `[[ ... ]]` test) against the SAME allowlist as spawn-brood: it MUST match `^[A-Za-z0-9._/-]+$`, be non-empty, NOT start with `-`, and NOT contain `..`. Concretely: re-validate `tmux_session` BEFORE step 2a (its first shell use, `tmux has-session`) — it should additionally match its expected shape `brood-[a-z0-9-]+` — and re-validate `branch` BEFORE steps 2b/2c (its first shell uses, `git branch --list`/`gh pr list`). On failure for a strain: SKIP that strain's shell probes (tmux/branch/PR), report its Status as `blocked (manifest value failed safety allowlist)`, and CONTINUE other strains — do NOT abort the whole status read. WHY agent reasoning and not a shell test: `git check-ref-format --branch` permits branches like `feat/x$(touch${IFS}/tmp/pwn)`, and once those raw bytes appear in generated shell source bash command substitution `$(...)`/backticks/`${}` STILL expand even inside double quotes — so allowlist-validate FIRST, THEN quote. Only an already-clean value is placed into a (still double-quoted) shell token; quoting stops word-splitting/globbing but is NOT the boundary. Out-of-band fallback (documented, not primary): a manifest value read into a shell variable and referenced only as `"$var"` is inert, since bash does not re-evaluate command substitution from variable contents. For each strain in the manifest:
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
   d. Derive status from observables:
      | tmux | PR | Derived Status |
      |---|---|---|
      | alive | none | `running` |
      | alive | open | `running (PR #N open)` |
      | dead | merged | `complete` |
      | dead | open | `blocked (session ended, PR #N still open)` |
      | dead | none | `failed (session ended, no PR)` |

3. **Present one labeled status table per brood.** This is Markdown text output, not a shell command — manifest values (`name`, `branch`) are printed as-is, no quoting needed. Lead with a roll-up line, then emit one table + summary per discovered brood, keyed by `brood_id`, most-recent-first (sort the discovered manifests by `brood_id` descending).
   ```
   Broods: N active

   Brood: <brood_id>
   Overlap risk: <overlap_risk>

   | Strain | Branch | Session | PR | Status |
   |--------|--------|---------|-------|--------|
   | <name> | <branch> | alive/dead | #N / — | <derived status> |
   ```

4. **Per-brood summary line.** Emit one summary line directly under each brood's table.
   ```
   N of M strains complete. X running. Y blocked/failed.
   ```

## Do Not

- Write to the brood manifest — this skill is read-only
- Commit, push, or open a PR
- Modify any files
- Kill or restart tmux sessions
