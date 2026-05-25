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
#   - Each iteration computes a CHEAP SCALAR snapshot via ONE non-paginated
#     GraphQL query (PR state; comment + review + reviewThreads totalCounts;
#     check rollup state; check-context totalCount) plus a Codex 👍 PRESENT bool
#     (via paginated REST reactions). No bodies, no nodes, no cursor walks — the
#     poll only answers "did anything change?" and "is the PR terminal?".
#   - It DIFFS the scalar snapshot in bash against the previous iteration and
#     emits a single minimal marker line ONLY on a real delta or a terminal
#     state. The reviewer re-fetches ALL feedback bodies and does the full
#     classification on wake; the poll never interprets.
#   - A no-change iteration emits NOTHING (silent) → Monitor feeds nothing back
#     → the model is never woken → zero model tokens during idle.
#   - It reads each gh command's stdout directly via command substitution. There
#     is NO functional pipe (`tail -f | grep`, etc.) feeding Monitor.
#   - No /tmp. No stop-file. Monitor is stopped natively by the skill.
#
# Accepted trade-off (coarse scalars, not fingerprints): a silent thread
# resolve→reopen with no new comment, or a check swapped for another at the same
# rollup state and same context count, does not bump a scalar and so does not fire
# on that exact poll. Such a cycle surfaces on the NEXT activity or the next
# reviewer wake — the reviewer re-fetches ALL state on every wake, and Codex
# reopens normally carry a new comment that bumps a scalar. The cost is "caught a
# cycle late," never "missed forever."
#
# Markers emitted (one token-cheap line each):
#   CHANGED          a non-terminal delta in the scalar snapshot (wake reviewer)
#   STATE=MERGED     PR merged (terminal)
#   STATE=CLOSED     PR closed unmerged (terminal)
#   CODEX_APPROVED   Codex 👍 newly present, OR already present at the baseline
#                    poll (skill confirms via reviewer; terminal clean only if
#                    nothing actionable remains)
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
# Base-10-coerce before any arithmetic / numeric comparison. The digit-only case
# guards above guarantee decimal digits, but bash reads a leading-zero value as
# octal in $(( )) and [ -ge ] — 08/09 error under set -u, 060 mis-scales to 48s.
MAX_WATCH_SECONDS=$((10#$MAX_WATCH_SECONDS))
POLL_INTERVAL_SECONDS=$((10#$POLL_INTERVAL_SECONDS))
# Reject a zero (or otherwise non-positive) poll interval: `sleep 0` would make
# the loop re-poll immediately and hammer gh api until timeout, risking rate
# limits. Require at least one second between polls before entering the loop.
[ "$POLL_INTERVAL_SECONDS" -ge 1 ] || poll_fail

deadline=$(($(date +%s) + MAX_WATCH_SECONDS))
fail_count=0

# Previous-snapshot scalars. Empty until the first successful poll establishes
# the baseline; the baseline poll itself emits no CHANGED marker.
prev_state=""
prev_comments=""
prev_reviews=""
prev_threads=""
prev_rollup=""
prev_checktotal=""
prev_codex=""
have_baseline=0

# compute_snapshot: fills the global scalar variables from ONE non-paginated
# GraphQL query (PR state + comment/review/reviewThreads totalCounts + check
# rollup state + check-context totalCount) plus a paginated REST reactions read
# for the Codex 👍 bool. Returns 0 on success, non-zero on failure of the query
# or the reactions call. Every count is a cheap totalCount — no nodes, no
# pageInfo, no isResolved, no per-context identity — so a new/changed thread or a
# new/dropped check bumps a count and fires CHANGED; the reviewer does the full
# body-level classification on wake (thin poll, no interpretation). A check-less
# PR has a null statusCheckRollup, which coerces to ROLLUP=NONE / CHECKTOTAL=0
# (not a failure). Writes diagnostic stderr to /dev/null (never /tmp).
compute_snapshot() {
  local raw line

  raw=$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      state
      comments { totalCount }
      reviews { totalCount }
      reviewThreads(first: 0) { totalCount }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 0) { totalCount }
            }
          }
        }
      }
    }
  }
}' --jq '
    .data.repository.pullRequest as $pr |
    ($pr.commits.nodes[0].commit.statusCheckRollup) as $rollup |
    "STATE=" + $pr.state,
    "COMMENTS=" + ($pr.comments.totalCount | tostring),
    "REVIEWS=" + ($pr.reviews.totalCount | tostring),
    "THREADS=" + ($pr.reviewThreads.totalCount | tostring),
    "ROLLUP=" + (($rollup.state) // "NONE"),
    "CHECKTOTAL=" + (($rollup.contexts.totalCount) // 0 | tostring)
  ' 2>/dev/null) || return 1

  # Parse the labeled scalar lines. Read the captured string directly — no pipe
  # into Monitor.
  while IFS= read -r line; do
    case "$line" in
      STATE=*) cur_state="${line#STATE=}" ;;
      COMMENTS=*) cur_comments="${line#COMMENTS=}" ;;
      REVIEWS=*) cur_reviews="${line#REVIEWS=}" ;;
      THREADS=*) cur_threads="${line#THREADS=}" ;;
      ROLLUP=*) cur_rollup="${line#ROLLUP=}" ;;
      CHECKTOTAL=*) cur_checktotal="${line#CHECKTOTAL=}" ;;
    esac
  done <<EOF
$raw
EOF

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

  cur_state=""; cur_comments=""; cur_reviews=""
  cur_threads=""; cur_rollup=""; cur_checktotal=""; cur_codex=""

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
    # First successful poll establishes the baseline; emit nothing for the
    # generic count/state scalars (they are the baseline, not a delta). EXCEPT a
    # pre-existing Codex 👍: if the PR already carries approval when monitoring
    # starts, the emit-on-change diff would never surface it (it is baseline
    # state, not a delta), so the loop could idle to WATCH_TIMEOUT instead of
    # terminating clean after a confirmation pass. Emit CODEX_APPROVED once at
    # baseline so the skill runs the same confirmation pass it would for a
    # newly-present 👍 (terminal clean ONLY if nothing actionable remains — D14).
    if [ "$cur_codex" = "true" ]; then
      echo "CODEX_APPROVED"
    fi
    have_baseline=1
  else
    # Codex 👍 newly present is its own marker (the skill runs a confirmation
    # pass rather than treating it as a generic CHANGED delta).
    if [ "$cur_codex" = "true" ] && [ "$prev_codex" != "true" ]; then
      echo "CODEX_APPROVED"
    elif [ "$cur_state" != "$prev_state" ] \
      || [ "$cur_comments" != "$prev_comments" ] \
      || [ "$cur_reviews" != "$prev_reviews" ] \
      || [ "$cur_threads" != "$prev_threads" ] \
      || [ "$cur_rollup" != "$prev_rollup" ] \
      || [ "$cur_checktotal" != "$prev_checktotal" ]; then
      echo "CHANGED"
    fi
    # No-change iteration: emit nothing.
  fi

  prev_state="$cur_state"
  prev_comments="$cur_comments"
  prev_reviews="$cur_reviews"
  prev_threads="$cur_threads"
  prev_rollup="$cur_rollup"
  prev_checktotal="$cur_checktotal"
  prev_codex="$cur_codex"

  sleep "$POLL_INTERVAL_SECONDS"
done
