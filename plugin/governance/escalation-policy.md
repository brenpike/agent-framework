# Escalation Policy

## Purpose

Defines the conditions under which agents must stop and escalate rather than guessing.

## Escalation Rules

Stop and report instead of guessing when any of the following is true:

- correctness requires editing a file not listed in the assignment
- the requested change crosses an ownership boundary in the Authority Matrix
- a designer task requires a "Material visual decision" (see Definitions) without project-level design guidance present
- a designer task requires runtime behavior, state derivation, data flow, routing, runtime keyboard handling, or live-region behavior
- git state matches the "Unsafe git state" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`
- any item from `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Required Git Preflight) is undefined
- the change matches more than one row of `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` Bump Type Determination, or matches none, or — for an artifact that requires a bump — `CLAUDE.md` does not list the full set of artifact files per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` (Bump Execution): canonical version file, required mirrors, changelog/release notes, package/artifact metadata, documentation mirrors, and release validation files when applicable
- feedback's classification per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` is one of `question-needs-user-input`, `architecture-or-contract-concern`, or `version-or-release-concern`; OR the comment body is tagged `P0`; OR the comment body names any of `CVE`, `CWE`, `auth`, `secret`, `credential`, `SSRF`, `RCE`, `injection`, `XSS`
- validation cannot be run AND the change touches any of: public API, runtime behavior, build/package output, version/release files, or files explicitly listed in `CLAUDE.md` as requiring validation
