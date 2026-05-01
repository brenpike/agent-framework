# agent-framework

Claude Code plugin providing a structured multi-agent framework with orchestrator, planner, coder, and designer agents plus workflow skills for git branching, commits, PRs, and code review remediation.

## Install

Inside Claude Code, add the marketplace then install the plugin:

```text
/plugin marketplace add https://github.com/brenpike/agent-framework.git
/plugin install agent-framework@brenpike
```

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

2. Create `CLAUDE.md` with project-specific details:
   - Build/test commands
   - Package names and version file paths
   - Versioning configuration (bump triggers, changelogs, tag prefixes)
   - Architecture and code style notes

3. Create `AGENTS.md` at the project root with project-specific Codex review guidance. Use `governance/AGENTS.template.md` as a starting point and adapt:
   - Review focus areas
   - Severity definitions
   - Project-specific conventions for reviewers

Once configured, the orchestrator is the session default agent. All skills are available namespaced as `agent-framework:<skill-name>`.

## Recommended companion plugins

- [`claude-mem`](https://github.com/thedotmack/claude-mem) — provides the optional `claude-mem:mem-search` skill referenced by the planner for cross-session memory and continuity. Install separately as a Claude Code plugin. The agent framework works without it; if installed, planning invokes `claude-mem:mem-search` before every plan unless the repo has zero commits or the user explicitly opts out.

## After cloning a project that uses this plugin

```text
/plugin marketplace add https://github.com/brenpike/agent-framework.git
/plugin install agent-framework@brenpike
```

## Agents

| Agent | Role |
|---|---|
| `agent-framework:orchestrator` | Default agent. Coordinates all work, owns git workflow, branch/PR decisions, versioning decisions, and external review routing. |
| `agent-framework:planner` | Research and implementation planning. Read-only — no file writes. |
| `agent-framework:coder` | Implementation within explicitly assigned file scope. |
| `agent-framework:designer` | Presentational UI/UX work within explicitly assigned file scope. |

## Skills

All skills are invoked using the namespaced form:

| Skill | Purpose |
|---|---|
| `agent-framework:setup-project` | One-time project setup: write required `.claude/settings.json` keys (enabledPlugins + default agent) |
| `agent-framework:create-working-branch` | Create or confirm a compliant working branch before implementation |
| `agent-framework:checkpoint-commit` | Commit a completed phase, milestone, version bump, or review-remediation item |
| `agent-framework:open-plan-pr` | Open a pull request after completion, validation, and versioning gates pass |
| `agent-framework:address-pr-feedback` | Fix a specific generic or human PR comment (one-time) |
| `agent-framework:request-codex-review` | Request Codex review on an existing pushed PR |
| `agent-framework:watch-pr-feedback` | Monitor a PR for new review feedback and route to remediation skills |

## Governance

Reference documentation in `governance/`:

| File | Contents |
|---|---|
| `agent-system-policy.md` | Cross-agent constraints, authority matrix, allowed agent topology |
| `branching-pr-workflow.md` | Branch taxonomy, naming rules, commit and PR policy |
| `pr-review-remediation-loop.md` | External PR review feedback handling and classification |
| `versioning.md` | SemVer rules, bump triggers, changelog and tag policy |
| `AGENTS.template.md` | Template for project-specific Codex reviewer guidance |

Governance rules are embedded in agent definitions. These files are reference material for humans and for agents that need to re-read specific rules.

## Plugin limitations

The following agent frontmatter fields are not supported by the Claude Code plugin system and are omitted from plugin agent definitions:

- `mcpServers` — configure MCP servers at the project or global level instead
- `permissionMode` — read-only enforcement is achieved by limiting the planner's `tools` frontmatter to read-only commands; see the planner's `tools` list in `agents/planner.md`

## License

MIT
