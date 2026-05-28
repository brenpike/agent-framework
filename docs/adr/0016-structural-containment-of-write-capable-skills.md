# Write-capable user-driven skills are structurally contained by tool capability and spawn topology

**Status:** accepted — 2026-05-27

User-driven skills that carry `Write`/`Edit` in `allowed-tools` (e.g. `tdd`, `refactor-to-depth`) cannot mutate source outside the branch → checkpoint → review → PR lifecycle. Containment is structural — a property of agent tool grants and spawn topology — not an advisory rule, so no per-skill governance preflight is needed and the invariant covers all present and future write/edit skills.

## Context

The `refactor-to-depth` local review raised: can a write-capable skill the user invokes mutate product code outside the governed lifecycle? `refactor-to-depth` and `tdd` run tight write→test→edit→test loops, so they must edit locally; the question is whether that escapes governance. This ADR records why it structurally cannot.

## Decision

1. A skill is loaded instructions executing in the **invoking agent's** context, using that agent's `tools:`. `allowed-tools` only pre-approves (skips permission prompts) for tools the agent already holds; it never grants a capability the agent lacks.
2. The user reaches only the orchestrator (`hivemind:overlord`), whose `tools:` are `Read, Bash, Skill, Monitor, Agent(...)` — no `Write`, no `Edit`. A write/edit skill invoked at the orchestrator level physically cannot mutate files; its write intent routes through the orchestrator's normal delegate-to-executor lifecycle (git preflight → working branch → drone/changeling).
3. Write-capable executors (`hivemind:drone`, `hivemind:changeling`) are spawned only by the orchestrator, after git preflight, inside an established working branch. Loop-heavy write skills run **inside** such a delegated executor — the orchestrator delegates the whole task and the executor runs the loop locally — because ping-ponging each micro-write through the orchestrator would lose working state.
4. Therefore no user-reachable write-capable context exists outside the lifecycle. Containment follows from tool capability plus spawn topology, so no per-skill governance preflight is required.
5. Boundary: outside hivemind (a raw host session invoking the skill directly), the host framework owns governance; the skills stay portable and assume no lifecycle.

## Consequences

- No per-skill governance preflight is needed; the invariant generalizes to every current and future write/edit skill without per-skill review.
- The portability boundary (point 5) holds: the skills carry no hivemind lifecycle assumptions, so a raw-host invocation is governed by that host, not this plugin.
- `plugin/governance/security-policy.md` references this ADR as the rationale for treating write-capable skills as contained.
