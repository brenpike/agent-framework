---
name: address-pr-feedback
description: Fix a specific generic GitHub PR comment or reviewer comment on an existing pull request. Use for non-Codex or ambiguous PR feedback requests.
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
  - Agent(planner, coder, designer)
  - Skill
shell: powershell
---

# Address PR Feedback

Fix one-time generic, human, non-Codex, or ambiguous PR feedback.

Follow:

- `agent-system-policy.md`
- `branching-pr-workflow.md`
- `versioning.md`
- `pr-review-remediation-loop.md`
- the GraphQL Reference section at the end of this file for PR review threads, thread replies, and GraphQL review data

## Invocation Boundary

Use for:

- `fix PR comment on PR #N`
- `address reviewer feedback`
- `fix the unresolved comment`
- ambiguous PR feedback requests

Do not use for explicit Codex review loops. Use `run-codex-review-loop` only when Codex is explicitly requested.

## Required Inputs

At minimum:

- PR number or PR URL

Optional:

- comment URL
- comment author
- file path
- quoted comment text
- whether to reply after fixing

## Procedure

1. Confirm PR exists, target branch, head branch, current branch, and safe working tree.
2. Fetch top-level PR comments, inline review comments, unresolved review threads, and review summaries using the GraphQL Reference section at the end of this file where GraphQL review-thread data is required.
3. Identify the target comment.
   - If exactly one unresolved/actionable candidate exists, process it.
   - If multiple unrelated candidates exist and the user did not identify one, return blocked with candidates.
4. Classify feedback using `pr-review-remediation-loop.md`.
5. Route to planner/coder/designer according to policy.
6. Apply the smallest correct fix.
7. Run relevant validation when feasible.
8. Commit and push when a change was made and policy allows.
9. Reply with concise fix summary, validation, and commit SHA when appropriate.

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

Use the blocked report contract from `agent-system-policy.md` for blocked states.

## GraphQL Reference

# GitHub PR Review GraphQL Reference

Use these operations for pull request review remediation.

Resolvable pull request review threads are GraphQL objects. Do not try to resolve review threads using REST review-comment IDs.

## Shell and Parsing Rules

Use deterministic GitHub CLI commands.

Prefer:

- `gh pr view --json ... --jq ...`
- `gh api graphql --jq ...`

Do not dynamically probe for Python, Node, standalone `jq`, or PowerShell parsers. Do not shell-hop for routine parsing.

If `gh --jq` cannot produce the required value, return `blocked` instead of improvising parser fallbacks.

## Pagination Requirement

Examples below fetch first pages. Implementations must page through any connection that may exceed the page size, including:

- review threads
- thread comments
- top-level PR comments
- reviews

If pagination is required but not implemented, return `blocked` rather than claiming full coverage.

Pass `-F after="CURSOR"` (using `endCursor` from `pageInfo`) on subsequent fetches. Omit `-F after` for the first page. Nested connection pagination (e.g., thread comments beyond the first page) requires a separate per-thread query using the thread `id` and a comment-level cursor.

## Fetch Reviews

Use this query to retrieve review summaries (including `CHANGES_REQUESTED` and `COMMENTED` reviews whose body contains actionable feedback not captured in inline threads).

```bash
gh api graphql \
  -f owner="OWNER" \
  -f repo="REPO" \
  -F pr=123 \
  -f query='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviews(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          author { login }
          state
          body
          submittedAt
          url
        }
      }
    }
  }
}'
```

Filter results to reviews where `state` is `CHANGES_REQUESTED` or `COMMENTED` and `body` is non-empty. Pass `-F after="CURSOR"` using `endCursor` from `pageInfo` on subsequent fetches.

## Fetch Review Threads

```bash
gh api graphql \
  -f owner="OWNER" \
  -f repo="REPO" \
  -F pr=123 \
  -f query='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      number
      url
      state
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 20) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              author { login }
              body
              createdAt
              url
              path
              line
              diffHunk
            }
          }
        }
      }
    }
  }
}'
```

## Fetch Unresolved Thread Summary Lines

```bash
gh api graphql \
  -f owner="OWNER" \
  -f repo="REPO" \
  -F pr=123 \
  -f query='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 20) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
    }
  }
}' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false)
        | . as $thread
        | $thread.comments.nodes[]
        | "THREAD=\($thread.id) COMMENT=\(.id) AUTHOR=\(.author.login) PATH=\($thread.path) LINE=\($thread.line // "") URL=\(.url)"'
```

## Fetch Thread Comments (Paginated)

Use this query to retrieve additional pages of comments from a single review thread when `comments(first: 20)` returns `pageInfo.hasNextPage == true`. `threadId` is the thread's GraphQL node id (e.g., `PRRT_...`).

```bash
gh api graphql \
  -f threadId="THREAD_NODE_ID" \
  -f query='
query($threadId: ID!, $after: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 20, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          author { login }
          body
          createdAt
          url
        }
      }
    }
  }
}'
```

Pass `-F after="CURSOR"` using `endCursor` from `pageInfo` on all continuation fetches. Omit `-F after` only for the initial fetch (first page of the thread's comments).

## Fetch Top-Level PR Comments

Top-level PR comments are issue comments because every PR is also an issue.

```bash
gh api graphql \
  -f owner="OWNER" \
  -f repo="REPO" \
  -F pr=123 \
  -f query='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          author { login }
          body
          createdAt
          url
        }
      }
    }
  }
}' \
  --jq '.data.repository.pullRequest.comments.nodes[]
        | "COMMENT=\(.id) AUTHOR=\(.author.login) URL=\(.url)"'
```

## Reply to Review Thread

```bash
gh api graphql \
  -f threadId="THREAD_ID" \
  -f body="Fixed in COMMIT_SHA. Summary: ..." \
  -f query='
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(
    input: {
      pullRequestReviewThreadId: $threadId,
      body: $body
    }
  ) {
    comment { id url }
  }
}'
```

## Resolve Review Thread

```bash
gh api graphql \
  -f threadId="THREAD_ID" \
  -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}'
```

## Author Filtering

When processing Codex-only feedback, include comments whose author login matches the repository's Codex reviewer identity.

If identity is unclear, report candidate authors and ask the user before processing non-human or ambiguous reviewers.

## Safety Rules

- Reply before resolving.
- Resolve only threads actually fixed, pushed, and validated.
- Include commit SHA when code changed.
- Do not resolve unresolved questions.
- Do not resolve rejected P0/P1, security, public API, compatibility, versioning, or release feedback without user approval unless policy explicitly permits it.
