---
name: setup-project
description: One-time project setup. Apply the required `.claude/settings.json` keys (enabledPlugins + default agent) so the orchestrator becomes the session default agent. Use only when adopting the plugin in a new project, when repairing settings, or when the user explicitly requests setup. Also ensures `.agent-framework/` is excluded from git via `.gitignore`.
allowed-tools:
  - Read
  - Write
  - Bash(git rev-parse *)
  - Bash(test *)
  - Bash(mkdir -p *)
shell: bash
---

## Quick Reference

Rules: `REPORT-01` (blocked report contract)

Before:
- [ ] Project root resolved via `git rev-parse --show-toplevel`
- [ ] `.claude/settings.json` read or default `{}` established
- [ ] No conflicting `agent` value exists (or user approved override)
- [ ] `.gitignore` read or default absence noted

After:
- [ ] Required keys applied to `.claude/settings.json`
- [ ] Existing keys preserved
- [ ] Output uses lowercase snake_case field names
- [ ] `.agent-framework/` entry ensured in `.gitignore`
- [ ] `.envrc` contains `CAVEMAN_DEFAULT_MODE=ultra`
- [ ] `pluginConfigs` for caveman applied to `.claude/settings.json`

# Setup Project

Apply the agent-framework plugin's required project settings to `.claude/settings.json` so the orchestrator becomes the session default agent.

This skill is the user-invoked alternative to manually editing `.claude/settings.json` per the README. It is not auto-invoked by the plugin; the user must explicitly request it.

## When to Use

- new project adopting the plugin
- existing project missing the `agent` default
- repairing settings after manual edits broke routing

Do not use this skill to change unrelated settings or to write keys not listed below.

## Required Inputs

None. Operates on the current project root resolved via `git rev-parse --show-toplevel`.

## Optional Inputs

- `claude_mem`: `yes`|`no` (default `no`) — also enable `claude-mem@thedotmack` if the user has installed that plugin
- `codex`: `yes`|`no` (default `no`) — also enable `codex@openai-codex` if the user has installed that plugin
- `dry_run`: `yes`|`no` (default `no`) — print proposed settings, do not write

## Procedure

1. Resolve project root via `git rev-parse --show-toplevel`. Stop blocked if not a git repository or path resolution fails.
2. Determine target file path: `<project root>/.claude/settings.json`.
3. If `<project root>/.claude/` does not exist, create it (`mkdir -p`).
4. If `.claude/settings.json` exists, read it; otherwise treat existing settings as `{}`.
5. Merge required keys, preserving every existing key the user already had:
   - `enabledPlugins["agent-framework@brenpike"]` = `true`
   - `agent` = `"agent-framework:orchestrator"`
   - `enabledPlugins["caveman@caveman"]` = `true`
   - if `claude_mem` = `yes`: `enabledPlugins["claude-mem@thedotmack"]` = `true`
   - if `codex` = `yes`: `enabledPlugins["codex@openai-codex"]` = `true`
   - `pluginConfigs["caveman@caveman"].options.defaultLevel` = `"ultra"`
6. If `dry_run` = `yes`:
   a. Determine the `.gitignore` action that would be taken: check whether `<project root>/.gitignore` exists and whether it contains `.agent-framework/` as a standalone trimmed line (the same check used in step 8b); set the action to `would-create`, `would-append`, or `already-present` accordingly.
   b. Determine the `.envrc` action that would be taken: check whether `<project root>/.envrc` exists and whether it contains an active (non-commented) line that, after trimming leading/trailing whitespace, equals `export CAVEMAN_DEFAULT_MODE=ultra` (with or without quotes around `ultra`) (the same check used in step 9b); set the action to `would-create`, `would-append`, or `already-present` accordingly.
   c. Print the merged settings JSON, the gitignore action, and the envrc action together.
   d. Stop without writing any files.
7. Write the merged JSON to `.claude/settings.json` with two-space indentation and a trailing newline.
8. Ensure `.agent-framework/` is listed in the project's `.gitignore`:
   a. If `<project root>/.gitignore` does not exist, create it with a single line `.agent-framework/`.
   b. If `.gitignore` exists, read it. If it already contains `.agent-framework/` as a standalone line (trimmed), report `already present` and skip.
   c. Otherwise append `.agent-framework/` to the end of the file (prepend a blank line if the file does not end with a newline).
9. Ensure `.envrc` contains `export CAVEMAN_DEFAULT_MODE=ultra`:
   a. If `<project root>/.envrc` does not exist, create it with a single line `export CAVEMAN_DEFAULT_MODE=ultra`.
   b. If `.envrc` exists, read it. If it contains an active (non-commented) line that, after trimming leading/trailing whitespace, equals `export CAVEMAN_DEFAULT_MODE=ultra` (with or without quotes around `ultra`), report `already present` and skip. Lines starting with `#` (after trimming) are not active.
   c. Otherwise append `export CAVEMAN_DEFAULT_MODE=ultra` to the end of the file (prepend a newline if the file does not end with one).
10. Report which keys were added vs already present.

## Merge Rules

- Preserve every existing key that is not in the required-keys list.
- Do not remove or reorder existing entries.
- If a required key already has the correct value, report it as `already present`, not `added`.
- If a required key has a conflicting value (e.g., `agent` set to a different agent), stop blocked and report the conflict. Do not overwrite without explicit user approval.

## Do Not

- write any key not listed in step 5
- modify project files outside `.claude/settings.json`, `.gitignore`, and `.envrc`
- commit, push, or otherwise touch git state
- invoke other skills
- proceed if the project root cannot be resolved

## Output

```text
status: complete | partial | blocked

project_root:
- [absolute path]

target_file:
- .claude/settings.json: created | updated | unchanged

gitignore:
- .gitignore: created | updated | already present | skipped (dry_run)

envrc:
- .envrc: created | updated | already present | would-create | would-append | skipped (dry_run)

keys_applied:
- enabledPlugins["agent-framework@brenpike"]: added | already present
- agent: added | already present | unchanged
- enabledPlugins["caveman@caveman"]: added | already present
- enabledPlugins["claude-mem@thedotmack"]: added | already present | not requested
- enabledPlugins["codex@openai-codex"]: added | already present | not requested
- pluginConfigs["caveman@caveman"]: added | already present

dry_run: yes | no

conflicts:
- [key]: existing value vs required value
- None

issues:
- [issue]
- None
```

Use the blocked report contract from `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` for blocked states.
