# Execution Algorithm — Verbose Procedural Detail

Extracted procedural detail for complex Execution Algorithm steps, referenced by the orchestrator skeleton. Each section is self-contained: the orchestrator reads the relevant section and executes without additional context.

Source: `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md` (Execution Algorithm).

## Step 0: Intake

**Intake (task-type classification and claude-mem detection).** Before planner delegation or trivial fast path routing, perform the following intake sub-steps:

- **Task-type classification (intake).** Classify the task as exactly one of `bugfix|refactor|feature|incident` per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Task-Type Classification). Use the tie-break rule from that section when the task fits multiple labels. Record the classification as `task-type:` in the Session facts block (canonical key per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Session Fact Cache)). Trivial fast path (TFP) tasks default to the most restrictive applicable budget profile (i.e., `bugfix` limits unless the task clearly fits a less restrictive label). For every Step-omitting bypass per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Bypass Code Matrix), assign a synthetic task checkpoint ID `TASK-NNN` so mid-phase budget breaches and Path B partial checkpoints have a stable identifier. The matrix is the single source of truth for which codes are Step-omitting and how each interacts with `step:`, report type, `TASK-NNN`, the Session Fact key, and the `evidence:` slot.
- **PR-feedback-remediation detection (intake).** Before claude-mem detection, check the user's raw task input for a PR feedback remediation request. A match requires BOTH: (a) a reference to an existing PR — `PR <N>`, `#<N>`, or a GitHub PR URL; AND (b) an action-plus-target pair — an action verb (`address`, `fix`, `resolve`, `handle`, `remediate`) combined with a feedback-target noun (`comments`, `feedback`, `threads`, `review`, `findings`). When both signals are present: record `routing: pr-feedback-remediation` and `pr: <N>` in Session facts. Task-type classification still runs (defaults to `bugfix` per tie-break rule). The `routing` signal takes precedence over normal STT routing at `after=intake-complete`. When NOT detected: no-op; normal intake continues. Note: "fix PR 95" alone (action verb without feedback-target noun) does NOT match — it could mean "continue implementing PR 95." The heuristic requires both signals to avoid false positives.
- **claude-mem detection.** Detect and record per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (claude-mem Detection). Record `claude-mem: present|absent` in Session facts.
- **Pre-planning memory lookup.** When `claude-mem: present`, run pre-planning lookup per `${CLAUDE_PLUGIN_ROOT}/governance/context-management-policy.md` (Pre-Planning Memory Lookup). Pass results per that section.

## Step 11: Version Bump Detection

Before PR readiness, apply `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` (Bump Trigger) against changed files. When `CLAUDE.md` does not define project-specific bump-trigger paths, the Bump Trigger and "No bump is required by default" lists are exhaustive (per versioning.md): a change matching the "No bump" list requires no bump; a change matching the Bump Trigger list requires a bump (use Bump Type Determination to choose the type). Stop and ask the user only when (a) the change matches more than one row of Bump Type Determination, or (b) it matches no row, or (c) for an artifact that requires a bump, `CLAUDE.md` does not list the full set of artifact files per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` (Bump Execution) — canonical version file, required mirrors, changelog/release notes, package/artifact metadata, documentation mirrors, and release validation files when applicable.

## Step 13a: Pre-PR Local Review

**Pre-PR local review.** After validation and before pushing or opening a PR, invoke the `agent-framework:local-reviewer` agent when ALL of the following are true: (a) the user has not opted out of local review (task input does not contain "skip review", "no review", or "skip local review"); (b) codex-plugin-cc availability is unknown or confirmed present (the agent itself detects availability).

a. Invoke `agent-framework:local-reviewer` via the Agent tool with input contract:

```yaml
base: <resolved trunk>
working_branch: <current working branch>
trunk: <resolved trunk>
claude_mem: present | absent
max_iterations: 10  # default; raise on user-approved continuation
```

b. The local-reviewer agent owns the entire loop lifecycle internally (review invocation, classification, break-fix detection, simple fix delegation at sonnet, validation, checkpoint commits, iteration advancement). The orchestrator does not drive individual iterations.

c. Handle terminal return per STT rows 44-53:
   - `exit: clean, no fix commits` → proceed to step 14 (open PR).
   - `exit: clean, fix commits exist` → re-run step 11 (version bump detection) against new HEAD.
   - `exit: max-iterations-reached` → STOP: surface three choices (continue with raised ceiling / push and open PR now / stop). On continue: re-invoke local-reviewer with `max_iterations` raised (e.g., 20) — pass the returned `ledger_path` as `resume_from_ledger` so break-fix history and prior fix SHAs are preserved.
   - `exit: break-fix-break` → STOP: surface conflict summary.
   - `exit: injection-suspect` → STOP: surface finding details.
   - `exit: user-input-required` → STOP: surface finding.
   - `exit: high-severity-rejection` → STOP: await explicit user approval. The local-reviewer returns the finding details (finding_id, title, rationale_text) — surface them to the user.
   - `exit: planner-escalation` → delegate planner (opus) for remediation plan → delegate per plan (coder or designer, opus) to implement → verify → validate → checkpoint-commit → re-invoke local-reviewer with the returned `ledger_path` as `resume_from_ledger` so break-fix history and prior fix SHAs are preserved.
   - `blocked: codex unavailable` → log `Review: local pre-PR review skipped (codex unavailable)`, proceed to step 14.
   - `blocked: other` → STOP: surface blocker.

d. Tool-error recovery (STT row 71): if the local-reviewer agent crashes or times out (exit 124/137) AFTER starting execution (fix ledger exists at `.agent-framework/review-loop/fix-ledger.yaml`), read the ledger path and re-invoke with `resume_from_ledger`. If no ledger exists (spawn failure), fall through to generic tool-error rows.

## Step 15: Post-PR Review

**Post-PR review.** After the PR is opened (step 14), invoke the `agent-framework:github-reviewer` agent when (a) the user request contains `review`, `codex`, or `audit`; OR (b) `CLAUDE.md` sets review-on-PR = true. If neither (a) nor (b) is true, skip review and proceed to the Final Report with `Review: Requested: no`. External review is opt-in; this is the default path.

### Standard Path: Mode Routing

When review is opted-in after PR open, route by keyword presence in the original user request:

- **STT row 54 — watch mode:** user request contains `watch`, `monitor`, `wait`, `poll`, or `loop` → invoke `agent-framework:github-reviewer` in watch mode:

```yaml
mode: watch
pr: <PR number>
working_branch: <current working branch>
base: <resolved trunk>
reviewer_filter: all
max_watch_duration: 14400
max_remediation_cycles: 3
```

- **STT row 55 — fix mode:** user request contains none of the watch keywords → invoke `agent-framework:github-reviewer` in fix mode (one-shot):

```yaml
mode: fix
pr: <PR number>
working_branch: <current working branch>
base: <resolved trunk>
```

The github-reviewer agent owns the entire remediation lifecycle internally (Monitor setup for watch mode, feedback detection, PR status check detection, classification, injection scanning, simple fix delegation at sonnet, validation, checkpoint commits, push, fix-SHA reply posting, thread resolution, cycle tracking). The orchestrator does not drive individual remediation items — this includes both review comment remediation and failed CI check remediation.

**PR status check remediation:** The github-reviewer detects failed PR status checks (`gh pr checks` with `bucket == "fail"`) alongside review comments. Failed checks are classified as `failed-ci-check`, routed to coder at sonnet for simple fixes (≤2 files, no architecture impact), or escalated to orchestrator for complex CI failures. Checks that require `.github/workflows/` changes or touch >2 files trigger `planner-escalation`. After fix and push, checks re-run automatically — no thread resolution needed (checks are stateless). No new STT rows are required; existing `github-reviewer-returned` exit reasons cover all check-related outcomes.

Handle terminal return per STT rows 59-67:
- `exit: clean` → Final Report. Note: `clean` means both review feedback and PR status checks are resolved (or no actionable items existed).
- `exit: max-cycles-reached` → STOP: surface summary of remaining open items.
- `exit: pr-merged` → Final Report.
- `exit: pr-closed` → Final Report.
- `exit: injection-suspect` → STOP: surface finding details.
- `exit: user-input-required` → STOP: surface finding.
- `exit: planner-escalation` → delegate planner (opus) for remediation plan → delegate per plan (coder or designer, opus) to implement → verify → validate → checkpoint → push → re-invoke github-reviewer fresh (new invocation — resolved threads filtered by API).
- `exit: high-severity-rejection` → STOP: await explicit user approval (rationale already posted by the reviewer agent).
- `blocked` → STOP: surface blocker.

### Ad-Hoc Path: Explicit Codex Review Request

When the user explicitly requests Codex review (outside the standard pipeline), use `agent-framework:request-github-codex-review` skill to submit the review request, then:

- On `succeeded, watch requested` (STT row 68): invoke github-reviewer in watch mode (same as standard path above).
- On `succeeded, no watch` (STT row 69): Final Report with `Review: Requested: yes`.
- On `blocked` (STT row 70): STOP: surface blocker.

### Tool-Error Recovery (STT row 72)

If the github-reviewer agent crashes or times out (exit 124/137) AFTER starting execution (evidence: pushed commits or posted replies visible in the PR), re-invoke github-reviewer fresh. The agent's crash recovery design (C3) ensures no duplicate work: resolved threads are excluded by API, self-authored replies are filtered at detection, and pushed commits persist.

If no evidence of execution exists (spawn failure), fall through to generic tool-error rows.
