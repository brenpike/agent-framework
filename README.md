# agent-framework

Claude Code plugin providing a multi-agent framework with orchestrator, planner, coder, and designer agents plus workflow skills for git branching, commits, PRs, and review remediation.

## Install

```bash
claude plugin add brenpike/agent-framework
```

## Per-Project Setup

After installing the plugin, each project that uses it needs:

1. **Enable the plugin** in your project's `.claude/settings.json`:

```json
{
  "enabledPlugins": ["agent-framework"]
}
```

2. **Create a `CLAUDE.md`** at your project root with project-specific paths, commands, packages, artifact rules, and versioning configuration. The agents reference `CLAUDE.md` for project-specific adapter details.

3. **Create an `AGENTS.md`** at your project root if you use external AI reviewers (e.g., Codex). Copy `governance/AGENTS.md` as a starting point and customize for your project's review focus.

## Agents

| Agent | Role |
|---|---|
| **orchestrator** | Control plane. Coordinates planner, coder, and designer. Owns task routing, git preflight, branch/worktree decisions, checkpoint commits, PR submission, versioning decisions, and external review-feedback routing. Does not implement code. |
| **planner** | Creates implementation plans by researching the codebase, identifying risks and edge cases, assigning explicit file scopes, and recommending delivery shape. Does not modify files. |
| **coder** | Implements code, fixes bugs, refactors safely, updates assigned tests/release metadata, and validates behavior within explicitly assigned file scope. |
| **designer** | Handles presentational UI/UX work, design tokens, layout, accessibility presentation, and visual states within explicitly assigned file scope. |

The default agent is `orchestrator` (configured in `settings.json`).

## Skills

| Skill | Description |
|---|---|
| `create-working-branch` | Create or confirm the compliant working branch before implementation begins. |
| `checkpoint-commit` | Create a checkpoint commit after a completed phase, milestone, version bump, or review remediation item. |
| `open-plan-pr` | Open a pull request after completion, validation, and versioning gates pass. |
| `request-codex-review` | Request Codex review on an existing pushed PR. |
| `address-pr-feedback` | Fix a specific generic, human, or ambiguous PR comment (non-Codex). |
| `run-codex-review-loop` | Run the bounded Codex review remediation and re-review loop. |
| `watch-pr-feedback` | Watch a PR for new unresolved review feedback and route to remediation skills. |

## Governance

The `governance/` directory contains shared policy documents referenced by agents and skills:

- `agent-system-policy.md` -- cross-agent constraints, authority matrix, role boundaries, escalation rules
- `branching-pr-workflow.md` -- trunk-based development, branch taxonomy, commit policy, PR workflow
- `pr-review-remediation-loop.md` -- external PR review feedback handling, classification, routing, fix rules
- `versioning.md` -- SemVer rules, bump triggers, changelog, tags
- `AGENTS.md` -- guidance for external AI reviewers (e.g., Codex)

These documents define mandatory behavior for all agents. Project-specific overrides belong in each project's `CLAUDE.md`.

## License

MIT
