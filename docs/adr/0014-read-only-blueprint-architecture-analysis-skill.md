# Architecture analysis is a read-only blueprint skill feeding the standard pipeline

**Status:** accepted — 2026-05-26

`hivemind:improving-architecture` is a read-only analysis skill that emits a Markdown refactoring blueprint of ranked deepening candidates (shallow → deep modules) and then feeds the existing overlord pipeline. It is NOT a do-everything analyze-and-refactor agent: it does not edit code, does not author CONTEXT.md/ADRs, does not spawn agents, and does not produce a runnable plan. It is a member of the same family as `hivemind:zoom-out` and `hivemind:bootstrap-context` — analysis in, Markdown out.

## Context

The skill is ported from Matt Pocock's `improve-codebase-architecture` skill, which bundles analysis, multi-design exploration, an HTML report artifact, and refactoring into one capability. That shape collides with hivemind's invariants:

- **The overlord never implements** — only `hivemind:drone`/`hivemind:changeling` edit product code, and `hivemind:cerebrate` is read-only. A skill that both analyzes and refactors would have to either edit code (violating the analysis role) or smuggle implementation through the wrong agent.
- **One plan = one branch = one PR.** A skill that decides on a design AND drives its implementation would own state that belongs to the overlord's git lifecycle.
- **Bash Command Discipline forbids out-of-cwd and HTML temp writes**, so the upstream skill's HTML report artifact is not portable into this plugin.
- CONTEXT.md/ADR authorship and adversarial design hardening already have an owner: `hivemind:plan-interrogation`.

The design question was how much of the upstream skill to keep, and where each dropped responsibility should land.

## Decision

`hivemind:improving-architecture` does exactly one thing: read-only architecture analysis that emits an inline Markdown **refactoring blueprint** (never called a "plan") of ranked deepening candidates. Everything else is delegated to existing owners:

- **HTML report dropped** in favor of inline Markdown — Bash Command Discipline forbids out-of-cwd/HTML temp writes, and Markdown composes with the rest of the pipeline.
- **CONTEXT.md/ADR authorship and adversarial grilling delegated to `hivemind:plan-interrogation`**, which is reclassified from user-invoked-only to ALSO overlord-invocable. On an accepted blueprint candidate the overlord ALWAYS invokes it — no gate, because it self-right-sizes (trivial candidates converge fast).
- **No agent-spawning.** The skill returns a blueprint; the overlord routes an accepted, hardened candidate into the standard pipeline (`cerebrate` → `drone`/`changeling` → version → validate → review → PR).
- **Multi-design exploration deferred to `cerebrate`**, the existing planning owner, rather than re-implemented inside the analysis skill.

## Considered Options

| Option | Rejected because |
|---|---|
| Port the upstream skill whole (analyze + explore designs + HTML report + refactor) | Violates overlord-never-implements and read-only-analysis invariants; HTML artifact breaks Bash Command Discipline; duplicates `cerebrate` planning and `plan-interrogation` hardening |
| Read-only blueprint skill feeding the standard pipeline (chosen) | One responsibility per component; reuses `plan-interrogation` for hardening and `cerebrate` for planning; Markdown output composes with the existing lifecycle |
| Gate the post-blueprint `plan-interrogation` invocation on candidate size | Unnecessary — `plan-interrogation` self-right-sizes, so trivial candidates converge fast; a gate adds a decision point with no benefit |

## Consequences

- `hivemind:improving-architecture` joins the `zoom-out`/`bootstrap-context` analysis family — read-only, Markdown out, no code edits.
- `hivemind:plan-interrogation` is reclassified overlord-invocable; its interactivity is unchanged (it still grills the user question-by-question regardless of trigger).
- An accepted blueprint candidate always passes through `plan-interrogation` before `cerebrate`, with no size gate.
- Each responsibility (analysis, hardening, planning, implementation) stays with its existing owner; the skill adds no new agent topology.
- A future need for parallel multi-design exploration is handled by `cerebrate`, not by growing this skill.
