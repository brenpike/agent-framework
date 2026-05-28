---
name: seed-hive
description: One-time project setup. Apply the required `.claude/settings.json` keys (enabledPlugins + default agent) so the overlord becomes the session default agent. Use only when adopting the plugin in a new project, when repairing settings, or when the user explicitly requests setup. Also ensures `.hivemind/` is excluded from git via `.gitignore`.
allowed-tools:
  - Read
  - Write
  - Bash(git rev-parse *)
  - Bash(test *)
  - Bash(ls *)
  - Bash(grep *)
  - Bash(command -v *)
  - Bash(mkdir -p *)
  - Bash(chmod +x *)
  - Skill
shell: bash
---

## Quick Reference

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
- [ ] `hivemind:creep-spread` invoked (or skipped in dry_run)
- [ ] Test command detected and recorded under `## Validation` in repo-root `CLAUDE.md` if absent (or `already documented` / `none detected`; previewed in dry_run)

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
     Bash(echo *)
     Bash(printf *)
     Bash(cat *)
     Bash(grep *)
     Bash(jq *)
     Bash(head *)
     Bash(tail *)
     Bash(ls *)
     Bash(wc *)
     Bash(sort *)
     Bash(uniq *)
     Bash(git ls-files *)
     Bash(git ls-tree *)
     Bash(git grep *)
     Bash(git tag)
     Bash(git tag -l*)
     Bash(git tag --list*)
     Bash(git stash list)
     Bash(git stash show *)
     Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)
     ```
     The template grants read/output helper Bash commands (`echo`, `printf`, `cat`, `grep`, `jq`, `head`, `tail`, `ls`, `wc`, `sort`, `uniq`), scoped git read subcommands (`git ls-files *`, `git ls-tree *` — both read-only object/working-tree listers; `git tag` is list-only via the three `git tag` / `git tag -l*` / `git tag --list*` forms — never broad `git tag *`, which would permit creating tags), and the codex-companion node entry. These read/output helpers are safe to auto-approve because Claude Code re-prompts (ask/deny) on any command that writes or redirects to a path OUTSIDE the session working directory (only `> /dev/null` is exempt) and splits compound commands (`&&`/`||`/`;`/`|`/newline), requiring each subcommand to match a rule independently. Granting `Bash(echo *)`/`Bash(printf *)`/`Bash(cat *)`/`Bash(sort *)` therefore does NOT create an arbitrary-file-write vector — `echo evil > /etc/passwd`, `printf x > ~/.bashrc`, `sort -o /etc/x`, and `cmd && rm -rf y` all re-prompt. The only silent write any granted helper permits is into the working directory, which is a uniform, bounded surface identical for `jq`/`head`/`tail`/`ls`/`wc`/`uniq`/`grep` as for `echo`/`printf`/`cat`/`sort`. Pipeline skills (`molt`, `create-working-branch`, `open-plan-pr`, `adaptation-cycle`) also grant `Bash(printf *)` via their own `allowed-tools` for routing-data output — safe for the same reason. The codex-companion rule uses the literal placeholder path `/path/to/.claude/plugins/cache/openai-codex/codex/*`; the consumer must replace `/path/to/` with their own home directory path after setup. Do NOT seed `acceptEdits` mode, `Edit`, or `Write` into consumer settings.
6. If `dry_run` = `yes`:
   a. Determine the `.gitignore` action that would be taken: check whether `<project root>/.gitignore` exists and whether it contains `.hivemind/` as a standalone trimmed line (the same check used in step 8b); set the action to `would-create`, `would-append`, or `already-present` accordingly.
   b. If `caveman` = `yes`: determine the `.envrc` action that would be taken: check whether `<project root>/.envrc` exists and whether it contains an active (non-commented) line that, after trimming leading/trailing whitespace, equals `export CAVEMAN_DEFAULT_MODE=ultra` (with or without quotes around `ultra`) (the same check used in step 9b); set the action to `would-create`, `would-append`, or `already-present` accordingly.
   c. If `claude_mem` = `yes`: determine the `claude_mem_path` action that would be taken by applying the same checks as steps 11b–11e, without writing: one of `would-set <resolved-path>` (when `~/.claude-mem/settings.json` exists, is valid JSON, has a missing/empty `CLAUDE_CODE_PATH`, and a `claude` binary resolves), `already set` (key already non-empty), `skipped (claude-mem not installed)` (file absent), `skipped (malformed json)` (file not valid JSON), or `skipped (claude binary not found)` (no `claude` binary resolves).
   d. If `seed_allowlist` = `yes`: determine the `permissions.allow` additions that would be made by applying the same union/append-if-absent check as step 5 and Merge Rules, without writing: for each template rule, classify it as `would-add` (not currently in `permissions.allow`) or `already present`. The merged settings JSON printed in step 6e already reflects these additions; additionally list the would-add vs already-present rules explicitly.
   e. Print the merged settings JSON, the gitignore action, (if `caveman` = `yes`) the envrc action, (if `claude_mem` = `yes`) the claude_mem action, and (if `seed_allowlist` = `yes`) the allowlist would-add / already-present breakdown together.
   f. Stop without writing any of the files governed by steps 7–12 (settings.json, .gitignore, .envrc, .claude/hooks/, ~/.claude-mem/settings.json). Continue to steps 13 and 14, which each carry their own `dry_run` branch (step 13 skips `creep-spread` invocation; step 14h computes and prints the test-command preview without writing).
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
13. Invoke `hivemind:creep-spread` to analyze the project and generate a populated `CONTEXT.md` (or `CONTEXT-MAP.md` for multi-context repos). If `dry_run` = `yes`: skip invocation, report `context_bootstrap: skipped (dry_run)`. The skill has its own skip guard for existing files.
14. Detect the project's test command and record it under a `## Validation` section in the repo-root `CLAUDE.md` if absent. DETECT only — never run, install, or scaffold a harness. Each signal must resolve to a real, executable test command. Step 14a explicitly rejects the `npm/yarn/pnpm init` default placeholder (`Error: no test specified`); other no-op or failing scripts remain a known limitation — review or override the recorded command after setup (dry_run previews the action).
    a. Match each signal below against repo-root or conventional well-known locations. Require the ACTUAL signal, not mere file existence — inspect the file content named in the signal:
       - JS ecosystem (`package.json` present): emit at most ONE command for this ecosystem, choosing the first sub-signal that matches in order. The vitest/jest sub-signals are FALLBACKS — they apply only when the `scripts.test` sub-signal is UNMATCHED for this ecosystem (so a curated `npm test` that handles env flags, setup, or workspace routing is never bypassed by a parallel `npx vitest run` / `npx jest`):
         1. `scripts.test` entry whose value is a string that does NOT contain the case-insensitive substring `Error: no test specified` → that script (`npm test`). When the value DOES contain that substring (the `npm init` / `yarn init` / `pnpm init` placeholder `"echo \"Error: no test specified\" && exit 1"`), treat this sub-signal as UNMATCHED and fall through to sub-signals 2–3 below. The content-based substring match is intentionally runner-agnostic — it auto-covers all three init defaults; do not add per-runner branches. Non-string `scripts.test` values (array, object) are likewise treated as unmatched and fall through. Missing `scripts` object entirely is already unmatched. Accepted tradeoff: chained scripts that mention the placeholder string mid-pipeline (e.g. `"echo \"Error: no test specified\" && vitest run"`) are also rejected by this substring match; sub-signals 2–3 cover the common recovery, and if none of 1–3 match the JS ecosystem contributes nothing and the existing no-signal path applies.
         2. (only when sub-signal 1 is UNMATCHED) `package.json` declares a `vitest` dependency or config → `npx vitest run`.
         3. (only when sub-signals 1–2 are UNMATCHED) `package.json` declares a `jest` dependency or config → `npx jest`.
       - `pyproject.toml` or `setup.py` with a pytest signal (a `pytest` dependency, `[tool.pytest]` config, or `tests/` test files) → `pytest`
       - `go.mod` → `go test ./...`
       - `Cargo.toml` → `cargo test`
       - `*.csproj` or `*.sln` referencing `Microsoft.NET.Test.Sdk` → `dotnet test`
       - `mix.exs` → `mix test`
       - `Gemfile` or `spec/` with an `rspec` signal → `bundle exec rspec`
       - `Makefile` with a real `test:` target → `make test`
    b. When more than one signal matches (a monorepo or multi-ecosystem repo), record ALL detected commands — one per ecosystem. Never pick one, never fabricate a combined runner. Match only root / workspace-root signals; do not emit one command per nested package.
    c. Read repo-root `CLAUDE.md` if present. If it ALREADY documents a test or validation command — the `## Validation` convention — record NOTHING, leave the existing prose untouched (never overwrite or reorder it), and report `already documented`. This is append-if-absent only, identical in spirit to the `.gitignore` / `.envrc` / `CLAUDE_CODE_PATH` guards.
    d. Otherwise, with one or more commands detected, record them under a `## Validation` section in repo-root `CLAUDE.md` as a fenced code block (or a list of fenced blocks when multiple). If the section is missing, append a minimal `## Validation` section containing only the detected command(s); if it exists without a command, append the command(s) into it without touching surrounding content.
    e. If repo-root `CLAUDE.md` does not exist and a command is detected, create a minimal repo-root `CLAUDE.md` containing only the `## Validation` section with the detected command(s).
    f. If NO signal matches, record nothing fabricated: note the absence and RECOMMEND that the user document a validation command manually. NEVER install, scaffold, or invent a harness or command. A documented-validation-only or non-executable repo (a Markdown plugin, a docs repo) is a legitimate outcome.
    g. Re-running is idempotent: when a command is already recorded (step 14c), write nothing and report `already documented` — no duplicate lines or sections.
    h. If `dry_run` = `yes`: compute the action without writing and print it — `would-record <commands>`, `already documented`, or `none-detected (recommend manual)` — consistent with the step 6 previews. Repo-root `CLAUDE.md` ONLY — never per-context `CONTEXT.md` files.

## Merge Rules

- Preserve every existing key that is not in the required-keys list.
- Do not remove or reorder existing entries.
- If a required key already has the correct value, report it as `already present`, not `added`.
- If a required key has a conflicting value (e.g., `agent` set to a different agent), stop blocked and report the conflict. Do not overwrite without explicit user approval.
- `permissions.allow` (when `seed_allowlist` = `yes`) merges as an array union, append-if-absent: keep every existing entry in its original order, then append each template rule whose exact string is not already in the array. Never overwrite, remove, dedupe, or reorder the user's existing entries. A template rule already present is reported as `already present`, not `added`. If `permissions.allow` is absent, create it containing only the template rules (in template order). If `permissions` exists without `allow`, add the `allow` array while preserving other `permissions` keys.

## Do Not

- write any key not listed in step 5 (except `hooks.SubagentStart` when `caveman` = `yes`, as specified in steps 5 and 10d; and `permissions.allow` ONLY when `seed_allowlist` = `yes`, as specified in step 5)
- modify project files outside `.claude/settings.json`, `.gitignore`, `.envrc`, `.claude/hooks/`, repo-root `CLAUDE.md` (create-or-append-if-absent only, per step 14), and files created or modified by invoked skills
- install, scaffold, or invent a test harness; run the detected test command; or overwrite, reorder, or replace an existing documented test/validation command in repo-root `CLAUDE.md` (step 14 detects and records append-if-absent only)
- modify `~/.claude-mem/settings.json` beyond setting its single `CLAUDE_CODE_PATH` key (and only when `claude_mem` = `yes`, the file already exists, the key is empty/missing, and a `claude` binary resolves, per step 11); never overwrite an existing non-empty `CLAUDE_CODE_PATH`, and never touch any other key in that file
- commit, push, or otherwise touch git state
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
- creep-spread: invoked | skipped (dry_run)

test_command:
- repo-root CLAUDE.md ## Validation: recorded <commands> | already documented | none detected (recommend manual) | would-record (dry_run) | skipped (dry_run)

conflicts:
- [key]: existing value vs required value
- None

issues:
- [issue]
- None
```

Use the Worker Report — Blocked schema from `${CLAUDE_PLUGIN_ROOT}/governance/report-format.md` for blocked states.
