#!/usr/bin/env bash
#
# Thin CHANGED-event prefilter for the github-review-loop skill.
#
# The skill arms this on every CHANGED Monitor event before dispatching the
# reviewer. It runs ONE cheap GraphQL call and emits a single labeled stdout
# result that tells the skill whether to dispatch the reviewer
# (`PREFILTER_DISPATCH`) or silently keep the Monitor armed and update the
# baseline (`PREFILTER_SKIP`). Its purpose is to suppress self-echo CHANGED
# storms that survive the thin-poll's scalar-token diff — specifically the case
# where the latest non-self thread comment already carries a self-authored
# `Fixed in <SHA>.` reply but no thread resolution has been recorded yet.
#
# Contract:
#   - Cheap single-query check. Reads the captured GraphQL string directly via
#     command substitution — no functional pipe feeding any consumer.
#   - Emits `PREFILTER_SKIP` only when zero unresolved review threads carry a
#     latest non-self comment that matches `REVIEWER_FILTER` AND lacks a
#     `Fixed in <SHA>.` marker AND the `reviewThreads.totalCount` tripwire is
#     ≤ 50. Otherwise emits `PREFILTER_DISPATCH`.
#   - Fail-open on GraphQL error: emits `PREFILTER_ERROR=<reason>` and exits
#     non-zero so the skill treats the event as DISPATCH. Better to wake the
#     reviewer for an extra cycle than to silently swallow real feedback.
#   - Fail-open on >50-node overflow in any of `reviewThreads`, `comments`, or
#     `reviews`. The bound is reached when any connection's `totalCount`
#     exceeds 50 nodes; the prefilter cannot reliably author-classify activity
#     past page 1, so it dispatches the reviewer rather than risk a silent
#     drop.
#   - No /tmp. No stop-file. No pagination loop. Stderr diagnostics go to
#     /dev/null.
#
# Accepted trade-offs:
#   - The 50-node bound is enforced symmetrically across all three pullRequest
#     connections the loop cares about: `reviewThreads`, `comments`, and
#     `reviews`. When ANY of their totalCounts exceeds 50, prefilter FAILS
#     OPEN to `PREFILTER_DISPATCH` rather than risk skipping a real finding
#     that sits outside the inspected page. This is a deliberately
#     filter-blind decision: the prefilter cannot author-classify activity
#     past page 1, so it dispatches and lets the reviewer adjudicate. Mirrors
#     the poll-side `THREADS_TOTAL` / `COMMENTS_TOTAL` / `REVIEWS_TOTAL`
#     scalars in `pr-change-detect-poll.sh`'s accepted-trade-off block and
#     the same "wake unnecessarily > miss feedback" posture. Cost under
#     `codex-only`: a >50 issue-comment burst from humans will wake the
#     reviewer once and return clean — acceptable vs silent drop.
#   - Body-marker detection uses regex `Fixed in [0-9a-f]{7,40}\.` (required
#     trailing period per `plugin/agents/github-reviewer.md` step 11 reply
#     format: `Fixed in <SHA>. <one-line summary>.`). Loose prose mentioning
#     "Fixed in" without a hex SHA + trailing period is rejected.
#   - Each unresolved review thread is inspected with `comments(last: 20)`,
#     not `comments(last: 1)`. The full set of non-self matching comments in
#     each thread is walked: a thread is `ACTIONABLE` if ANY non-self comment
#     matching `REVIEWER_FILTER` lacks a `Fixed in <SHA>.` marker. This
#     prevents an unresolved reviewer finding from being hidden when a later
#     reply from a non-matching author (maintainer, different bot) sits as
#     the latest comment under `codex-only`. The thread also tracks the
#     latest self-authored `Fixed in <SHA>.` reply by `databaseId` (monotonic
#     per-comment, matches the poll's id-token discipline). The reviewer
#     posts that reply after committing a fix and BEFORE attempting to
#     resolve the thread; the resolve mutation is non-blocking and may fail.
#     A non-self matching comment is treated as HANDLED only when its
#     `databaseId` is LESS THAN OR EQUAL to that latest self fix-reply id;
#     otherwise it is ACTIONABLE. This covers two cases together:
#       (a) crash-recovery: the reviewer posted its fix-SHA reply but the
#           resolve mutation failed → the original Codex finding's
#           databaseId is below the self reply's databaseId → HANDLED, the
#           original finding is NOT re-dispatched on its own fix.
#       (b) follow-up finding: a later Codex (or matching-author) comment
#           lands in the SAME unresolved thread → its databaseId is above
#           the latest self fix-reply → ACTIONABLE, the reviewer is
#           dispatched. Without the per-comment ordering, any self fix-reply
#           would short-circuit the whole thread to HANDLED and the new
#           finding would be silently swallowed.
#   - If a thread carries more than 20 comments, the per-thread overflow
#     ALWAYS falls back to DISPATCH (filter-blind — same posture as the
#     connection-level 50-node bounds). An older unresolved reviewer finding
#     can sit outside the last 20 replies; failing open only when matching
#     comments are already visible would let the original finding go
#     undispatched while the poll wakes on later thread activity.
#   - Top-level PR comments and review-body summaries are also inspected.
#     `github-reviewer` treats those as fix candidates (see
#     `plugin/agents/github-reviewer.md` step 3) but they live outside review
#     threads, so the per-thread fix-SHA skip rule does not apply to them.
#     The prefilter follows the "fail open" half of Codex P1 — if ANY
#     non-self matching top-level comment or review-body summary exists,
#     emit `PREFILTER_DISPATCH`. The poll's own author-aware id-token dedup
#     (`LATEST_NONSELF_ISSUE_COMMENT_ID`, `LATEST_FILTERED_REVIEW_ID`)
#     bounds the cost — a static unhandled top-level finding fires at most
#     once per its appearance, not repeatedly.
#
# Markers emitted (one labeled line):
#   PREFILTER_SKIP            silently update baseline; do NOT dispatch
#   PREFILTER_DISPATCH        at least one actionable unresolved thread exists
#   PREFILTER_ERROR=<reason>  GraphQL or input failure; skill treats as
#                             DISPATCH (fail-open)
#
# Positional arguments supplied by the skill at invocation:
#   $1  OWNER             base-repo owner
#   $2  REPO              base-repo name
#   $3  PR_NUMBER         integer PR number
#   $4  REVIEWER_FILTER   "codex-only" | "all" | "<login>"
#                         (default "codex-only" when empty)
#   $5  SELF_LOGIN        viewer login used to strip self-authored latest
#                         comments from the actionable set (required)

set -u

OWNER="${1:-}"
REPO="${2:-}"
PR_NUMBER="${3:-}"
REVIEWER_FILTER="${4:-}"
SELF_LOGIN="${5:-}"

# Validate inputs before binding the GraphQL query. Empty OWNER/REPO/SELF_LOGIN
# or a non-integer PR_NUMBER would corrupt the Int binding or defeat the
# self-strip logic. Mirrors the validation posture of pr-change-detect-poll.sh.
prefilter_fail() {
  echo "PREFILTER_ERROR=$1"
  exit 1
}
[ -n "$OWNER" ] || prefilter_fail "missing-owner"
[ -n "$REPO" ] || prefilter_fail "missing-repo"
case "$PR_NUMBER" in ''|*[!0-9]*) prefilter_fail "invalid-pr-number" ;; esac
# REVIEWER_FILTER defaults to codex-only when empty; any non-empty string is
# accepted as a login form (codex-only | all | <login>).
[ -n "$REVIEWER_FILTER" ] || REVIEWER_FILTER="codex-only"
# SELF_LOGIN is required: without it the jq filter cannot strip self-authored
# latest comments, and the self-echo storm this prefilter exists to suppress
# would re-emerge.
[ -n "$SELF_LOGIN" ] || prefilter_fail "missing-self-login"

# Single non-paginated GraphQL call: each unresolved review thread's last 20
# comments (per-thread; threads with >20 comments overflow to DISPATCH), bounded
# to the first 50 threads; plus the last 50 top-level PR comments and last 50
# review summaries so the prefilter can detect non-self matching feedback
# outside review threads. The --jq filter emits tokens for the bash-side
# decision:
#   ACTIONABLE          any non-self matching thread comment lacks a
#                       `Fixed in <SHA>.` marker
#   HANDLED             every non-self matching thread comment carries the
#                       marker
#   ACTIONABLE_TOPLEVEL any non-self matching top-level PR comment exists
#   ACTIONABLE_REVIEW   any non-self matching review summary body exists
# All non-self comments in each thread are walked, not just the latest, so a
# later non-matching author reply cannot hide an unresolved matching finding.
# The thread-level fix-SHA skip cannot be transferred to top-level / review-
# body items (those use `Addresses: <url>` in a SEPARATE self-authored comment,
# not an in-place reply), so the prefilter fails open on any non-self matching
# top-level or review-body activity and lets the reviewer adjudicate. The poll
# de-duplicates the wake by author-aware id token so a static unhandled
# top-level finding does not fire repeatedly.
result=$( ( set -o pipefail; \
  gh api graphql \
    -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
    -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      comments(last: 50) {
        totalCount
        nodes { author { login } body }
      }
      reviews(last: 50) {
        totalCount
        nodes { author { login } body state }
      }
      reviewThreads(first: 50) {
        totalCount
        nodes {
          isResolved
          comments(last: 20) {
            totalCount
            nodes {
              databaseId
              author { login }
              body
            }
          }
        }
      }
    }
  }
}' 2>/dev/null \
  | jq -r --arg login "$SELF_LOGIN" --arg filter "$REVIEWER_FILTER" '
    # Reusable identity-match predicate for the active REVIEWER_FILTER. The
    # caller passes the stripped login; this returns true when that login is
    # non-self AND matches the filter.
    def matches_filter($a):
      $a != $login
      and (
        if $filter == "codex-only" then $a == "chatgpt-codex-connector"
        elif $filter == "all" then true
        else $a == $filter
        end
      );

    .data.repository.pullRequest as $pr |
    $pr.reviewThreads as $rt |
    "THREADS_TOTAL=" + (($rt.totalCount // 0) | tostring),
    "COMMENTS_TOTAL=" + (($pr.comments.totalCount // 0) | tostring),
    "REVIEWS_TOTAL=" + (($pr.reviews.totalCount // 0) | tostring),

    # Per-thread inspection: walk ALL non-self matching comments. A thread is
    # ACTIONABLE if ANY matching comment lacks a `Fixed in <SHA>.` marker OR
    # post-dates the latest self fix-reply.
    #
    # The thread tracks the latest self-authored `Fixed in <SHA>.` reply by
    # `databaseId` (monotonic per-comment, matches the id-token discipline
    # used by the poll script). The reviewer posts that reply after
    # committing a fix and BEFORE attempting to resolve the thread; the
    # resolve mutation is non-blocking and may fail. A non-self matching
    # comment is HANDLED only when its body already carries the marker OR
    # when its databaseId is LESS THAN OR EQUAL to the latest self fix-reply
    # databaseId. Otherwise it is ACTIONABLE. This handles both:
    #   (a) crash-recovery: the existing reviewer comment databaseId is
    #       below the self reply databaseId → HANDLED, not re-dispatched.
    #   (b) follow-up finding in the same unresolved thread: the new
    #       reviewer comment databaseId is above the latest self fix-reply
    #       → ACTIONABLE, the reviewer wakes. The previous `$self_fixed`
    #       short-circuit would have hidden this; the per-comment ordering
    #       guarantees it surfaces.
    # If no self fix-reply exists in the page, the latest-id sentinel is 0
    # (every non-self matching databaseId is > 0), so ordering reduces to
    # the marker check alone.
    #
    # When a thread carries more than 20 comments, the per-thread page may
    # have dropped earlier matching comments; fail open with ACTIONABLE
    # UNCONDITIONALLY. An older unresolved reviewer finding sitting outside
    # the last 20 replies would otherwise yield an empty marks set and emit
    # nothing, letting the poll silently `PREFILTER_SKIP` after the wake.
    ($rt.nodes[]
      | select(.isResolved == false)
      | . as $thread
      | (($thread.comments.totalCount // 0) > ($thread.comments.nodes | length)) as $thread_overflow
      | ([
          $thread.comments.nodes[]
          | . as $c
          | (($c.author.login // "") | sub("\\[bot\\]$"; "")) as $a
          | select($a == $login)
          | select((($c.body // "") | test("Fixed in [0-9a-f]{7,40}\\.")))
          | (.databaseId // 0)
        ] | (if length == 0 then 0 else max end)) as $latest_self_fix_id
      | ([
          $thread.comments.nodes[]
          | . as $c
          | (($c.author.login // "") | sub("\\[bot\\]$"; "")) as $a
          | select(matches_filter($a))
          | (($c.body // "") | test("Fixed in [0-9a-f]{7,40}\\."))
            or ((.databaseId // 0) <= $latest_self_fix_id)
        ]) as $marks
      | if $thread_overflow then "ACTIONABLE"
        elif ($marks | length) == 0 then empty
        elif ($marks | any(. == false)) then "ACTIONABLE"
        else "HANDLED"
        end),

    # Top-level PR comments: any non-self matching body fails open to
    # ACTIONABLE_TOPLEVEL. Thread-style in-place dedup does not apply; the
    # reviewer posts a separate `Addresses: <url>` comment for top-level work.
    ($pr.comments.nodes[]?
      | . as $c
      | (($c.author.login // "") | sub("\\[bot\\]$"; "")) as $a
      | select(matches_filter($a))
      | select((($c.body // "") | gsub("[[:space:]]+"; "")) != "")
      | "ACTIONABLE_TOPLEVEL"),

    # Review summaries (CHANGES_REQUESTED / COMMENTED with body): any non-self
    # matching body fails open to ACTIONABLE_REVIEW. APPROVED / DISMISSED are
    # not actionable feedback for the reviewer.
    ($pr.reviews.nodes[]?
      | . as $r
      | (($r.author.login // "") | sub("\\[bot\\]$"; "")) as $a
      | select(matches_filter($a))
      | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED")
      | select((($r.body // "") | gsub("[[:space:]]+"; "")) != "")
      | "ACTIONABLE_REVIEW")
  ' \
) ) || prefilter_fail "graphql-failed"

# Parse the three totalCount tripwires out of the captured output. Mirrors the
# label-prefixed parse pattern used by pr-change-detect-poll.sh. Defaults each
# to 0 when the line is absent so a malformed payload behaves like a 0-node
# page on every connection.
threads_total=0
comments_total=0
reviews_total=0
while IFS= read -r line; do
  case "$line" in
    THREADS_TOTAL=*) threads_total="${line#THREADS_TOTAL=}" ;;
    COMMENTS_TOTAL=*) comments_total="${line#COMMENTS_TOTAL=}" ;;
    REVIEWS_TOTAL=*) reviews_total="${line#REVIEWS_TOTAL=}" ;;
  esac
done <<EOF
$result
EOF
case "$threads_total" in ''|*[!0-9]*) threads_total=0 ;; esac
case "$comments_total" in ''|*[!0-9]*) comments_total=0 ;; esac
case "$reviews_total" in ''|*[!0-9]*) reviews_total=0 ;; esac

# Bash-side decision. ACTIONABLE / ACTIONABLE_TOPLEVEL / ACTIONABLE_REVIEW
# anywhere wins (dispatch). Otherwise, when ANY of the three pullRequest
# connections (`reviewThreads`, `comments`, `reviews`) holds more than 50 nodes,
# the in-page inspection is untrustworthy on at least one axis — fail OPEN to
# DISPATCH rather than risk skipping a real finding outside the page. Only
# HANDLED lines (or empty output) with all three totalCounts bounded means
# every unresolved actionable thread already carries a `Fixed in <SHA>.` reply
# and no non-self top-level / review activity is present and no oversized
# connection could be hiding new feedback — silently update baseline.
case "$result" in
  *ACTIONABLE_TOPLEVEL*|*ACTIONABLE_REVIEW*|*ACTIONABLE*)
    echo "PREFILTER_DISPATCH"
    ;;
  *)
    if [ "$threads_total" -gt 50 ] || [ "$comments_total" -gt 50 ] || [ "$reviews_total" -gt 50 ]; then
      echo "PREFILTER_DISPATCH"
    else
      echo "PREFILTER_SKIP"
    fi
    ;;
esac
exit 0
