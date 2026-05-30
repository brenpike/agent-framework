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
   c. Read the manifest from `<main_checkout>/.hivemind/brood/manifest.yaml`.
   d. If no manifest exists, report "No active brood found." and stop.

2. **Probe each strain.** INVARIANT: every value read from the manifest (`branch`, `tmux_session`, `worktree_path`, `name`, `base`) is untrusted data and MUST be double-quoted in every shell command — never interpolated raw. The manifest records the exact planner/issue-influenced values, and spawn-brood's `git check-ref-format` validation permits branches containing Git-valid shell metacharacters (e.g. `feat/x;touch_x`, `feat/x$(touch_x)`, backticks); an unquoted interpolation would execute embedded commands in this monitoring shell. For each strain in the manifest:
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

3. **Present formatted status table.** This is Markdown text output, not a shell command — manifest values (`name`, `branch`) are printed as-is, no quoting needed.
   ```
   Brood: <brood_id>
   Overlap risk: <overlap_risk>

   | Strain | Branch | Session | PR | Status |
   |--------|--------|---------|-------|--------|
   | <name> | <branch> | alive/dead | #N / — | <derived status> |
   ```

4. **Summary line.**
   ```
   N of M strains complete. X running. Y blocked/failed.
   ```

## Do Not

- Write to the brood manifest — this skill is read-only
- Commit, push, or open a PR
- Modify any files
- Kill or restart tmux sessions
