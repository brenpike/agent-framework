# Placeholders: OWNER, REPO, PR_NUMBER
gh api graphql -f owner="OWNER" -f repo="REPO" -F pr=PR_NUMBER -f query='
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
'

graphql_status=$?
if [ "$graphql_status" -ne 0 ]; then
  exit "$graphql_status"
fi

# Detect Codex approval via 👍 reaction. Use --paginate for complete coverage
# of the reactions connection (a bounded first-N slice can miss the bot's
# reaction when a PR has many reactions, leaving watch to run until timeout).
codex_approved=$(gh api --paginate "repos/OWNER/REPO/issues/PR_NUMBER/reactions" \
  --jq '.[] | select(.content == "+1") | ((.user.login // "") | sub("\\[bot\\]$"; "")) | select(. == "chatgpt-codex-connector") | "CODEX_APPROVED=\(.)"' 2>/dev/null)
if [ -n "$codex_approved" ]; then
  printf '%s\n' "$codex_approved" | head -1
fi

# gh pr checks exit codes: 0=passed, 1=failed (captured), 8=pending, other=error
required_checks=$(gh pr checks PR_NUMBER --repo OWNER/REPO --required --json name --jq '.[].name' 2>/dev/null)
check_stderr_file=$(mktemp)
check_output=$(gh pr checks PR_NUMBER --repo OWNER/REPO --json name,state,bucket,link,description --jq '.[] | select(.bucket == "fail") | "CHECK_FAIL=\(.name | gsub("[\\t\\n\\r]"; " "))\tSTATE=\(.state)\tBUCKET=\(.bucket)\tLINK=\((.link // "") | gsub("[\\t\\n\\r]"; " "))\tDESC=\((.description // "") | gsub("[\\t\\n\\r]"; " "))"' 2>"$check_stderr_file")
check_status=$?
if [ "$check_status" -ne 0 ] && [ "$check_status" -ne 1 ] && [ "$check_status" -ne 8 ]; then
  check_stderr_line=$(tr '\n' ' ' < "$check_stderr_file")
  printf 'CHECK_POLL_ERROR=gh pr checks failed (exit %s)%s\n' \
    "$check_status" \
    "${check_stderr_line:+ STDERR=$check_stderr_line}"
fi
rm -f "$check_stderr_file"
if [ -n "$check_output" ]; then
  printf '%s\n' "$check_output" | while IFS= read -r check_line; do
    check_name=$(printf '%s' "$check_line" | cut -f1 | sed 's/^CHECK_FAIL=//')
    if printf '%s' "$required_checks" | grep -qxF "$check_name"; then
      printf '%s\tREQUIRED=yes\n' "$check_line"
    else
      printf '%s\tREQUIRED=no\n' "$check_line"
    fi
  done
fi
