# CLAUDE.md

Guidance for Claude Code instances working **on this repo** (not consuming the published plugin).

## What this repo is

Source for the `agent-framework` Claude Code plugin + a single-plugin marketplace pointing at it. Plugin defines four agents (orchestrator, planner, coder, designer) and seven skills; governance docs are plugin **runtime data** loaded by agents, not just human reference.

## Repository layout

```
.claude-plugin/marketplace.json   # marketplace manifest at repo root → source: ./plugin
plugin/                           # plugin root (resolves to ${CLAUDE_PLUGIN_ROOT})
  .claude-plugin/plugin.json      # plugin manifest (name, version)
  agents/{orchestrator,planner,coder,designer}.md
  skills/<skill-name>/SKILL.md
  skills/_shared/                 # cross-skill helper docs (e.g. GraphQL ops)
  governance/                     # *.md loaded by agents at runtime
docs/planning/                    # human-only working notes (not loaded by plugin)
README.md
CLAUDE.md
```

`${CLAUDE_PLUGIN_ROOT}` resolves to `plugin/` because that's where `plugin.json` lives. All cross-refs inside `plugin/` use `${CLAUDE_PLUGIN_ROOT}/...` paths — never relative or repo-rooted paths.

Anything the runtime loads must live under `plugin/`. `docs/` is for human-only notes (planning, design discussion) and is never referenced by agents or skills.

## Editing rules specific to this repo

- **Path refs across plugin files MUST use `${CLAUDE_PLUGIN_ROOT}/...`.** Bare `governance/foo.md` or `agents/foo.md` paths break when consumers install the plugin. Grep for bare paths before merging.
- **Agent frontmatter limits:** Claude Code plugin system does not honor `mcpServers` or `permissionMode` in agent frontmatter. Read-only enforcement on planner is done by restricting `tools:` list, not by `permissionMode`. Don't re-add these fields.
- **Skills are namespaced as `agent-framework:<skill>`** when consumed. Internal cross-references in skill/agent bodies should use the namespaced form so docs match runtime behavior.
- **Governance docs are load-bearing.** Renaming a section header inside `plugin/governance/*.md` may break agent rules that reference that header by name (e.g. `(Required Git Preflight)`, `(Definitions → Trivial change)`). Search for header references before renaming.

## Versioning

Single source of truth: `plugin/.claude-plugin/plugin.json` `"version"`. Bump triggers and policy: `plugin/governance/versioning.md`. README does not carry a version.

## Branching / PR workflow

This repo dogfoods its own plugin's workflow. Authoritative rules: `plugin/governance/branching-pr-workflow.md`, `plugin/governance/agent-system-policy.md`, `plugin/governance/pr-review-remediation-loop.md`. When working here, follow them — orchestrator → working branch → checkpoint commits → PR → Codex review.

Default branches:
- Trunk / PR base: `main`
- Working branch naming: per `branching-pr-workflow.md` (Branch Creation)

## Validation

No build or test suite. "Validation" for changes here is:

1. JSON manifests parse: `python -c "import json; json.load(open('plugin/.claude-plugin/plugin.json'))"` and same for `.claude-plugin/marketplace.json`.
2. No bare path refs introduced — `grep -rE '\b(agents|skills|governance)/' plugin/` should only return `${CLAUDE_PLUGIN_ROOT}/...` lines or `_shared/` references; flag anything else.
3. Smoke install in a scratch Claude Code session before publishing breaking layout changes:
   ```text
   /plugin marketplace add <local-path-or-git-url>
   /plugin install agent-framework@brenpike
   ```

## Common pitfalls

- Adding a new governance doc but forgetting to reference it from an agent → dead file.
- Adding a new skill but forgetting `${CLAUDE_PLUGIN_ROOT}/skills/_shared/...` ref when reusing shared helpers.
- Editing `marketplace.json` `source` away from `./plugin` — breaks consumer installs.
- Putting plugin content at repo root instead of under `plugin/` — `${CLAUDE_PLUGIN_ROOT}` will not resolve where authors expect.

## Companion plugins referenced

`claude-mem:mem-search` is optional — planner uses it when present, skips when absent. Do not hard-require it from any agent or skill.
