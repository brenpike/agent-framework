---
name: setup-project
description: One-time project setup. Apply the required `.claude/settings.json` keys (enabledPlugins + default agent) so the overlord becomes the session default agent. Use only when adopting the plugin in a new project, when repairing settings, or when the user explicitly requests setup. Also ensures `.hivemind/` is excluded from git via `.gitignore`.
allowed-tools:
  - Read
  - Write
  - Bash(git rev-parse *)
  - Bash(test *)
  - Bash(command -v *)
  - Bash(mkdir -p *)
  - Bash(chmod +x *)
  - Skill
shell: bash
---

## Quick Reference

Rules: `REPORT-01` (blocked report contract)

Before:
- [ ] Project root resolved via `git rev-parse --show-toplevel`
- [ ] `.claude/settings.json` read or default `{}` established
- [ ] No conflicting `agent` value exists (or user approved override)
- [ ] `.gitignore` read or default absence noted
- [ ] If `claude_mem` = `yes`: `~/.claude-mem/settings.json` existence checked and (if present) read

After:
- [ ] Required keys applied to `.claude/settings.json`
- [ ] Existing keys preserved
- [ ] Output uses lowercase snake_case field names
- [ ] `.hivemind/` entry ensured in `.gitignore`
- [ ] If `caveman` = `yes`: `.envrc` contains `CAVEMAN_DEFAULT_MODE=ultra`, `pluginConfigs` for caveman applied, SubagentStart hook configured
- [ ] If `claude_mem` = `yes` and `~/.claude-mem/settings.json` present with empty/missing `CLAUDE_CODE_PATH`: key set to dynamically-resolved `claude` path (only that key), and user told to restart the worker
- [ ] `hivemind:bootstrap-context` invoked (or skipped in dry_run)

# Setup Project

Apply the hivemind plugin's required project settings to `.claude/settings.json` so the overlord becomes the session default agent.

This skill is the user-invoked alternative to manually editing `.claude/settings.json` per the README. It is not auto-invoked by the plugin; the user must explicitly request it.

## When to Use

- new project adopting the plugin
- existing project missing the `agent` default
- repairing settings after manual edits broke routing

Do not use this skill to change unrelated settings or to write keys not listed below.

## Required Inputs

None. Operates on the current project root resolved via `git rev-parse --show-toplevel`.

## Optional Inputs

- `caveman`: `yes`|`no` (default `no`) — also enable `caveman@caveman`, configure `pluginConfigs`, set up `.envrc`, and install the SubagentStart hook for caveman ultra mode
- `claude_mem`: `yes`|`no` (default `no`) — also enable `claude-mem@thedotmack` if the user has installed that plugin
- `codex`: `yes`|`no` (default `no`) — also enable `codex@openai-codex` if the user has installed that plugin
- `seed_allowlist`: `yes`|`no` (default `no`) — also merge a recommended least-privilege `permissions.allow` template into the project `.claude/settings.json`. When omitted (default `no`), `permissions.allow` is left untouched and existing behavior is unchanged. Union/append-if-absent only: never overwrites, removes, or reorders the user's existing `permissions.allow` entries
- `dry_run`: `yes`|`no` (default `no`) — print proposed settings, do not write

## Procedure

1. Resolve project root via `git rev-parse --show-toplevel`. Stop blocked if not a git repository or path resolution fails.
2. Determine target file path: `<project root>/.claude/settings.json`.
3. If `<project root>/.claude/` does not exist, create it (`mkdir -p`).
4. If `.claude/settings.json` exists, read it; otherwise treat existing settings as `{}`.
5. Merge required keys, preserving every existing key the user already had:
   - `enabledPlugins["hivemind@brenpike"]` = `true`
   - `agent` = `"hivemind:overlord"`
   - if `caveman` = `yes`: `enabledPlugins["caveman@caveman"]` = `true`
   - if `claude_mem` = `yes`: `enabledPlugins["claude-mem@thedotmack"]` = `true`
   - if `codex` = `yes`: `enabledPlugins["codex@openai-codex"]` = `true`
   - if `caveman` = `yes`: `pluginConfigs["caveman@caveman"].options.defaultLevel` = `"ultra"`
   - if `caveman` = `yes`: `hooks.SubagentStart` entry pointing to `.claude/hooks/caveman-ultra-subagent.sh` (see step 10d for hook structure)
   - if `seed_allowlist` = `yes`: merge the recommended least-privilege template below into `permissions.allow` using union/append-if-absent semantics (see Merge Rules) — append only rules not already present, preserving the user's existing entries and their order. The frozen template rule set (mirror exactly; do not add, drop, or reword entries):
     ```
     Bash(jq *)
     Bash(head *)
     Bash(tail *)
     Bash(ls *)
     Bash(cat *)
     Bash(wc *)
     Bash(sort *)
     Bash(uniq *)
     Bash(echo *)
     Bash(printf *)
     Bash(git ls-files *)
     Bash(git tag *)
     Bash(git grep *)
     Bash(git stash list)
     Bash(git stash show *)
     Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)
     ```
     The codex-companion rule uses the literal placeholder path `/path/to/.claude/plugins/cache/openai-codex/codex/*`; the consumer must replace `/path/to/` with their own home directory path after setup. Do NOT seed `acceptEdits` mode, `Edit`, or `Write` into consumer settings.
6. If `dry_run` = `yes`:
   a. Determine the `.gitignore` action that would be taken: check whether `<project root>/.gitignore` exists and whether it contains `.hivemind/` as a standalone trimmed line (the same check used in step 8b); set the action to `would-create`, `would-append`, or `already-present` accordingly.
   b. If `caveman` = `yes`: determine the `.envrc` action that would be taken: check whether `<project root>/.envrc` exists and whether it contains an active (non-commented) line that, after trimming leading/trailing whitespace, equals `export CAVEMAN_DEFAULT_MODE=ultra` (with or without quotes around `ultra`) (the same check used in step 9b); set the action to `would-create`, `would-append`, or `already-present` accordingly.
   c. If `claude_mem` = `yes`: determine the `claude_mem_path` action that would be taken by applying the same checks as steps 11b–11e, without writing: one of `would-set <resolved-path>` (when `~/.claude-mem/settings.json` exists, is valid JSON, has a missing/empty `CLAUDE_CODE_PATH`, and a `claude` binary resolves), `already set` (key already non-empty), `skipped (claude-mem not installed)` (file absent), `skipped (malformed json)` (file not valid JSON), or `skipped (claude binary not found)` (no `claude` binary resolves).
   d. If `seed_allowlist` = `yes`: determine the `permissions.allow` additions that would be made by applying the same union/append-if-absent check as step 5 and Merge Rules, without writing: for each template rule, classify it as `would-add` (not currently in `permissions.allow`) or `already present`. The merged settings JSON printed in step 6e already reflects these additions; additionally list the would-add vs already-present rules explicitly.
   e. Print the merged settings JSON, the gitignore action, (if `caveman` = `yes`) the envrc action, (if `claude_mem` = `yes`) the claude_mem action, and (if `seed_allowlist` = `yes`) the allowlist would-add / already-present breakdown together.
   f. Stop without writing any files.
7. Write the merged JSON to `.claude/settings.json` with two-space indentation and a trailing newline.
8. Ensure `.hivemind/` is listed in the project's `.gitignore`:
   a. If `<project root>/.gitignore` does not exist, create it with a single line `.hivemind/`.
   b. If `.gitignore` exists, read it. If it already contains `.hivemind/` as a standalone line (trimmed), report `already present` and skip.
   c. Otherwise append `.hivemind/` to the end of the file (prepend a blank line if the file does not end with a newline).
9. If `caveman` = `yes`: ensure `.envrc` contains `export CAVEMAN_DEFAULT_MODE=ultra`:
   a. If `<project root>/.envrc` does not exist, create it with a single line `export CAVEMAN_DEFAULT_MODE=ultra`.
   b. If `.envrc` exists, read it. If it contains an active (non-commented) line that, after trimming leading/trailing whitespace, equals `export CAVEMAN_DEFAULT_MODE=ultra` (with or without quotes around `ultra`), report `already present` and skip. Lines starting with `#` (after trimming) are not active.
   c. Otherwise append `export CAVEMAN_DEFAULT_MODE=ultra` to the end of the file (prepend a newline if the file does not end with one).
10. If `caveman` = `yes`: ensure the SubagentStart hook for caveman ultra mode is configured:
    a. Create `<project root>/.claude/hooks/` directory if it does not exist (`mkdir -p`).
    b. If `<project root>/.claude/hooks/caveman-ultra-subagent.sh` does not exist, create it with the following content and make it executable (`chmod +x`):
       ```bash
       #!/usr/bin/env bash

       cat <<'EOF'
       {
         "hookSpecificOutput": {
           "hookEventName": "SubagentStart",
           "additionalContext": "Caveman mode requirement for this project: operate in caveman ultra mode for this entire subagent conversation. Do not silently fall back to full, lite, or normal verbosity unless the user explicitly requests it."
         }
       }
       EOF
       ```
    c. If the file already exists, report `already present` and skip.
    d. Ensure `.claude/settings.json` contains a `hooks.SubagentStart` entry pointing to `.claude/hooks/caveman-ultra-subagent.sh`. The entry structure is:
       ```json
       {
         "hooks": {
           "SubagentStart": [
             {
               "hooks": [
                 {
                   "type": "command",
                   "command": ".claude/hooks/caveman-ultra-subagent.sh"
                 }
               ]
             }
           ]
         }
       }
       ```
       If already present, report `already present`. If absent, merge it into the settings JSON.
11. If `claude_mem` = `yes`: ensure claude-mem's own `CLAUDE_CODE_PATH` is provisioned. This is a belt-and-suspenders safeguard: the root cause is arguably upstream in claude-mem's background worker (which should self-resolve the `claude` binary), and an empty `CLAUDE_CODE_PATH` causes that worker to silently discard all queued observations. This step is a convenience fix only. Note: `~/.claude-mem/settings.json` is claude-mem's OWN config in the user's HOME directory — it is entirely separate from this repo's project `.claude/settings.json` and must not be confused with it.
    a. If `claude_mem` != `yes`, skip this step entirely; report `claude_mem_path: skipped (claude_mem not enabled)`. The step 5 `enabledPlugins["claude-mem@thedotmack"]` write is independent of this step.
    b. If `~/.claude-mem/settings.json` does not exist, claude-mem is not actually installed: report `claude_mem_path: skipped (claude-mem not installed)` and continue. Do not create the file. The step 5 enabledPlugins write still happens regardless.
    c. Read `~/.claude-mem/settings.json`. If it is not valid JSON, do not crash or clobber it: report `claude_mem_path: skipped (malformed json)` in `issues` and continue without writing.
    d. Inspect the `CLAUDE_CODE_PATH` key. If it is present with any non-empty string value, report `claude_mem_path: already set` and write NOTHING — never overwrite a user-provided value, even if that value points to a now-invalid path. Only act when `CLAUDE_CODE_PATH` is missing or an empty string.
    e. Resolve the `claude` binary path DYNAMICALLY in this order, taking the first that resolves: (1) `command -v claude`; (2) fallback `~/.local/bin/claude` (verify with `test -x`); (3) fallback `~/.claude/local/claude` (verify with `test -x`). Never hard-code a home directory path — expand `~` at runtime. If `command -v claude` resolves to a shell alias or function rather than a real executable, prefer the path it reports if it is an executable file; otherwise continue to the fallbacks. If none resolve, report `claude_mem_path: skipped (claude binary not found)` and write NOTHING.
    f. Otherwise set ONLY the `CLAUDE_CODE_PATH` key to the resolved path, preserving every other key in `~/.claude-mem/settings.json`. Write with two-space indentation and a trailing newline. Report `claude_mem_path: set`.
    g. After setting the path, the claude-mem background worker must be restarted to load the new value. Do NOT auto-restart it (keep this step side-effect-light). PRINT a manual follow-up instruction telling the user to restart the claude-mem worker (e.g. via claude-mem's worker restart) or note that it will pick up the new value on the next session.
12. Report which keys were added vs already present.
13. Invoke `hivemind:bootstrap-context` to analyze the project and generate a populated `CONTEXT.md` (or `CONTEXT-MAP.md` for multi-context repos). If `dry_run` = `yes`: skip invocation, report `context_bootstrap: skipped (dry_run)`. The skill has its own skip guard for existing files.

## Merge Rules

- Preserve every existing key that is not in the required-keys list.
- Do not remove or reorder existing entries.
- If a required key already has the correct value, report it as `already present`, not `added`.
- If a required key has a conflicting value (e.g., `agent` set to a different agent), stop blocked and report the conflict. Do not overwrite without explicit user approval.
- `permissions.allow` (when `seed_allowlist` = `yes`) merges as an array union, append-if-absent: keep every existing entry in its original order, then append each template rule whose exact string is not already in the array. Never overwrite, remove, dedupe, or reorder the user's existing entries. A template rule already present is reported as `already present`, not `added`. If `permissions.allow` is absent, create it containing only the template rules (in template order). If `permissions` exists without `allow`, add the `allow` array while preserving other `permissions` keys.

## Do Not

- write any key not listed in step 5 (except `hooks.SubagentStart` when `caveman` = `yes`, as specified in steps 5 and 10d; and `permissions.allow` ONLY when `seed_allowlist` = `yes`, as specified in step 5)
- modify project files outside `.claude/settings.json`, `.gitignore`, `.envrc`, `.claude/hooks/`, and files created or modified by invoked skills (`hivemind:bootstrap-context`)
- modify `~/.claude-mem/settings.json` beyond setting its single `CLAUDE_CODE_PATH` key (and only when `claude_mem` = `yes`, the file already exists, the key is empty/missing, and a `claude` binary resolves, per step 11); never overwrite an existing non-empty `CLAUDE_CODE_PATH`, and never touch any other key in that file
- commit, push, or otherwise touch git state
- invoke skills other than `hivemind:bootstrap-context`
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
- .envrc: created | updated | already present | would-create | would-append | skipped (dry_run) | skipped (caveman not enabled)

hooks:
- .claude/hooks/caveman-ultra-subagent.sh: created | already present | skipped (caveman not enabled)
- hooks.SubagentStart in settings.json: added | already present | skipped (caveman not enabled)

claude_mem_path:
- ~/.claude-mem/settings.json CLAUDE_CODE_PATH: set | already set | skipped (claude-mem not installed) | skipped (claude binary not found) | skipped (malformed json) | would-set | skipped (claude_mem not enabled)

keys_applied:
- enabledPlugins["hivemind@brenpike"]: added | already present
- agent: added | already present | unchanged
- enabledPlugins["caveman@caveman"]: added | already present | not requested
- enabledPlugins["claude-mem@thedotmack"]: added | already present | not requested
- enabledPlugins["codex@openai-codex"]: added | already present | not requested
- pluginConfigs["caveman@caveman"]: added | already present | not requested

permissions_allow:
- [rule string]: added | already present | would-add (dry_run)
- not requested
# one line per template rule when seed_allowlist = yes; `not requested` when seed_allowlist = no

dry_run: yes | no

context_bootstrap:
- bootstrap-context: invoked | skipped (dry_run)

conflicts:
- [key]: existing value vs required value
- None

issues:
- [issue]
- None
```

Use the Worker Report — Blocked schema from `${CLAUDE_PLUGIN_ROOT}/governance/report-format.md` for blocked states.
