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

## Amendment (2026-06-02, #182): nested broods are visible by construction; any orchestrator may be a hatchery

This amendment clarifies the meaning of "children are brood-unaware" and records the brood-status discovery-anchoring decision. It does NOT revise the original Decision or Context above.

1. **"Children brood-unaware" means unaware of being part of a PARENT's brood.** A child orchestrator does not know peer strains exist, does not report to a parent manifest, and carries no brood-specific code paths — exactly as the original Decision states. This does NOT forbid an orchestrator being a hatchery for its OWN brood. Any orchestrator may act as a hatchery: spawn-brood already supports recursive spawn, and an orchestrator dispatching a brood from its own worktree is the same hatchery primitive applied one level down. The two facts compose: a child is unaware of its parent's brood AND may simultaneously own a brood of its own.

2. **brood-status anchors discovery to the CURRENT worktree (`git rev-parse --show-toplevel`).** This is the same anchor `spawn-brood.sh` uses when it writes brood state, so the read side and the write side agree by construction. Each orchestrator-acting-as-hatchery therefore sees the broods it spawned — they live under its own checkout's `.hivemind/broods/`. A child that spawned a sub-brood sees it by running brood-status from its own worktree. Nested broods are visible at each hatchery level by construction: there is no tree-walk and no cross-worktree enumeration — each level sees its direct children. From the main checkout, `show-toplevel` equals the main checkout, so top-level behavior is unchanged.

3. **Security-neutral-to-positive.** The issue #161 read discipline — ground-truth path derivation (the per-strain ledger anchor is the real worktree from `git worktree list --porcelain` keyed by branch; the manifest `worktree_path` is display-only), the `CHECKOUT_ROOT ⊇ git-worktree ⊇ ledger` confinement chain, the bounded two-scalar jq projection with MISSING/MALFORMED tokens, and the informational-only contract that never overrides observable status — applies recursively at every hatchery level, for ANY checkout root. The main coordinator still runs from the main checkout (untouchable by a child), so its ceiling is unchanged; a child-hatchery applies the SAME discipline one level down. spawn-brood already supports recursive spawn, so this change only makes an already-possible nested brood VISIBLE — a monitoring improvement, not a widened boundary. See `${CLAUDE_PLUGIN_ROOT}/governance/security-policy.md` (Trust-Boundary Discipline, boundary 3) and ADR-0021.
