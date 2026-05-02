# Execution State Machine

> **Status:** Planning / advisory material.
> This document is not active governance. It maps the workflow behavior already defined in `plugin/agents/orchestrator.md` (Execution Algorithm) and the referenced governance files. It introduces no new rules.

## States

### 1. Intake

The orchestrator receives a task from the user.

See `docs/planning/routing-matrix.md` for the full user-intent-to-skill/agent routing matrix referenced from this state.

- **Owner:** orchestrator
- **Entry gate:** none (initial state)
- **Transitions:**
  - &rarr; **Plan** (default; Execution Algorithm step 1)
  - &rarr; **Trivial Fast Path** (only when every condition of the planner-skip exception is answered "yes" from the task input as written)
  - &rarr; **Blocked** (task is unintelligible or violates a hard prohibition)

---

### 2. Plan

The orchestrator delegates to `agent-framework:planner`. The planner reads, researches, and returns a complete plan with file scopes, phases, dependencies, delivery shape, versioning implications, and open questions.

- **Owner:** planner (delegated by orchestrator)
- **Entry gate:** task received from Intake
- **Transitions:**
  - &rarr; **Git Preflight** (planner returns a complete plan with no open questions; Execution Algorithm steps 4-5)
  - &rarr; **Blocked** (planner fails and retry/fallback is exhausted; step 2)
  - &rarr; *return to user* (planner returns open questions; step 3 -- orchestrator surfaces questions and stops)

---

### 3. Trivial Fast Path

The orchestrator determines that every planner-skip condition is satisfied and skips the planner. The skip decision must be stated explicitly in the orchestrator's report with each condition listed and resolved.

This is not a shortcut past Git Preflight. Implementation cannot begin until Git Preflight completes.

- **Owner:** orchestrator
- **Entry gate:** all six planner-skip conditions answered "yes" from the task input as written (one owner, one known file, trivial change, branch classification stated or unambiguous, version impact = none, no review remediation)
- **Transitions:**
  - &rarr; **Git Preflight** (always; the fast path still requires full preflight before implementation)
  - &rarr; **Blocked** (git state is unsafe, or preflight values cannot be resolved)

---

### 4. Git Preflight

The orchestrator explicitly establishes all required git context: work classification, base branch, working branch name, branch exists vs. create, worktree decision, checkpoint commit policy, and PR target.

If any item is undefined, implementation must not begin.

- **Owner:** orchestrator
- **Entry gate:** complete plan returned from Plan, OR Trivial Fast Path conditions satisfied
- **Transitions:**
  - &rarr; **Branch** (all seven preflight items are defined and consistent)
  - &rarr; **Blocked** (any preflight item is undefined, or values contradict each other, or git state is unsafe)

---

### 5. Branch

The orchestrator creates or confirms the working branch via `agent-framework:create-working-branch`. Branch creation happens only after the plan is complete (or fast-path applies), open questions are resolved, implementation is ready to begin, and repo state is safe.

- **Owner:** orchestrator (via `agent-framework:create-working-branch` skill)
- **Entry gate:** all Git Preflight items defined and consistent; repo state is safe
- **Transitions:**
  - &rarr; **Implement** (branch created or confirmed successfully)
  - &rarr; **Blocked** (branch creation fails, repo state is unsafe, or trunk branch would be checked out)

---

### 6. Implement

The orchestrator converts the plan into phases and delegates each phase to `agent-framework:coder` or `agent-framework:designer` with exact file scope. Independent non-overlapping phases may run in parallel when worktree conditions are met; otherwise phases run sequentially.

Each phase delegation includes the full Delegation Template (or compact form for trivial single-file tasks).

- **Owner:** coder and/or designer (delegated by orchestrator)
- **Entry gate:** working branch created or confirmed; plan phases defined
- **Transitions:**
  - &rarr; **Validate** (phase implementation complete; worker returns report)
  - &rarr; **Blocked** (worker reports blocked, touches files outside assigned scope, or implementation began without full preflight)

---

### 7. Validate

The orchestrator performs Phase Verification after each phase: checks that changed files are within assigned scope, worker report matches the Shared Worker Report Contract, validation procedure was run, git state is safe, version impact is reported when applicable, and no blocked items exist.

Validation also runs before PR readiness per the Validation procedure definition.

- **Owner:** orchestrator (verification); coder/designer (running validation commands as part of their phase)
- **Entry gate:** phase implementation complete; worker report received in Shared Worker Report Contract format
- **Transitions:**
  - &rarr; **Checkpoint Commit** (phase verified, more phases remain or checkpoint conditions met)
  - &rarr; **Implement** (phase verified, next phase ready, no checkpoint needed yet)
  - &rarr; **PR** (final phase verified, all phases complete, version bump complete or not required)
  - &rarr; **Blocked** (validation fails, worker touched files outside scope, or git state is unsafe)

---

### 8. Checkpoint Commit

The orchestrator commits a completed phase, milestone, version bump, or review-remediation fix via `agent-framework:checkpoint-commit`. Checkpoint commits are allowed only when specific conditions from Commit Policy are met.

- **Owner:** orchestrator (via `agent-framework:checkpoint-commit` skill)
- **Entry gate:** at least one checkpoint condition is true (phase verified, milestone verified, pre-risky-phase recovery point, review-remediation fix validated, or version bump complete)
- **Transitions:**
  - &rarr; **Implement** (more phases remain in the plan)
  - &rarr; **Validate** (version bump was just committed; run final validation before PR)
  - &rarr; **PR** (all phases and version work complete, final validation passed)
  - &rarr; **Blocked** (commit fails or git state becomes unsafe)

---

### 9. PR

The orchestrator opens a pull request via `agent-framework:open-plan-pr`. PRs are opened only when the approved plan is complete, validation passed, outputs are coherent and in scope, required version/release metadata is included, the working branch has been pushed, and the branch is ready to merge.

- **Owner:** orchestrator (via `agent-framework:open-plan-pr` skill)
- **Entry gate:** approved plan complete; validation passed (all declared commands passed, or "Not run" when no commands defined); version/release metadata included when required; working branch pushed
- **Transitions:**
  - &rarr; **External Review** (user request contains `review`, `codex`, or `audit`; OR project `CLAUDE.md` sets review-on-PR = true)
  - &rarr; **Final Report** (no external review requested or required)
  - &rarr; **Blocked** (PR creation fails with non-transient error)

---

### 10. External Review

The orchestrator requests external review (Codex, human reviewer, or other external reviewer). This state is optional -- entered only when review is explicitly requested or required by project policy.

- **Owner:** orchestrator (via `agent-framework:request-codex-review` skill for Codex; direct for other reviewers)
- **Entry gate:** PR exists and has been pushed; validation completed or known to be in progress
- **Transitions:**
  - &rarr; **Remediation** (review feedback received with at least one actionable item per the Classification list)
  - &rarr; **Final Report** (review returns APPROVED with no new actionable findings, or no unresolved actionable feedback remains)
  - &rarr; **Blocked** (GitHub API or parser failure that is non-transient or exhausted after retry)

---

### 11. Remediation

The orchestrator classifies and routes review feedback per `pr-review-remediation-loop.md`. Actionable items are delegated to coder/designer for the smallest correct fix. Each fix follows: delegate, validate, commit, push, reply with SHA, resolve thread.

This state is optional -- entered only when external review produces actionable feedback.

- **Owner:** orchestrator (classification/routing); coder/designer (fix implementation, delegated)
- **Entry gate:** at least one unresolved actionable review item exists (classified as `actionable-code-change`, `actionable-test-change`, `actionable-doc-change`, `architecture-or-contract-concern`, `design-or-UX-concern`, or `version-or-release-concern`)
- **Transitions:**
  - &rarr; **External Review** (all actionable items remediated and re-review conditions met; request another review)
  - &rarr; **Final Report** (no unresolved actionable feedback remains after remediation, or stop condition reached)
  - &rarr; **Blocked** (stop condition reached: 3 iteration maximum exceeded, finding repeats after attempted remediation, question-needs-user-input, architecture/API/versioning decision required, unsafe git state, or non-transient API/parser failure)

---

### 12. Final Report

The orchestrator produces the final field-based report covering: result, completed deliverables, files, validation, git state, versioning, review status, and issues.

- **Owner:** orchestrator
- **Entry gate:** one of: (a) PR opened and no review requested, (b) review completed with APPROVED or no remaining actionable items, (c) remediation completed with no remaining actionable items
- **Transitions:**
  - none (terminal state)

---

### 13. Blocked

The orchestrator produces the Blocked Report Contract: status, stage, blocker, retry status, fallback used, impact, and next action.

Blocked is reachable from any state that has a required gate when that gate fails.

- **Owner:** orchestrator
- **Entry gate:** any gate failure from any state (see Blocked Reachability below)
- **Transitions:**
  - none (terminal state; requires user intervention to resume)

---

## Blocked Reachability

Blocked is a valid transition from every state that has a required gate. The table below maps each source state to its gate-failure triggers.

| Source State | Gate Failure Triggering Blocked |
|---|---|
| Intake | Task violates hard prohibition; unintelligible input |
| Plan | Planner fails and retry/fallback exhausted |
| Trivial Fast Path | Git state unsafe; preflight values unresolvable |
| Git Preflight | Any preflight item undefined; values contradict; git state unsafe |
| Branch | Branch creation fails; repo state unsafe; would check out trunk |
| Implement | Worker blocked; files outside scope; implementation without full preflight |
| Validate | Validation fails; worker scope violation; git state unsafe |
| Checkpoint Commit | Commit fails; git state unsafe |
| PR | PR creation fails (non-transient) |
| External Review | Non-transient API/parser failure |
| Remediation | 3-iteration max; repeated finding; user-input needed; architecture/API/version decision; unsafe git state; non-transient failure |

## Workflow Paths

The following paths trace through the state machine, corresponding to the Execution Algorithm steps in `orchestrator.md`.

### Standard Path (with planner)

```
Intake -> Plan -> Git Preflight -> Branch -> Implement -> Validate
  -> Checkpoint Commit -> Implement -> ... (repeat per phase)
  -> Validate (final) -> PR -> Final Report
```

Execution Algorithm mapping: Intake (receive task) &rarr; Plan (step 1) &rarr; Git Preflight (steps 4-5) &rarr; Branch (step 6) &rarr; Implement/Validate/Checkpoint Commit cycle (steps 7-10) &rarr; version bump if required (steps 11-12, within Implement/Validate/Checkpoint Commit) &rarr; final Validate (step 13) &rarr; PR (step 14) &rarr; Final Report.

### Standard Path (with external review)

```
Intake -> Plan -> Git Preflight -> Branch -> Implement -> Validate
  -> Checkpoint Commit -> ... -> PR -> External Review
  -> Remediation -> External Review -> ... -> Final Report
```

Execution Algorithm mapping: same as above through PR (step 14), then External Review (step 15) &rarr; Remediation (step 15, feedback loop) &rarr; re-review or Final Report.

### Trivial Fast Path

```
Intake -> Trivial Fast Path -> Git Preflight -> Branch -> Implement
  -> Validate -> Checkpoint Commit -> PR -> Final Report
```

Execution Algorithm mapping: Intake &rarr; Trivial Fast Path (planner-skip exception applied at step 1) &rarr; Git Preflight (steps 4-5; not skipped) &rarr; Branch (step 6) &rarr; Implement/Validate/Checkpoint Commit (steps 7-10) &rarr; PR (step 14) &rarr; Final Report.

### Blocked at any gate

```
<any gated state> -> Blocked
```

Any state whose entry gate fails transitions to Blocked. The orchestrator produces the Blocked Report Contract. User intervention is required to resume.

## Invariants

These invariants hold across all paths through the state machine. They are not new rules; they restate constraints enforced by the governance documents.

1. **No implementation before Git Preflight.** The Implement state is reachable only through Branch, which is reachable only through Git Preflight. This holds for both the standard path and the Trivial Fast Path.
2. **Trivial Fast Path does not skip preflight.** The Trivial Fast Path state transitions exclusively to Git Preflight (or Blocked). There is no edge from Trivial Fast Path to Branch, Implement, or any later state.
3. **Blocked is reachable from every gated state.** Every state except Intake (which has no entry gate) and the two terminal states (Final Report, Blocked) can transition to Blocked on gate failure.
4. **External Review and Remediation are optional.** The PR state can transition directly to Final Report when no review is requested or required.
5. **One plan = one branch = one PR.** The Branch state creates exactly one working branch per approved plan, and the PR state opens exactly one PR per plan.
6. **Workers never commit unless delegated.** Checkpoint Commit is owned by the orchestrator via skill. Coder may commit only when explicitly delegated.
7. **Trunk is never committed to directly.** The Branch state creates a non-trunk working branch. No path permits direct trunk commits.
