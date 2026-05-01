---
name: address-pr-feedback
description: Fix a specific generic GitHub PR comment or reviewer comment on an existing pull request. Use for one-time fixes of Codex, human reviewer, or bot comments — anything that is not a watch/monitor/poll/wait/loop/continue request.
disable-model-invocation: false
allowed-tools:
  - Read
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git rev-parse *)
  - Bash(git fetch *)
  - Bash(git diff *)
  - Bash(git log *)
  - Bash(git add *)
  - Bash(git commit *)
  - Bash(git push *)
  - Bash(gh pr view *)
  - Bash(gh pr comment *)
  - Bash(gh api *)
  - Agent(agent-framework:planner, agent-framework:coder, agent-framework:designer)
  - Skill
shell: powershell
---

# Address PR Feedback

Fix one-time PR feedback (Codex, human reviewer, or bot comments alike).

Follow:

- `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`
- `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`
- Read `${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md` for the complete GraphQL operations reference.

## Invocation Boundary

Use when the user request does not contain any of: `watch`, `monitor`, `wait`, `poll`, `loop`.

The comment author does not affect skill selection — this skill handles one-time fixes for Codex, human reviewer, and bot comments alike. Author affects classification, not routing.

Typical user phrasings that match: `fix PR comment on PR #N`, `address reviewer feedback`, `fix the unresolved comment`, `fix Codex comment on PR #N`, `address Codex feedback on this PR`.

## Required Inputs

At minimum one of:

- PR number or PR URL, OR
- a current git branch with exactly one open PR on the configured remote (the skill resolves the PR via `gh pr view --json number,state` against the current branch)

If neither is available, return the Blocked Report Contract with `Stage: fetch` and `Blocker: no PR identified`.

Optional:

- comment URL
- comment author
- file path
- quoted comment text
- whether to reply after fixing

## Procedure

1. Resolve PR: if the caller passed a PR number/URL, use it; otherwise run `gh pr view --json number,state --jq .number` against the current branch. If no open PR is associated with the current branch, return Blocked with `Blocker: no PR identified`. Then confirm the resolved PR exists, capture target branch and head branch, and confirm git state is not unsafe per the "Unsafe git state" definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md`.
2. Fetch top-level PR comments, inline review comments, unresolved review threads, and review summaries using `${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md` where GraphQL review-thread data is required.
3. Identify the target comment.
   - If exactly one unresolved/actionable candidate exists, process it.
   - If multiple unrelated candidates exist and the user did not identify one, return blocked with candidates.
4. Classify feedback using `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` (Classification).
5. Route per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` (Routing) to `agent-framework:planner`, `agent-framework:coder`, or `agent-framework:designer`.
6. Delegate the "Smallest correct fix" per `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions).
7. Run validation per the "Validation procedure" definition. If `CLAUDE.md` lists no validation commands, report `Validated: Not run (no validation commands defined)`.
8. Commit and push when all of: a change was made; the head branch is not the resolved trunk; there are no unresolved validation failures.
9. Reply with fix summary, validation result, and commit SHA whenever a change was made and pushed. Reply mechanism depends on feedback source:
   - inline review comment or review thread → `addPullRequestReviewThreadReply` GraphQL mutation on the originating thread
   - top-level PR comment (issue comment) → `gh pr comment <pr> --body "..."` referencing the original comment URL
   - review summary (review with no inline thread) → `gh pr comment` referencing the review URL
   Every actionable fix gets a reply with the commit SHA so the re-review gate in `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` (Re-review preconditions) is satisfied.

Do not request Codex re-review from this skill unless the user explicitly asks.

## Output

```text
Status: complete | partial | blocked

PR:
- Number:
- Branch:
- Target:

Feedback:
- Source:
- Author:
- URL:
- Classification:

Changed:
- path/to/file
- None

Validated:
- [check]
- Not run

Git:
- Commit:
- Pushed: yes | no

Reply:
- Posted: yes | no
- URL:
- Not posted because:

Issues:
- [issue]
- None
```

Use the blocked report contract from `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` for blocked states.
