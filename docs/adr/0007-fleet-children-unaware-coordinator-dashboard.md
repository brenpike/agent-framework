# Fleet children are unaware; coordinator is a status dashboard

**Status:** accepted — 2026-05-22

Fleet child orchestrator sessions run as standard orchestrator instances with no fleet awareness. The coordinator orchestrator serves as a status dashboard and on-demand helper, not a merge orchestrator or version coordinator.

## Context

The fleet feature enables parallel orchestrator execution across git worktrees. The core architecture question: how much should child sessions know about the fleet, and how much should the coordinator manage?

Two coordination problems exist: (1) merge conflicts when parallel PRs target the same trunk, and (2) version bump conflicts when multiple streams modify the same version file. Both could be solved by centralized coordination (coordinator manages merge order and version bumps) or by independence (each child handles its own, conflicts resolved as they arise).

## Decision

Child orchestrator sessions receive a stream description as their task input via `tmux send-keys`. They run the standard orchestrator pipeline — planner, branch, implement, version bump, review, PR — with no knowledge that peer sessions exist. No fleet-specific code paths in the orchestrator agent.

The coordinator orchestrator's responsibilities after dispatch:
1. Monitor fleet status on demand (fleet-status skill)
2. Help with rebases or other tasks on user request
3. Report aggregate status when all streams complete

The coordinator does NOT:
- Automatically rebase branches after a peer PR merges
- Coordinate version bump ordering or ownership
- Manage merge sequencing
- Write to child worktrees

## Why this works

The planner's decomposition into streams is designed to minimize file-scope overlap. When overlap is minimal, merge conflicts are rare and version bump conflicts are simple rebases. This matches how human teams operate — developers work independently, handle conflicts as they arise, and don't coordinate merge order through a central authority.

## Considered Options

| Option | Rejected because |
|---|---|
| Children report status to shared manifest | Requires fleet awareness in orchestrator agent; concurrent writes to manifest; coupling |
| Coordinator manages merge sequence (rebase after each merge) | Cannot safely rebase a worktree while its child session is active; adds complex phasing (active vs merge phase) |
| Coordinator owns all version bumps (children skip step 7) | Requires children to know they should skip step 7; adds post-fleet coordination step; doesn't match how human teams version |
| Children coordinate with each other via shared state | Peer-to-peer coordination between LLM sessions has no proven pattern; massive complexity for marginal benefit |

## Consequences

- Child orchestrator agent definition is unchanged — zero fleet-specific code paths
- Merge conflicts are possible but expected to be rare given planner decomposition quality
- Version bump races are possible — second PR to merge rebases and adjusts version, same as a human developer would
- Coordinator mode is simple: dispatch + monitor + help on request
- If planner decomposition is poor (high file overlap), fleet UX degrades to manual conflict resolution — this is a planner quality signal, not a fleet architecture failure
