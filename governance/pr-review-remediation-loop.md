# PR Review Remediation Loop

## Purpose

Defines how Claude agents respond to external pull request review feedback, including Codex GitHub reviews.

Codex and other external AI reviewers are external reviewers, not Claude Code subagents.

## Ownership

The orchestrator owns the loop:

- request external review
- check feedback
- identify unresolved review threads/comments
- classify and route feedback
- verify fixes are committed and pushed
- reply to review threads/comments
- resolve review threads
- request re-review
- stop safely

Skills may execute loop steps only when invoked by the orchestrator. Ownership remains with the orchestrator.

## Entry Criteria

Start only after:

- a PR exists
- the PR branch has been pushed
- required validation completed or is known to be in progress
- external review was requested or feedback already exists

## Feedback Sources

Check:

- unresolved PR review threads
- inline PR review comments
- top-level PR comments
- requested-changes or commented review summaries
- CI failures on files changed in this PR or referenced by review feedback

## Classification

Classify every review item as one of:

- `actionable-code-change`
- `actionable-test-change`
- `actionable-doc-change`
- `architecture-or-contract-concern`
- `design-or-UX-concern`
- `version-or-release-concern`
- `question-needs-user-input`
- `non-actionable`
- `incorrect-or-rejected`

Do not silently ignore review feedback.

## Routing

- `coder`: source, tests, docs, build, packaging, release metadata, serialization, generation, runtime behavior, validation fixes
- `designer`: presentational UI/UX or static accessibility fixes
- `planner`: multi-step, risky, public API, architecture, compatibility, package/release, versioning, generated-output, cross-cutting, or test-strategy feedback
- user: product, public API, architecture, security, compatibility, release, or versioning decisions that cannot be safely inferred

## Fix Rules

For each actionable item:

1. identify the exact thread/comment
2. identify affected files
3. delegate the "Smallest correct fix" per `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions)
4. update tests when behavior changes
5. update version/release metadata when the change matches the Bump Trigger in `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`
6. run validation per the "Validation procedure" definition
7. commit and push to the PR branch
8. reply with fix summary and commit SHA
9. resolve only after fix is pushed and validation has been run or explicitly reported as Not run

## Rejected Feedback

If feedback is incorrect or intentionally not applied:

1. reply with rationale (no length limit, but include: why the feedback does not apply, and what alternative addresses the underlying concern if any)
2. do not resolve the thread; leave it open
3. before rejecting any feedback in the categories P0, P1, security, public API, compatibility, architecture, package/release, or versioning: post the rationale comment and stop. Do not resolve the thread. Wait for explicit user instruction to either resolve or remediate.

## Re-review

Request another external review only when every one of the following is true:

- every classification = `actionable-*` item from this loop has had its fix pushed
- every fix has a corresponding reply on the originating thread that includes the commit SHA
- the user has not asked to skip re-review for this PR
- there is at least one new commit on the PR branch since the last review request (compared by HEAD SHA)

Default Codex re-review request:

```text
@codex review the latest changes and verify the prior findings were addressed. Focus only on remaining regressions, missing tests, public API compatibility, security issues, package/release behavior, versioning, and risky behavior changes.
```

Do not request a review more than once for the same PR HEAD SHA.

## Stop Conditions

Stop when any of the following is true:

- no unresolved actionable review feedback remains on the PR
- the latest review on the PR has state `APPROVED` and posts no new actionable findings
- the loop has run 3 remediation iterations on this PR
- a finding "repeats after attempted remediation" per the "Same finding" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`
- any new feedback item is classified `question-needs-user-input`
- feedback requires a decision in any of: architecture, public API surface, compatibility, release behavior, versioning
- a CI check unrelated to the changed files in this PR is failing
- remediation would require violating any rule in `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`, `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`, or this file
- git state matches the "Unsafe git state" definition
- a GitHub API or parser failure occurred and the failure does not match the "Transient failure" definition (or it does but the single retry already failed)

Default maximum: 3 remediation iterations per PR.

After 3 iterations, summarize remaining items, attempted fixes, non-convergence reason, and recommended next action.

## Thread Resolution Rule

Resolve review threads only after:

- fix is committed
- fix is pushed
- relevant validation is complete or explicitly reported
- reply was posted

Do not resolve unresolved questions or unapproved rejected high-severity feedback.

## Remediation Ledger

Maintain a short session-local ledger during each loop:

- PR number/URL
- branch
- iteration
- feedback queue
- classification
- owner
- status
- validation
- pushed commits
- remaining items

Do not commit the ledger unless the user or project policy explicitly requests it.

## Skill Selection

Skill selection depends only on user-request keywords; the comment author (Codex, human reviewer, bot) does not affect which skill is used. PR identification is the skill's responsibility, not the router's — see `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions → One-time vs watch routing).

- `agent-framework:watch-pr-feedback`: when the user request contains at least one of `watch`, `monitor`, `wait`, `poll`, or `loop`. The skill resolves the target PR (named in the request, current branch's open PR, or returns Blocked).
- `agent-framework:address-pr-feedback`: every other PR-feedback request — one-time fixes for Codex, human reviewer, or bot comments. Use this for `fix Codex comment on PR #N`, `address reviewer feedback`, `fix the unresolved comment`, etc.

## Monitoring

A remediation skill is not a monitor. A monitor detects new feedback and routes to remediation skills.

Monitoring must be read-only, deterministic, bounded, parser-stable, and truthfully reported. Full rules: `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Monitoring Policy).

Use `agent-framework:watch-pr-feedback` for monitor-backed behavior. If Monitor, `/loop`, scheduling support, or the approved parser strategy is unavailable, fall back to manual remediation or return `blocked`.
