# Reviewer Agents Architecture Plan (v2)

## Document Purpose

Self-contained implementation plan for introducing two specialist reviewer agents (`local-reviewer` and `github-reviewer`) to the agent-framework plugin. Supersedes v1 (`docs/planning/reviewer-agents-plan.md`) with revised architecture decisions from plan interrogation session.

**Key changes from v1:** Self-owning delegation model (replaces Pattern A), simplified contracts (terminal-only returns), three skill retirements (up from two), `request-github-codex-review` removed from normal flow, push-triggered auto-review, revised phasing with parallel execution.

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

## Architecture Decisions

### Decision 1: Two Specialist Agents

| Option | Description | Verdict |
|---|---|---|
| 1. Single unified `reviewer` agent | One agent handles both local and GitHub flows | Mixed concerns; large agent; no context isolation between flows |
| 2. Separate `local-reviewer` + `github-reviewer` | Two focused agents, each owning one distinct flow | **Chosen** — clean separation, fresh context per flow, natural skill-to-agent promotion |
| 3. `reviewer` agent without fix delegation | Reviewer classifies but returns to orchestrator for all delegation | Marginal improvement; doesn't solve core problem |

**Why Option 2:**
- **Natural evolution** — `review-loop-controller` and `watch-github-pr-feedback` already have agent-shaped logic; this is promotion not invention
- **Fresh context per flow** — Local review may consume 5-10 iterations; GitHub reviewer starts with clean context
- **Focused tool surfaces** — local-reviewer needs no Monitor/gh/push; github-reviewer needs no fix-ledger/break-fix-detection
- **Failure isolation** — Bug in GitHub review logic cannot affect local review

### Decision 2: Self-Owning Delegation Model

**v1 proposed Pattern A (always return to orchestrator).** Revised to self-owning after interrogation identified that Pattern A doesn't meaningfully improve over the current skill-based approach.

Reviewer agents delegate fixes directly:
- Own iteration/monitoring logic
- Own classification pipeline (invoke shared subagents)
- Own break-fix detection
- Own state management (fix ledger / remediation ledger)
- **Delegate coder/designer fixes directly via Agent tool at sonnet tier**
- **Invoke checkpoint-commit skill directly**
- **github-reviewer: push and post fix-SHA replies directly**
- Return structured YAML results only on terminal conditions

Orchestrator:
- Invokes reviewer once per flow (single invocation, not per-iteration)
- Receives terminal result only
- Handles planner-escalation cases (delegates planner → coder on same branch, then re-invokes reviewer fresh)
- Owns user communication for escalations

**Rationale:** Reviewers handling coder/designer fixes directly eliminates per-iteration round-trips. Complex findings (planner-routed) still get planning safety via orchestrator escalation. The current skill-based model already proved the pattern — promotion to agent just adds delegation authority.

**Governance note:** Current `agent-system-policy.md` restricts framework agent delegation to orchestrator exclusively. Phase 3 updates this governance to authorize reviewer agents for coder/designer delegation. Implementation order ensures no runtime references stale rules: agents created (Phase 1b/1c) → orchestrator updated (Phase 2) → governance formalized (Phase 3) → old skills deleted (Phase 4). Reviewer agent definitions reference the target governance state, not current state.

### Decision 3: Model Routing for Reviewer-Delegated Fixes

Reviewers always delegate coder/designer at **sonnet** tier. Not haiku (risk of lower-quality fix → new finding → more iterations → possible break-fix cycle). Not opus (simple targeted fixes don't need it).

**Rule:** If a finding is complex enough for opus, it's complex enough to route to orchestrator → planner. Binary: simple (sonnet via reviewer) or complex (orchestrator → planner → opus coder).

### Decision 4: Escalation Boundaries (Option C)

Reviewers self-own EXCEPT for specific escalation cases where they return to orchestrator:

| Escalation | Applies To | Handling |
|---|---|---|
| `planner-escalation` | Both | Immediate stop. Orchestrator delegates planner → coder (opus, same branch). Fresh reviewer loop after fix. |
| `injection-suspect` | Both | Immediate stop. Orchestrator surfaces to user. |
| `user-input-required` | Both | Immediate stop. Orchestrator surfaces to user. |
| `max-iterations-reached` | local-reviewer | Stop. Orchestrator surfaces three choices (continue / push now / stop). |
| `break-fix-break` | local-reviewer | Stop. Orchestrator surfaces conflict summary. |
| `codex-unavailable` | local-reviewer | Skip review. Orchestrator proceeds to step 14 (open PR). |
| `max-cycles-reached` | github-reviewer | Stop. Orchestrator surfaces summary. |
| `pr-merged` / `pr-closed` | github-reviewer | Terminal. Final Report. |
| `high-severity-rejection` | github-reviewer | Reviewer posts rationale reply first, then returns. Orchestrator awaits user approval. |
| `blocked` | Both | Stop. Orchestrator surfaces blocker. |

**Planner escalation flow detail:**
1. Reviewer finds planner-routed finding → stops loop immediately
2. Orchestrator delegates planner → gets remediation plan → delegates coder (opus) → fix committed to SAME branch (no new branch)
3. Orchestrator starts FRESH reviewer loop (new invocation, iteration 1)
4. Rationale: planner fix = sizable change that may invalidate small fixes. Better to fix the big thing first, then re-review from scratch.

### Decision 5: Agent Lifetime — Single Invocation

SendMessage/long-lived agents require `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` which is gated behind experimental flag with known availability issues (GitHub issues #37051, #35240, #42737).

Chosen approach: Orchestrator invokes reviewer agent via Agent tool once. Reviewer runs full loop internally. Returns only on terminal condition. State managed internally (fix ledger on disk for local-reviewer, session-local for github-reviewer).

### Decision 6: Cross-Step Override Dropped for Review Context

The cross-step override rule ("actionable fix touching files in more than one planner step routes to planner") is a phase-execution concern. By review time, all phases are complete. Architectural complexity is already caught by `architecture-or-contract-concern` classification. If coder returns blocked or needs scope expansion, reviewer escalates to orchestrator.

### Decision 7: Push-Triggered Auto-Review

Codex is configured to automatically review when commits are pushed to a PR. No explicit `request-github-codex-review` invocation needed in the normal flow — not between remediation cycles, and not after PR creation.

`request-github-codex-review` becomes ad-hoc only (user explicitly says "get Codex to review this").

**Normal flow:** open PR → push triggers auto-review → github-reviewer in watch mode monitors for feedback.

**Batch-push rule:** github-reviewer pushes once per remediation cycle (after all fixes for that cycle are committed), never per-fix. This prevents multiple Codex auto-reviews from triggering in rapid succession.

### Decision 8: Continuation After Max-Iterations

- **local-reviewer (C1):** Fix ledger persists on disk (`.agent-framework/review-loop/`). On re-invocation with higher max_iterations, reviewer reads existing ledger and resumes. No state loss.
- **github-reviewer (C3):** Fresh state on re-invocation. Acceptable since re-review produces fresh feedback. Remediation ledger is session-local.

**Crash recovery (github-reviewer):** If github-reviewer crashes mid-cycle after pushing fixes and resolving threads, re-invocation with fresh state is safe. GitHub API returns only UNRESOLVED threads — already-resolved threads from prior fixes are filtered out. Pushed commits are visible to Codex on next auto-review. No duplicate work occurs.

### Decision 9: Break-Fix Detection — Shared Algorithm

Both agents implement identical break-fix detection:
- SHA-based finding deduplication (finding `id` = SHA-256 of `file + line_start + line_end + title`)
- Repeat-fix counter
- Signals: line-range overlap, git revert, N-2 iteration delta
- Invoke shared `break-fix-detector.md` subagent from `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/`

### Decision 10: Monitoring Policy Absorption (YAGNI)

`monitoring-policy.md` absorbed fully into `github-reviewer.md` (sole Monitor consumer). If a future agent/skill needs Monitor, extract back out then. Cost of extraction is trivial.

---

## Communication Contracts

### Orchestrator → local-reviewer (input)

```yaml
base: <branch>
working_branch: <branch>
trunk: <branch>
claude_mem: present | absent
max_iterations: 10  # default
resume_from_ledger: <path>  # optional, for continuation after max-iterations-reached
```

### local-reviewer → Orchestrator (terminal output)

```yaml
exit_reason: clean | max-iterations-reached | break-fix-break | injection-suspect | user-input-required | planner-escalation | blocked
iterations_completed: <int>
findings_resolved: <int>
findings_open: <int>
fix_commits_exist: true | false  # orchestrator needs for version-bump re-check

# On planner-escalation:
escalation:
  finding_id: <id>
  classification: <classification>
  file: <path>
  title: <title>
  details: <body>

# On injection-suspect:
escalation:
  finding_id: <id>
  pattern_category: <P1-P4>

# On break-fix-break:
break_fix:
  signals_fired: <list>
  conflicting_findings: <list>
  prior_fix_commit: <sha>

# On blocked:
blocker: <reason>
```

### Orchestrator → github-reviewer (fix mode input)

```yaml
mode: fix
pr: <number or URL>
working_branch: <branch>  # NEW — reviewer verifies current branch matches before push
base: <branch>             # NEW — for reference/safety checks
target: <comment URL or ID>  # optional; absent = all unresolved on PR
```

### Orchestrator → github-reviewer (watch mode input)

```yaml
mode: watch
pr: <number or URL>
working_branch: <branch>  # NEW
base: <branch>             # NEW
reviewer_filter: codex-only | all | <author>  # default: all
max_watch_duration: 14400  # seconds, default 4h
max_remediation_cycles: 3  # default
```

### github-reviewer → Orchestrator (terminal output)

```yaml
exit_reason: clean | max-cycles-reached | pr-merged | pr-closed | injection-suspect | user-input-required | planner-escalation | high-severity-rejection | blocked
mode: fix | watch
cycles_completed: <int>  # watch mode only
findings_resolved: <int>
findings_open: <int>

# On planner-escalation:
escalation:
  candidate_url: <url>
  classification: <classification>
  file: <path>
  title: <title>
  details: <body>

# On injection-suspect:
escalation:
  candidate_url: <url>
  finding_id: <id>
  pattern_category: <P1-P4>

# On high-severity-rejection:
escalation:
  candidate_url: <url>
  severity_category: <category>
  rationale_posted: true  # reviewer already posted rationale reply before returning
  thread_id: <id>

# On blocked:
blocker: <reason>
monitoring: active | not_active  # watch mode only
```

---

## Agent Tool Surfaces

### local-reviewer

| Tool | Purpose |
|---|---|
| Read | Read files, fix ledger, shared references |
| Write | Write/update fix ledger |
| Bash (git status, branch, diff, log, rev-parse) | Git state queries |
| Bash (validation commands) | Run CLAUDE.md validation |
| Agent | Delegate to coder/designer (sonnet tier) |
| Skill | Invoke `agent-framework:local-codex-review`, `agent-framework:checkpoint-commit` |

Does NOT need: Monitor, gh API, git push

### github-reviewer

| Tool | Purpose |
|---|---|
| Read | Read files, shared references |
| Write | Write remediation ledger (session-local) |
| Bash (git status, branch, diff, log, rev-parse) | Git state queries |
| Bash (git push) | Push fix commits to PR branch |
| Bash (gh pr view, gh pr comment, gh api) | GitHub API for classification, post-fix replies, thread resolution |
| Bash (validation commands) | Run CLAUDE.md validation |
| Agent | Delegate to coder/designer (sonnet tier) |
| Skill | Invoke `agent-framework:checkpoint-commit` |
| Monitor | Poll for new PR review comments (watch mode) |

---

## Governance Absorption Strategy

### Documents to Retire (Content Absorbed into Agents)

| Document | Absorbed Into | Rationale |
|---|---|---|
| `monitoring-policy.md` | `github-reviewer.md` | Sole consumer for PR review monitoring (YAGNI — extract if second consumer appears) |
| `pr-review-remediation-loop.md` | Decomposed — see below | Mixed ownership; split by concern |

### `pr-review-remediation-loop.md` Decomposition

| Content | Destination |
|---|---|
| Classification taxonomy (10 classes) | `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/review-classification-taxonomy.md` (new shared file) |
| Routing table (classification → agent) | Same shared file (updated: reviewer delegates coder/designer directly at sonnet; planner-routed → return to orchestrator) |
| Severity categories | Same shared file |
| Iteration loop mechanics | Absorbed into `local-reviewer.md` |
| Fix ledger management | Absorbed into `local-reviewer.md` |
| Fix rules | Absorbed into both reviewer agents (shared reference in taxonomy file for common rules) |
| GitHub remediation cycle tracking | Absorbed into `github-reviewer.md` |
| Monitoring section | Absorbed into `github-reviewer.md` (along with monitoring-policy.md) |
| Rejection rationale protocol | Split: non-high-severity handled by github-reviewer directly; high-severity → reviewer posts rationale then returns to orchestrator |
| Re-review section | Removed — push triggers auto-review; `request-github-codex-review` is ad-hoc only |
| Stop conditions | Absorbed into respective reviewer agents |
| Thread resolution rules | Absorbed into `github-reviewer.md` |
| Remediation ledger | Absorbed into `github-reviewer.md` |
| Pre-PR local review loop section | Absorbed into `local-reviewer.md` |
| Cross-step override | Dropped for review context (architecture concerns caught by classification) |

### Documents to Update (Reference Changes)

| Document | Change |
|---|---|
| `orchestrator.md` | Remove `monitoring-policy.md` and `pr-review-remediation-loop.md` refs; add reviewer agent delegation; new STT rows; update skill routing; update model routing; update hard prohibitions (allow delegation to local-reviewer and github-reviewer); update delegation templates |
| `core-contract.md` | Remove retired docs from governance loadout table; update agent list from 4 to 6 |
| `agent-system-policy.md` | Topology 4→6 agents; Authority Matrix updated (reviewers own classification, fix delegation for simple fixes, checkpoint-commit, push/reply for github-reviewer); update role boundaries; update one-time/watch routing definition (replace skill refs with agent refs) |
| `execution-algorithm-detail.md` | Rewrite steps 13a and 15 (much simpler — invoke reviewer, handle terminal return) |
| `escalation-policy.md` | Update classification ref → shared taxonomy file |
| `branching-pr-workflow.md` | Update `pr-review-remediation-loop.md` ref → shared taxonomy |
| `security-policy.md` | Replace retired skill names with new agent names in injection-suspect references |
| `communication-policy.md` | Remove retired skills from scope list |
| `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/feedback-classifier.md` | Update taxonomy ref → shared file |
| `${CLAUDE_PLUGIN_ROOT}/skills/local-codex-review/SKILL.md` | Update description: "Invoked by local-reviewer agent" (was "review-loop-controller only") |

---

## Skill Changes

### Skills Retired (Fully Absorbed into Agents)

| Skill | Absorbed Into | Rationale |
|---|---|---|
| `review-loop-controller` | `local-reviewer` agent | Full loop logic, classification, break-fix detection, fix ledger — all absorbed |
| `watch-github-pr-feedback` | `github-reviewer` agent | Monitor lifecycle, classification, cycle tracking — all absorbed |
| `address-github-pr-feedback` | `github-reviewer` agent | Classify mode absorbed into github-reviewer; post-fix mode absorbed (github-reviewer posts replies directly) |

### Skills Modified

| Skill | Change |
|---|---|
| `local-codex-review` | Update description only: "Invoked by local-reviewer agent" |
| `request-github-codex-review` | Preserved as ad-hoc only. Remove from normal orchestrator flow. Update description to clarify ad-hoc usage. |

---

## Shared Helper Relocation

| File | From | To |
|---|---|---|
| `break-fix-detector.md` | `skills/review-loop-controller/agents/` | `skills/_shared/agents/` |
| `fix-ledger-schema.md` | `skills/review-loop-controller/references/` | `skills/_shared/references/` |
| `monitor-command-template.sh` | `skills/watch-github-pr-feedback/references/` | `skills/_shared/references/` |
| `preflight-check.sh` | `skills/watch-github-pr-feedback/references/` | `skills/_shared/references/` |

> **Note:** Phase 1a creates files at new `_shared/` locations. Original files remain in their current skill directories until Phase 4 deletes the retired skills. Both locations coexist during Phases 1-3 to avoid breaking existing skill references.

New shared file:
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/review-classification-taxonomy.md` — extracted from `pr-review-remediation-loop.md`, contains: classification taxonomy (10 classes), routing table (updated for self-owning model), severity categories, common fix rules

Existing shared files (unchanged):
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/feedback-classifier.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/injection-suspect-checker.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md`

---

## Orchestrator STT Refactoring

### Tokens Removed

| Token | Reason |
|---|---|
| `review-loop-controller-returned` | Replaced by `local-reviewer-returned` |
| `classify-pr-feedback-returned` | Absorbed into `github-reviewer-returned` |
| `watch-pr-feedback-returned` | Absorbed into `github-reviewer-returned` |
| `review-loop-fix-complete` | Reviewer handles fixes internally |
| `pr-remediation-fix-complete` | Reviewer handles fixes internally |
| `address-pr-feedback-complete` | Skill fully retired |

### Token Changes

| Token | Change |
|---|---|
| `request-github-codex-review-complete` | Removed from normal pipeline flow; retained only for ad-hoc user requests |

### New STT Rows (Replacing Rows 42-78)

| # | after= | Condition | GOTO |
|---|---|---|---|
| 42 | local-reviewer-returned | exit: clean, no fix commits | step 14: open PR |
| 43 | local-reviewer-returned | exit: clean, fix commits exist | step 11 (re-run version bump) |
| 44 | local-reviewer-returned | exit: max-iterations-reached | STOP: surface choices (continue / push now / stop) |
| 45 | local-reviewer-returned | exit: break-fix-break | STOP: surface conflict summary |
| 46 | local-reviewer-returned | exit: injection-suspect | STOP: surface finding details |
| 47 | local-reviewer-returned | exit: user-input-required | STOP: surface finding |
| 48 | local-reviewer-returned | exit: planner-escalation | delegate planner → coder (opus, same branch) → re-invoke local-reviewer (fresh) |
| 49 | local-reviewer-returned | blocked: codex unavailable | step 14: open PR |
| 50 | local-reviewer-returned | blocked: other | STOP: surface blocker |
| 51 | open-plan-pr-complete | succeeded, review opted-in | invoke github-reviewer (watch mode) |
| 52 | open-plan-pr-complete | succeeded, review not requested | Final Report |
| 53 | open-plan-pr-complete | blocked | STOP: surface blocker |
| 54 | pr-skipped | user opted out of PR | Final Report |
| 55 | github-reviewer-returned | exit: clean | Final Report |
| 56 | github-reviewer-returned | exit: max-cycles-reached | STOP: surface summary |
| 57 | github-reviewer-returned | exit: pr-merged | Final Report |
| 58 | github-reviewer-returned | exit: pr-closed | Final Report |
| 59 | github-reviewer-returned | exit: injection-suspect | STOP: surface finding details |
| 60 | github-reviewer-returned | exit: user-input-required | STOP: surface finding |
| 61 | github-reviewer-returned | exit: planner-escalation | delegate planner → coder (opus, same branch) → re-invoke github-reviewer (fresh) |
| 62 | github-reviewer-returned | exit: high-severity-rejection | STOP: await user approval (rationale already posted by reviewer) |
| 63 | github-reviewer-returned | blocked | STOP: surface blocker |
| 64 | request-github-codex-review-complete | succeeded, watch requested | invoke github-reviewer (watch mode) |
| 65 | request-github-codex-review-complete | succeeded, no watch | Final Report |
| 66 | request-github-codex-review-complete | blocked | STOP: surface blocker |
| 67 | local-reviewer-returned | tool-error (timeout/crash) | read fix ledger from disk → re-invoke with resume_from_ledger |
| 68 | github-reviewer-returned | tool-error (timeout/crash) | re-invoke github-reviewer (fresh — resolved threads filtered by API) |

27 rows (down from 37 current, down from 35 in v1). The `request-github-codex-review-complete` rows (64-66) are ad-hoc only — not part of the normal pipeline.

---

## Implementation Phases

### Phase 1a: Shared Helpers + Taxonomy Extraction

**Files created (copied to new location; originals remain until Phase 4 retirement):**
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/break-fix-detector.md` (moved from `skills/review-loop-controller/agents/`)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/fix-ledger-schema.md` (moved from `skills/review-loop-controller/references/`)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/monitor-command-template.sh` (moved from `skills/watch-github-pr-feedback/references/`)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/preflight-check.sh` (moved from `skills/watch-github-pr-feedback/references/`)
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/review-classification-taxonomy.md` (new — extracted from `pr-review-remediation-loop.md`)

**Depends on:** Nothing. No existing functionality removed.

**Checkpoint after completion.**

### Phase 1b: local-reviewer Agent Definition (PARALLEL with 1c)

**Files created:**
- `${CLAUDE_PLUGIN_ROOT}/agents/local-reviewer.md` (new — ~400-500 lines)

**Content scope:**
- Agent frontmatter (name, description, tools)
- Full loop logic (iterate, classify, delegate fix at sonnet, validate, checkpoint, repeat)
- Break-fix detection integration (invoke shared subagent)
- Fix ledger management (read/write from disk)
- Classification pipeline (invoke shared subagents: feedback-classifier, injection-suspect-checker)
- Escalation boundary definitions (when to return to orchestrator)
- Input/output contract (terminal-only)
- Continuation support (C1 — read existing ledger on re-invocation)
- References to shared taxonomy, fix-ledger-schema, break-fix-detector
- Governance references: agent-system-policy.md, security-policy.md, communication-policy.md

**Depends on:** Phase 1a (shared helpers must exist)

**Checkpoint after completion.**

### Phase 1c: github-reviewer Agent Definition (PARALLEL with 1b)

**Files created:**
- `${CLAUDE_PLUGIN_ROOT}/agents/github-reviewer.md` (new — ~500-600 lines)

**Content scope:**
- Agent frontmatter (name, description, tools including Monitor)
- Two modes: fix (one-shot) and watch (Monitor-based polling)
- Monitor setup and lifecycle (absorbed from monitoring-policy.md)
- Shell/parser policy (absorbed from monitoring-policy.md)
- Classification pipeline (invoke shared subagents)
- Fix delegation at sonnet tier
- Validation, checkpoint-commit, push, post-fix reply, thread resolution
- Remediation cycle tracking and stop conditions
- Rejection rationale handling (non-high-severity: handle directly; high-severity: post reply, return to orchestrator)
- Escalation boundary definitions
- Input/output contract (terminal-only)
- Pre-push safety checks: verify current branch = working_branch, verify no unsafe git state per agent-system-policy.md definition, fail fast on mismatch
- References to shared taxonomy, GraphQL ops, monitor-command-template, preflight-check
- Governance references: agent-system-policy.md, security-policy.md, communication-policy.md

**Depends on:** Phase 1a (shared helpers must exist)

**Checkpoint after completion.**

### Phase 2: Orchestrator + Execution Algorithm

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md` — new STT rows (25 review-related, replacing 37); new delegation targets (local-reviewer, github-reviewer); updated skill routing (remove retired skills, add reviewer agent routing); updated model routing table (add reviewer delegation rows); update hard prohibitions (allow delegation to local-reviewer and github-reviewer); update delegation template (add reviewer delegation templates); remove governance refs (monitoring-policy.md, pr-review-remediation-loop.md)
- `${CLAUDE_PLUGIN_ROOT}/governance/execution-algorithm-detail.md` — rewrite Step 13a (simplified: invoke local-reviewer once, handle terminal return, planner escalation re-invokes fresh); rewrite Step 15 (simplified: if review opted-in, invoke github-reviewer watch mode after PR open; handle terminal return; planner escalation re-invokes fresh; ad-hoc request-github-codex-review path preserved separately)

**Depends on:** Phases 1a, 1b, 1c (agents must exist before orchestrator references them)

**Checkpoint after completion.**

### Phase 3: Governance Updates

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` — Topology 4→6 agents (add local-reviewer, github-reviewer); Authority Matrix (add reviewer rows: own classification, fix delegation for simple fixes, checkpoint-commit; github-reviewer: push, reply, thread resolution); update role boundaries; update "One-time vs watch routing" definition (replace skill refs with agent mode refs); update "Skill agent boundary" to note reviewer agents are not skills
- `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` — remove retired skills from scope list
- `${CLAUDE_PLUGIN_ROOT}/governance/core-contract.md` — remove monitoring-policy.md and pr-review-remediation-loop.md from governance loadout; update agent count to 6; update plugin description ref
- `${CLAUDE_PLUGIN_ROOT}/governance/escalation-policy.md` — update classification ref → shared taxonomy file
- `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` — update `pr-review-remediation-loop.md` ref → shared taxonomy
- `${CLAUDE_PLUGIN_ROOT}/governance/security-policy.md` — replace retired skill names with new agent names in injection-suspect classification references
- `${CLAUDE_PLUGIN_ROOT}/skills/_shared/agents/feedback-classifier.md` — update taxonomy ref → shared file
- `${CLAUDE_PLUGIN_ROOT}/skills/local-codex-review/SKILL.md` — update description: "Invoked by local-reviewer agent" (was "review-loop-controller only")
- `${CLAUDE_PLUGIN_ROOT}/skills/request-github-codex-review/SKILL.md` — update description to clarify ad-hoc usage only; remove any "invoked by orchestrator in normal flow" language

**Files deleted:**
- `${CLAUDE_PLUGIN_ROOT}/governance/monitoring-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`

**Depends on:** Phase 2 (orchestrator references must be updated before governance docs are deleted)

**Checkpoint after completion.**

### Phase 4: Skill Retirement

**Files deleted:**
- `${CLAUDE_PLUGIN_ROOT}/skills/review-loop-controller/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/review-loop-controller/agents/break-fix-detector.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/review-loop-controller/references/fix-ledger-schema.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/watch-github-pr-feedback/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/watch-github-pr-feedback/references/monitor-command-template.sh`
- `${CLAUDE_PLUGIN_ROOT}/skills/watch-github-pr-feedback/references/preflight-check.sh`
- `${CLAUDE_PLUGIN_ROOT}/skills/address-github-pr-feedback/SKILL.md` (fully retired — not modified)

**Directories to clean up (delete if empty after file removal):**
- `skills/review-loop-controller/agents/`
- `skills/review-loop-controller/references/`
- `skills/review-loop-controller/`
- `skills/watch-github-pr-feedback/references/`
- `skills/watch-github-pr-feedback/`
- `skills/address-github-pr-feedback/`

**Depends on:** Phase 3 (all references to retired skills must be removed first)

**Checkpoint after completion.**

### Phase 5: Version Bump + Validation

**Files modified:**
- `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` — version bump 1.6.4 → 1.7.0; description update (six agents, note skill retirements)

**Validation (all must pass):**
1. `jq . plugin/.claude-plugin/plugin.json > /dev/null`
2. `jq . .claude-plugin/marketplace.json > /dev/null`
3. Bare-path grep: `grep -rE '\b(agents|skills|governance)/' plugin/` — only `${CLAUDE_PLUGIN_ROOT}/...` lines or `_shared/` references
4. Orphan reference check: `grep -r "review-loop-controller\|watch-github-pr-feedback\|address-github-pr-feedback\|monitoring-policy\|pr-review-remediation-loop" plugin/` — should return zero results
5. Agent count check: verify 6 `.md` files in `plugin/agents/`
6. Retired skill directories removed: verify `skills/review-loop-controller/`, `skills/watch-github-pr-feedback/`, `skills/address-github-pr-feedback/` do not exist
7. Smoke install: verify plugin loads without error in a scratch session (manual post-merge if sandbox unavailable)

**Depends on:** Phase 4

**Checkpoint after completion.**

### Phase Dependency Graph

```
Phase 1a (shared helpers)
    ├──→ Phase 1b (local-reviewer)  ──┐
    └──→ Phase 1c (github-reviewer) ──┤  [1b and 1c PARALLEL]
                                      ↓
                                Phase 2 (orchestrator)
                                      ↓
                                Phase 3 (governance)
                                      ↓
                                Phase 4 (skill retirement)
                                      ↓
                                Phase 5 (version bump + validation)
```

---

## Risks

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | STT refactoring introduces routing errors | Orchestrator misroutes review results | New rows preserve same terminal semantics; validate by tracing each exit_reason through STT |
| R2 | Orphan references to retired docs/skills | Dead links in governance | Exhaustive grep in Phase 5 validation (check 4) |
| R3 | Shared taxonomy extraction misses content | Classification diverges between agents | Diff extracted taxonomy against original `pr-review-remediation-loop.md` sections |
| R4 | Agent tool surface too broad/narrow | Agent fails at runtime or gets unnecessary permissions | Cross-reference each agent's procedure steps against tool requirements |
| R5 | Break-fix detector path change breaks existing references | Subagent invocation fails | Update all `${CLAUDE_PLUGIN_ROOT}` paths in Phase 1a; validate via grep |
| R6 | Self-owning reviewer context overflow after many iterations | Agent stalls or loses context mid-loop | Bounded by max_iterations (default 10); local-reviewer has disk-backed ledger for state preservation; github-reviewer has max_remediation_cycles (default 3) |
| R7 | Sonnet-tier coder produces lower quality fixes than opus | More review iterations needed, potential break-fix | Break-fix detection catches oscillation; planner-escalation catches complexity; acceptable trade-off given cost savings |
| R8 | Planner escalation loses reviewer context | Fixes from prior iterations may be invalidated by planner fix | Fresh reviewer loop after planner fix is intentional — prior fixes are committed and will be re-reviewed |
| R9 | `address-github-pr-feedback` full retirement misses edge case | Post-fix thread resolution breaks | github-reviewer absorbs all three modes (classify, fix, post-fix); validate thread resolution works end-to-end |
| R10 | Reviewer agent crash/timeout mid-loop | Partial work lost or duplicated | local-reviewer: disk-backed ledger enables re-invocation with `resume_from_ledger`. github-reviewer: GitHub API state (resolved threads filtered) prevents re-processing. Both fall through to existing tool-error STT rows (79-84) for spawn failures. |
| R11 | Reviewer agent fails to spawn (tool-error at invocation) | Review flow blocked | Falls through to existing orchestrator tool-error STT rows (79-84). No reviewer-specific handling needed — standard error classification applies. |

---

## Version Impact

- **Type:** Minor bump (new backward-compatible capability)
- **Current:** 1.6.4
- **Target:** 1.7.0
- **Rationale:** Two new agents with internal skill consolidation (three skills retired, two governance docs absorbed). External orchestrator-mediated workflows unchanged; internal routing restructured. Minor bump appropriate per versioning policy for new capability.

---

## Branch Strategy

- **Classification:** feature
- **Branch name:** `feature/reviewer-agents`
- **Base:** main
- **PR target:** main
- **Checkpoint commits:** one per phase (1a, 1b, 1c, 2, 3, 4, 5)
- **Worktrees:** Phase 1b and 1c may use parallel worktrees if supported

---

## Files Impacted (Complete Summary)

### New Files (7)
- `plugin/agents/local-reviewer.md`
- `plugin/agents/github-reviewer.md`
- `plugin/skills/_shared/agents/break-fix-detector.md` (moved)
- `plugin/skills/_shared/references/fix-ledger-schema.md` (moved)
- `plugin/skills/_shared/references/monitor-command-template.sh` (moved)
- `plugin/skills/_shared/references/preflight-check.sh` (moved)
- `plugin/skills/_shared/references/review-classification-taxonomy.md` (new — extracted)

### Modified Files (12)
- `plugin/agents/orchestrator.md`
- `plugin/governance/execution-algorithm-detail.md`
- `plugin/governance/agent-system-policy.md`
- `plugin/governance/communication-policy.md`
- `plugin/governance/core-contract.md`
- `plugin/governance/escalation-policy.md`
- `plugin/governance/branching-pr-workflow.md`
- `plugin/governance/security-policy.md`
- `plugin/skills/_shared/agents/feedback-classifier.md`
- `plugin/skills/local-codex-review/SKILL.md`
- `plugin/skills/request-github-codex-review/SKILL.md`
- `plugin/.claude-plugin/plugin.json`

### Deleted Files (8)
- `plugin/governance/monitoring-policy.md`
- `plugin/governance/pr-review-remediation-loop.md`
- `plugin/skills/review-loop-controller/SKILL.md`
- `plugin/skills/review-loop-controller/agents/break-fix-detector.md`
- `plugin/skills/review-loop-controller/references/fix-ledger-schema.md`
- `plugin/skills/watch-github-pr-feedback/SKILL.md`
- `plugin/skills/watch-github-pr-feedback/references/monitor-command-template.sh`
- `plugin/skills/watch-github-pr-feedback/references/preflight-check.sh`

### Deleted Directories (5, if empty)
- `plugin/skills/review-loop-controller/`
- `plugin/skills/watch-github-pr-feedback/`
- `plugin/skills/address-github-pr-feedback/`

**Total: 7 new + 12 modified + 8 deleted = 27 file operations across 7 checkpoint commits**
