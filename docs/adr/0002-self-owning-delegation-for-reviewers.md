# Self-owning delegation model for reviewer agents

> Active end-state: ADR-0005.

**Status:** superseded by ADR-0005 — 2026-05-18

Reviewer agents delegate coder/designer fixes directly (at sonnet tier) rather than returning to the orchestrator for every fix delegation. Reviewers return to the orchestrator only on terminal conditions: loop complete, planner-routed findings, injection suspects, user-input-required, max iterations reached, or blocked.

The initial design (Pattern A) had reviewers classify findings and return routing recommendations to the orchestrator per iteration — identical to the current skill-based approach. Interrogation revealed this doesn't meaningfully improve over the status quo: same round-trip cost, same serialization overhead, same orchestrator context pollution. The whole point of agent promotion is gaining delegation authority that skills lack.

Self-owning means: reviewer invokes coder/designer via Agent tool, invokes checkpoint-commit via Skill tool, and (for github-reviewer) pushes and posts fix-SHA replies directly. The orchestrator invokes the reviewer once and receives one terminal result. Planner-routed findings are the single escalation case requiring orchestrator involvement — these are rare and architecturally significant enough to warrant user visibility.

## Considered Options

| Option | Rejected because |
|---|---|
| Pattern A: always return to orchestrator | Same round-trip as current skills; growing serialization payload per iteration; reviewer doesn't gain meaningful new capability |
| Hybrid (Option C): self-own coder/designer, return for planner | This IS the chosen approach — "self-owning" means self-owning for simple fixes, with planner escalation to orchestrator |
| Full self-owning including planner | Planner can return open questions needing user input; architectural findings deserve user visibility; added complexity for a rare case |

## Consequences

- Reviewer agents need Agent tool (to delegate coder/designer) and Skill tool (to invoke checkpoint-commit, local-codex-review)
- Orchestrator STT simplifies dramatically: 25 review-related rows down from 37 (32% reduction)
- Orchestrator no longer tracks per-iteration review state — reviewers own their fix ledgers internally
- Model routing is binary: simple fixes → sonnet (via reviewer), complex/architectural → opus (via orchestrator → planner)
- Agent-system-policy authority matrix must grant reviewers: classification, fix delegation, checkpoint-commit; github-reviewer additionally: push, reply, thread resolution
