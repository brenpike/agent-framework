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
- `Git issue: ...` — when git state matches the "Unsafe git state" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` or any preflight item is undefined
- `Ready to resolve: yes|no` — when the work was review-remediation

## Context Management Fields (Handoff Schema)

At phase close, workers must capture the following fields in addition to the standard report contract fields above. These fields form the handoff artifact — stored as claude-mem observations when available, or as an in-session artifact under `.agent-framework/handoffs/` when claude-mem is absent.

Required observation fields:
- `Objective:` — the phase's stated goal
- `Scope in:` — files/areas included
- `Scope out:` — files/areas explicitly excluded
- `Decisions:` — DEC-NNN tagged list (use descriptive labels in Slice 1)
- `Assumptions:` — ASM-NNN tagged list (use descriptive labels in Slice 1)
- `Open questions:` — unresolved items requiring future attention
- `Artifacts:` — files created or modified with paths
- `Evidence refs:` — EVD-NNN tagged list (commit SHAs, test output, artifact refs)
- `Next actions:` — what the next phase must do
- `Risk level:` — low | medium | high

Contract compatibility note: existing required report fields (`Status`, `Changed`, `Validated`, `Need scope change`, `Issues`) remain required. Context management fields are additive in Slice 1. Hard requirement enforcement deferred to Slice 2.

## Step Delta

Workers must append a `Step delta:` section to every phase-closing report when a `Step: STEP-NNN` field was included in the delegation. This section enables compact phase-to-phase state transfer.

```text
Step delta:
  Step: STEP-NNN
  Outcome: [what was accomplished]
  Decisions: DEC-NNN — [decision and rationale]
  Assumptions unresolved: ASM-NNN — [assumption and impact]
  Evidence: EVD-NNN — [test output / commit SHA / artifact ref]
```

The orchestrator extracts the `Step delta:` section after phase verification, stores it (as a claude-mem observation or under `.agent-framework/handoffs/STEP-NNN.md`), and delegates the next phase with only the compact step-delta — not the full prior phase report or tool outputs.

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

## Session Fact Cache

Certain facts are resolved repeatedly during a task. Agents may cache them to avoid redundant lookups.

### Cacheable Facts

| Fact | Description |
|------|-------------|
| trunk | Resolved trunk branch name (e.g., `main`) |
| validation commands | The declared validation command(s) from CLAUDE.md |
| artifact paths | Canonical version file and required mirrors from CLAUDE.md |
| review policy | Whether review-on-PR is true in CLAUDE.md |
| version file | Current version string at task start |
| bump-trigger-paths | Whether CLAUDE.md defines project-specific bump-trigger paths (`defined` \| `undefined`) |
| `active-step` | Current `STEP-NNN` ID from the active plan |

### Cache Rules

- Agents MAY cache these facts after resolving them during a task
- Cached values MAY be passed in a `Session facts:` block in delegation templates or final reports
- Fresh checks always override cached values — cache is advisory only
- Agents must not treat cached values as authoritative when the underlying file or state may have changed

### Staleness Conditions

Cache must be discarded when any of the following occurs:

- Rebase or history rewrite on the working branch
- Base branch advances (new commits on trunk since cache was set)
- CLAUDE.md is modified during the task
- Plan is re-sequenced or step is re-assigned by orchestrator (`active-step`)
