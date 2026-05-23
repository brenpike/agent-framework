---
name: fleet-status
description: Check status of all active fleet sessions. Reports per-stream tmux session state, branch existence, and PR status from external observables. Trigger: "fleet status", "brood status", "check fleet", "fleet progress", "how's the fleet".
allowed-tools:
  - Bash(tmux *)
  - Bash(git worktree *)
  - Bash(git branch *)
  - Bash(gh pr *)
  - Bash(cat *)
  - Read
---

# Fleet Status

Check the status of all active fleet sessions. Reports per-stream tmux session state, branch existence, and PR status from external observables.

This is an **interactive skill** — it produces user-visible text output.

## Procedure

1. **Locate fleet manifest.**
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
   c. Read the manifest from `<main_checkout>/.agent-framework/fleet/manifest.yaml`.
   d. If no manifest exists, report "No active fleet found." and stop.

2. **Probe each stream.** For each stream in the manifest:
   a. Check tmux session alive:
      ```bash
      tmux has-session -t <tmux_session> 2>/dev/null
      ```
      Exit 0 = alive. Non-zero = dead.
   b. Check branch exists:
      ```bash
      git branch --list <branch>
      ```
      Non-empty output = exists.
   c. Check PR state:
      ```bash
      gh pr list --head <branch> --json number,state --jq '.[0] // empty'
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

3. **Present formatted status table.**
   ```
   Fleet: <fleet_id>
   Overlap risk: <overlap_risk>

   | Stream | Branch | Session | PR | Status |
   |--------|--------|---------|-------|--------|
   | <name> | <branch> | alive/dead | #N / — | <derived status> |
   ```

4. **Summary line.**
   ```
   N of M streams complete. X running. Y blocked/failed.
   ```

## Do Not

- Write to the fleet manifest — this skill is read-only
- Commit, push, or open a PR
- Modify any files
- Kill or restart tmux sessions
