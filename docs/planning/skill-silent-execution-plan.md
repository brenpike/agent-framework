# Skill Silent Execution Plan

## Summary

Convert all pipeline-critical skills from text-output to silent execution (tool-calls only). Root cause of pipeline halting: skills produce text containing "Status: complete" as their final action, which ends the model's turn and halts pipeline execution.

## Branch

`refactor/yaml-communication-protocol` — same branch as PR 89. Avoids merge conflicts with the YAML communication protocol changes already landed there.

## Root Cause

When a skill writes text output (e.g., "Status: complete\nBranch: ...\nCommit: ..."), that text is the model's final generation in the turn. Claude Code's turn boundary: last output = text with no subsequent tool call = turn complete = wait for user input. Pipeline halts.

Workers (via Agent tool) don't have this problem — Agent tool creates a subprocess, output returns as tool_result, orchestrator continues. Skills (via Skill tool) execute within the orchestrator's context — their text IS the orchestrator's text.

## Design Decisions

| # | Decision | Rationale |
|---|---|---|
| DEC-001 | No `report_source: skill` discriminator | The `after=` token mechanism already distinguishes skills from workers. Adds token overhead for no functional gate. |
| DEC-002 | Minimal result data — only new info for routing | Skills should not echo back inputs the orchestrator already knows (base, classification, working_branch, etc.) |
| DEC-003 | Convention in communication-policy.md, not a formal schema | Each skill has unique domain fields. A shared schema adds no value. 3-4 rules suffice. |
| DEC-004 | YAML convention for data format, no code fences | Valid YAML prevents drift back to space-in-keys chaos. Code fences waste tokens. |
| DEC-005 | Skills produce zero text output | Text output = turn ends = pipeline halts. Root cause fix. |
| DEC-006 | Skills end on a tool call as their final action | Tool call = model gets result back = can continue generating = orchestrator resumes. |
| DEC-007 | Full silence — no mid-execution narration | Token savings, consistency with Continuous Execution Rule, prevents mid-narration from accidentally being last action. |
| DEC-008 | Exit code as success/failure signal: 0 = proceed, 1 = needs user decision | Binary gate. Orchestrator reads exit code to determine succeeded/blocked. |
| DEC-009 | No "status: complete" or "status: blocked" anywhere in skill output | The string itself confuses the LLM's state machine regardless of where it appears (text or tool_result). |
| DEC-010 | STT skill rows use `succeeded`/`blocked` vocabulary | Distinct from worker rows which keep `status: complete`/`status: blocked`. Eliminates confusion vector. |
| DEC-011 | `local-codex-review` → user-invocable: false | One behavior per skill. No dual-mode logic. User reviews go through orchestrator → review-loop-controller → Final Report. |
| DEC-012 | Complex loop skills flagged for future Agent conversion | Own context window, proper subprocess isolation, internal return. Separate future work. |
| DEC-013 | Governance files updated to codify all decisions | communication-policy.md, orchestrator.md, agent-system-policy.md all need updates. |

## Implementation Phases

### Phase 1: Governance + Orchestrator

**Files:**
- `plugin/governance/communication-policy.md`
- `plugin/agents/orchestrator.md`
- `plugin/governance/agent-system-policy.md`

**Changes:**

communication-policy.md — Add "Skill Output Convention" section:
- Pipeline skills produce zero text output (no narration, no structured output blocks)
- Final action is always a tool call
- Exit code 0 = orchestrator proceeds, exit code 1 = blocked (needs user decision)
- Blocked reason in stderr, routing data in stdout
- No `status:` field in skill output — ever
- Data format: valid YAML, snake_case keys, minimal (only new info for routing)

orchestrator.md:
- STT skill rows: `status: complete` → `succeeded`, `status: blocked` → `blocked`
- Add under Phase Verification or Skill Routing: "Pipeline skills are not phases. Do not apply Phase Verification to skill execution. After a pipeline skill's final tool call returns, determine outcome from exit code (0 = succeeded, 1 = blocked), read routing data from stdout, match the `after=` token, and execute GOTO."
- Update Skill Routing note: local-codex-review no longer user-invocable
- Remove any reference to reading skill "output text" — replace with reading final Bash result

agent-system-policy.md:
- Clarify REPORT-01 applies to worker reports and user-facing skills only, not pipeline skills

### Phase 2: Simple Pipeline Skills

**Files:**
- `plugin/skills/checkpoint-commit/SKILL.md`
- `plugin/skills/create-working-branch/SKILL.md`
- `plugin/skills/open-plan-pr/SKILL.md`
- `plugin/skills/request-github-codex-review/SKILL.md`

**Per-skill changes:**
- Remove `## Output` section entirely
- Add execution discipline: "Do not produce any text output at any point during execution. Your only outputs are tool calls. Your final action must be a Bash tool call."
- Restructure procedure so final step is naturally a Bash command
- Update Quick Reference: remove "Output uses skill output contract" checkbox
- Blocked = `printf 'blocker: <reason>' >&2; exit 1` as final Bash call

**Final Bash stdout (exit 0) per skill:**

| Skill | What exits stdout on success |
|---|---|
| checkpoint-commit | Natural `git commit` output (SHA + message) |
| create-working-branch | Natural `git switch`/`git checkout` output (branch confirmation) |
| open-plan-pr | `gh pr view` JSON with url + headRefOid (verification step already exists) |
| request-github-codex-review | Natural `gh pr comment` output (confirmation) |

### Phase 3: Complex Pipeline Skills

**Files:**
- `plugin/skills/review-loop-controller/SKILL.md`
- `plugin/skills/local-codex-review/SKILL.md`
- `plugin/skills/watch-github-pr-feedback/SKILL.md`
- `plugin/skills/address-github-pr-feedback/SKILL.md`

**Changes:**
- Same "no text, end on tool call" discipline
- `local-codex-review`: remove `user-invocable: true` from frontmatter. Final Bash = printf with findings YAML (exit 0) or blocker (exit 1).
- `review-loop-controller`: already writes ledger. Final action = Bash printf with exit_reason + routing summary. Orchestrator reads ledger for full detail if needed.
- `watch-github-pr-feedback`: Final Bash = printf with classified feedback items (exit 0) or stop-reason (exit 1). Monitor runs separately.
- `address-github-pr-feedback`: classify mode final = Bash printf with classification + routing. Post-fix mode final = the GraphQL/gh command itself.

**Complex skill data format (Bash stdout, valid YAML):**

Example — review-loop-controller exit 0:
```yaml
exit_reason: none
iteration: 1
findings:
  - id: abc123
    classification: actionable-code-change
    routing: coder
    severity: P1
    file: src/foo.ts
    title: Missing null check
open_count: 1
resolved_count: 0
```

Example — review-loop-controller exit 1:
```
blocker: max-iterations-reached
iteration: 10
open_count: 2
```

### Phase 4: Setup-Project (Standalone)

**Files:**
- `plugin/skills/setup-project/SKILL.md`

**Changes:**
- Fix `Status:` → `status:` (capital-S bug from pre-PR-89)
- Normalize field names to snake_case
- This skill stays user-facing (text output preserved — user wants to see setup results)

## Skills NOT Modified

| Skill | Reason |
|---|---|
| `plan-interrogation` | User-interactive, conversational, no structured output |
| `tdd` | Invoked by coder (worker context), user-facing, no pipeline role |

## Risks

| # | Risk | Mitigation |
|---|---|---|
| RISK-001 | Model doesn't resume orchestrator behavior after skill's final tool call | Explicit instruction in orchestrator.md: "After pipeline skill's final tool call, match STT immediately." |
| RISK-002 | review-loop-controller ↔ local-codex-review interaction breaks | Both change in same phase. Verify controller reads codex-review's Bash output. |
| RISK-003 | Exit code 1 from Bash command failures confused with "blocked" signal | Skills handle command failures internally (retry/error handling) before reaching intentional exit 1. |
| RISK-004 | watch-github-pr-feedback + Monitor interaction with "no text" rule | Monitor is separate mechanism. Skill processes events via tool calls. Flag for future Agent conversion. |
| RISK-005 | Phase Verification accidentally applied to skill execution | Explicit "Skills ≠ phases" clarification in orchestrator.md Phase 1. |

## Future Work (Out of Scope)

- Convert review-loop-controller, watch-github-pr-feedback to Agent-based invocation (own context window)
- Evaluate address-github-pr-feedback and local-codex-review for Agent conversion
- Consider whether setup-project should also adopt silent pattern

## Validation

Per CLAUDE.md:
1. `jq . plugin/.claude-plugin/plugin.json > /dev/null`
2. `jq . .claude-plugin/marketplace.json > /dev/null`
3. `grep -rE '\b(agents|skills|governance)/' plugin/` — only `${CLAUDE_PLUGIN_ROOT}/...` or `_shared/`

## Versioning

- Impact: required
- Bump type: patch (internal communication protocol, no public API change)
- Artifact: `plugin/.claude-plugin/plugin.json`
