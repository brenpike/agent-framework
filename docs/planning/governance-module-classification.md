# Governance Module Classification

> **Planning/design spec only.** This document is a working reference for Step 22 (EFF-2) of the Phase 4 implementation plan. It is not active governance and is not loaded by any agent or skill at runtime. Active governance lives exclusively under `plugin/governance/`.

## Classification Table

All 10 governance modules under `plugin/governance/` are classified below. `AGENTS.template.md` is explicitly excluded; it is a template for agent frontmatter, not a governance module.

| Module | Classification | Activation Condition |
|---|---|---|
| `agent-system-policy.md` | Mandatory | Always |
| `branching-pr-workflow.md` | Mandatory | Always |
| `git-policy.md` | Mandatory | Always |
| `scope-policy.md` | Mandatory | Always |
| `communication-policy.md` | Mandatory | Always |
| `escalation-policy.md` | Mandatory | Always |
| `versioning.md` | Conditional | Workflow touches bump-trigger paths, OR `CLAUDE.md` defines versioned artifacts |
| `validation-policy.md` | Conditional | Workflow includes a validation phase |
| `pr-review-remediation-loop.md` | Conditional | Workflow includes PR feedback or review remediation |
| `monitoring-policy.md` | Conditional | User request contains `watch`, `monitor`, `wait`, `poll`, or `loop` |

## Mandatory Module Invariant

The six mandatory modules are always loaded for every workflow. No activation condition, user override, project configuration, or workflow classification can suppress them. They form the irreducible governance baseline for all agent activity.

## Conditional Module Activation Rules

Each conditional module activates when its condition is met. All conditions use **fail-open** semantics: when it is uncertain whether the condition is met, include the module.

### `versioning.md`

**Condition:** The workflow touches bump-trigger paths, OR the project's `CLAUDE.md` defines versioned artifacts.

Fail-open: If it is uncertain whether the planned file scope overlaps with bump-trigger paths, or if `CLAUDE.md` references versions but the trigger definition is unclear, include `versioning.md`.

### `validation-policy.md`

**Condition:** The workflow includes a validation phase.

Fail-open: If the workflow may produce changes that require validation but the plan does not explicitly name a validation phase, include `validation-policy.md`.

### `pr-review-remediation-loop.md`

**Condition:** The workflow includes PR feedback or review remediation.

Fail-open: If the workflow involves an open PR or may receive review feedback, include `pr-review-remediation-loop.md`.

### `monitoring-policy.md`

**Condition:** The user request contains at least one of the keywords: `watch`, `monitor`, `wait`, `poll`, or `loop`.

Fail-open: If the user request contains language that could imply monitoring or polling behavior even without an exact keyword match, include `monitoring-policy.md`.

## Fallback Rule

**Fail-open: when uncertain, include.** The planner must err toward over-inclusion of conditional modules. Never omit a conditional module due to uncertainty about whether its activation condition is met. The cost of loading an unnecessary module is negligible; the cost of omitting a needed module is a governance gap.

## CLAUDE.md Override Mechanism

A project can force-include any conditional module by listing it in the project's `CLAUDE.md`. When a conditional module is named in `CLAUDE.md`, that explicit listing overrides the activation condition: the module is included regardless of whether the activation condition would otherwise be met.

This mechanism is one-directional. `CLAUDE.md` can force-include a conditional module but cannot suppress a mandatory module.

## `Workflow loadout:` Output Field Format

When the planner emits a plan (Step 22b), it includes a `Workflow loadout:` field that declares which conditional modules are active for the workflow. The format is:

```
Workflow loadout:
- <conditional-module-name>
- <conditional-module-name>
```

The field lists only active conditional modules. Mandatory modules are never listed because they are always loaded (per the mandatory module invariant).

When no conditional modules are needed, the field uses the literal string:

```
Workflow loadout:
- all mandatory only
```

Rules for this field:

- Field name is exactly `Workflow loadout:` (capital W, lowercase l, colon, no extra punctuation).
- Each active conditional module appears as a single list item using its exact filename (e.g., `versioning.md`, not a shortened or alternate name).
- Mandatory modules are never listed; their inclusion is implicit and invariant.
- The literal string `all mandatory only` is used when zero conditional modules are active; it appears as a single list item, not as free text.
