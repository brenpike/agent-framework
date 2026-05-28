# Architecture analysis is a read-only skill that emits a decoupled refactoring-blueprint artifact

**Status:** accepted — 2026-05-26

`hivemind:improving-architecture` is a read-only analysis skill that emits a path-agnostic refactoring-blueprint artifact (inline Markdown) of ranked deepening candidates (shallow → deep modules). A separate downstream consumer acts on that artifact — the same pattern as `plan-to-prd` → `prd-to-issues` (ADR-0013) — with no bespoke architecture routing in the overlord. It is NOT a do-everything analyze-and-refactor agent: it does not edit code, does not author CONTEXT.md/ADRs, does not spawn agents, and does not produce a runnable plan. It is a member of the same family as `hivemind:zoom-out` and `hivemind:bootstrap-context` — analysis in, Markdown out.

## Context

The skill is ported from Matt Pocock's `improve-codebase-architecture` skill, which bundles analysis, multi-design exploration, an HTML report artifact, and refactoring into one capability. That shape collides with hivemind's invariants:

- **The overlord never implements** — only `hivemind:drone`/`hivemind:changeling` edit product code, and `hivemind:cerebrate` is read-only. A skill that both analyzes and refactors would have to either edit code (violating the analysis role) or smuggle implementation through the wrong agent.
- **One plan = one branch = one PR.** A skill that decides on a design AND drives its implementation would own state that belongs to the overlord's git lifecycle.
- **Bash Command Discipline forbids out-of-cwd and HTML temp writes**, so the upstream skill's HTML report artifact is not portable into this plugin.
- CONTEXT.md/ADR authorship and adversarial design hardening already have an owner: `hivemind:plan-interrogation`.

The design question was how much of the upstream skill to keep, and where each dropped responsibility should land.

## Decision

`hivemind:improving-architecture` does exactly one thing: read-only architecture analysis that emits a **path-agnostic refactoring blueprint** artifact (inline Markdown) of ranked deepening candidates (shallow → deep modules). It does not edit code, write docs/ADRs, spawn agents, or perform the refactor. The blueprint is a decoupled artifact consumed downstream — the SAME pattern as `plan-to-prd` → `prd-to-issues` (ADR-0013): a producer skill emits an artifact; a separate consumer acts on it; the overlord/human chains them. This makes architecture analysis a member of the path-agnostic artifact-transform family established by ADR-0012, not a bespoke orchestration capability.

- **HTML report dropped** in favor of inline Markdown — Bash Command Discipline forbids out-of-cwd/HTML temp writes, and Markdown composes as a path-agnostic artifact (ADR-0012).
- **No bespoke fast path.** The skill returns a blueprint; a chosen candidate enters the overlord's NORMAL pipeline like any other task. There is no architecture-specific routing in the overlord.
- **The planned consumer is `hivemind:refactor-to-depth`** (drone-invoked, performs the deepening). One asymmetry vs `prd-to-issues`: `refactor-to-depth` edits product code, so its executor runs inside the overlord's git lifecycle (branch → checkpoint → validate → version → review → PR). The artifact-consumption model still holds — the producer stays read-only and the executor stays governed.
- **Hardening is OPTIONAL, not forced.** The blueprint's generic "Next steps" already recommends hardening (e.g. via `hivemind:plan-interrogation`) before implementing; the overlord/operator decides. The skill stays framework-agnostic — no orchestration prose, no agent names in its body.
- **CONTEXT.md/ADR authorship and adversarial grilling remain with `hivemind:plan-interrogation`**, which is reclassified from user-invoked-only to ALSO overlord-invocable — a general capability, not architecture coupling.
- **Multi-design exploration deferred to `cerebrate`**, the existing planning owner, rather than re-implemented inside the analysis skill.

## Considered Options

| Option | Rejected because |
|---|---|
| Port the upstream skill whole (analyze + explore designs + HTML report + refactor) | Violates overlord-never-implements and read-only-analysis invariants; HTML artifact breaks Bash Command Discipline; duplicates `cerebrate` planning and `plan-interrogation` hardening |
| Bespoke architecture fast path: overlord always invokes the skill, then always hardens an accepted candidate via `plan-interrogation` before `cerebrate`, with no gate | Adds architecture-specific orchestration prose to the overlord and couples the skill to a fixed downstream sequence; diverges from the path-agnostic artifact-transform pattern (ADR-0012/0013) the rest of the plugin uses |
| Read-only blueprint as a decoupled artifact in the path-agnostic transform family (chosen) | Producer emits a path-agnostic blueprint; a separate consumer (`hivemind:refactor-to-depth`) acts on it; the overlord/human chains them — same shape as `plan-to-prd` → `prd-to-issues`. No bespoke fast path; hardening is optional/normal; the skill stays framework-agnostic |

## Consequences

- `hivemind:improving-architecture` joins the `zoom-out`/`bootstrap-context` analysis family AND the path-agnostic artifact-transform family (ADR-0012/0013) — read-only, Markdown blueprint out, no code edits, no orchestration prose, no agent names in its body.
- The blueprint is a decoupled artifact: a chosen candidate enters the overlord's NORMAL pipeline like any other task. There is NO bespoke architecture fast path in the overlord.
- The planned consumer is `hivemind:refactor-to-depth` (drone-invoked). Because it edits product code, its executor runs inside the overlord's git lifecycle (branch → checkpoint → validate → version → review → PR) — the one asymmetry vs `prd-to-issues`, whose consumer only writes issues. The artifact-consumption model holds; the executor stays governed.
- Hardening (e.g. via `hivemind:plan-interrogation`) is OPTIONAL and operator-decided — the blueprint's "Next steps" recommends it before implementing, but nothing forces it. No size gate exists because no automatic invocation exists.
- `hivemind:plan-interrogation` is reclassified overlord-invocable as a general capability (not architecture coupling); its interactivity is unchanged (it still grills the user question-by-question regardless of trigger).
- A future need for parallel multi-design exploration is handled by `cerebrate`, not by growing this skill.

This supersedes the prior ADR-0014 statements that the overlord ALWAYS invokes `plan-interrogation` on an accepted candidate and that an accepted blueprint candidate always passes through `plan-interrogation` before `cerebrate` with no gate. The decoupled artifact-transform model replaces the bespoke architecture fast path.

---

## Naming update (2026-05-27)

The `bootstrap-context` skill referenced in this ADR has been renamed to `creep-spread`. The substantive decision recorded here (read-only blueprint architecture-analysis skill) is unchanged; only the skill identifier rotated. Legacy invocations continue to match via trigger aliases.
