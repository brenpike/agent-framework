# Swap cerebrate and overlord agent names for canon fidelity

**Status:** accepted — 2026-05-23

The coordinator/control-plane agent is renamed `overlord`; the read-only planner is renamed `cerebrate`. The mapping follows StarCraft canon by cognitive function, not command rank. Clean break — no alias or deprecation period.

## Context

Hivemind originally named the coordinator `cerebrate` and the planner `overlord` — inverted relative to StarCraft canon and English etymology. "Cerebrate" denotes the brain/thinker: in canon, cerebrates planned campaigns, adapted strategy, and governed broods. Overlords are psionic relays and command infrastructure — distributed neural processors that route directives, coordinate organisms, and distribute/execute strategy rather than originate it.

Two mapping axes conflict and cannot both be satisfied:

- **Cognitive function:** cerebrate = strategic brain (originates the plan); overlord = psionic router (distributes/executes the plan).
- **Command rank (canon tree):** Overmind → Cerebrate → Overlord → combat organisms. The cerebrate outranks the overlord.

Hivemind's coordinator is the always-on session entry point: the user talks to it first, it owns git/PR lifecycle, and it invokes the planner on demand. Naming the coordinator `overlord` therefore places the overlord operationally above the cerebrate it invokes — inverting the canon rank.

Agent names are the plugin's public API: consumers set `"agent": "hivemind:cerebrate"` in `.claude/settings.json`.

## Decision

Swap the names: coordinator → `overlord`, planner → `cerebrate`. Map canon by **cognitive function, not command rank**.

Frame the relationship as intelligence + execution rather than vertical rank: the **cerebrate** originates the plan (the brain); the **overlord** is the psionic relay that routes the Overmind's directives, consults the cerebrate for the plan, and distributes execution to drones and changelings. This mirrors canon — "cerebrates planned campaigns; overlords served operationally, distributing strategy."

Clean break: no alias, symlink, duplicate file, or migration-notice agent. The migration is a one-line settings edit, documented in the changelog and README.

## Why this works

A creature's defining canon trait is its cognitive function, not its position in a hierarchy. "Cerebrate" literally means to use the brain; a cerebrate that only dispatches is the worst possible mismatch. The overlord's defining trait is being a psionic relay/router. The cognitive mapping captures both essences exactly.

The apparent rank inversion mostly dissolves under correct framing: the coordinator follows the planner's plan — operational authority, strategic deference, like a chief executive consulting a chief strategist. Connective command infrastructure naturally sits at the operational center without outranking the brain it serves.

## Considered Options

| Option | Rejected because |
|---|---|
| Keep names, fix only role descriptions | The names themselves are the mismatch; a coordinating "cerebrate" and a planning "overlord" contradict both canon and etymology |
| Map by command rank (cerebrate stays the coordinator) | Forces a non-thinking cerebrate — the worst mismatch — and would require re-architecting control flow to make the planner the session entry point |
| Alias/redirect the old name to the new agent | Claude Code resolves an agent name directly to a file; there is no alias or redirect mechanism |
| Symlink `cerebrate.md` → `overlord.md` | Untested and likely unsupported by the plugin loader |
| Duplicate the coordinator at both names temporarily | Maintenance burden and confusion; two names for one agent |
| Migration-notice agent at the old name | The agent would load but not function — a silent failure, worse than a clean break |

## Consequences

- **Breaking for consumers.** A stale `"agent": "hivemind:cerebrate"` now boots the read-only planner as the session default. Because the name still resolves, this fails silently rather than erroring. Mitigated by the MAJOR bump and the migration note.
- MAJOR version bump: 1.10.2 → 2.0.0.
- CONTEXT.md drops the canon command-rank arrow; agent relationships are reframed as cognitive function (intelligence + execution).
- README bioform table: 🧠 maps to the Cerebrate (Strategist), 👁 maps to the Overlord (Orchestrator).
- No behavior change — each agent's logic, tools, and governance loads are unchanged; only names and descriptive prose swapped.
