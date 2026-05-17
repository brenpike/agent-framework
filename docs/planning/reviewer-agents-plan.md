# Reviewer Agents Architecture Plan

## Document Purpose

Self-contained implementation plan for introducing two specialist reviewer agents (`local-reviewer` and `github-reviewer`) to the agent-framework plugin. Covers problem statement, architecture decisions, communication contracts, governance changes, phasing, risks, and validation.

---

## Problem Statement

The orchestrator currently carries heavy code review logic across two distinct flows:
- **Pre-PR local review** (Step 13a): iterative Codex review loop with fix delegation, break-fix detection, validation, checkpointing
- **Post-PR GitHub review** (Step 15): external review monitoring, feedback classification, fix delegation, push, thread resolution

Pain points:
1. **Orchestrator overload** — Steps 13a and 15 are substantial procedural algorithms with multi-step branching. ~37 State Transition Table rows (rows 42-78, ~43% of all transitions) dedicated to review logic.
2. **Skills can't delegate** — Per agent-system-policy.md, skills must return routing recommendations to orchestrator for fix delegation. Every fix requires a round-trip.
3. **Duplicated routing logic** — The routing table (classification → agent) appears in 5 places: review-loop-controller, watch-github-pr-feedback, address-github-pr-feedback, pr-review-remediation-loop.md, and orchestrator's step 13a/15 logic.
4. **Context window cost** — Orchestrator loads full review governance (pr-review-remediation-loop.md, monitoring-policy.md, security-policy.md injection rules) alongside all other responsibilities.
5. **No context isolation** — Long-running local review iterations pollute context when GitHub review starts immediately after.

---

## Architecture Decision: Two Specialist Agents

### Options Evaluated

| Option | Description | Verdict |
|---|---|---|
| 1. Single unified `reviewer` agent | One agent handles both local and GitHub flows | Mixed concerns; large agent; no context isolation between flows |
| 2. Separate `local-reviewer` + `github-reviewer` | Two focused agents, each owning one distinct flow | **Chosen** — clean separation, fresh context per flow, natural skill-to-agent promotion |
| 3. `reviewer` agent without fix delegation | Reviewer classifies but returns to orchestrator for all delegation | Marginal improvement; doesn't solve core problem |

### Why Option 2

- **Natural evolution** — `review-loop-controller` and `watch-github-pr-feedback` already have agent-shaped logic; this is promotion not invention
- **Fresh context per flow** — Local review may consume 5-10 iterations; GitHub reviewer starts with clean context
- **Focused tool surfaces** — local-reviewer needs no Monitor/gh/push; github-reviewer needs no fix-ledger/break-fix-detection
- **Failure isolation** — Bug in GitHub review logic cannot affect local review
- **56% shared / 44% divergent** logic ratio — borderline, but divergent parts (loop mechanics, state management, I/O boundary, tool requirements, exit conditions) are substantial enough to justify separation

### Delegation Model: Pattern A (Always Return to Orchestrator)

Reviewer agents NEVER delegate fixes directly. They:
- Own iteration/monitoring logic
- Own classification pipeline (invoke shared subagents)
- Own break-fix detection
- Own state management (fix ledger / remediation ledger)
- Return structured YAML results with classification + routing recommendations

Orchestrator:
- Receives findings with routing recommendations
- Delegates fixes to coder/designer/planner (may invoke planner for complex fixes)
- Sends fix results back to reviewer for next iteration
- Owns user communication for escalations

Rationale: If reviewer delegated directly to coder, complex multi-file findings would skip planning. "Question-needs-user-input" and escalation cases break if reviewer surfaces directly. Orchestrator retains delegation authority and planner safety.

### Agent Lifetime: Iterative Re-invocation

SendMessage/long-lived agents require `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` which is gated behind experimental flag with known availability issues (GitHub issues #37051, #35240, #42737).

Chosen approach: Orchestrator invokes reviewer agent via Agent tool per iteration, passing accumulated state. Reviewer returns structured results. Orchestrator drives loop externally. Same proven pattern as current `review-loop-controller` skill.

### Break-Fix Detection: Same Algorithm Both Agents

Both agents implement identical break-fix detection:
- SHA-based finding deduplication (finding `id` = SHA-256 of `file + line_start + line_end + title`)
- Repeat-fix counter
- Signals: line-range overlap, git revert, N-2 iteration delta
- Invoke shared `break-fix-detector.md` subagent

---

## Communication Contracts

### Orchestrator → local-reviewer (input)

```yaml
mode: iterate | continue
base: <branch>
working_branch: <branch>
trunk: <branch>
claude_mem: present | absent
max_iterations: <int>  # default 10
fix_results:           # on continue only
  - finding_id: <sha>
    fix_sha: <commit-sha>
    validated: yes | not applicable
```

### local-reviewer → Orchestrator (output)

```yaml
exit_reason: none | clean | max-iterations-reached | break-fix-break | injection-suspect | user-input-required
iteration: <int>
open_count: <int>
resolved_count: <int>
fix_commits_exist: true | false
findings:
  - id: <finding_id>
    classification: <classification>
    routing: coder | designer | planner | none
    severity: <severity_category>
    file: <file_path>
    title: <finding_title>
# On injection-suspect:
finding_id: <id>
pattern_category: <P1-P4>
# On break-fix-break:
signals_fired: <list>
conflicting_findings: <list>
prior_fix_commit: <sha>
```

### Orchestrator → github-reviewer (classify mode input)

```yaml
mode: classify
pr: <number or URL>
target: <comment URL or ID>  # optional
```

### Orchestrator → github-reviewer (watch mode input)

```yaml
mode: watch
pr: <number or URL>
reviewer_filter: codex-only | all | <author>
max_watch_duration: <seconds>  # default 14400
poll_interval: <seconds>  # default 60
max_remediation_cycles: <int>  # default 3
```

### github-reviewer → Orchestrator (classify mode output)

```yaml
mode: classify
candidate_url: <url>
source_kind: inline-review-thread | top-level-pr-comment | review-summary
classification: <classification>
severity_category: standard | P0 | P1 | security
routing: coder | designer | planner | none
thread_id: <id>
target_comment_id: <id>
rationale_action: post-rejection-reply  # when applicable
rationale_text: <text>
```

### github-reviewer → Orchestrator (watch mode output)

```yaml
items:
  - candidate_url: <url>
    source_kind: <kind>
    classification: <classification>
    severity_category: <category>
    routing: <routing>
    thread_id: <id>
    target_comment_id: <id>
monitoring: active | not_active
stopped_because: <reason>
pr_state: <state>  # when PR transitions to MERGED/CLOSED
```

---

## Governance Absorption Strategy

### Documents to Retire (Content Absorbed into Agents)

| Document | Absorbed Into | Rationale |
|---|---|---|
| `monitoring-policy.md` | `github-reviewer.md` | Sole consumer for PR review monitoring |
| `pr-review-remediation-loop.md` | Decomposed — see below | Mixed ownership; split by concern |

### `pr-review-remediation-loop.md` Decomposition

| Content | Destination |
|---|---|
| Classification taxonomy (10 classes) | `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/review-classification-taxonomy.md` (new shared file) |
| Routing table (classification → agent) | Same shared file |
| Severity categories | Same shared file |
| Iteration loop mechanics | Absorbed into `local-reviewer.md` |
| Fix ledger management | Absorbed into `local-reviewer.md` |
| GitHub remediation cycle tracking | Absorbed into `github-reviewer.md` |
| Rejection rationale protocol | Stays with orchestrator (execution-algorithm-detail) |

### Documents to Update (Reference Changes)

| Document | Change |
|---|---|
| `orchestrator.md` | Remove `monitoring-policy.md` and `pr-review-remediation-loop.md` refs; add reviewer agent routing |
| `core-contract.md` | Remove from governance loadout table; update agent list to 6 |
| `escalation-policy.md` | Update classification ref → shared taxonomy file |
| `branching-pr-workflow.md` | Update `pr-review-remediation-loop.md` ref → shared taxonomy |
| `security-policy.md` | Replace retired skill names with new agent names |
| `communication-policy.md` | Remove retired skills from scope list |
| `agent-system-policy.md` | Topology 4→6, Authority Matrix, delegation paths, role boundaries |
| `execution-algorithm-detail.md` | Rewrite steps 13a and 15 |
| `feedback-classifier.md` | Update taxonomy ref → shared file |

---

## Skill Changes

### Skills Retired (Absorbed into Agents)

| Skill | Absorbed Into |
|---|---|
| `review-loop-controller` | `local-reviewer` agent |
| `watch-github-pr-feedback` | `github-reviewer` agent |

### Skills Modified

| Skill | Change |
|---|---|
| `address-github-pr-feedback` | Remove classify mode entirely; retain post-fix mode only |

### Skills Preserved (No Changes)

| Skill | Invoked By |
|---|---|
| `local-codex-review` | `local-reviewer` agent |
| `request-github-codex-review` | `github-reviewer` agent |

---

## Shared Helper Relocation

| File | From | To |
|---|---|---|
| `break-fix-detector.md` | `skills/review-loop-controller/agents/` | `skills/_shared/agents/` |
| `fix-ledger-schema.md` | `skills/review-loop-controller/references/` | `skills/_shared/references/` |
| `monitor-command-template.sh` | `skills/watch-github-pr-feedback/references/` | `skills/_shared/references/` |
| `preflight-check.sh` | `skills/watch-github-pr-feedback/references/` | `skills/_shared/references/` |

New shared file:
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/review-classification-taxonomy.md` — extracted from `pr-review-remediation-loop.md`

Existing shared files (unchanged):
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/feedback-classifier.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/injection-suspect-checker.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md`

---

## Orchestrator STT Refactoring

### Tokens Replaced

| Removed | Replaced By |
|---|---|
| `review-loop-controller-returned` | `local-reviewer-returned` |
| `classify-pr-feedback-returned` | `github-reviewer-returned` |
| `watch-pr-feedback-returned` | `github-reviewer-returned` |

### New STT Rows (Replacing Rows 42-78)

| # | after= | Condition | GOTO |
|---|---|---|---|
| 42 | local-reviewer-returned | exit: clean, no fix commits | step 14: open PR |
| 43 | local-reviewer-returned | exit: clean, fix commits exist | step 11 (re-run) |
| 44 | local-reviewer-returned | exit: none (findings) | delegate fixes per routing |
| 45 | local-reviewer-returned | exit: max-iterations | STOP: surface choices |
| 46 | local-reviewer-returned | exit: break-fix/inject/user-input | STOP: surface |
| 47 | local-reviewer-returned | blocked: codex unavailable | step 14: open PR |
| 48 | local-reviewer-returned | blocked: non-codex | STOP: surface to user |
| 49 | review-loop-fix-complete | status: complete, more fixes remain | delegate next fix |
| 50 | review-loop-fix-complete | status: complete, all fixes applied | validation (within review loop) |
| 51 | review-loop-fix-complete | status: blocked | STOP: surface blocker |
| 52 | pr-remediation-fix-complete | status: complete | validation (within PR remediation) |
| 53 | pr-remediation-fix-complete | status: blocked | STOP: surface blocker |
| 54 | open-plan-pr-complete | succeeded, review requested | step 15: external review |
| 55 | open-plan-pr-complete | succeeded, no review requested | Final Report |
| 56 | open-plan-pr-complete | blocked | STOP: surface blocker |
| 57 | pr-skipped | user opted out of PR | Final Report |
| 58 | request-github-codex-review-complete | succeeded, watch requested | invoke github-reviewer (watch mode) |
| 59 | request-github-codex-review-complete | succeeded, no watch | Final Report |
| 60 | request-github-codex-review-complete | blocked | STOP: surface blocker |
| 61 | github-reviewer-returned | classify: blocked (injection/question/multiple) | STOP: surface to user |
| 62 | github-reviewer-returned | classify: actionable routing | delegate fix per routing |
| 63 | github-reviewer-returned | classify: non-actionable/rejected, non-high-severity | mark complete or post rejection → Final Report |
| 64 | github-reviewer-returned | classify: rejected, high-severity | post rationale → STOP: await user approval |
| 65 | github-reviewer-returned | watch: actionable items | delegate fix per routing |
| 66 | github-reviewer-returned | watch: non-actionable/rejected, non-high-severity | mark complete, continue or Final Report |
| 67 | github-reviewer-returned | watch: rejected, high-severity | post rationale → STOP: await user approval |
| 68 | github-reviewer-returned | watch: no new items, monitoring active | continue (silent) |
| 69 | github-reviewer-returned | watch: no new items, monitoring not active | STOP: surface |
| 70 | github-reviewer-returned | watch: injection-suspect | STOP: surface |
| 71 | github-reviewer-returned | watch: question-needs-user-input | STOP: surface |
| 72 | github-reviewer-returned | watch: PR merged/closed | Final Report |
| 73 | github-reviewer-returned | watch: blocked (other) | STOP: surface |
| 74 | address-pr-feedback-complete | succeeded, more items remain | next item |
| 75 | address-pr-feedback-complete | succeeded, no more items | continue or Final Report |
| 76 | address-pr-feedback-complete | blocked | STOP: surface blocker |

35 rows (down from 37), cleaner structure with mode discrimination in condition column.

---

## Implementation Phases

### Phase 1: Foundation (Shared Helpers + New Agents)

**Files created/moved:**
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/break-fix-detector.md` (moved)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/fix-ledger-schema.md` (moved)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/monitor-command-template.sh` (moved)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/preflight-check.sh` (moved)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/review-classification-taxonomy.md` (new — extracted)
- `${CLAUDE_PLUGIN_ROOT}/agents/local-reviewer.md` (new)
- `${CLAUDE_PLUGIN_ROOT}/agents/github-reviewer.md` (new)

**Depends on:** Nothing. No existing functionality removed.

### Phase 2: Orchestrator + Execution Algorithm

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md` — new STT, new delegation targets, updated skill/agent routing, updated model routing, removed governance refs
- `${CLAUDE_PLUGIN_ROOT}/governance/execution-algorithm-detail.md` — rewrite steps 13a and 15

**Depends on:** Phase 1 (agents must exist before orchestrator references them)

### Phase 3: Governance Updates

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/core-contract.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/escalation-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/security-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/feedback-classifier.md`

**Files deleted:**
- `${CLAUDE_PLUGIN_ROOT}/governance/monitoring-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`

**Depends on:** Phase 2 (orchestrator references must be updated before governance docs are deleted)

### Phase 4: Skill Retirement

**Files deleted:**
- `${CLAUDE_PLUGIN_ROOT}/skills/review-loop-controller/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/review-loop-controller/agents/break-fix-detector.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/review-loop-controller/references/fix-ledger-schema.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/watch-github-pr-feedback/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/watch-github-pr-feedback/references/monitor-command-template.sh`
- `${CLAUDE_PLUGIN_ROOT}/skills/watch-github-pr-feedback/references/preflight-check.sh`

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/skills/address-github-pr-feedback/SKILL.md` — remove classify mode

**Depends on:** Phase 3 (all references to retired skills must be removed first)

### Phase 5: Version Bump + Validation

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` — version bump (minor), description update (six agents)

**Validation:**
- `jq . plugin/.claude-plugin/plugin.json > /dev/null`
- `jq . .claude-plugin/marketplace.json > /dev/null`
- Bare-path grep: `grep -rE '\b(agents|skills|governance)/' plugin/` — only `${CLAUDE_PLUGIN_ROOT}/...` lines
- Orphan reference check: `grep -r "review-loop-controller\|watch-github-pr-feedback\|monitoring-policy\|pr-review-remediation-loop" plugin/` — should return zero results
- Agent count check: verify 6 `.md` files in `plugin/agents/`

**Depends on:** Phase 4

---

## Risks

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | STT refactoring introduces routing errors | Orchestrator misroutes review results | New rows preserve same condition semantics; validate by tracing each exit_reason through STT |
| R2 | Orphan references to retired docs/skills | Dead links in governance | Exhaustive grep in Phase 5 validation |
| R3 | `address-github-pr-feedback` post-fix mode broken by classify removal | Thread resolution fails | Post-fix steps 1-4 are self-contained; verify imports/refs independently |
| R4 | Shared taxonomy extraction misses content | Classification diverges between agents | Diff extracted taxonomy against original `pr-review-remediation-loop.md` sections |
| R5 | Agent tool surface too broad/narrow | Agent fails at runtime or gets unnecessary permissions | Cross-reference each agent's procedure steps against tool requirements |
| R6 | Break-fix detector path change breaks existing references | Subagent invocation fails | Update all `${CLAUDE_PLUGIN_ROOT}` paths in Phase 1; validate via grep |

---

## Version Impact

- **Type:** Minor bump (new backward-compatible capability)
- **Current:** 1.6.4
- **Target:** 1.7.0
- **Rationale:** Two new agents, two skills retired, two governance docs retired — significant capability addition that doesn't break existing consumer workflows

---

## Branch Strategy

- **Classification:** feature
- **Branch name:** `feature/reviewer-agents`
- **Base:** main
- **PR target:** main
- **Checkpoint commits:** one per phase
