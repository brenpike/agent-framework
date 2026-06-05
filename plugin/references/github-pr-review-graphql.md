# GitHub PR Review GraphQL Reference

Use these operations for pull request review remediation.

Resolvable pull request review threads are GraphQL objects. Do not try to resolve review threads using REST review-comment IDs.

## Contents

- [Shell and Parsing Rules](#shell-and-parsing-rules) — deterministic CLI commands and jq usage constraints
- [Pagination Requirement](#pagination-requirement) — mandatory paging for all connections that may exceed page size
- [Fetch Reviews](#fetch-reviews) — retrieve review summaries including `CHANGES_REQUESTED` and `COMMENTED` states
- [Fetch Review Threads](#fetch-review-threads) — retrieve inline review threads with comments and metadata
- [Fetch Thread Comments (Paginated)](#fetch-thread-comments-paginated) — retrieve additional comment pages from a single thread
- [Fetch Top-Level PR Comments](#fetch-top-level-pr-comments) — retrieve issue-level comments (not inline review threads)
- [Detection Filtering](#detection-filtering) — filters to apply before yielding any result as actionable feedback
- [Reply to Review Thread](#reply-to-review-thread) — mutation to post a reply to an existing review thread
- [Resolve Review Thread](#resolve-review-thread) — mutation to mark a review thread as resolved
- [Author Filtering](#author-filtering) — rules for scoping feedback to specific reviewer identities
- [Codex Approval Detection](#codex-approval-detection) — paginated 👍 reaction lookup that signals Codex approval

## Shell and Parsing Rules

Use `gh --jq` only for inline value extraction. No ad-hoc standalone `jq`, `python3`, `python`, `node`, or PowerShell. No `/tmp/` for data processing. If `gh --jq` cannot produce the required value, return `blocked`.

Sanctioned exception — canonical fix-history classification: the github-reviewer agent captures the raw `gh api graphql` JSON (threads/comments/reviews/top-level, with the contract fields `isResolved`, `comments.totalCount`, comment `databaseId`, `author.login`, `body`, top-level/review `url`, review `state`) and pipes it through the shared filter FILE `${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/fix-history-classify.jq` via `jq -f`. This is a pure offline function over already-fetched JSON and is the single source of truth for the skip/order/overflow predicate; it is NOT the ad-hoc inline `jq` munging this rule prohibits.

## Pagination Requirement

Page all connections via `-F after="CURSOR"` using `endCursor` from `pageInfo`. Omit `-F after` on first page. Nested connections (e.g., thread comments) require per-item queries with the item's `id`. This requirement governs the reviewer's deep body-level fetch (reviews, review threads, thread comments, top-level comments) and the Codex approval reactions lookup — NOT the `github-review-loop` thin poll, which is deliberately coarse (scalar `totalCount`s only, no connection walking) per plan D5; citing this section to justify adding cursor walks to the poll is out of scope.

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
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              databaseId
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

### Unresolved summary output

```
--jq '.data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | . as $thread
      | $thread.comments.nodes[]
      | select(.body != null and (.body | gsub("[[:space:]]+"; "") != ""))
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
          databaseId
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
        | select(.body != null and (.body | gsub("[[:space:]]+"; "") != ""))
        | select(.author.login != $ENV.SELF_LOGIN)
        | "COMMENT=\(.id) AUTHOR=\(.author.login) URL=\(.url)"'
# SELF_LOGIN is resolved at runtime via: gh api user --jq .login
```

## Detection Filtering

All queries must apply both filters before yielding results as actionable feedback. Silently skip items that fail either filter.

1. **Exclude empty body:** `select(.body != null and (.body | gsub("[[:space:]]+"; "") != ""))`
2. **Exclude self-authored:** `select(.author.login != $ENV.SELF_LOGIN)` — resolve once per poll: `export SELF_LOGIN=$(gh api user --jq .login)`

The Fetch Review Threads (unresolved summary output) and Fetch Top-Level PR Comments templates apply both filters inline. The Fetch Reviews and Fetch Thread Comments (Paginated) templates return raw nodes — consuming agents must apply both filters to their results before yielding as actionable feedback. For Fetch Reviews, also filter to `state` values `CHANGES_REQUESTED` or `COMMENTED`.

An `APPROVED` review state is NOT how Codex signals approval — Codex never files an `APPROVED` review. Codex approval is a 👍 reaction on the PR object (see [Codex Approval Detection](#codex-approval-detection)).

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

When `reviewer_filter` is `codex-only`, include only comments from the Codex reviewer identity. The Codex reviewer's canonical login base is `chatgpt-codex-connector`. Inside `reactions` nodes the login carries a `[bot]` suffix (`chatgpt-codex-connector[bot]`); match by stripping a trailing `[bot]` and comparing equal to `chatgpt-codex-connector`. If identity is unclear, ask the user before processing.

## Codex Approval Detection

Codex signals approval via a 👍 reaction on the PR object (not an `APPROVED` review). Detect it with the paginated REST reactions endpoint so the bot's reaction is found even when a PR has more than one page of reactions:

```bash
gh api --paginate "repos/OWNER/REPO/issues/PR_NUMBER/reactions" \
  --jq '.[] | select(.content == "+1") | ((.user.login // "") | sub("\\[bot\\]$"; "")) | select(. == "chatgpt-codex-connector")'
```

REST content `+1` is the 👍 reaction. A reactor matches Codex when its login, with a trailing `[bot]` stripped, equals `chatgpt-codex-connector`. Codex approval is terminal for the github-reviewer ONLY when no unresolved non-self actionable items remain. The 👀 `eyes` reaction (REST content `eyes`) means "still running" — never treat it as approval (the `+1` filter already excludes it).
