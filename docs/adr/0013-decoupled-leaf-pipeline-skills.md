# Pipeline skills are decoupled leaf transforms

**Status:** accepted — 2026-05-25

The three new meta-pipeline skills (`hivemind:create-handoff`, `hivemind:plan-to-prd`, `hivemind:prd-to-issues`) form a conceptual pipeline but do not chain by referencing or invoking each other. Each is an independently-invocable leaf transform. Composition, if ever wanted, is the job of a separate future orchestrator skill — not of the leaves.

## Context

The three new skills read as a sequence: an interrogated plan becomes a PRD, the PRD becomes vertically-sliced issues, and a handoff can bridge any session boundary along the way. The design question is whether they should chain mechanically — one skill referencing or invoking the next — or stay independent. Mechanical chaining would couple the stages: a single stage could not run standalone, mid-pipeline resumability (a locked decision — every stage accepts its artifact from live context OR a persisted file plus an optional handoff) would break, and a change to one skill would ripple into the others.

## Decision

No skill references or invokes another. Each is an independently-invocable leaf transform consuming explicit, session-agnostic inputs (live context OR a persisted file, plus an optional handoff). Composition, if ever desired, is a *separate* future orchestrator skill (e.g. `idea-to-issues`) that calls each leaf in succession and owns the coupling. The stage-transition decision — including whether to offer a handoff at a stage boundary — is driven by the overlord or the Overmind, never embedded as a prompt inside a stage skill.

## Considered Options

| Option | Rejected because |
|---|---|
| Built-in chaining (e.g. `plan-to-prd` auto-invokes `create-handoff` or `prd-to-issues`) | Tight coupling; cannot run a single stage standalone; breaks mid-pipeline resumability; a change in one skill ripples into the others |
| Decoupled leaf transforms (chosen) | Each skill independently invocable and testable; a future orchestrator can add composition without touching the leaves |

## Consequences

- Each skill is independently invocable and testable in isolation
- Human / natural-language flow drives stage transitions today; there is no built-in automation between stages
- A future orchestrator skill can add end-to-end automation without modifying the leaves — it owns the coupling
- Per-skill `allowed-tools` exclude any "invoke `hivemind:*`" capability, enforcing the decoupling mechanically
- The stage-end handoff offer is overlord/human-driven, never a skill-embedded prompt
