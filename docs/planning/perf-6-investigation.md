# PERF-6: Per-Invocation Model Override Investigation

Step 23 of the Phase 4 Implementation Plan.

## Status

**Yes** — Claude Code's Agent() tool supports per-invocation model overrides via a `model` parameter. The orchestrator can pass `model` with values `sonnet`, `opus`, or `haiku` when invoking any subagent, overriding the agent definition's `model` frontmatter field. PERF-1 should use this mechanism for per-task model routing.

## Question (a): Does Claude Code plugin system support per-invocation model overrides?

**Answer: Yes.**

### Evidence

#### 1. Agent frontmatter `model` field (static, per-agent)

Each agent definition specifies a default model in its YAML frontmatter:

| Agent file | `model` value |
|---|---|
| `plugin/agents/orchestrator.md` | `claude-sonnet-4-6` |
| `plugin/agents/planner.md` | `claude-opus-4-6` |
| `plugin/agents/coder.md` | `claude-opus-4-6` |
| `plugin/agents/designer.md` | `claude-sonnet-4-6` |

The frontmatter `model` field is validated as required by `tests/plugin/agent-frontmatter-valid.json` (required fields: `name`, `description`, `model`, `tools`). This establishes that every agent must declare a default model.

#### 2. Agent() tool `model` parameter (dynamic, per-invocation)

The Agent() tool — available to the orchestrator and to skills that declare it in their `allowed-tools` — accepts a `model` parameter. Per the tool's schema definition visible in the orchestrator's system context:

- **Parameter name:** `model`
- **Valid values:** `sonnet`, `opus`, `haiku`
- **Behavior:** "Optional model override for this agent. Takes precedence over the agent definition's model frontmatter."
- **Scope:** per-invocation; each Agent() call can specify a different model

This means the orchestrator can invoke the same agent definition (e.g., `agent-framework:coder`) with different models on different invocations without modifying any agent file.

#### 3. Skills do not have independent model selection

Skill YAML frontmatter uses `disable-model-invocation: false` but does not include a `model` field. All seven skills in the plugin (`address-pr-feedback`, `checkpoint-commit`, `create-working-branch`, `open-plan-pr`, `request-codex-review`, `setup-project`, `watch-pr-feedback`) follow this pattern. Skills inherit the model context of the calling agent or session — they do not independently select a model tier.

#### 4. CLAUDE.md confirmation of frontmatter limits

The project's `CLAUDE.md` states: "Agent frontmatter limits: Claude Code plugin system does not honor `mcpServers` or `permissionMode` in agent frontmatter." This confirms that `model` is among the frontmatter fields that the plugin system does honor, alongside `name`, `description`, and `tools`.

#### 5. Web search unavailable

WebSearch was unavailable during this investigation. No official Claude Code plugin documentation was consulted. All findings are based on code inspection of the agent files, skill files, test fixtures, and the Agent() tool schema as observed in the orchestrator's runtime system context.

## Question (b): If yes — what is the exact mechanism and how would PERF-1 use it for per-task routing?

### Mechanism

The Agent() tool's `model` parameter provides per-invocation model override:

- **Caller:** Any agent or skill with `Agent(...)` in its tools list (currently: orchestrator, `address-pr-feedback` skill, `watch-pr-feedback` skill via the address skill)
- **Syntax:** Pass `model` as a parameter when invoking Agent(), e.g., `Agent(agent-framework:coder, model=haiku)`
- **Precedence:** The per-invocation `model` value takes precedence over the agent definition's frontmatter `model` field. If `model` is omitted from the Agent() call, the frontmatter default is used.
- **Valid values:** `sonnet`, `opus`, `haiku` (short names mapping to the current generation of each model tier)
- **Scope:** The override applies only to that single invocation. Subsequent calls to the same agent revert to the frontmatter default unless a new override is passed.

### How PERF-1 would use this

The orchestrator selects a model tier based on the task type and complexity, then passes it as the `model` parameter when delegating to subagents. The frontmatter `model` values serve as sensible defaults; the orchestrator overrides them only when cost-optimization logic dictates a different tier.

#### Routing strategy

The orchestrator would apply a decision matrix mapping task characteristics to model tiers:

| Task type | Agent | Default (frontmatter) | Override | Rationale |
|---|---|---|---|---|
| Planning (any complexity) | planner | opus | (none — use default) | Planning benefits from strongest reasoning |
| Complex implementation (multi-file, architecture) | coder | opus | (none — use default) | Complex work benefits from opus |
| Simple implementation (single-file, trivial change) | coder | opus | `sonnet` | Single-file trivial edits do not need opus-level reasoning |
| Review remediation (simple fix) | coder | opus | `sonnet` | Targeted fixes with clear instructions |
| Review remediation (architecture concern) | coder | opus | (none — use default) | Architecture changes need stronger reasoning |
| Presentational UI/UX | designer | sonnet | (none — use default) | Designer tasks are well-scoped by nature |
| Routine git/PR skills | (skill) | (inherited) | N/A | Skills inherit model; no override mechanism for skills |

#### Concrete routing examples

1. **Planner invocation** — always use frontmatter default (opus): `Agent(agent-framework:planner)` — no override needed.

2. **Coder: simple single-file docs fix** — override to sonnet: `Agent(agent-framework:coder, model=sonnet)` — the trivial fast path criteria are met, sonnet is sufficient.

3. **Coder: multi-file refactor** — use frontmatter default (opus): `Agent(agent-framework:coder)` — complex cross-file work benefits from stronger reasoning.

4. **Coder: review remediation of a typo fix** — override to sonnet: `Agent(agent-framework:coder, model=sonnet)` — targeted fix with clear instructions.

5. **Designer: presentational styling** — use frontmatter default (sonnet): `Agent(agent-framework:designer)` — already on sonnet.

6. **Coder: version bump** — override to sonnet: `Agent(agent-framework:coder, model=sonnet)` — mechanical file edits with clear instructions.

#### Cost impact estimate

Current defaults: planner=opus, coder=opus, designer=sonnet, orchestrator=sonnet. By routing simple coder tasks to sonnet, PERF-1 could reduce per-invocation cost for those tasks by the opus-to-sonnet cost ratio while preserving opus for tasks that benefit from it.

## Question (c): If no — alternative approaches

N/A — per-invocation override confirmed.

## Recommendation for PERF-1

**Use the Agent() tool's `model` parameter for per-task model routing.** This is the recommended approach for PERF-1 (Phase 5).

Implementation plan:

1. **Define a routing matrix** in the orchestrator agent definition (or in a governance doc referenced by the orchestrator) that maps task characteristics to model tiers. The matrix should consider: trivial fast path eligibility, number of files in scope, whether the task involves architecture or contract changes, and whether it is review remediation.

2. **Orchestrator passes `model` parameter** when delegating to subagents based on the routing matrix. The frontmatter defaults remain as fallbacks and serve as the "full capability" tier for each agent.

3. **No new agent variants needed.** The `model` parameter eliminates the need for separate `coder-lite.md` or `designer-lite.md` definitions — the same agent definition serves all tiers.

4. **No changes to skills.** Skills inherit model context from the calling agent. Skill-level model routing is not needed because skills are invoked by the orchestrator (which already runs on sonnet) or by other agents whose model is already determined.

5. **Haiku tier consideration.** The `haiku` value is available but should be used cautiously. Candidate tasks: mechanical file operations with zero decision-making (e.g., renaming a single variable across one file). Most tasks benefit from at least sonnet-level reasoning. Start with a sonnet/opus split and evaluate haiku eligibility after observing sonnet performance on simple tasks.

## Sources

### Files inspected

- `plugin/agents/orchestrator.md` — frontmatter: `model: claude-sonnet-4-6`, tools include `Agent(agent-framework:planner, agent-framework:coder, agent-framework:designer)`
- `plugin/agents/planner.md` — frontmatter: `model: claude-opus-4-6`
- `plugin/agents/coder.md` — frontmatter: `model: claude-opus-4-6`
- `plugin/agents/designer.md` — frontmatter: `model: claude-sonnet-4-6`
- `plugin/skills/address-pr-feedback/SKILL.md` — frontmatter: `disable-model-invocation: false`, tools include `Agent(...)`
- `plugin/skills/checkpoint-commit/SKILL.md` — frontmatter: `disable-model-invocation: false`, no `model` field
- `plugin/skills/create-working-branch/SKILL.md` — frontmatter: `disable-model-invocation: false`, no `model` field
- `plugin/skills/open-plan-pr/SKILL.md` — frontmatter: `disable-model-invocation: false`, no `model` field
- `plugin/skills/request-codex-review/SKILL.md` — frontmatter: `disable-model-invocation: false`, no `model` field
- `plugin/skills/setup-project/SKILL.md` — frontmatter: `disable-model-invocation: false`, no `model` field
- `plugin/skills/watch-pr-feedback/SKILL.md` — frontmatter: `disable-model-invocation: false`, no `model` field
- `tests/plugin/agent-frontmatter-valid.json` — validates required frontmatter fields including `model`
- `CLAUDE.md` — documents agent frontmatter limits (plugin system does not honor `mcpServers` or `permissionMode`)
- `docs/planning/framework-review-and-improvement-plan.md` — Step 23 definition, PERF-1/PERF-6 descriptions

### Web sources

- None (WebSearch was unavailable; findings based entirely on code inspection and Agent() tool schema observation)
