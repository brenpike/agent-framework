---
name: watch-pr-feedback
description: Watch a specific GitHub pull request for new unresolved review comments or review threads using Monitor when available, then route to the appropriate remediation skill. Use only when the user explicitly asks to watch, monitor, wait, poll, loop, or continue handling new PR feedback as it appears.
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

- `agent-system-policy.md`
- `pr-review-remediation-loop.md`
- the GraphQL Reference section at the end of this file

## Invocation Boundary

Use only when the user explicitly asks to:

- watch or monitor PR comments
- wait for review feedback
- poll/check repeatedly
- keep handling feedback as it appears
- loop on Codex/human review feedback
- use Monitor for PR feedback

Do not use for one-time requests like `fix PR comment on PR #N`; use `address-pr-feedback`.

## Required Inputs

At minimum:

- PR number or PR URL

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
- stop on user/product decision
- stop on repeated finding
- stop on unsafe git state
- do not merge PR
- do not approve PR

## Procedure

1. Confirm PR exists and is open using `gh pr view --json state --jq .state`.
2. Confirm GitHub CLI access works.
3. Confirm current branch and working tree state.
4. Start Monitor when available using one deterministic, read-only feedback-detection command based on the GraphQL Reference section at the end of this file. Detection must cover review threads, top-level PR comments, and review summaries (reviews with `CHANGES_REQUESTED` or `COMMENTED` state whose body contains actionable feedback not captured in inline threads). Fetch and ledger review summary IDs and states alongside thread and comment IDs.
5. Track seen comment/thread/review IDs in a session-local ledger.
6. When new feedback appears, classify source:
   - Codex feedback
   - human reviewer feedback
   - CI/system feedback
   - ambiguous
7. Route:
   - explicit Codex loop request → `run-codex-review-loop`
   - generic/human/ambiguous feedback → `address-pr-feedback`
8. Stop on policy stop conditions.

## Monitor Rules

Monitor commands must be:

- read-only
- deterministic
- bounded
- parser-stable
- based on `gh --json/--jq` or `gh api graphql --jq`

Do not probe or fallback through Python, Node, standalone `jq`, PowerShell, or shell translations.

If Monitor startup or parser strategy fails:

1. retry once only if transient
2. perform one manual feedback check when safe
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
- run-codex-review-loop: [count]
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
