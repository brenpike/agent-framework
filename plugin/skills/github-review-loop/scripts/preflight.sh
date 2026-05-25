#!/usr/bin/env bash
#
# Preflight resolution for the github-review-loop skill.
#
# Resolves and verifies the facts the skill needs before it dispatches the
# cycle-0 reviewer pass and arms the change-detect poll:
#   - PR number, owner, repo
#   - PR is OPEN
#   - the local working branch matches the expected working_branch
#   - the resolved base branch
#   - SELF_LOGIN (the authenticated gh identity, used for self-comment filtering)
#
# Emits labeled results on stdout for the skill to read directly. No /tmp. No
# stop-file. On any failure it prints a PREFLIGHT_ERROR line and exits non-zero.
#
# Placeholders substituted by the skill before running:
#   PR_REF          PR number or URL
#   WORKING_BRANCH  expected working branch
#   BASE_BRANCH     expected base branch (PR target)

set -u

PR_REF="PR_REF"
WORKING_BRANCH="WORKING_BRANCH"
BASE_BRANCH="BASE_BRANCH"

fail() {
  echo "PREFLIGHT_ERROR=$1"
  exit 1
}

# Resolve PR number, state, and base via gh's own --jq (no standalone jq).
pr_number=$(gh pr view "$PR_REF" --json number --jq '.number' 2>/dev/null) \
  || fail "could not resolve PR number"
pr_state=$(gh pr view "$PR_REF" --json state --jq '.state' 2>/dev/null) \
  || fail "could not resolve PR state"
pr_base=$(gh pr view "$PR_REF" --json baseRefName --jq '.baseRefName' 2>/dev/null) \
  || fail "could not resolve PR base"
owner=$(gh pr view "$PR_REF" --json headRepositoryOwner --jq '.headRepositoryOwner.login' 2>/dev/null)
repo=$(gh pr view "$PR_REF" --json headRepository --jq '.headRepository.name' 2>/dev/null)

# Fall back to the base repository's owner/name when the head is the same repo
# (the common case for non-fork PRs, where headRepositoryOwner may be empty).
if [ -z "${owner:-}" ] || [ -z "${repo:-}" ]; then
  repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) \
    || fail "could not resolve owner/repo"
  owner="${repo_nwo%%/*}"
  repo="${repo_nwo#*/}"
fi

[ "$pr_state" = "OPEN" ] || fail "PR is not OPEN (state=$pr_state)"

self_login=$(gh api user --jq '.login' 2>/dev/null) \
  || fail "could not resolve SELF_LOGIN"

current_branch=$(git branch --show-current 2>/dev/null) \
  || fail "could not read current git branch"
[ "$current_branch" = "$WORKING_BRANCH" ] \
  || fail "current branch '$current_branch' does not match working_branch '$WORKING_BRANCH'"

# Emit resolved facts for the skill.
echo "PR_NUMBER=$pr_number"
echo "OWNER=$owner"
echo "REPO=$repo"
echo "STATE=$pr_state"
echo "BASE=$pr_base"
echo "WORKING_BRANCH=$current_branch"
echo "SELF_LOGIN=$self_login"
echo "PREFLIGHT_OK=true"
