# Pre-flight validation query for github-reviewer agent
#
# This file is a reference template loaded via Read tool. It is NOT executed
# directly as a script. The skill reads this file, substitutes OWNER, REPO,
# and PR_NUMBER with resolved values, and runs the resulting commands.
#
# Placeholders: OWNER, REPO, PR_NUMBER (used in both the GraphQL query and the
# gh pr checks commands below).
#
# Output lines:
#   STATE=        PR open/closed/merged state
#   THREAD=       unresolved review thread reference
#   COMMENT=      PR-level or thread comment reference
#   REVIEW=       CHANGES_REQUESTED or COMMENTED review reference
#   CHECK_FAIL=   failed status check (tab-separated fields; see gh pr checks block)
#
# Failures from gh pr checks are surfaced as data (CHECK_FAIL= lines) and do
# not cause the preflight to exit non-zero.

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

# Check PR status checks for failures.
# Uses gh pr checks (REST-backed). Failures are surfaced as data, not blockers.
# REQUIRED field derived from --required flag; defaults to "no" if unavailable.
required_checks=$(gh pr checks PR_NUMBER --repo OWNER/REPO --required --json name --jq '.[].name' 2>/dev/null)
gh pr checks PR_NUMBER --repo OWNER/REPO --json name,state,bucket,link,description --jq '.[] | select(.bucket == "fail") | "CHECK_FAIL=\(.name | gsub("[\\t\\n\\r]"; " "))\tSTATE=\(.state)\tBUCKET=\(.bucket)\tLINK=\((.link // "") | gsub("[\\t\\n\\r]"; " "))\tDESC=\((.description // "") | gsub("[\\t\\n\\r]"; " "))"' 2>/dev/null | while IFS= read -r check_line; do
  check_name=$(printf '%s' "$check_line" | cut -f1 | sed 's/^CHECK_FAIL=//')
  if printf '%s' "$required_checks" | grep -qxF "$check_name"; then
    printf '%s\tREQUIRED=yes\n' "$check_line"
  else
    printf '%s\tREQUIRED=no\n' "$check_line"
  fi
done
