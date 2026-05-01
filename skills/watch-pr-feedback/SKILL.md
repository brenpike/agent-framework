---
name: watch-pr-feedback
description: Watch a specific GitHub pull request for new unresolved review comments or review threads using Monitor when available, then route to the appropriate remediation skill. Use only when the user explicitly asks to watch, monitor, wait, poll, or loop on new PR feedback.
disable-model-invocation: false
allowed-tools:
  - Bash(gh pr view *)
  - Bash(gh api *)
  - Bash(git status *)
  - Bash(git branch *)
  - Monitor
  - Skill
shell: powershell
---

# Watch PR Feedback

Watch a specific PR for new unresolved review feedback and route to remediation skills.

This skill detects and routes. It must not directly edit files, commit, push, reply, resolve threads, approve PRs, or merge PRs.

Follow:

- `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`
- Read `${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md` for the complete GraphQL operations reference.

## Invocation Boundary

Use only when the user explicitly asks to:

- watch or monitor PR comments
- wait for review feedback
- poll/check repeatedly
- keep handling feedback as it appears
- loop on Codex/human review feedback
- use Monitor for PR feedback

Do not use for one-time requests like `fix PR comment on PR #N`; use `agent-framework:address-pr-feedback`.

## Required Inputs

At minimum one of:

- PR number or PR URL, OR
- a current git branch with exactly one open PR on the configured remote (the skill resolves the PR via `gh pr view --json number,state` against the current branch)

If neither is available, return the Blocked Report Contract with `Stage: skill selection` (when called for input resolution) or `Stage: fetch` (when called mid-procedure) and `Blocker: no PR identified`.

Optional:

- reviewer filter: Codex-only | all reviewers | specific author
- max watch duration
- polling interval
- max remediation cycles
- stop-on-human-reviewer-comments
- stop-on-P0/P1-findings

## Defaults

- reviewer filter: Codex-only after a Codex review request; otherwise all unresolved comments
- max remediation cycles: 3
- max speculative fix attempts per thread: 1
- max watch duration: 4 hours
- stop when any new feedback item is classified `question-needs-user-input` per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`
- stop when a finding meets the "Same finding" / "repeats after attempted remediation" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions)
- stop when git state matches the "Unsafe git state" definition
- stop when PR state becomes `MERGED` or `CLOSED`
- do not merge PR
- do not approve PR

## Procedure

1. Resolve PR: if the caller passed a PR number/URL, use it; otherwise run `gh pr view --json number,state --jq '.state + ":" + (.number | tostring)'` against the current branch. Confirm the resolved PR's state is `OPEN`. If no PR is associated with the current branch, or the resolved PR's state is not `OPEN` (e.g., `MERGED`, `CLOSED`), return Blocked with `Blocker: no open PR identified` (include the resolved state when available).
2. Confirm GitHub CLI access works.
3. Confirm current branch and working tree state.
4. Start Monitor when available using one deterministic, read-only feedback-detection command based on `${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md`. Detection must cover review threads, top-level PR comments, review summaries (reviews with state in `CHANGES_REQUESTED` or `COMMENTED` whose body, when classified per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` Classification, maps to any `actionable-*` class), and the PR's `state` field on every poll so terminal transitions to `MERGED` or `CLOSED` are observable. Fetch and ledger review summary IDs and states alongside thread and comment IDs.
5. Track seen comment/thread/review IDs in a session-local ledger.
6. When new feedback appears, classify source:
   - human reviewer feedback
   - CI/system feedback
   - ambiguous
7. Route generic/human/ambiguous feedback → `agent-framework:address-pr-feedback`.
8. Stop on policy stop conditions, including PR state transition to `MERGED` or `CLOSED`. On terminal-state detection, stop the Monitor (e.g., via TaskStop) and report the terminal state — do not continue polling a terminal resource.

## Monitor Rules

Monitor commands must be:

- read-only
- deterministic
- bounded
- parser-stable
- based on `gh --json/--jq` or `gh api graphql --jq`

Do not probe or fallback through Python, Node, standalone `jq`, PowerShell, or shell translations.

Full rules: `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Monitoring Policy and Shell and Parser Policy).

If Monitor startup or parser strategy fails:

1. retry exactly once if the failure matches the "Transient failure" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`
2. run exactly one manual check using the same read-only command if git state is not unsafe per the "Unsafe git state" definition
3. report `Monitoring: not active`

Do not start a second Monitor with a different parser strategy unless the user explicitly approves.

## State Ledger

Track session-local:

- seen comment IDs
- seen review thread IDs
- comments already remediated
- comments skipped as non-actionable
- comments requiring user input
- remediation cycle count
- monitor startup status

Do not reprocess the same item unless new activity appears or the user explicitly asks to retry.

## Output

```text
Status: complete | partial | blocked

PR:
- Number:
- State:
- Branch:
- Target:

Watch:
- Mode: Monitor | scheduled | manual
- Monitoring: active | not active
- Parser: gh --jq | other-approved | unavailable
- Cycles:
- Seen comments:
- New actionable comments:

Routed:
- address-pr-feedback: [count]
- None

Stopped because:
- [reason]

Next action:
- [required next step]
- None

Issues:
- [issue]
- None
```

Use the blocked report contract from `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` for blocked states.
