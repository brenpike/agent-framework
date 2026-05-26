---
name: improving-architecture
description: >-
  Analyzes a codebase read-only and emits a ranked refactoring blueprint of deepening
  opportunities — turning shallow modules (small behaviour behind a large, leaky interface)
  into deep ones for testability and AI-navigability. Use when the user wants to improve
  architecture, find refactoring opportunities, consolidate tightly-coupled modules, make
  the codebase more testable, or make it more AI-navigable. Distinct from zoom-out (which
  maps and orients) and bootstrap-context (which generates the domain glossary): this finds
  and ranks specific refactors but never edits code, writes docs, or spawns agents.
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash(git log *)
  - Bash(git ls-files *)
shell: bash
---

# Improving Architecture

Analyze a codebase and surface architectural friction as **deepening opportunities** — refactors that turn shallow modules (a small amount of behaviour behind a large, leaky interface) into deep ones (a large amount of behaviour behind a small interface). The aim is testability and AI-navigability. The output is a **refactoring blueprint** emitted inline as Markdown.

## Read-only boundary

This skill is strictly read-only analysis. It does NOT:

- edit, refactor, or write any product code;
- write `CONTEXT.md`, `CONTEXT-MAP.md`, or ADRs (that is `hivemind:plan-interrogation`'s job);
- spawn agents or run multi-agent design exploration (that is `cerebrate`'s job);
- emit HTML or write any file — the blueprint is returned inline in the response.

If asked to "just do the refactor," refuse and point to the pipeline below. This skill produces a **blueprint**; it never executes one.

## Downstream pipeline

The blueprint is an input to the hivemind pipeline, not a finished plan. After the user accepts a candidate:

1. The overlord invokes **`hivemind:plan-interrogation`** on the accepted candidate — always; it self-right-sizes, so trivial candidates converge fast. Interrogation grills the candidate and owns any `CONTEXT.md` / ADR writes.
2. **`cerebrate`** converts the hardened blueprint into an executable implementation plan (and does any deeper multi-design interface exploration).
3. **`drone`** / **`changeling`** perform the refactor.
4. Then: version → validate → review → PR.

Term discipline: the artifact this skill emits is a **blueprint**, never a "plan." A plan is `cerebrate`'s downstream output — do not collide the vocabulary.

## Glossary

The skill uses two distinct vocabularies:

- **Architecture terms** (module, interface, implementation, depth/deep/shallow, seam, adapter, leverage, locality) come from `${CLAUDE_PLUGIN_ROOT}/skills/improving-architecture/references/LANGUAGE.md`. Use them exactly — do not drift into "component," "service," "API," or "boundary."
- **Domain terms** (Order, Invoice, Shipment) come from the project's `CONTEXT.md` / `CONTEXT-MAP.md`. Name candidates with these: "the Order intake module is shallow," never "the FooBarHandler is shallow."

The primary signal is the **deletion test**: imagine deleting a module and inlining its body at every call site. If complexity *vanishes*, it was a pass-through — shallow. If complexity *reappears across N callers*, it was earning its keep — deep. A "complexity reappears across many callers" is the signal a candidate is worth deepening. Full definitions and principles in `${CLAUDE_PLUGIN_ROOT}/skills/improving-architecture/references/LANGUAGE.md`.

## Workflow

### 1. Explore

Discover context in this priority order, then walk the code:

1. Read `CLAUDE.md`, `AGENTS.md`, `AGENT.md` at the repo root if present — follow their pointers.
2. Read `CONTEXT.md` or `CONTEXT-MAP.md` at the repo root if present.
3. If `CONTEXT-MAP.md` exists, the repo is **multi-context** — read the map and **scope the analysis to one bounded context** (ask the user which, if ambiguous). Use that context's `CONTEXT.md` for domain terms.
4. Read existing ADRs in `docs/adr/` if the directory exists.
5. Walk the code in the area of interest. Do not follow rigid heuristics — explore organically and note where you experience friction:
   - Where does understanding one concept require bouncing between many small modules?
   - Where are modules **shallow** — interface nearly as complex as the implementation?
   - Where were pure functions extracted only for testability, while the real bugs hide in how they are called (no **locality**)?
   - Where do tightly-coupled modules leak across their seams?
   - Which parts are untested, or hard to test through their current interface?

Apply the deletion test to anything you suspect is shallow.

**If there is no `CONTEXT.md` / `CONTEXT-MAP.md` and no `docs/adr/`:** proceed with vocabulary inferred from the code, and recommend the user run `hivemind:bootstrap-context` first for sharper domain naming. (Mirror `zoom-out`'s behavior — do not block.)

### 2. Assess

Apply the three references to turn friction into candidates:

- `${CLAUDE_PLUGIN_ROOT}/skills/improving-architecture/references/LANGUAGE.md` — depth/shallowness vocabulary and the deletion test, to identify and name shallow modules and leaky interfaces.
- `${CLAUDE_PLUGIN_ROOT}/skills/improving-architecture/references/DEEPENING.md` — classify each candidate's dependencies (in-process / local-substitutable / remote-owned → port+adapter / true-external → mock+inject) and derive the testing recommendation across the new seam.
- `${CLAUDE_PLUGIN_ROOT}/skills/improving-architecture/references/INTERFACE-DESIGN.md` — inline "design it twice" reasoning: sketch 2–3 interface shapes for each candidate, compare by depth/locality/seam placement, and commit to one recommendation.

If a candidate contradicts an existing ADR, surface it only when the friction is real enough to warrant reopening the ADR — mark it clearly in the card. Do not list every refactor an ADR forbids.

### 3. Blueprint

Emit the refactoring blueprint inline as Markdown, using the template below. Rank candidates strongest-first. Mermaid fenced blocks are allowed inline for before/after diagrams — never write them to a file.

## Refactoring blueprint template

```markdown
# Refactoring Blueprint: <area / bounded context>

<One-paragraph read on the area's architectural health, in LANGUAGE.md + CONTEXT.md terms.>

## Candidate 1 — <short name in domain vocabulary> — [Strong | Worth exploring | Speculative]

**Files:** <exact paths / module scopes involved>
**Confidence:** <High | Medium | Low>

**Problem.** <Why the current shape causes friction. Name the shallow modules and leaky
interfaces. State the deletion-test result.>

**Proposed deepening.** <The one recommended interface shape for the deepened module —
entry points plus the invariants, ordering, and error modes a caller must know. Dependency
category and the resulting testing recommendation across the seam.>

**Benefits.** <In terms of leverage (callers) and locality (maintainers), and how tests
improve once the interface becomes the test surface.>

**Before → After.**

​```mermaid
graph TD
  subgraph Before
    A[caller] --> B[shallow mod 1]
    A --> C[shallow mod 2]
    A --> D[shallow mod 3]
  end
  subgraph After
    A2[caller] --> E[deep module]
  end
​```

## Candidate 2 — ...

## Top recommendation

<Which candidate to tackle first and why, in one short paragraph.>

## Next steps

This is a blueprint, not a plan. To act on a candidate:

1. The overlord runs `hivemind:plan-interrogation` on it (owns any CONTEXT.md / ADR writes).
2. `cerebrate` turns the hardened candidate into an implementation plan.
3. `drone` / `changeling` perform the refactor; then version → validate → review → PR.
```

## When to use

- The user wants to find where the codebase is hard to test, hard to navigate, or tightly coupled, and wants concrete, ranked refactors.
- Before planning a refactor — to produce candidates the planning pipeline can harden.

Not this skill:

- **Just mapping / orienting** in unfamiliar code → `zoom-out`.
- **Generating a domain glossary** → `hivemind:bootstrap-context`.
- **Hardening a chosen candidate, writing CONTEXT.md / ADRs** → `hivemind:plan-interrogation`.
- **Producing or executing an implementation plan** → `cerebrate`, then `drone` / `changeling`.

## Edge cases

- **No `CONTEXT.md` / `docs/adr/`:** do not block. Infer vocabulary from code, recommend `hivemind:bootstrap-context` first, and proceed.
- **Multi-context repo (`CONTEXT-MAP.md` present):** scope the blueprint to one bounded context; ask which if ambiguous.
- **"Just do the refactor" / "apply this":** refuse. This skill is read-only; point to the downstream pipeline (plan-interrogation → cerebrate → drone / changeling).
