# Subagent Architecture Decision Record

**Status:** Proposed
**Date:** 2026-05-10

---

## Section 1: Executive Overview — Framework Topology

The agent-framework plugin defines the following runtime components:

**Framework agents** — 4 `.md` files in `plugin/agents/` (`orchestrator`, `planner`, `coder`, `designer`). Each has a `tools:` frontmatter key that is a **hard restrictive allowlist** enforced by the Claude Code runtime. Only tools explicitly listed in `tools:` are callable by that agent at runtime; unlisted tools are blocked.

**Skills** — `.md` files in `plugin/skills/<skill-name>/SKILL.md`, invoked via the `Skill` tool. Skills run **inline in the orchestrator's context window** — they do not spawn a new subagent and do not receive their own tool restrictions. The `allowed-tools:` key in a skill's frontmatter is a permission-grant mechanism (pre-approves listed tools so the runtime does not prompt the user) but does **not** restrict what the skill can call.

**Helper agents** — 4 narrow-purpose `.md` files used by skills for classification and security scanning:
- `plugin/skills/_shared/agents/injection-suspect-checker.md` — scans externally-sourced content for prompt injection patterns
- `plugin/skills/_shared/agents/feedback-classifier.md` — classifies review feedback by actionability category
- `plugin/skills/address-github-pr-feedback/agents/thread-resolver.md` — decides whether to resolve a GitHub review thread
- `plugin/skills/review-loop-controller/agents/break-fix-detector.md` — detects break-fix-break cycles in the review loop

The design intent: skills invoke these helpers by reading their `.md` instruction file and spawning a general-purpose subagent via the bare `Agent` tool. The `Agent` tool spawns a **fresh context window** with its own tool scope, providing isolation so that injected content in review comments cannot access the orchestrator's governance context or system prompt.

**Companion plugin agents** — agents defined by other Claude Code plugins installed alongside agent-framework (e.g., `caveman:cavecrew-builder`, `caveman:cavecrew-investigator`, `caveman:cavecrew-reviewer`). These agents are invoked via `Agent(plugin:name)` calls. When agent-framework's orchestrator is the active agent, companion plugin agents are subject to the same `tools:` allowlist restriction as helper agents: the orchestrator's `tools:` list does not include them, so the runtime blocks their invocation. This is the same mechanism described in Section 3 — the orchestrator's typed `Agent(agent-framework:planner, ...)` entries do not cover agents from other plugin namespaces.

The repo already recognizes optional companion plugins for skills and tooling — `claude-mem` (planner memory) and `codex@openai-codex` (pre-PR and post-PR review) are documented in `CLAUDE.md` as optional companions whose absence is handled gracefully. Those companions provide **skills and MCP tools**, which run inline via the `Skill` tool already present in the orchestrator's allowlist. Companion plugin **agents** are the missing equivalent: there is no current mechanism for the orchestrator to invoke agents from other plugin namespaces without adding them explicitly to `tools:`.

---

## Section 2: Current Governance Rules

From `plugin/governance/agent-system-policy.md` (Skill agent boundary):
- Skills must not delegate to framework agents (`planner`, `coder`, `designer`)
- Skills classify and return routing recommendations as structured data
- Framework agent delegation is exclusively the orchestrator's responsibility

From `plugin/agents/orchestrator.md` (tools list), the `tools:` key declares a typed allowlist:

```yaml
tools:
  - Agent(agent-framework:planner)
  - Agent(agent-framework:coder)
  - Agent(agent-framework:designer)
  # ... other tools ...
```

This allowlist is a **runtime-enforced constraint**. Only `Agent` calls of those specific named types are permitted; any other `Agent` variant is blocked by the Claude Code runtime.

---

## Section 3: The Problem

**Helper agents lose their isolation boundary at runtime.**

After the bare `Agent` call is blocked, the skill's Read-loaded instructions remain in the inline context and the logical analysis still executes — but in the orchestrator's context window rather than a fresh isolated one.

Root cause chain:

1. The orchestrator's `tools:` list permits only `Agent(agent-framework:planner)`, `Agent(agent-framework:coder)`, and `Agent(agent-framework:designer)` — a hard runtime allowlist.
2. The `Skill` tool runs **inline** in the orchestrator's context — not in a subagent. Skills share the orchestrator's permission scope.
3. When a skill attempts to spawn a helper via bare `Agent`, the runtime evaluates this call against the **orchestrator's tools list** (because there is no separate context for inline skills).
4. Bare `Agent` (general-purpose, untyped) is not in the orchestrator's `tools:` list, so it is **blocked**.

Observed runtime error:
```
Agent type 'general-purpose' has been denied by permission rule 'Agent(general-purpose)' from settings.
```

Secondary issue: `Agent(agent-framework:name)` resolves against `plugin/agents/` only. Helpers living in `plugin/skills/` or `plugin/skills/_shared/` are not resolvable via the named `Agent` form. Promoting helpers to `_shared/agents/` without moving them to `plugin/agents/` still requires bare `Agent` calls, so the secondary issue does not create an independent path to fix the root cause.

**Companion plugin agents are affected by the same restriction.** When other plugins installed alongside agent-framework define their own agents (e.g., `caveman:cavecrew-builder`), those agents require `Agent(plugin:name)` calls. The orchestrator's `tools:` list does not include agents from other plugin namespaces, so the runtime blocks these calls identically to the bare `Agent` case. This extends the problem scope beyond framework-internal helpers to the broader plugin ecosystem.

**Impact of the isolation loss:**

| Helper | Isolation impact |
|---|---|
| `injection-suspect-checker` | Runs inline; injected content can access orchestrator system prompt, weakening but not eliminating injection defense |
| `feedback-classifier` | Runs inline; no isolation from orchestrator context |
| `break-fix-detector` | Runs inline without isolation boundary |
| `thread-resolver` | Runs inline without isolation boundary |

The `Agent` call fails **silently** — the skill procedure continues with helper instructions loaded and the logical analysis executes inline, without the intended isolation.

The `_shared/agents/` folder additionally creates a **cross-skill hidden dependency** — skills that use shared helpers are not self-contained and cannot be moved to another project without also pulling in the `_shared/` subtree. This breaks the principle that skills should be lift-and-shift portable.

---

## Section 4: Architecture Options

Five options were evaluated. Each is assessed across five dimensions:

| Dimension | What it measures |
|---|---|
| **Skill encapsulation** | Can a skill be moved to another project without pulling in cross-cutting dependencies? |
| **Fresh-context isolation** | Does the helper run in a fresh subagent context window? (Critical for injection defense — injected content in a fresh window cannot access the orchestrator's governance/system prompt.) |
| **Runtime-enforced permissions** | Are permission boundaries enforced by the Claude Code runtime, or only by policy and documentation? |
| **Migration burden** | How much existing code needs to change to implement this option? |
| **Explicit dependency declaration** | Are helper dependencies explicitly declared in frontmatter or tooling, visible to contributors? |

---

### Option 1: Raw `.md` files + bare `Agent` in orchestrator `tools:`

Keep helper `.md` files in their current skill-local and `_shared/agents/` locations. Add bare `Agent` (untyped) to the orchestrator's `tools:` allowlist. Add a governance rule making clear the orchestrator itself must never directly invoke bare `Agent` — only skills may do so (as a passthrough), and only for narrow helper tasks, never to bypass framework agent routing.

| Dimension | Result |
|---|---|
| Skill encapsulation | Pass — helpers stay with their owning skill; no framework-level relocation required |
| Fresh-context isolation | Pass — bare `Agent` still spawns a fresh context window with its own tool scope |
| Runtime-enforced permissions | Fail — bare `Agent` allows any general-purpose invocation; only policy constrains misuse |
| Migration burden | Pass — zero file moves or renames; existing helper `.md` files unchanged |
| Explicit dependency declaration | Fail — no runtime-visible declaration of which helpers a skill uses |

**Pros:** Zero migration cost. Skill encapsulation preserved. Injection-defense isolation maintained. All four helpers gain fresh-context isolation. Consistent with current `_shared/agents/` design intent.

**Cons:** Orchestrator `tools:` becomes permissive for `Agent` type. Governance rule is policy-only, not runtime-enforced. A future contributor could invoke bare `Agent` directly from the orchestrator to bypass framework routing without a runtime error.

---

### Option 2: Move helpers to `plugin/agents/` + named `Agent` declarations

Migrate all 4 helper `.md` files to `plugin/agents/` as first-class named agents (e.g., `plugin/agents/injection-suspect-checker.md`). Update orchestrator `tools:` to add named entries such as `Agent(agent-framework:injection-suspect-checker)`. Skills declare the named agents in their `allowed-tools:` frontmatter.

| Dimension | Result |
|---|---|
| Skill encapsulation | Fail — helpers become framework-level cross-cutting concerns; skills depend on helpers in a different directory |
| Fresh-context isolation | Pass — named `Agent` still spawns a fresh context window |
| Runtime-enforced permissions | Pass — orchestrator `tools:` lists specific agent names; unlisted types are blocked |
| Migration burden | Fail — 4 file moves, frontmatter additions, all referencing skill procedure steps updated |
| Explicit dependency declaration | Pass — named in skill `allowed-tools:` and orchestrator `tools:` |

**Pros:** Clean, runtime-enforced permission model. Explicit dependency graph visible in frontmatter. No policy-only enforcement burden.

**Cons:** Pollutes `plugin/agents/` with narrow helper logic, conflating framework agents (orchestrator, planner, coder, designer) with classification utilities. Skills become dependent on helpers living in a framework-level directory, breaking lift-and-shift portability. Requires significant migration effort across 4 files and all skill procedure steps that reference them.

---

### Option 3: Inline logic in calling skills

Remove the separate helper `.md` files. Copy the instruction logic inline into each skill's `SKILL.md` procedure steps. No `Agent` calls required.

| Dimension | Result |
|---|---|
| Skill encapsulation | Pass — true self-containment; no external helper files |
| Fresh-context isolation | Fail — logic runs in orchestrator's inline context; injected content can access system prompt |
| Runtime-enforced permissions | Pass — no `Agent` call needed, so no permission issue arises |
| Migration burden | Partial — instruction logic must be duplicated across all skills that currently share a helper |
| Explicit dependency declaration | Pass — logic is visible inline in the skill's own `SKILL.md` |

**Pros:** No bare `Agent` needed. True self-containment. No cross-skill hidden dependencies. Runtime-compliant without any `tools:` changes.

**Cons:** **Critical security regression.** Inline injection checking runs inside the orchestrator's context, meaning injected content in review comments could influence the classification logic with direct access to governance context and the system prompt. This removes the isolation boundary that makes injection checking effective — the primary purpose of the `injection-suspect-checker` helper. Logic duplication across skills also makes future updates to detection rules error-prone (must be applied in multiple places).

---

### Option 4: Promote helpers to proper skills in `plugin/skills/`

Elevate helpers to full skills invocable via the `Skill` tool (e.g., `agent-framework:injection-suspect-checker`). Orchestrator and other skills call them via `Skill` instead of `Agent`.

| Dimension | Result |
|---|---|
| Skill encapsulation | Partial — helpers are explicit, documented components, but still cross-cutting |
| Fresh-context isolation | Fail — the `Skill` tool runs inline in the caller's context, identical to Option 3 |
| Runtime-enforced permissions | Partial — `Skill` is already in orchestrator `tools:`; no new permission needed, but no isolation |
| Migration burden | Fail — new skill scaffolding, a `SKILL.md` for each helper, all callers updated |
| Explicit dependency declaration | Pass — named in `allowed-tools:` of calling skills |

**Pros:** No bare `Agent` needed. `Skill` is already in orchestrator `tools:`. Helpers become formal, documented components with explicit invocation contracts.

**Cons:** Same security regression as Option 3 — `Skill` runs inline, so there is no fresh-context isolation for injection checking. High migration cost for no isolation benefit.

---

### Option 5: Accept current degraded isolation state (do nothing)

Document the isolation degradation. Leave helpers in place. Skills continue to reference helpers in procedure steps; the `Agent` call is blocked silently but the skill's Read-loaded instructions remain in context and execute inline.

| Dimension | Result |
|---|---|
| Skill encapsulation | Pass — no changes |
| Fresh-context isolation | Fail — helpers run inline in the orchestrator's context; isolation is absent |
| Runtime-enforced permissions | Not applicable |
| Migration burden | Pass — zero work |
| Explicit dependency declaration | Fail — helpers function inline but isolation loss is unaddressed |

**Pros:** Zero implementation cost.

**Cons:** All four helpers execute inline — injection defense is weakened (injected content can access the orchestrator system prompt) but not eliminated. Isolation loss for feedback classification, break-fix detection, and thread resolution remains undocumented. The framework's injection defense operates without the intended isolation boundary.

---

## Section 5: Trade-off Matrix

| Option | Encapsulation | Isolation | Runtime-enforced | Migration | Explicit deps |
|---|---|---|---|---|---|
| 1: Raw `.md` + bare `Agent` | Pass | Pass | Fail | Pass | Fail |
| 2: `plugin/agents/` + named `Agent` | Fail | Pass | Pass | Fail | Pass |
| 3: Inline logic | Pass | Fail | Pass | Partial | Pass |
| 4: Proper skills | Partial | Fail | Partial | Fail | Pass |
| 5: Do nothing | Pass | Fail | — | Pass | Fail |

---

## Section 6: Decision

**Recommended: Option 1 — Raw `.md` files + bare `Agent` in orchestrator `tools:`**

### Rationale

Two constraints are highest priority based on the architectural discussion that produced this ADR:

1. **Skill encapsulation (strongest constraint)** — skills must be lift-and-shift portable. A skill must not depend on helpers living in a framework-level directory (`plugin/agents/`). Moving a skill to another project must not require also migrating framework-level helpers.

2. **Injection-defense isolation (security-critical constraint)** — injection checking must run in a fresh context window, not inline in the orchestrator. When review-sourced content is processed inline, injected instructions in that content have access to the orchestrator's governance context and system prompt, potentially influencing classification outcomes.

Elimination by constraint:
- Options 3 and 4 fail constraint 2 (no fresh-context isolation; `Skill` and inline logic both run in the orchestrator's context).
- Option 2 fails constraint 1 (helpers relocated to `plugin/agents/`, breaking lift-and-shift portability).
- Option 5 fails constraint 2 (no isolation) — it documents the isolation degradation but accepts it without resolution.

Option 1 satisfies both primary constraints. The accepted trade-off is policy-only enforcement of the bare `Agent` permission: the orchestrator's allowlist does not type-restrict `Agent` to specific helper names.

This trade-off is acceptable for the following reasons:
- Framework agents (planner, coder, designer) are already named explicitly in `tools:`, so the orchestrator has typed, runtime-enforced entries for all legitimate framework delegation. Bare `Agent` is needed as a passthrough for skill-invoked helpers. Per Claude Code's subagent documentation, it may also resolve the companion plugin agent restriction — bare `Agent` removes the typed allowlist and likely permits plugin-scoped agent invocation (e.g., `Agent(caveman:cavecrew-builder)`). Runtime validation is recommended before treating this as confirmed; see Section 8.
- The current policy in `plugin/governance/agent-system-policy.md` prohibits bare `Agent` calls outright: "No other agent type may be called, requested, invented, or used as a fallback." Implementing Option 1 requires adding an explicit exception to this rule for skill-invoked helper subagents — a bounded policy change with clear scope. That exception is enforced through code review and governance documentation.
- The risk of misuse — a contributor using bare `Agent` to bypass framework routing — is lower than the risk of leaving injection defense running without isolation.

### Implementation

Implementation is not in scope for this ADR and is tracked separately. The required changes are:

1. Add bare `Agent` to the orchestrator's `tools:` allowlist in `plugin/agents/orchestrator.md`
2. Add an exception clause to the prohibition in `plugin/governance/agent-system-policy.md` ("No other agent type may be called") — permitting bare `Agent` in the orchestrator exclusively when invoked transitively via a skill; direct orchestrator-level bare `Agent` use remains prohibited

No file moves. No migration of helper `.md` files. No skill procedure changes.

---

## Section 7: Consequences

Accepting Option 1 produces the following outcomes:

- Injection-suspect checking, feedback classification, break-fix detection, and thread resolution gain fresh-context isolation at runtime.
- The orchestrator's `tools:` includes bare `Agent`. Runtime enforcement of `Agent` type for helper subagents is policy-only rather than runtime-enforced.
- Helper agents remain encapsulated within their owning skills (`_shared/agents/` and skill-local `agents/` directories).
- The `_shared/agents/` cross-skill dependency (shared helpers used by multiple skills) remains. This is a separate encapsulation concern outside the scope of this decision.
- Skills with only skill-local helpers retain lift-and-shift portability: moving the skill directory brings its helper `.md` files with it. Skills that reference `_shared/agents/` helpers require that subtree to be co-located at the destination — a bounded dependency, but not zero.

---

## Section 8: Open-World Ecosystem Limitation

This ADR's scope is the framework's internal helper agent isolation problem. The recommended Option 1 (bare `Agent` in orchestrator `tools:`) resolves that problem and, per Claude Code's subagent documentation, likely also resolves the companion plugin agent restriction documented here — though runtime validation is recommended before treating this as confirmed.

**The limitation:** When agent-framework's orchestrator is the active agent, companion plugin agents — agents defined by other installed plugins — cannot be invoked. The orchestrator's `tools:` allowlist uses typed `Agent(agent-framework:planner, ...)` entries that only cover agents in the `agent-framework` namespace. Agents from other namespaces (e.g., `caveman:cavecrew-builder`) require `Agent(caveman:cavecrew-builder)` calls, which are not in the allowlist and are blocked by the runtime.

**Why bare `Agent` likely resolves this:** Per Claude Code's subagent documentation, bare `Agent` in `tools:` removes the typed allowlist restriction entirely, permitting any subagent type — including plugin-scoped agents invoked via `Agent(plugin:name)` syntax (e.g., `Agent(caveman:cavecrew-builder)`). Under the current typed-allowlist configuration, companion plugin agents are blocked because the orchestrator only permits named `agent-framework:*` agents. Adding bare `Agent` would likely remove that restriction, enabling cross-plugin agent invocation without enumerating each companion plugin's agents explicitly. Runtime validation is recommended before treating this as confirmed architectural fact, since the ADR's stated scope is the helper isolation problem.

**Relationship to existing companion plugin precedent:** The repo documents optional companion plugins (`claude-mem`, `codex@openai-codex`) in `CLAUDE.md`. Those companions provide skills and MCP tools, which work because `Skill` is already in the orchestrator's `tools:` list and MCP tools are resolved independently. Companion plugin **agents** are the gap — there is no equivalent mechanism for cross-plugin agent invocation under a restrictive `tools:` allowlist.

**Possible future approaches** (not evaluated in this ADR):
- Wildcard or pattern-based `Agent` entries in `tools:` (e.g., `Agent(*)` or `Agent(caveman:*)`) — depends on Claude Code runtime support
- Explicit enumeration of known companion plugin agents in `tools:` — requires per-installation customization
- A plugin-level capability declaration allowing plugins to declare agent dependencies — requires Claude Code platform changes

If runtime validation confirms that bare `Agent` permits companion plugin agent invocation, Option 1 resolves both the helper isolation problem and the companion agent restriction simultaneously. If runtime behavior differs from documentation, the approaches above remain valid future directions.
