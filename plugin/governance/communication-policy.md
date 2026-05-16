# Communication Policy

## Communication Standard

Agents communicate via structured YAML documents. Every report and delegation must parse as valid YAML. Include only fields relevant to the report type; omit optional fields when empty.

Evidence handling: always externalize test output, build logs, diffs >50 lines, and command output >50 lines to `.agent-framework/evidence/<EVD-NNN>.md`. All other evidence: max 50 lines inline — exceeding this threshold requires externalization. Reference externalized evidence by anchor ID only. See `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Progressive Evidence Loading) for the canonical always-externalize list and lazy-load triggers.

## Worker Report — Complete (Non-Trivial)

Use for any phase-closing report when the delegation included `step: STEP-NNN`.

```yaml
status: complete
step: STEP-001
outcome: [what was accomplished]
changed: [file1, file2]
validated:
  check_name: pass|fail
version: required|none
scope_out: ["*"]
decisions:
  DEC-001: [decision and rationale]
risks:
  RISK-001: [description]:[low|medium|high]
assumptions:
  ASM-001: [assumption]
evidence:
  EVD-001: [one-line synopsis]
next: [what next phase must do]
risk_level: low|medium|high
```

Field notes:
- `decisions`, `risks`, `assumptions`, `evidence` — anchor IDs per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Retrieval Anchors)
- `risks` — list `None` when no concrete risks were identified
- `evidence` — one-line synopsis only; full content externalized per evidence handling rules above
- `scope_out` — files/areas explicitly excluded; use `["*"]` for none

## Worker Report — Blocked

Use when any stage cannot proceed.

```yaml
status: blocked
stage: [planning|implementation|validation|git|versioning|review|monitoring]
blocker: [one-line reason]
retry: [not attempted|retried once|exhausted]
impact: [what cannot proceed]
next: [specific next step]
```

## Worker Report — Trivial

Use when the delegation carried no `step:` field and the change is trivial.

```yaml
status: complete
changed: [file]
validated:
  check: pass
```

## Delegation Template

```yaml
task: [required outcome]
step: STEP-001
bypass: TRIVIAL_CHANGE
files: [exact file list]
done_when: [observable completion condition]
depends_on: [prior phase output | none]
edge_cases: [case list]
git:
  class: refactor
  base: main
  work: refactor/governance-dedup-compression
  worktree: no
  commit: checkpoint expected
  pr: main
  model: sonnet
constraints: [list]
anchor_reservation:
  DEC: "001-003"
  RISK: "001-002"
  ASM: "001-002"
  EVD: "001-003"
memory_context: [results | none]
session_facts:
  trunk: main
  validation: "jq . plugin/.claude-plugin/plugin.json > /dev/null"
  task_type: refactor
  claude_mem: present
  active_step: STEP-001
```

Variant fields — include inline when the delegation type requires them:

- **Version bump:** add `version: {from: X.Y.Z, to: A.B.C}`. Model: sonnet.
- **Review remediation:** add `review: {pr: N, source: Codex|human, thread: id, classification: type, severity: P0|P1|P2}`. Constraint: do not resolve threads.

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
| `active-task` | Synthetic `TASK-NNN` ID for delegations carrying a Step-omitting Bypass Allowlist code per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Bypass Code Matrix), assigned at intake. Used in lieu of `active-step` only when `Step: STEP-NNN` is omitted, so Path B partial checkpoints have a stable identifier. |
| `task-type` | One of `bugfix\|refactor\|feature\|incident` — resolved at task intake per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Task-Type Classification) |
| `claude-mem` | One of `present\|absent` — resolved at task intake by checking `~/.claude/settings.json` and `<project root>/.claude/settings.json` for `"claude-mem@thedotmack": true` under `enabledPlugins` per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (claude-mem Detection) |
| `trunk-freshness` | One of `fresh\|stale (N behind)\|stale (diverged — local N ahead)\|stale (diverged — local M ahead, N behind)\|skipped` — resolved during Required Git Preflight trunk freshness check; skipped when skip conditions from `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Trunk Freshness Gate) apply |

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
