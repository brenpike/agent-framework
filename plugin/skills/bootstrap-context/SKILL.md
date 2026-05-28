---
name: bootstrap-context
description: '[DEPRECATED — renamed to creep-spread] Analyze project artifacts and generate a populated CONTEXT.md (or CONTEXT-MAP.md and multiple CONTEXT.md files for multi-context repos). This skill is a compatibility stub that forwards to `hivemind:creep-spread`.'
allowed-tools:
  - Skill
shell: bash
---

# Bootstrap Context (deprecated)

## Deprecated

`bootstrap-context` was renamed to `creep-spread` in v2.14.0. This stub exists for backward-compatibility with `/hivemind:bootstrap-context` slash invocations and will be removed in a future MAJOR release.

## Action

1. Print a one-line deprecation notice (`[deprecation] hivemind:bootstrap-context → hivemind:creep-spread`) and invoke `hivemind:creep-spread` via the `Skill` tool, forwarding any arguments the caller supplied. Do not perform CONTEXT.md generation in this stub — `hivemind:creep-spread` owns all behavior.

## Do Not

- Do not duplicate `hivemind:creep-spread` logic.
- Do not write any files.
- Do not invoke any other skill.
