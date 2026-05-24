# Hivemind

Multi-agent orchestration framework for Claude Code. Coordinates specialized bioforms to plan, build, review, and ship code — so you don't have to manage the pipeline yourself.

## Install

Inside Claude Code, add the marketplace then install the plugin:

```text
/plugin marketplace add https://github.com/brenpike/hivemind.git
/plugin install hivemind@brenpike
```

## Requirements

- **bash** (macOS, Linux, or WSL on Windows)
- **git** and **gh** (GitHub CLI)
- Claude Code CLI

As of v1.0.0, PowerShell and native Windows support have been removed. All toolchain scripts are bash-based.

## Per-project setup

1. Enable the plugin and set the overlord as the session default agent in `.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "hivemind@brenpike": true
  },
  "agent": "hivemind:overlord"
}
```

The `agent` key sets the default agent for the project session. Without it, Claude Code starts with the default agent and the overlord is only reachable on-demand via the Agent tool — bypassing the workflow guarantees.

Or run the setup skill once to apply the required keys automatically:

```text
/hivemind:setup-project
```

The setup skill also adds `.hivemind/` to your project's `.gitignore`. This directory is created at runtime by the overlord for ephemeral plans, handoffs, and checkpoints — it should not be committed. If you prefer manual setup, add `.hivemind/` to your project's `.gitignore` directly.

**Optional: seed a least-privilege permission allowlist.** Pass `seed_allowlist=yes` to pre-populate a recommended set of `permissions.allow` entries in `.claude/settings.json`:

```text
/hivemind:setup-project seed_allowlist=yes
```

The seeded entries cover read-helper Bash commands (e.g. `grep`, `cat`), scoped git read subcommands, and `echo`/`printf`. They are appended-if-absent — existing entries are never overwritten or removed. `node`, `Edit`, and `Write` are intentionally **not** auto-approved; those require explicit per-project decisions.

For prompt-free local Codex review (`hivemind:adaptation-cycle`), add your Codex cache path to the project's `.claude/settings.json` (or the gitignored `.claude/settings.local.json`):

```json
"Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)"
```

Replace `/path/to/` with your actual home directory path. The `codex/*` wildcard covers all Codex CLI entry points so the entry does not need updating when Codex is upgraded.

2. Create `CLAUDE.md` with project-specific details:
   - Build/test commands
   - Package names and version file paths
   - Versioning configuration (bump triggers, changelogs, tag prefixes)
   - Architecture and code style notes

3. Create `AGENTS.md` at the project root with project-specific Codex review guidance. Include:
   - Review focus areas
   - Severity definitions
   - Project-specific conventions for reviewers

Once configured, the overlord is the session default agent. All skills are available namespaced as `hivemind:<skill-name>`.

## Recommended companion plugins

- [`claude-mem`](https://github.com/thedotmack/claude-mem) — provides optional cross-session memory and continuity. Install separately as a Claude Code plugin. Hivemind works without it; if installed, the cerebrate reads claude-mem memory directly via the MCP search tool (`mcp__plugin_claude-mem_mcp-search__*`) before every plan unless the repo has zero commits or the user explicitly opts out. Writes happen through claude-mem's automatic capture (there is no write MCP tool). `uvx` (from [Astral's `uv`](https://astral.sh/uv)) is an optional dependency of claude-mem that enables its semantic (vector/Chroma) search backend; without it, claude-mem falls back to keyword search and MCP tools remain fully callable. Install with `curl -LsSf https://astral.sh/uv/install.sh | sh`; diagnostics at `~/.claude-mem/logs/` (look for `CHROMA_MCP` entries).

- [`codex`](https://github.com/openai/codex-plugin-cc) — provides local and GitHub-integrated Codex code review. Install and configure with:
  ```text
  /plugin marketplace add https://github.com/openai/codex-plugin-cc.git
  /plugin install codex@openai-codex
  /reload-plugins
  /codex:setup
  ```
  When installed, enables local pre-PR Codex review via the `local-reviewer` agent (backed by `hivemind:adaptation-cycle`) and post-PR review automation via the `github-reviewer` agent (a self-owning agent that handles monitoring, feedback classification, fix delegation, and thread resolution). The framework works without it; if not installed, local review steps are skipped gracefully.

- [`caveman`](https://github.com/caveman/caveman) (`caveman@caveman`) — Token-compressed communication. Optional. When installed, all framework agents output in caveman ultra mode. The `setup-project` skill auto-configures it, or add manually to `.claude/settings.json`:
  ```json
  "enabledPlugins": { "caveman@caveman": true },
  "pluginConfigs": { "caveman@caveman": { "options": { "defaultLevel": "ultra" } } }
  ```

## After cloning a project that uses this plugin

```text
/plugin marketplace add https://github.com/brenpike/hivemind.git
/plugin install hivemind@brenpike
```

## The Swarm

Hivemind coordinates specialized bioforms to plan, build, review, and ship code — so you don't have to manage the pipeline yourself.

### Know Your Bioforms

| Bioform | Role | What it does |
|---|---|---|
| :eye: **Overlord** | Orchestrator | The control plane. Routes the Overmind's directives, distributes the cerebrate's plan, owns the git lifecycle, spawns specialists. Never writes code. Your main interface. |
| :brain: **Cerebrate** | Strategist | Originates the plan. Scans the territory and produces the **directive** — the intelligence the swarm executes. Read-only; thinks, never writes. |
| :hammer: **Drone** | Builder | Builds code within its assigned scope. The workhorse of the swarm. |
| :performing_arts: **Changeling** | Shaper | Handles UI, styling, and visual presentation. Reshapes how things look and feel. |

### The Lifecycle

```
You --> Overlord --> Cerebrate (plan) --> Directive
                 --> Drone/Changeling (build) --> Essence
                 --> Adaptation Cycle (review) --> PR
```

1. You give the **overlord** a task
2. The **cerebrate** scans the territory and returns a **directive**
3. The overlord **spawns** specialists (**drones** / **changelings**) phase by phase
4. Each phase produces **essence** — knowledge carried forward
5. An **adaptation cycle** reviews the work before shipping
6. A PR is opened when the swarm stabilizes

### Brood Mode — Parallel Execution

When the work is big enough, the overlord can split it into independent **strains** and dispatch a **brood** — multiple parallel sessions, each running its own full lifecycle in a separate git worktree.

```
You --> Overlord --> Cerebrate (decompose)
                 --> "3 independent strains detected. Deploy brood?"
                 --> Yes --> Hatchery mode
                           --> Strain A (tmux tab) --> own branch, own PR
                           --> Strain B (tmux tab) --> own branch, own PR
                           --> Strain C (tmux tab) --> own branch, own PR
```

The overlord enters **hatchery** mode — monitoring the brood from home base while each strain evolves independently.

### Signals

| Signal | Meaning |
|---|---|
| :fire: **Flare** | Urgent — agent hit something it can't resolve alone. Overlord stops and asks you. |
| :zap: **Reflex** | Simple task — overlord skips the cerebrate and spawns a drone directly. |
| :dna: **Mutation Decay** | Two fixes are fighting each other. Swarm stops. You decide. |
| :arrows_counterclockwise: **Adaptation Cycle** | Review in progress — the swarm is stabilizing before shipping. |

### Plain English Still Works

Every themed term maps to a plain concept. You don't need to learn the language to use the framework:

| You can say... | Or say... | Same thing |
|---|---|---|
| "checkpoint commit" | "molt" | Save progress at a phase boundary |
| "spawn a brood" | "dispatch a fleet" | Run parallel sessions |
| "what's the status" | "brood status" | Check progress across sessions |
| "plan this" | "send the cerebrate" | Get a plan before building |

The theme is for fun. The framework works with or without it.

## Repository layout

```
.claude-plugin/
  marketplace.json          # marketplace manifest (lives at repo root; points to ./plugin)
plugin/                     # plugin root — everything Claude Code loads lives here
  .claude-plugin/
    plugin.json             # plugin manifest
  agents/                   # agent definitions (overlord, cerebrate, drone, changeling, local-reviewer, github-reviewer)
  skills/                   # skill definitions (incl. _shared/ helpers)
  governance/               # runtime governance docs loaded via ${CLAUDE_PLUGIN_ROOT}/governance/
docs/
tools/                      # dev-only validation scripts (policy linter, report validator)
tests/                      # dev-only test fixtures and checks (policy, reports, plugin compatibility)
AGENTS.md                   # project-specific Codex reviewer guidance
CHANGELOG.md                # project changelog (Keep a Changelog format)
CLAUDE.md                   # project instructions for Claude Code
README.md
```

`plugin/governance/` is the active runtime governance directory. Agents and skills reference these files via `${CLAUDE_PLUGIN_ROOT}/governance/` paths; they are loaded at runtime and affect agent behavior.

`tools/` and `tests/` contain development-time validation scripts and test fixtures. They live outside `plugin/` and are not distributed as plugin runtime data.

`${CLAUDE_PLUGIN_ROOT}` resolves to the `plugin/` directory at runtime, so all internal cross-references (e.g. `${CLAUDE_PLUGIN_ROOT}/governance/definitions.md`) resolve correctly without per-consumer configuration.

## Agents

| Agent | Role |
|---|---|
| `hivemind:overlord` | Default agent. Coordinates all work, owns git workflow, branch/PR decisions, versioning decisions, and external review routing. |
| `hivemind:cerebrate` | Research and implementation planning. Read-only — no file writes. |
| `hivemind:drone` | Implementation within explicitly assigned file scope. |
| `hivemind:changeling` | Presentational UI/UX work within explicitly assigned file scope. |
| `hivemind:local-reviewer` | Pre-PR iterative Codex review with self-owning fix delegation at sonnet tier. |
| `hivemind:github-reviewer` | Post-PR review monitoring, feedback classification, fix delegation, push, and thread resolution. |

## Skills

All skills are invoked using the namespaced form:

| Skill | Purpose |
|---|---|
| `hivemind:bootstrap-context` | Analyze project artifacts and generate a populated CONTEXT.md (or CONTEXT-MAP.md for multi-context repos) with domain terms extracted from code, docs, and config |
| `hivemind:molt` | Commit a completed phase, milestone, version bump, or review-remediation item |
| `hivemind:create-working-branch` | Create or confirm a compliant working branch before implementation |
| `hivemind:adaptation-cycle` | Run a pre-PR local Codex review on the current branch diff — invocable directly by users or via `hivemind:local-reviewer` |
| `hivemind:open-plan-pr` | Open a pull request after completion, validation, and versioning gates pass |
| `hivemind:plan-interrogation` | Interactive plan interview — challenges a plan against the project's domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) as decisions crystallise |
| `hivemind:setup-project` | One-time project setup: write required `.claude/settings.json` keys (enabledPlugins + default agent) and add `.hivemind/` to `.gitignore` |
| `hivemind:tdd` | Implement features using Test-Driven Development (TDD) with the red-green-refactor cycle — invoke from `hivemind:drone` context only |
| `hivemind:spawn-brood` | Dispatch parallel overlord sessions — spawns N Claude Code instances in separate git worktrees via tmux |
| `hivemind:brood-status` | Check status of all active brood sessions — reports per-strain tmux session state, branch existence, and PR status |
| `hivemind:zoom-out` | Zoom out for broader context — maps relevant modules and callers using the project's domain glossary vocabulary |

## Governance

Reference documentation in `plugin/governance/`:

| File | Contents |
|---|---|
| `definitions.md` | Canonical vocabulary, authority matrix, agent roles, and cross-agent constraints |
| `workflow.md` | Branch taxonomy, naming rules, commit and PR policy, overlord workflow |
| `safety-rails.md` | Hard-stop rules, security constraints, secret-handling, and escalation triggers |
| `report-format.md` | Phase-closing report schemas, handoff formats, and step-delta structure |
| `versioning.md` | SemVer rules, bump triggers, changelog and tag policy |
| `security-policy.md` | External content boundaries, destructive-fix confirmation gate, injection classification |

Governance docs are plugin runtime data — agents load them via `${CLAUDE_PLUGIN_ROOT}/governance/` paths at runtime. They are load-bearing: renaming section headers or files can break agent rules that reference them. See `CLAUDE.md` for editing constraints.

## Plugin limitations

The following agent frontmatter fields are not supported by the Claude Code plugin system and are omitted from plugin agent definitions:

- `mcpServers` — configure MCP servers at the project or global level instead
- `permissionMode` — read-only enforcement is achieved by limiting the cerebrate's `tools` frontmatter to read-only commands; see the cerebrate's `tools` list in `plugin/agents/cerebrate.md`

## License

MIT
