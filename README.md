# agent-framework

Claude Code plugin providing a structured multi-agent framework with orchestrator, planner, coder, and designer agents plus workflow skills for git branching, commits, PRs, and code review remediation.

## Install

Install once, globally:

```bash
claude plugin install https://github.com/brenpike/agent-framework
```

## Per-project setup

1. Enable the plugin in `.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "agent-framework@brenpike": true
  }
}
```

2. Create `CLAUDE.md` with project-specific details:
   - Build/test commands
   - Package names and version file paths
   - Versioning configuration (bump triggers, changelogs, tag prefixes)
   - Architecture and code style notes

3. Create `AGENTS.md` with project-specific Codex review guidance:
   - Review focus areas
   - Severity definitions
   - Project-specific conventions for reviewers

That is all. The orchestrator is automatically the default agent. All skills are available namespaced as `agent-framework:<skill-name>`.

## After cloning a project that uses this plugin

```bash
claude plugin install https://github.com/brenpike/agent-framework
```

## Agents

| Agent | Role |
|---|---|
| `agent-framework:orchestrator` | Default agent. Coordinates all work, owns git workflow, branch/PR decisions, versioning decisions, and external review routing. |
| `agent-framework:planner` | Research and implementation planning. Read-only — no file writes. |
| `agent-framework:coder` | Implementation within explicitly assigned file scope. |
| `agent-framework:designer` | Presentational UI/UX work within explicitly assigned file scope. |

## Skills

All skills are invoked as `agent-framework:<skill-name>`:

| Skill | Purpose |
|---|---|
| `create-working-branch` | Create or confirm a compliant working branch before implementation |
| `checkpoint-commit` | Commit a completed phase, milestone, version bump, or review-remediation item |
| `open-plan-pr` | Open a pull request after completion, validation, and versioning gates pass |
| `address-pr-feedback` | Fix a specific generic or human PR comment (one-time) |
| `request-codex-review` | Request Codex review on an existing pushed PR |
| `watch-pr-feedback` | Monitor a PR for new review feedback and route to remediation skills |

## Governance

Reference documentation in `governance/`:

| File | Contents |
|---|---|
| `agent-system-policy.md` | Cross-agent constraints, authority matrix, allowed agent topology |
| `branching-pr-workflow.md` | Branch taxonomy, naming rules, commit and PR policy |
| `pr-review-remediation-loop.md` | External PR review feedback handling and classification |
| `versioning.md` | SemVer rules, bump triggers, changelog and tag policy |
| `AGENTS.md` | Template for project-specific Codex reviewer guidance |

Governance rules are embedded in agent definitions. These files are reference material for humans and for agents that need to re-read specific rules.

## Plugin limitations

The following agent frontmatter fields are not supported by the Claude Code plugin system and are omitted from plugin agent definitions:

- `mcpServers` — configure MCP servers (context7, claude-mem, etc.) at the project or global level instead
- `permissionMode` — the planner enforces read-only behavior via its instructions

## License

MIT
