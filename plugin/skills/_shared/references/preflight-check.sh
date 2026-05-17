# Pre-flight validation query for github-reviewer agent
#
# This file is a reference template loaded via Read tool. It is NOT executed
# directly as a script. The skill reads this file, substitutes OWNER, REPO,
# and PR_NUMBER with resolved values, and runs the resulting gh api graphql
# command once via the existing Bash(gh api *) permission.
#
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
