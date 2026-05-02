# Communication Policy

## Purpose

Defines agent-to-agent communication standards and shared report contracts.

## Communication Standard

Agent-to-agent communication must be field-based.

Rules:

- every line of the report must be either a heading, a labeled field of the form `Field: value`, a list item under such a field, or blank — no standalone sentences outside a field
- include every required section in the contract being used (Shared Worker Report Contract or Blocked Report Contract)
- include an optional section only when at least one item exists for it; otherwise omit the section heading entirely
- report facts, blockers, scope needs, validation, versioning, review state, and git state directly
- do not restate policy or workflow rules inside routine reports

## Shared Worker Report Contract

Use this by default for planner-delegated worker output:

```text
Status: complete | partial | blocked

Changed:
- path/to/file
- None

Validated:
- [check]
- Not run

Need scope change:
- path/to/file: reason
- None

Issues:
- [issue]
- None
```

Optional lines. Include each line below only when its trigger fires; otherwise omit the line entirely.

- `Refs: ...` — when the worker consulted external docs, prior commits, or memory; list them
- `States handled: ...` — when the assignment had a `States:` or `Edge cases:` field; list each state addressed
- `Commit: ...` — when the worker is delegated to commit (per Authority Matrix); include the SHA
- `Version: required|none|unknown` — when the changed files match the project's bump-trigger paths or, when undefined, do not match the "No bump is required by default" list
- `Review item: ...` — when the work was review-remediation; include the comment ID or thread ID
- `Git issue: ...` — when git state matches the "Unsafe git state" definition or any preflight item is undefined
- `Ready to resolve: yes|no` — when the work was review-remediation

## Blocked Report Contract

Use this for blocked planning, execution, validation, git, versioning, review, monitoring, or skill states:

```text
Status: blocked
Stage: [planning | implementation | validation | git workflow | versioning | review remediation | monitoring | skill selection | fetch | parse | route]
Blocker: [one-line reason]
Retry status: [not attempted | retried once | exhausted]
Fallback used: [none | description]
Impact: [what cannot proceed]
Next action:
- [specific next step]
```
