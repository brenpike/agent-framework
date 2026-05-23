# Brood children are unaware; hatchery is a status dashboard

**Status:** accepted — 2026-05-22

> Terminology note (2026-05-23): This ADR predates the brood/strain/hatchery glossary migration. The decision is unchanged; "fleet"→"brood", "stream"→"strain", and "coordinator (mode)"→"hatchery" throughout. The filename is retained as an immutable historical identifier.

Brood child orchestrator sessions run as standard orchestrator instances with no brood awareness. The hatchery orchestrator serves as a status dashboard and on-demand helper, not a merge orchestrator or version coordinator.

## Context

The brood feature enables parallel orchestrator execution across git worktrees. The core architecture question: how much should child sessions know about the brood, and how much should the hatchery manage?

Two coordination problems exist: (1) merge conflicts when parallel PRs target the same trunk, and (2) version bump conflicts when multiple strains modify the same version file. Both could be solved by centralized coordination (hatchery manages merge order and version bumps) or by independence (each child handles its own, conflicts resolved as they arise).

## Decision

Child orchestrator sessions receive a strain description as their task input via `tmux send-keys`. They run the standard orchestrator pipeline — planner, branch, implement, version bump, review, PR — with no knowledge that peer sessions exist. No brood-specific code paths in the orchestrator agent.

The hatchery orchestrator's responsibilities after dispatch:
1. Monitor brood status on demand (brood-status skill)
2. Help with rebases or other tasks on user request
3. Report aggregate status when all strains complete

The hatchery does NOT:
- Automatically rebase branches after a peer PR merges
- Coordinate version bump ordering or ownership
- Manage merge sequencing
- Write to child worktrees

## Why this works

The planner's decomposition into strains is designed to minimize file-scope overlap. When overlap is minimal, merge conflicts are rare and version bump conflicts are simple rebases. This matches how human teams operate — developers work independently, handle conflicts as they arise, and don't coordinate merge order through a central authority.

## Considered Options

| Option | Rejected because |
|---|---|
| Children report status to shared manifest | Requires brood awareness in orchestrator agent; concurrent writes to manifest; coupling |
| Hatchery manages merge sequence (rebase after each merge) | Cannot safely rebase a worktree while its child session is active; adds complex phasing (active vs merge phase) |
| Hatchery owns all version bumps (children skip step 7) | Requires children to know they should skip step 7; adds post-brood coordination step; doesn't match how human teams version |
| Children coordinate with each other via shared state | Peer-to-peer coordination between LLM sessions has no proven pattern; massive complexity for marginal benefit |

## Consequences

- Child orchestrator agent definition is unchanged — zero brood-specific code paths
- Merge conflicts are possible but expected to be rare given planner decomposition quality
- Version bump races are possible — second PR to merge rebases and adjusts version, same as a human developer would
- Hatchery mode is simple: dispatch + monitor + help on request
- If planner decomposition is poor (high file overlap), brood UX degrades to manual conflict resolution — this is a planner quality signal, not a brood architecture failure
