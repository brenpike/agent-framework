---
name: setup-project
description: '[DEPRECATED — renamed to seed-hive] One-time project setup. Apply the required `.claude/settings.json` keys (enabledPlugins + default agent) so the overlord becomes the session default agent. This skill is a compatibility stub that forwards to `hivemind:seed-hive`. Use only when adopting the plugin in a new project, when repairing settings, or when the user explicitly requests setup.'
allowed-tools:
  - Skill
shell: bash
---

# Setup Project (deprecated)

## Deprecated

`setup-project` was renamed to `seed-hive` in v2.14.0. This stub exists for backward-compatibility with `/hivemind:setup-project` slash invocations and will be removed in a future MAJOR release.

## Action

1. Print a one-line deprecation notice (`[deprecation] hivemind:setup-project → hivemind:seed-hive`) and invoke `hivemind:seed-hive` via the `Skill` tool, forwarding any arguments the caller supplied. Do not perform settings.json or .gitignore work in this stub — `hivemind:seed-hive` owns all behavior.

## Do Not

- Do not duplicate `hivemind:seed-hive` logic.
- Do not write any files.
- Do not invoke any other skill.
