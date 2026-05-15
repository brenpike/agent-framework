---
name: plan-interrogation
description: >-
  Intensely interviews the user about their plan — one question at a time — challenging it
  against the project's existing domain model, sharpening terminology, and updating/creating
  documentation (CONTEXT.md, ADRs) as decisions crystallise. Use when the user wants to
  stress-test a plan, challenge a plan, interrogate a plan, red-team a plan, or harden a plan
  against their project's language and documented decisions. Trigger on: "stress-test a plan",
  "challenge plan", "grill me", "interrogate plan", "red team plan", "harden plan",
  "/plan-interrogation".
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash(find *)
  - Bash(grep *)
  - Bash(ls *)
  - Bash(cat *)
  - Bash(mkdir -p *)
shell: bash
---

# Plan Interrogation

Interview relentlessly about every aspect of the plan until shared understanding is reached. Walk down each branch of the design tree, resolving dependencies one-by-one. Ask ONE question at a time, wait for feedback before continuing. Provide your own recommended answer with each question. If a question can be answered by exploring the codebase, explore instead of asking.

---

## Context discovery

On invocation, discover project context in this priority order:

1. **Read `CLAUDE.md`, `AGENTS.md`, and `AGENT.md`** at the repo root if they exist — find pointers to other docs.
2. **Read `CONTEXT.md` or `CONTEXT-MAP.md`** at the repo root if they exist.
3. **If `CONTEXT-MAP.md` exists** — multi-context repo; read the map to find the relevant context for the current topic.
4. **Read existing ADRs** from `docs/adr/` if the directory exists.
5. **Any paths explicitly referenced** in CLAUDE.md/AGENTS.md/AGENT.md.

---

## Domain awareness — file structure

Most repos have a single context:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
└── src/
```

If `CONTEXT-MAP.md` exists at the repo root, the repo has multiple contexts. Read the map to find where each lives and how they relate.

Create files lazily — only when there is something to write. If no `CONTEXT.md` exists, create it when the first term is resolved. If no `docs/adr/` exists, create it when the first ADR is needed.

---

## During the session

Four behaviors, always active:

### Challenge against the glossary

When the user uses a term that conflicts with an existing `CONTEXT.md` definition, call it out immediately: "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term: "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Stress-test with concrete scenarios

When domain relationships are discussed, invent scenarios that probe edge cases and force precision about boundaries.

### Cross-reference with code

When the user states how something works, check whether the code agrees; surface contradictions: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

---

## Updating CONTEXT.md

- Update `CONTEXT.md` inline as terms are resolved — do not batch.
- `CONTEXT.md` is a glossary ONLY — no implementation details, no specs, no scratch-pad content.
- Only include terms specific to the project's context — not general programming concepts.
- See `${CLAUDE_PLUGIN_ROOT}/skills/plan-interrogation/references/CONTEXT-FORMAT.md` for the full format reference.

---

## Creating ADRs

Only offer to create an ADR when ALL THREE conditions are true:

1. **Hard to reverse** — the cost of changing later is meaningful.
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **Real trade-off** — genuine alternatives existed; one was chosen for specific reasons.

If any of the three is missing, skip the ADR.

See `${CLAUDE_PLUGIN_ROOT}/skills/plan-interrogation/references/ADR-FORMAT.md` for the full format reference.
