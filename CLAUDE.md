# CLAUDE.md

Guidance for Claude Code instances working **on this repo** (not consuming the published plugin).

## What this repo is

Source for the `hivemind` Claude Code plugin + a single-plugin marketplace pointing at it. Plugin defines four agents (overlord, cerebrate, drone, changeling) and ten skills; governance docs are plugin **runtime data** loaded by agents, not just human reference.

## Repository layout

```
.claude-plugin/marketplace.json   # marketplace manifest at repo root → source: ./plugin
plugin/                           # plugin root (resolves to ${CLAUDE_PLUGIN_ROOT})
  .claude-plugin/plugin.json      # plugin manifest (name, version)
  agents/{overlord,cerebrate,drone,changeling}.md
  skills/<skill-name>/SKILL.md
  skills/_shared/                 # cross-skill helper docs (e.g. GraphQL ops)
  governance/                     # *.md loaded by agents at runtime
README.md
CLAUDE.md
```

`${CLAUDE_PLUGIN_ROOT}` resolves to `plugin/` because that's where `plugin.json` lives. All cross-refs inside `plugin/` use `${CLAUDE_PLUGIN_ROOT}/...` paths — never relative or repo-rooted paths.

Anything the runtime loads must live under `plugin/`.

## Editing rules specific to this repo

- **Path refs across plugin files MUST use `${CLAUDE_PLUGIN_ROOT}/...`.** Bare `governance/foo.md` or `agents/foo.md` paths break when consumers install the plugin. Grep for bare paths before merging.
- **Agent frontmatter limits:** Claude Code plugin system does not honor `mcpServers` or `permissionMode` in agent frontmatter. Read-only enforcement on cerebrate is done by restricting `tools:` list, not by `permissionMode`. Don't re-add these fields.
- **Skills are namespaced as `hivemind:<skill>`** when consumed. Internal cross-references in skill/agent bodies should use the namespaced form so docs match runtime behavior.
- **Governance docs are load-bearing.** Renaming a section header inside `plugin/governance/*.md` may break agent rules that reference that header by name (e.g. `(Required Git Preflight)`, `(Definitions → Trivial change)`). Search for header references before renaming.

## Versioning

Single source of truth: `plugin/.claude-plugin/plugin.json` `"version"`. Bump triggers and policy: `plugin/governance/versioning.md`. README does not carry a version.

## Branching / PR workflow

This repo dogfoods its own plugin's workflow. Authoritative rules: `plugin/governance/workflow.md`, `plugin/governance/definitions.md`. When working here, follow them — overlord → working branch → checkpoint commits → PR → Codex review.

Default branches:
- Trunk / PR base: `main`
- Working branch naming: per `workflow.md` (Branch Creation)

## Validation

No build or test suite. "Validation" for changes here is:

1. JSON manifests parse: `jq . plugin/.claude-plugin/plugin.json > /dev/null` and `jq . .claude-plugin/marketplace.json > /dev/null`.
2. No bare path refs introduced — `grep -rE '\b(agents|skills|governance)/' plugin/` should only return `${CLAUDE_PLUGIN_ROOT}/...` lines or `_shared/` references; flag anything else.
3. Smoke install in a scratch Claude Code session before publishing breaking layout changes:
   ```text
   /plugin marketplace add <local-path-or-git-url>
   /plugin install hivemind@brenpike
   ```

### Change-Class Validation

Apply the command set for the change class that matches the files modified.

| Change class | Condition | Required checks |
|---|---|---|
| docs-only | All modified files are outside `plugin/` and outside `.claude-plugin/` | None — skip JSON manifest and bare-path checks |
| plugin-runtime | Any modified file is inside `plugin/` or inside `.claude-plugin/` | Full: JSON manifest parse + bare-path grep (as defined above) |

When a single PR mixes docs-only and plugin-runtime files, apply the plugin-runtime command set.

## Common pitfalls

- Adding a new governance doc but forgetting to reference it from an agent → dead file.
- Adding a new skill but forgetting `${CLAUDE_PLUGIN_ROOT}/skills/_shared/...` ref when reusing shared helpers.
- Editing `marketplace.json` `source` away from `./plugin` — breaks consumer installs.
- Putting plugin content at repo root instead of under `plugin/` — `${CLAUDE_PLUGIN_ROOT}` will not resolve where authors expect.

## Companion plugins referenced

`claude-mem:mem-search` is optional — cerebrate uses it when present, skips when absent. Do not hard-require it from any agent or skill.

`codex@openai-codex` is optional — the overlord uses `codex-plugin-cc` for pre-PR local review via the `local-reviewer` agent (`hivemind:adaptation-cycle`). If not installed, the overlord skips local review and proceeds to PR. Run `codex:setup` after installation. Do not hard-require it from any agent or skill.

## Fleet execution

The plugin supports parallel multi-overlord execution via spawn-brood and brood-status skills. Each brood session runs in its own git worktree as an independent Claude Code instance.

- **Fleet PRD:** `docs/fleet-prd.md` — requirements, architecture decisions, manifest schema
- **Architecture decision:** `docs/adr/0007-fleet-children-unaware-coordinator-dashboard.md` — children have zero fleet awareness; coordinator is a status dashboard
- **Fleet manifest:** `.hivemind/fleet/manifest.yaml` (in main checkout; already gitignored under `.hivemind/`)
- **Worktree sessions:** `.claude/worktrees/` (gitignored)

Children are standard overlord sessions receiving a task description. No fleet-specific code paths exist in child sessions.

## Local developer setup

To eliminate permission prompts for the local Codex review flow (`hivemind:adaptation-cycle`), add your Codex cache path to `.claude/settings.local.json` (gitignored):

```json
{
  "permissions": {
    "allow": [
      "Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)"
    ]
  }
}
```

Replace `/path/to/` with your actual home directory path. This file is gitignored and must be created locally by each contributor.
