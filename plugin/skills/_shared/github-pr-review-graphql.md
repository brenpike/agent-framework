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

Filter results to reviews where `state` is `CHANGES_REQUESTED` or `COMMENTED`. Apply the Detection Filtering rules (see [Detection Filtering](#detection-filtering)) before yielding results as new feedback. Pass `-F after="CURSOR"` using `endCursor` from `pageInfo` on subsequent fetches.

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
        | select(.body != null and (.body | gsub("\\s+"; "") != ""))
        | select(.author.login != $ENV.SELF_LOGIN)
        | "THREAD=\($thread.id) COMMENT=\(.id) AUTHOR=\(.author.login) PATH=\($thread.path) LINE=\($thread.line // "") URL=\(.url)"'
# SELF_LOGIN is resolved at runtime via: gh api user --jq .login
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

Apply Detection Filtering rules (see [Detection Filtering](#detection-filtering)) to all results from this query before ledger entry or classification.

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
        | select(.body != null and (.body | gsub("\\s+"; "") != ""))
        | select(.author.login != $ENV.SELF_LOGIN)
        | "COMMENT=\(.id) AUTHOR=\(.author.login) URL=\(.url)"'
# SELF_LOGIN is resolved at runtime via: gh api user --jq .login
```

## Detection Filtering

All detection and poll queries must apply both filters before yielding results as new feedback. A result that fails either filter must be silently skipped — do not surface it as actionable feedback, count it toward the actionable total, or route it for remediation. A filtered result may be incremented in a separate observability counter (e.g., a `filtered (excluded)` ledger entry) solely for diagnostic purposes.

### Filter 1 — Exclude empty body

Exclude any comment or review where `body` is `null`, the empty string `""`, or contains only whitespace characters.

In `--jq` expressions use:

```
select(.body != null and (.body | gsub("\\s+"; "") != ""))
```

### Filter 2 — Exclude self/bot identity

Exclude any comment or review where `author.login` matches the authenticated identity of the agent running the query. This prevents the agent from treating its own previously posted replies as new incoming feedback.

Resolve and export the identity once per poll cycle before issuing queries. The syntax is shell-specific; both variants achieve the same result:

```bash
# Bash
export SELF_LOGIN=$(gh api user --jq .login)
# PowerShell
$env:SELF_LOGIN = (gh api user --jq .login)
```

`SELF_LOGIN` is a runtime-resolved variable. It is **not** a literal string placeholder — it must be assigned to the process environment before the `--jq` expression runs. In `--jq` expressions, pass it through the environment:

```
select(.author.login != $ENV.SELF_LOGIN)
```

Both filters apply to every detection query: review threads, thread comments, top-level PR comments, and review summaries.

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
