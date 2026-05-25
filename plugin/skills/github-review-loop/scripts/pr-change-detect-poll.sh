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
#     classes (no bodies): PR state; comment+review+unresolved-thread COUNTS;
#     check ROLLUP status; Codex 👍 PRESENT bool.
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
# Placeholders substituted by the skill before arming:
#   OWNER, REPO, PR_NUMBER, MAX_WATCH_DEFAULT (seconds), POLL_INTERVAL_DEFAULT (seconds)

set -u

OWNER="OWNER"
REPO="REPO"
PR_NUMBER=PR_NUMBER
MAX_WATCH_SECONDS=MAX_WATCH_DEFAULT      # substitute integer seconds (default: 3600)
POLL_INTERVAL_SECONDS=POLL_INTERVAL_DEFAULT  # substitute integer seconds (default: 60)

deadline=$(($(date +%s) + MAX_WATCH_SECONDS))
fail_count=0

# Previous-snapshot scalars. Empty until the first successful poll establishes
# the baseline; the baseline poll itself emits no CHANGED marker.
prev_state=""
prev_unresolved=""
prev_comments=""
prev_reviews=""
prev_rollup=""
prev_codex=""
have_baseline=0

# compute_snapshot: fills the global scalar variables from a single GraphQL
# query plus a checks rollup read. Returns 0 on success, non-zero on failure.
# Writes diagnostic stderr to /dev/null (never /tmp).
compute_snapshot() {
  local raw
  raw=$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      state
      comments { totalCount }
      reviews { totalCount }
      reviewThreads(first: 100) {
        nodes { isResolved }
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup { state }
          }
        }
      }
      reactions(content: THUMBS_UP, first: 100) {
        nodes { user { login } }
      }
    }
  }
}' --jq '
    .data.repository.pullRequest as $pr |
    "STATE=" + $pr.state,
    "UNRESOLVED=" + (([$pr.reviewThreads.nodes[] | select(.isResolved == false)] | length) | tostring),
    "COMMENTS=" + ($pr.comments.totalCount | tostring),
    "REVIEWS=" + ($pr.reviews.totalCount | tostring),
    "ROLLUP=" + (($pr.commits.nodes[0].commit.statusCheckRollup.state) // "NONE"),
    "CODEX=" + (([$pr.reactions.nodes[] | (.user.login // "") | sub("\\[bot\\]$"; "") | select(. == "chatgpt-codex-connector")] | length > 0) | tostring)
  ' 2>/dev/null) || return 1

  # Parse the labeled scalar lines into globals. Read stdout directly — no pipe
  # into Monitor; this is internal parsing of a captured string.
  local line
  while IFS= read -r line; do
    case "$line" in
      STATE=*) cur_state="${line#STATE=}" ;;
      UNRESOLVED=*) cur_unresolved="${line#UNRESOLVED=}" ;;
      COMMENTS=*) cur_comments="${line#COMMENTS=}" ;;
      REVIEWS=*) cur_reviews="${line#REVIEWS=}" ;;
      ROLLUP=*) cur_rollup="${line#ROLLUP=}" ;;
      CODEX=*) cur_codex="${line#CODEX=}" ;;
    esac
  done <<EOF
$raw
EOF

  # A well-formed snapshot always carries a non-empty PR state.
  [ -n "${cur_state:-}" ] || return 1
  return 0
}

while true; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "WATCH_TIMEOUT"
    exit 0
  fi

  cur_state=""; cur_unresolved=""; cur_comments=""
  cur_reviews=""; cur_rollup=""; cur_codex=""

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
      || [ "$cur_unresolved" != "$prev_unresolved" ] \
      || [ "$cur_comments" != "$prev_comments" ] \
      || [ "$cur_reviews" != "$prev_reviews" ] \
      || [ "$cur_rollup" != "$prev_rollup" ]; then
      echo "CHANGED"
    fi
    # No-change iteration: emit nothing.
  fi

  prev_state="$cur_state"
  prev_unresolved="$cur_unresolved"
  prev_comments="$cur_comments"
  prev_reviews="$cur_reviews"
  prev_rollup="$cur_rollup"
  prev_codex="$cur_codex"

  sleep "$POLL_INTERVAL_SECONDS"
done
