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
- `Decisions:` — each entry must carry an anchor ID in `DEC-NNN` format per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Retrieval Anchors)
- `Assumptions:` — each entry must carry an anchor ID in `ASM-NNN` format per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Retrieval Anchors)
- `Open questions:` — unresolved items requiring future attention
- `Artifacts:` — files created or modified with paths
- `Evidence refs:` — each entry must carry an anchor ID in `EVD-NNN` format per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Retrieval Anchors); evidence in the always-externalize categories (test output, build logs, large diffs, command output >50 lines) must be externalized to `.agent-framework/evidence/` regardless of size, and any other evidence exceeding 50 lines must also be externalized — referenced by anchor ID only (see Progressive Evidence Rule below)
- `Next actions:` — what the next phase must do
- `Risk level:` — low | medium | high

All context management fields above are mandatory for non-trivial phase-closing reports. Existing required report fields (`Status`, `Changed`, `Validated`, `Need scope change`, `Issues`) remain required alongside these fields.

## Step Delta

Workers must append a `Step delta:` section to every phase-closing report when a `Step: STEP-NNN` field was included in the delegation. This section enables compact phase-to-phase state transfer.

```text
Step delta:
  Step: STEP-NNN
  Outcome: [what was accomplished]
  Decisions: DEC-NNN — [decision and rationale] (anchor ID required)
  Assumptions unresolved: ASM-NNN — [assumption and impact] (anchor ID required)
  Evidence: EVD-NNN — [one-line synopsis only] (anchor ID required; ≤50 lines inline only when type permits — test output, build logs, large diffs, and command output >50 lines must always be externalized per Progressive Evidence Rule)
```

The orchestrator extracts the `Step delta:` section and all mandatory Context Management Fields after phase verification, stores the full candidate handoff (as a claude-mem observation or under `.agent-framework/handoffs/STEP-NNN.md`), and delegates the next phase with the compact candidate handoff — not the full prior phase report or tool outputs.

## Progressive Evidence Rule

Evidence fields in step-delta and context management fields reference anchors only — inline the anchor ID and a one-line synopsis. Full evidence content must not be inlined beyond 50 lines in any delegation, report, or handoff artifact.

The following evidence types must always be externalized regardless of size (mirrors `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Progressive Evidence Loading)):

- Test output (unit, integration, end-to-end)
- Build logs
- Large diffs (any diff exceeding 50 lines)
- Command output exceeding 50 lines

For all other evidence types, content exceeding 50 lines must be externalized:

1. Write the full evidence body to `.agent-framework/evidence/<ANCHOR-ID>.md` (e.g., `EVD-001.md`).
2. Reference the evidence in the report or step-delta by anchor ID only (e.g., `EVD-001 — [one-line synopsis]`).
3. Do not inline any portion of the externalized evidence beyond the synopsis.

See `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Progressive Evidence Loading) for the canonical always-externalize list and lazy-load triggers.

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
| `task-type` | One of `bugfix\|refactor\|feature\|incident` — resolved at task intake per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Budget Policy — Task-Type Classification) |

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
