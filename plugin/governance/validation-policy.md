# Validation Policy

## Purpose

Defines versioning enforcement and external review policy rules for all agents.

## Versioning Enforcement

`versioning.md` is mandatory for versioned artifacts. See `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`.

The orchestrator owns bump detection and bump type decisions. The coder may edit version/release metadata only when explicitly delegated.

A PR that requires a version bump is not ready until required version/release metadata is included.

If project-specific version paths or canonical version sources are unclear, stop and ask the user.

## External Review Policy

`pr-review-remediation-loop.md` is mandatory for external PR feedback. See `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`.

The orchestrator owns review feedback classification, routing, replies, resolution, and re-review requests.

Skills may perform classification only as orchestrator-invoked workflow steps. Ownership remains with the orchestrator.

Workers may remediate assigned feedback within explicit file scope. They must not reply to or resolve review threads unless explicitly delegated and allowed by policy.

Use the narrowest matching skill:

- `agent-framework:address-pr-feedback` — one-time PR-feedback fix (Codex, human reviewer, or bot comments); user request lacks watch-mode keywords
- `agent-framework:watch-pr-feedback` — user request contains at least one of `watch`, `monitor`, `wait`, `poll`, or `loop`

Full routing rule: see Definitions → One-time vs watch routing.
