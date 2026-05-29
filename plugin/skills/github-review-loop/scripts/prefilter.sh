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
#     `Fixed in <SHA>.` marker. Otherwise emits `PREFILTER_DISPATCH`.
#   - Fail-open on GraphQL error: emits `PREFILTER_ERROR=<reason>` and exits
#     non-zero so the skill treats the event as DISPATCH. Better to wake the
#     reviewer for an extra cycle than to silently swallow real feedback.
#   - No /tmp. No stop-file. No pagination loop. Stderr diagnostics go to
#     /dev/null.
#
# Accepted trade-offs:
#   - `reviewThreads(first: 50)` is bounded. A PR with more than 50 review
#     threads where the actionable thread sits past page 1 may emit
#     `PREFILTER_SKIP` for this cycle. It surfaces on the NEXT CHANGED event
#     — caught late, never missed forever. This mirrors the poll script's
#     coarse-scalar trade-off posture.
#   - Body-marker detection uses regex `Fixed in [0-9a-f]{7,40}\.` (required
#     trailing period per `plugin/agents/github-reviewer.md` step 11 reply
#     format: `Fixed in <SHA>. <one-line summary>.`). Loose prose mentioning
#     "Fixed in" without a hex SHA + trailing period is rejected.
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

# Single non-paginated GraphQL call: last comment per unresolved review thread,
# bounded to the first 50 threads. The --jq filter walks each thread and emits
# ONE token per matching unresolved thread:
#   ACTIONABLE  latest comment matches REVIEWER_FILTER AND body lacks a
#               `Fixed in <SHA>.` marker
#   HANDLED     latest comment matches REVIEWER_FILTER AND body carries the
#               marker
# Threads where the latest comment is self-authored are skipped (own replies
# are not actionable). Resolved threads are skipped entirely.
result=$(gh api graphql \
  -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
  --arg login "$SELF_LOGIN" --arg filter "$REVIEWER_FILTER" \
  -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 50) {
        nodes {
          isResolved
          comments(last: 1) {
            nodes {
              author { login }
              body
            }
          }
        }
      }
    }
  }
}' --jq '
    .data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false)
    | .comments.nodes[-1]
    | select(. != null)
    | . as $c
    | (($c.author.login // "") | sub("\\[bot\\]$"; "")) as $a
    | select($a != $login)
    | select(
        if $filter == "codex-only" then $a == "chatgpt-codex-connector"
        elif $filter == "all" then $a != $login
        else $a == $filter
        end)
    | if (($c.body // "") | test("Fixed in [0-9a-f]{7,40}\\."))
      then "HANDLED"
      else "ACTIONABLE"
      end
  ' 2>/dev/null) || prefilter_fail "graphql-failed"

# Bash-side decision. ACTIONABLE anywhere wins (dispatch); only HANDLED lines
# or empty output means every unresolved actionable thread already carries a
# `Fixed in <SHA>.` reply — silently update baseline.
case "$result" in
  *ACTIONABLE*) echo "PREFILTER_DISPATCH" ;;
  *)            echo "PREFILTER_SKIP" ;;
esac
exit 0
