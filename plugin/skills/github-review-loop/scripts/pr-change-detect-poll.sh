#!/usr/bin/env bash
#
# Thin PR change-detection poll for the github-review-loop skill.
#
# Predefined, exact statement: the skill arms this in the MAIN-SESSION Monitor
# every run and never reconstructs it. It runs as a BACKGROUND Monitor command,
# so the `while` loop + `sleep` between iterations is legal (foreground sleep is
# harness-blocked; this is not foreground).
#
# Contract:
#   - Each iteration computes a CHEAP SCALAR snapshot covering all four event
#     classes (no bodies): PR state; comment+review COUNTS plus reviewThreads
#     totalCount (uncapped) AND a paginated unresolved-thread count (isResolved
#     booleans only, no bodies); check ROLLUP status; Codex 👍 PRESENT bool (via
#     paginated REST reactions).
#   - It DIFFS the snapshot in bash against the previous iteration and emits a
#     single minimal marker line ONLY on a real delta or a terminal state.
#   - A no-change iteration emits NOTHING (silent) → Monitor feeds nothing back
#     → the model is never woken → zero model tokens during idle.
#   - It reads each gh command's stdout directly via command substitution. There
#     is NO functional pipe (`tail -f | grep`, etc.) feeding Monitor.
#   - No /tmp. No stop-file. Monitor is stopped natively by the skill.
#
# Markers emitted (one token-cheap line each):
#   CHANGED          a non-terminal delta in the scalar snapshot (wake reviewer)
#   STATE=MERGED     PR merged (terminal)
#   STATE=CLOSED     PR closed unmerged (terminal)
#   CODEX_APPROVED   Codex 👍 newly present (skill confirms via reviewer)
#   WATCH_TIMEOUT    max_watch_duration elapsed (terminal)
#   POLL_ERROR       repeated query failure (terminal; skill returns blocked)
#
# Positional arguments supplied by the skill when arming Monitor (all required;
# the skill/overlord layer resolves defaults and passes concrete values):
#   $1  OWNER                   base-repo owner
#   $2  REPO                    base-repo name
#   $3  PR_NUMBER               integer PR number
#   $4  MAX_WATCH_SECONDS       integer seconds before WATCH_TIMEOUT
#   $5  POLL_INTERVAL_SECONDS   integer seconds between polls

set -u

OWNER="${1:-}"
REPO="${2:-}"
PR_NUMBER="${3:-}"
MAX_WATCH_SECONDS="${4:-}"
POLL_INTERVAL_SECONDS="${5:-}"

# Validate inputs before any arithmetic or gh binding. Empty OWNER/REPO or a
# non-integer numeric arg would otherwise abort under set -u or corrupt the
# GraphQL Int binding / the $(( )) deadline math.
poll_fail() {
  echo "POLL_ERROR"
  exit 1
}
[ -n "$OWNER" ] || poll_fail
[ -n "$REPO" ] || poll_fail
case "$PR_NUMBER" in ''|*[!0-9]*) poll_fail ;; esac
case "$MAX_WATCH_SECONDS" in ''|*[!0-9]*) poll_fail ;; esac
case "$POLL_INTERVAL_SECONDS" in ''|*[!0-9]*) poll_fail ;; esac

deadline=$(($(date +%s) + MAX_WATCH_SECONDS))
fail_count=0

# Previous-snapshot scalars. Empty until the first successful poll establishes
# the baseline; the baseline poll itself emits no CHANGED marker.
prev_state=""
prev_threads=""
prev_comments=""
prev_reviews=""
prev_rollup=""
prev_codex=""
prev_unresolved=""
have_baseline=0

# compute_snapshot: fills the global scalar variables from a paginated GraphQL
# query (state + comment/review/reviewThreads totalCount + reviewThreads
# isResolved booleans + checks rollup) plus a paginated REST reactions read for
# the Codex 👍 bool. Returns 0 on success, non-zero on failure of ANY page or
# the reactions call. reviewThreads is tracked two ways: totalCount detects any
# new/changed thread (incl. a newly-added already-resolved one), and a paginated
# unresolved count (isResolved==false across ALL pages, booleans only — no
# bodies) detects resolution toggles incl. re-opened threads. Either delta fires
# CHANGED; the reviewer still does the full body-level classification on wake
# (thin poll, no interpretation). Writes diagnostic stderr to /dev/null (never /tmp).
compute_snapshot() {
  local unresolved_count=0
  local cursor=""
  local has_next="true"
  local raw line

  # Walk EVERY reviewThreads page. The cursor lives in the same query that
  # returns state/counts/rollup, so page 0 (no `after`) carries those scalars
  # and each page contributes isResolved BOOLEANS ONLY (no bodies — preserves
  # the thin-poll no-bodies invariant). totalCount is page-invariant, so it is
  # read from page 0 only; later pages must not clobber the page-0 scalars.
  while [ "$has_next" = "true" ]; do
    if [ -z "$cursor" ]; then
      raw=$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -f query='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      state
      comments { totalCount }
      reviews { totalCount }
      reviewThreads(first: 100, after: $after) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { isResolved }
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup { state }
          }
        }
      }
    }
  }
}' --jq '
    .data.repository.pullRequest as $pr |
    "STATE=" + $pr.state,
    "THREADS=" + ($pr.reviewThreads.totalCount | tostring),
    "COMMENTS=" + ($pr.comments.totalCount | tostring),
    "REVIEWS=" + ($pr.reviews.totalCount | tostring),
    "ROLLUP=" + (($pr.commits.nodes[0].commit.statusCheckRollup.state) // "NONE"),
    "HASNEXT=" + ($pr.reviewThreads.pageInfo.hasNextPage | tostring),
    "CURSOR=" + ($pr.reviewThreads.pageInfo.endCursor // ""),
    ($pr.reviewThreads.nodes[] | select(.isResolved == false) | "UNRESOLVED")
  ' 2>/dev/null) || return 1
    else
      raw=$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -f after="$cursor" -f query='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { isResolved }
      }
    }
  }
}' --jq '
    .data.repository.pullRequest.reviewThreads as $rt |
    "HASNEXT=" + ($rt.pageInfo.hasNextPage | tostring),
    "CURSOR=" + ($rt.pageInfo.endCursor // ""),
    ($rt.nodes[] | select(.isResolved == false) | "UNRESOLVED")
  ' 2>/dev/null) || return 1
    fi

    # Reset per-page pagination signals; an empty endCursor leaves cursor empty.
    has_next="false"
    cursor=""

    # Parse the labeled lines. Page-0 scalar lines (STATE/THREADS/COMMENTS/
    # REVIEWS/ROLLUP) appear only on page 0; HASNEXT/CURSOR appear every page;
    # one UNRESOLVED line per unresolved node on the current page. Read the
    # captured string directly — no pipe into Monitor.
    while IFS= read -r line; do
      case "$line" in
        STATE=*) cur_state="${line#STATE=}" ;;
        THREADS=*) cur_threads="${line#THREADS=}" ;;
        COMMENTS=*) cur_comments="${line#COMMENTS=}" ;;
        REVIEWS=*) cur_reviews="${line#REVIEWS=}" ;;
        ROLLUP=*) cur_rollup="${line#ROLLUP=}" ;;
        HASNEXT=*) has_next="${line#HASNEXT=}" ;;
        CURSOR=*) cursor="${line#CURSOR=}" ;;
        UNRESOLVED) unresolved_count=$((unresolved_count + 1)) ;;
      esac
    done <<EOF
$raw
EOF
  done
  cur_unresolved="$unresolved_count"

  # Codex 👍 via the paginated REST reactions endpoint. The --jq filter emits the
  # matching login ONCE per Codex +1 reaction and nothing otherwise; gh may apply
  # --jq per page, so aggregate to a bool in bash (non-empty output = present).
  # This avoids a 100-node GraphQL blind spot and the per-page slurp pitfall.
  local codex_logins
  codex_logins=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/reactions" \
    --jq '.[] | select(.content == "+1") | ((.user.login // "") | sub("\\[bot\\]$"; "")) | select(. == "chatgpt-codex-connector")' \
    2>/dev/null) || return 1
  if [ -n "$codex_logins" ]; then
    cur_codex="true"
  else
    cur_codex="false"
  fi

  # A well-formed snapshot always carries a non-empty PR state.
  [ -n "${cur_state:-}" ] || return 1
  return 0
}

while true; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "WATCH_TIMEOUT"
    exit 0
  fi

  cur_state=""; cur_threads=""; cur_comments=""
  cur_reviews=""; cur_rollup=""; cur_codex=""; cur_unresolved=""

  if ! compute_snapshot; then
    fail_count=$((fail_count + 1))
    if [ "$fail_count" -ge 2 ]; then
      echo "POLL_ERROR"
      exit 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi
  fail_count=0

  # Terminal PR state takes precedence over any other delta.
  if [ "$cur_state" = "MERGED" ]; then
    echo "STATE=MERGED"
    exit 0
  fi
  if [ "$cur_state" = "CLOSED" ]; then
    echo "STATE=CLOSED"
    exit 0
  fi

  if [ "$have_baseline" -eq 0 ]; then
    # First successful poll establishes the baseline; emit nothing.
    have_baseline=1
  else
    # Codex 👍 newly present is its own marker (the skill runs a confirmation
    # pass rather than treating it as a generic CHANGED delta).
    if [ "$cur_codex" = "true" ] && [ "$prev_codex" != "true" ]; then
      echo "CODEX_APPROVED"
    elif [ "$cur_state" != "$prev_state" ] \
      || [ "$cur_threads" != "$prev_threads" ] \
      || [ "$cur_comments" != "$prev_comments" ] \
      || [ "$cur_reviews" != "$prev_reviews" ] \
      || [ "$cur_rollup" != "$prev_rollup" ] \
      || [ "$cur_unresolved" != "$prev_unresolved" ]; then
      echo "CHANGED"
    fi
    # No-change iteration: emit nothing.
  fi

  prev_state="$cur_state"
  prev_threads="$cur_threads"
  prev_comments="$cur_comments"
  prev_reviews="$cur_reviews"
  prev_rollup="$cur_rollup"
  prev_codex="$cur_codex"
  prev_unresolved="$cur_unresolved"

  sleep "$POLL_INTERVAL_SECONDS"
done
