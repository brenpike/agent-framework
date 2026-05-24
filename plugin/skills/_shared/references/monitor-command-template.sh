# Placeholders: OWNER, REPO, PR_NUMBER, MAX_WATCH_DEFAULT, POLL_INTERVAL_DEFAULT
MAX_WATCH_SECONDS=MAX_WATCH_DEFAULT  # substitute integer seconds (default: 14400)
POLL_INTERVAL_SECONDS=POLL_INTERVAL_DEFAULT  # substitute integer seconds (default: 60)
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
      reactions(first: 50, content: THUMBS_UP) {
        nodes { user { login } }
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
   | "REVIEW=\(.id) AUTHOR=\(.author.login) STATE=\(.state) URL=\(.url)"),
  (.data.repository.pullRequest.reactions.nodes[]
   | (.user.login // "") as $rl
   | select(($rl | sub("\\[bot\\]$"; "")) == "chatgpt-codex-connector")
   | "CODEX_APPROVED=\($rl)")
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
  check_output=$(gh pr checks PR_NUMBER --repo OWNER/REPO --json name,state,bucket,link,description --jq '.[] | select(.bucket == "fail") | "CHECK_FAIL=\(.name | gsub("[\\t\\n\\r]"; " "))\tSTATE=\(.state)\tBUCKET=\(.bucket)\tLINK=\((.link // "") | gsub("[\\t\\n\\r]"; " "))\tDESC=\((.description // "") | gsub("[\\t\\n\\r]"; " "))"' 2>>"/tmp/af_poll_err_$$")
  check_exit=$?
  if [ "$check_exit" -gt 1 ] && [ "$check_exit" -ne 8 ]; then
    echo "CHECK_POLL_ERROR: gh pr checks failed (exit $check_exit)"
  elif [ -n "$check_output" ]; then
    printf '%s\n' "$check_output" | while IFS= read -r check_line; do
      check_first_field="${check_line%%	*}"
      check_name="${check_first_field#CHECK_FAIL=}"
      if printf '%s' "$required_checks" | grep -qxF "$check_name"; then
        printf '%s\tREQUIRED=yes\n' "$check_line"
      else
        printf '%s\tREQUIRED=no\n' "$check_line"
      fi
    done
  fi
  sleep $POLL_INTERVAL_SECONDS
done
