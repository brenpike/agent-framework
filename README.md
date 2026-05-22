# agent-framework

Claude Code plugin providing a structured multi-agent framework with orchestrator, planner, coder, designer, local-reviewer, and github-reviewer agents plus workflow skills for git branching, commits, PRs, and code review remediation.

## Install

Inside Claude Code, add the marketplace then install the plugin:

```text
/plugin marketplace add https://github.com/brenpike/agent-framework.git
/plugin install agent-framework@brenpike
```

## Requirements

- **bash** (macOS, Linux, or WSL on Windows)
- **git** and **gh** (GitHub CLI)
- Claude Code CLI

As of v1.0.0, PowerShell and native Windows support have been removed. All toolchain scripts are bash-based.

## Per-project setup

1. Enable the plugin and set the orchestrator as the session default agent in `.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "agent-framework@brenpike": true
  },
  "agent": "agent-framework:orchestrator"
}
```

The `agent` key sets the default agent for the project session. Without it, Claude Code starts with the default agent and the orchestrator is only reachable on-demand via the Agent tool — bypassing the workflow guarantees.

Or run the setup skill once to apply the required keys automatically:

```text
/agent-framework:setup-project
```

The setup skill also adds `.agent-framework/` to your project's `.gitignore`. This directory is created at runtime by the orchestrator for ephemeral plans, handoffs, and checkpoints — it should not be committed. If you prefer manual setup, add `.agent-framework/` to your project's `.gitignore` directly.

2. Create `CLAUDE.md` with project-specific details:
   - Build/test commands
   - Package names and version file paths
   - Versioning configuration (bump triggers, changelogs, tag prefixes)
   - Architecture and code style notes

3. Create `AGENTS.md` at the project root with project-specific Codex review guidance. Include:
   - Review focus areas
   - Severity definitions
   - Project-specific conventions for reviewers

Once configured, the orchestrator is the session default agent. All skills are available namespaced as `agent-framework:<skill-name>`.

## Recommended companion plugins

- [`claude-mem`](https://github.com/thedotmack/claude-mem) — provides the optional `claude-mem:mem-search` skill referenced by the planner for cross-session memory and continuity. Install separately as a Claude Code plugin. The agent framework works without it; if installed, planning invokes `claude-mem:mem-search` before every plan unless the repo has zero commits or the user explicitly opts out.

- [`codex`](https://github.com/openai/codex-plugin-cc) — provides local and GitHub-integrated Codex code review. Install and configure with:
  ```text
  /plugin marketplace add https://github.com/openai/codex-plugin-cc.git
  /plugin install codex@openai-codex
  /reload-plugins
  /codex:setup
  ```
  When installed, enables local pre-PR Codex review via the `local-reviewer` agent (backed by `agent-framework:local-codex-review`) and post-PR review automation via the `github-reviewer` agent (a self-owning agent that handles monitoring, feedback classification, fix delegation, and thread resolution). The framework works without it; if not installed, local review steps are skipped gracefully.

- [`caveman`](https://github.com/caveman/caveman) (`caveman@caveman`) — Token-compressed communication. Optional. When installed, all framework agents output in caveman ultra mode. The `setup-project` skill auto-configures it, or add manually to `.claude/settings.json`:
  ```json
  "enabledPlugins": { "caveman@caveman": true },
  "pluginConfigs": { "caveman@caveman": { "options": { "defaultLevel": "ultra" } } }
  ```

## After cloning a project that uses this plugin

```text
/plugin marketplace add https://github.com/brenpike/agent-framework.git
/plugin install agent-framework@brenpike
```

## Repository layout

```
.claude-plugin/
  marketplace.json          # marketplace manifest (lives at repo root; points to ./plugin)
plugin/                     # plugin root — everything Claude Code loads lives here
  .claude-plugin/
    plugin.json             # plugin manifest
  agents/                   # agent definitions
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
| `agent-framework:orchestrator` | Default agent. Coordinates all work, owns git workflow, branch/PR decisions, versioning decisions, and external review routing. |
| `agent-framework:planner` | Research and implementation planning. Read-only — no file writes. |
| `agent-framework:coder` | Implementation within explicitly assigned file scope. |
| `agent-framework:designer` | Presentational UI/UX work within explicitly assigned file scope. |
| `agent-framework:local-reviewer` | Pre-PR iterative Codex review with self-owning fix delegation at sonnet tier. |
| `agent-framework:github-reviewer` | Post-PR review monitoring, feedback classification, fix delegation, push, and thread resolution. |

## Skills

All skills are invoked using the namespaced form:

| Skill | Purpose |
|---|---|
| `agent-framework:bootstrap-context` | Analyze project artifacts and generate a populated CONTEXT.md (or CONTEXT-MAP.md for multi-context repos) with domain terms extracted from code, docs, and config |
| `agent-framework:checkpoint-commit` | Commit a completed phase, milestone, version bump, or review-remediation item |
| `agent-framework:create-working-branch` | Create or confirm a compliant working branch before implementation |
| `agent-framework:local-codex-review` | Run a pre-PR local Codex review on the current branch diff — invocable directly by users or via `agent-framework:local-reviewer` |
| `agent-framework:open-plan-pr` | Open a pull request after completion, validation, and versioning gates pass |
| `agent-framework:plan-interrogation` | Interactive plan interview — challenges a plan against the project's domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) as decisions crystallise |
| `agent-framework:setup-project` | One-time project setup: write required `.claude/settings.json` keys (enabledPlugins + default agent) and add `.agent-framework/` to `.gitignore` |
| `agent-framework:tdd` | Implement features using Test-Driven Development (TDD) with the red-green-refactor cycle — invoke from `agent-framework:coder` context only |
| `agent-framework:zoom-out` | Zoom out for broader context — maps relevant modules and callers using the project's domain glossary vocabulary |

## Governance

Reference documentation in `plugin/governance/`:

| File | Contents |
|---|---|
| `definitions.md` | Canonical vocabulary, authority matrix, agent roles, and cross-agent constraints |
| `workflow.md` | Branch taxonomy, naming rules, commit and PR policy, orchestrator workflow |
| `safety-rails.md` | Hard-stop rules, security constraints, secret-handling, and escalation triggers |
| `report-format.md` | Phase-closing report schemas, handoff formats, and step-delta structure |
| `versioning.md` | SemVer rules, bump triggers, changelog and tag policy |
| `security-policy.md` | External content boundaries, destructive-fix confirmation gate, injection classification |

Governance docs are plugin runtime data — agents load them via `${CLAUDE_PLUGIN_ROOT}/governance/` paths at runtime. They are load-bearing: renaming section headers or files can break agent rules that reference them. See `CLAUDE.md` for editing constraints.

## Plugin limitations

The following agent frontmatter fields are not supported by the Claude Code plugin system and are omitted from plugin agent definitions:

- `mcpServers` — configure MCP servers at the project or global level instead
- `permissionMode` — read-only enforcement is achieved by limiting the planner's `tools` frontmatter to read-only commands; see the planner's `tools` list in `plugin/agents/planner.md`

## License

MIT
