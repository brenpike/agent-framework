# Monitor Command Template for github-reviewer agent
#
# This file is a reference template loaded via Read tool. It is NOT executed
# directly. The skill reads this file, substitutes all placeholders with
# resolved values, and passes the resulting script as the `command` parameter
# to the Monitor tool.
#
# Placeholders (substitute before passing to Monitor). All placeholders are
# bare-token replacements applied to the script body. The shell variable
# names MAX_WATCH_SECONDS and POLL_INTERVAL_SECONDS are NOT placeholders —
# they are referenced later in the script (e.g. $POLL_INTERVAL_SECONDS) and
# must remain literal. Only the RHS placeholder tokens below are substituted.
#
# Identifier placeholders:
#   OWNER       — repository owner login
#   REPO        — repository name
#   PR_NUMBER   — integer PR number
#
# Value placeholders (RHS of assignments only):
#   MAX_WATCH_DEFAULT       — resolved 'max watch duration' optional input
#                             (integer seconds; default if no override: 14400)
#   POLL_INTERVAL_DEFAULT   — resolved 'polling interval' optional input
#                             (integer seconds; default if no override: 60)
#
# The stop file path /tmp/af_watch_stop_OWNER_REPO_prPR_NUMBER is derived
# from the resolved OWNER, REPO, and PR_NUMBER values.

MAX_WATCH_SECONDS=MAX_WATCH_DEFAULT  # placeholder; substitute integer seconds (default: 14400)
POLL_INTERVAL_SECONDS=POLL_INTERVAL_DEFAULT  # placeholder; substitute integer seconds (default: 60)
deadline=$(($(date +%s) + MAX_WATCH_SECONDS))
fail_count=0
trap "rm -f /tmp/af_poll_err_$$ /tmp/af_watch_stop_OWNER_REPO_prPR_NUMBER" EXIT
while true; do
  if [ -f "/tmp/af_watch_stop_OWNER_REPO_prPR_NUMBER" ]; then
    rm -f "/tmp/af_watch_stop_OWNER_REPO_prPR_NUMBER"
    echo "WATCH_STOPPED"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "WATCH_TIMEOUT"
    exit 0
  fi
  output=$(gh api graphql -f owner="OWNER" -f repo="REPO" -F pr=PR_NUMBER -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      state
      reviewThreads(last: 100) {
        nodes {
          id
          isResolved
          path
          line
          comments(last: 20) {
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
      comments(last: 100) {
        nodes {
          id
          author { login }
          body
          createdAt
          url
        }
      }
      reviews(last: 50) {
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
}' --jq '
  .data.viewer.login as $self |
  "STATE=" + .data.repository.pullRequest.state,
  (.data.repository.pullRequest.reviewThreads.nodes[]
   | select(.isResolved == false)
   | . as $thread
   | $thread.comments.nodes[]
   | select(.body != null and (.body | gsub("[[:space:]]+"; "") != ""))
   | select(.author.login != $self)
   | "THREAD=\($thread.id) COMMENT=\(.id) AUTHOR=\(.author.login) PATH=\($thread.path) LINE=\($thread.line // "") URL=\(.url)"),
  (.data.repository.pullRequest.comments.nodes[]
   | select(.body != null and (.body | gsub("[[:space:]]+"; "") != ""))
   | select(.author.login != $self)
   | "COMMENT=\(.id) AUTHOR=\(.author.login) URL=\(.url)"),
  (.data.repository.pullRequest.reviews.nodes[]
   | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED")
   | select(.body != null and (.body | gsub("[[:space:]]+"; "") != ""))
   | select(.author.login != $self)
   | "REVIEW=\(.id) AUTHOR=\(.author.login) STATE=\(.state) URL=\(.url)")
' 2>"/tmp/af_poll_err_$$")
  if [ $? -ne 0 ]; then
    fail_count=$((fail_count + 1))
    if [ "$fail_count" -ge 2 ]; then
      echo "POLL_ERROR: $(head -1 "/tmp/af_poll_err_$$")"
      exit 1
    fi
    sleep $POLL_INTERVAL_SECONDS
    continue
  fi
  fail_count=0
  if echo "$output" | grep -qE '^STATE=(MERGED|CLOSED)$'; then
    echo "$output" | grep '^STATE='
    exit 0
  fi
  echo "$output"
  # Poll PR status checks for failures
  required_checks=$(gh pr checks PR_NUMBER --repo OWNER/REPO --required --json name --jq '.[].name' 2>/dev/null)
  check_output=$(gh pr checks PR_NUMBER --repo OWNER/REPO --json name,state,bucket,link,description --jq '.[] | select(.bucket == "fail") | "CHECK_FAIL=\(.name)\tSTATE=\(.state)\tBUCKET=\(.bucket)\tLINK=\(.link)\tDESC=\(.description)"' 2>>"/tmp/af_poll_err_$$")
  if [ -n "$check_output" ]; then
    while IFS= read -r check_line; do
      check_first_field="${check_line%%	*}"
      check_name="${check_first_field#CHECK_FAIL=}"
      if printf '%s' "$required_checks" | grep -qxF "$check_name"; then
        printf '%s\tREQUIRED=yes\n' "$check_line"
      else
        printf '%s\tREQUIRED=no\n' "$check_line"
      fi
    done <<< "$check_output"
  fi
  sleep $POLL_INTERVAL_SECONDS
done

# --- Usage Notes ---
#
# Complete Monitor command: This is the full Monitor command including the
# 4-hour deadline, consecutive-failure exit, polling loop, and self-exit
# logic. Do not wrap it in an additional loop. When STATE=MERGED or
# STATE=CLOSED is detected, the script calls exit 0 — this terminates
# the Monitor background process ("Exit ends the watch"). After
# MAX_WATCH_SECONDS seconds (default: 14400 / 4 hours) the script emits
# WATCH_TIMEOUT and calls exit 0. After 2 consecutive poll failures the
# script emits POLL_ERROR: <first line of stderr> and calls exit 1.
#
# Monitor coverage limits: This query intentionally omits pageInfo and
# pagination. Full pagination would require multiple API calls per poll
# cycle, which is not feasible for a Monitor command. Instead, each
# connection uses last: N to fetch the most recent N items — new activity
# appears at the end of connections and is always within the fetched page.
# PRs with more than 100 unresolved review threads, 100 top-level
# comments, or 50 review summaries may have older items outside the
# fetched window; those items are not detected by this Monitor query.
# If a PR reaches these limits, run a one-time manual fetch using the
# full paginated queries in
# ${CLAUDE_PLUGIN_ROOT}/skills/_shared/github-pr-review-graphql.md.
#
# This command:
# - Uses no shell-level line continuation characters — the multiline
#   query and jq expressions live inside single-quoted strings, which
#   span multiple lines in bash without modification
# - Embeds viewer { login } in the GraphQL query and uses
#   .data.viewer.login as $self for self-author filtering — no
#   environment variable required
# - Always emits STATE=<value> first so Monitor detects MERGED or CLOSED
#   on every poll
# - Emits THREAD=... lines for unresolved review thread comments passing
#   all filters
# - Emits COMMENT=... lines for top-level PR comments passing all filters
# - Emits REVIEW=... lines for actionable review summaries passing all
#   filters
# - Emits CHECK_FAIL=... lines for failed PR status checks. Fields are
#   tab-separated: CHECK_FAIL=<name>, STATE=<state>, BUCKET=fail,
#   LINK=<url>, DESC=<description>, REQUIRED=<yes|no>. Only checks with
#   bucket=="fail" are emitted. The REQUIRED field is derived from
#   `gh pr checks --required`; if --required is unavailable (no branch
#   protection), all checks default to REQUIRED=no.
# - Uses only gh api graphql --jq — no external parser binaries required
# - Uses last: N on all connections instead of first: N — new activity is
#   always at the end of connections; last: ensures recent items are always
#   in the fetched page without requiring pagination
# - Uses gh pr checks (REST-backed) for status checks — separate rate-limit
#   bucket from the GraphQL review query
