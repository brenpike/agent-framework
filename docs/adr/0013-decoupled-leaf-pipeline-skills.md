# Pipeline skills are decoupled leaf transforms

**Status:** accepted — 2026-05-25 (clarified 2026-05-26)

The three new meta-pipeline skills (`hivemind:create-handoff`, `hivemind:plan-to-prd`, `hivemind:prd-to-issues`) form a conceptual pipeline but do not chain by referencing or invoking each other. Each is an independently-invocable leaf transform. Composition, if ever wanted, is the job of a separate future orchestrator skill — not of the leaves.

## Context

The three new skills read as a sequence: an interrogated plan becomes a PRD, the PRD becomes vertically-sliced issues, and a handoff can bridge any session boundary along the way. The design question is whether they should chain mechanically — one skill referencing or invoking the next — or stay independent. Mechanical chaining would couple the stages: a single stage could not run standalone, mid-pipeline resumability (a locked decision — every stage accepts its artifact from live context OR a persisted file plus an optional handoff) would break, and a change to one skill would ripple into the others.

## Decision

No skill references or invokes another. Each is an independently-invocable leaf transform consuming explicit, session-agnostic inputs (live context OR a persisted file, plus an optional handoff). Composition, if ever desired, is a *separate* future orchestrator skill (e.g. `idea-to-issues`) that calls each leaf in succession and owns the coupling. The stage-transition decision — including whether to offer a handoff at a stage boundary — is driven by the overlord or the Overmind, never embedded as a prompt inside a stage skill.

**Decoupling forbids dependency, not intent.** "No skill references or invokes another" means a skill must not name, hard-call, or depend on a specific `hivemind:<skill>`. It does NOT mean a skill should avoid describing the work to be done. A skill SHOULD express its intent clearly (e.g. "pin the current behavior with tests", "harden this candidate"); the framework's own skill-selection may then route that intent to an appropriate skill when it matches. This is **composition by intent**, not coupling — it creates no dependency, survives the target skill's absence (Claude does the work inline), and keeps each skill generic and reusable. Expressing intent that happens to match another skill's triggers is encouraged.

## Considered Options

| Option | Rejected because |
|---|---|
| Built-in chaining (e.g. `plan-to-prd` auto-invokes `create-handoff` or `prd-to-issues`) | Tight coupling; cannot run a single stage standalone; breaks mid-pipeline resumability; a change in one skill ripples into the others |
| Decoupled leaf transforms (chosen) | Each skill independently invocable and testable; a future orchestrator can add composition without touching the leaves |

## Consequences

- Each skill is independently invocable and testable in isolation
- Human / natural-language flow drives stage transitions today; there is no built-in automation between stages
- A future orchestrator skill can add end-to-end automation without modifying the leaves — it owns the coupling
- The decoupling is enforced by skill design and intent-expression convention, NOT by tooling: a skill's `allowed-tools` only *pre-approves* tools (skips permission prompts) and cannot restrict a skill — every tool remains callable and permission settings still govern. If hard blocking of cross-skill invocation were ever required, it would be done via Claude Code `permissions` deny rules, not skill frontmatter.
- The stage-end handoff offer is overlord/human-driven, never a skill-embedded prompt
- Skills compose by intent: a skill expressing work-intent that the framework may match to another skill is sanctioned and creates no dependency — only naming or invoking a specific `hivemind:<skill>` is forbidden
