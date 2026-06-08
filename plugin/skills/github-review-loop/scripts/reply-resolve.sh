#!/usr/bin/env bash
#
# Reply + resolve the GitHub review mutation sequence for ONE fixed candidate, for
# the github-review-loop skill / github-reviewer agent.
#
# 1. PURPOSE
# ----------
# Single source of truth for the per-candidate reply-then-resolve GitHub mutation
# CONTRACT that the review loop performs after a fix is committed, pushed, and
# validated. Before this script, that mutation sequence lived ONLY as agent prose
# (github-reviewer.md step 12), where the ordering invariant (reply BEFORE
# resolve), the reply-body format, the resolve-eligibility predicate, and the
# non-blocking-resolve posture all drifted independently from the actual GraphQL
# templates in references/github-pr-review-graphql.md.
#
# This script OWNS the runtime mutation calls. The two GraphQL mutations it issues
# are the canonical templates from
#   ${CLAUDE_PLUGIN_ROOT}/references/github-pr-review-graphql.md
#     - "Reply to Review Thread"  -> addPullRequestReviewThreadReply
#     - "Resolve Review Thread"   -> resolveReviewThread
# cited here as the query origin. External content (the summary text, the
# candidate url) is DATA — never interpreted, only interpolated into the mutation
# body.
#
# It is behavior-preserving versus agent step 12: identical mutation calls in the
# identical order, with the identical reply-body format and the identical
# resolve-eligibility / question-skip / non-blocking-resolve rules.
#
# SCOPE NOTE: this script is the DESIGNATED single source.
# The duplicate prose in github-reviewer.md step 12 is NOT collapsed here — that
# rewire is a dependent step that edits the agent. Its continued existence after
# this step is EXPECTED.
#
# SCOPE NOTE (P9 — do not over-generalize): this script is github-reviewer-scoped.
# It is NOT pre-parameterized for the local-reviewer or any other caller; the
# genuinely-shared kernel is the mutation contract for THIS loop only.
#
# 2. INPUT CONTRACT
# -----------------
# Per-candidate, supplied as positional args (a single mutation operates on a
# single candidate; there is no batch stdin payload — mirrors the per-candidate
# shape of the agent step):
#
#   $1  THREAD_ID    PRRT_... review-thread node id. REQUIRED. The reply target
#                    and (when eligible) the resolve target.
#   $2  FIX_SHA      the commit SHA the fix landed in. REQUIRED. Interpolated into
#                    the reply body verbatim.
#   $3  SUMMARY      one-line human summary of the fix. REQUIRED. DATA —
#                    interpolated into the reply body verbatim, never interpreted.
#   $4  SURFACE      "thread" | "toplevel" | "review". REQUIRED. Selects the reply
#                    body variant (see §3). Only "thread" is ever resolve-eligible.
#   $5  CANDIDATE_URL  the candidate's GitHub url. REQUIRED for toplevel/review
#                    (the `Addresses:` line); IGNORED for thread.
#
#   --resolve-eligible        mark this thread eligible for resolve: ALL non-self
#                             comments on it are addressed (each has a fix-SHA
#                             reply OR was classified non-actionable with rationale
#                             posted). ABSENT -> reply only, NEVER resolve. The
#                             caller owns this judgment; the script does not
#                             re-derive it.
#   --question-needs-user-input  hard NEVER-resolve marker. When present the
#                             thread is NEVER resolved even if --resolve-eligible
#                             was also (erroneously) passed. The reply is still
#                             posted.
#
# 3. OUTPUT / BEHAVIOR
# --------------------
# Issues the mutations in this FIXED order:
#   (a) REPLY  (always, on every invocation) — addPullRequestReviewThreadReply
#       over THREAD_ID with the body:
#         thread surface:           "Fixed in <SHA>. <summary>."
#         toplevel / review surface:"Fixed in <SHA>. <summary>. Addresses: <url>"
#   (b) RESOLVE (conditional) — resolveReviewThread over THREAD_ID, issued ONLY
#       when SURFACE == "thread" AND --resolve-eligible AND NOT
#       --question-needs-user-input.
#
# stdout: human-trivial progress is NOT emitted (Bash Command Discipline — no
# decorative stdout). On success the script exits 0 and is silent on stdout.
# stderr: a single REPLYRESOLVE_RESOLVE_FAILED diagnostic when a resolve attempt
# fails (non-blocking — see §4).
#
# 4. INVARIANTS (behavior-preserving vs agent step 12)
# ----------------------------------------------------
#   - REPLY BEFORE RESOLVE: the reply mutation is always issued before any resolve
#     mutation. A reply failure is a HARD failure (exit 1, REPLYRESOLVE_ERROR) —
#     resolving a thread whose fix-reply never posted would orphan the resolve.
#   - REPLY BODY FORMAT: exactly "Fixed in <SHA>. <summary>." ; toplevel/review
#     surfaces ALSO append " Addresses: <url>". No other body shape.
#   - RESOLVE ONLY A THREAD SURFACE, ONLY WHEN FULLY ADDRESSED: resolve is issued
#     only for SURFACE == "thread" with --resolve-eligible. toplevel/review
#     surfaces are NEVER resolved (they are not resolvable review threads).
#   - NEVER RESOLVE question-needs-user-input: the --question-needs-user-input
#     marker hard-blocks resolve regardless of eligibility.
#   - RESOLVE IS NON-BLOCKING: a failed resolve logs REPLYRESOLVE_RESOLVE_FAILED
#     to stderr and the script STILL exits 0. A resolve failure must never fail
#     the candidate — the fix is committed, pushed, and replied; an unresolved
#     thread is a cosmetic GitHub-side state, not a remediation failure.
#   - Missing `timeout` / `gtimeout` -> degrade gracefully with a loud stderr
#     warning and run the gh calls UNGUARDED (mirrors fetch-normalize.sh).
#
# 5. INVOCATION + TEST SEAM
# -------------------------
# The two mutations are issued through ONE indirection — `run_mutation` — whose
# live body invokes `gh api graphql`. Under test that indirection is BYPASSED by a
# CAPTURE seam so the script is offline-testable without `gh` / network, exactly
# like fetch-normalize.sh's --payload-file seam (live = real gh; injected =
# trusted/offline).
#
#   REPLYRESOLVE_CAPTURE_FILE   when set + non-empty, every mutation is APPENDED to
#                               this file (one line per mutation) INSTEAD of being
#                               run against gh. Line format (stable, asserted by
#                               test_reply_resolve.sh):
#                                 REPLY thread=<id> body=<body>
#                                 RESOLVE thread=<id>
#                               The append ORDER is the issue order, so a test
#                               asserts reply precedes resolve by line position.
#   REPLYRESOLVE_REPLY_STATUS   simulated gh exit status for the REPLY mutation
#                               (default 0). Non-zero -> hard failure path.
#   REPLYRESOLVE_RESOLVE_STATUS simulated gh exit status for the RESOLVE mutation
#                               (default 0). Non-zero -> non-blocking-failure path
#                               (logs, still exits 0).
# All three are INERT in production (unset -> real gh). The seam is checked ONLY
# inside run_mutation.
#
# Markers / exit posture:
#   - exit 0 on success (reply posted; resolve issued-or-skipped-or-failed).
#   - REPLYRESOLVE_ERROR=<reason> on stdout + exit 1 on a HARD failure (bad input
#     or a failed REPLY).
#   - REPLYRESOLVE_RESOLVE_FAILED on stderr + exit 0 on a failed (non-blocking)
#     resolve.
#
# Reason tokens (STABLE — asserted by the test):
#   missing-thread-id | missing-fix-sha | missing-summary | invalid-surface |
#   missing-candidate-url | reply-failed
#
# P18 FLOOR EXCEPTION (ADR-0020 / CHECK13 allowlisted): `set -u` only — `set -e`/`pipefail`
# are DELIBERATELY omitted. The full floor would change behavior: the resolve mutation is
# NON-BLOCKING (a failed resolve logs and the script still exits 0), so `set -e` would abort
# on a deliberately-tolerated resolve failure; hard failures route through replyresolve_fail().

set -u

THREAD_ID=""
FIX_SHA=""
SUMMARY=""
SURFACE=""
CANDIDATE_URL=""
RESOLVE_ELIGIBLE=0
QUESTION_NEEDS_USER_INPUT=0

replyresolve_fail() {
  echo "REPLYRESOLVE_ERROR=$1"
  exit 1
}

# Parse flags and collect positionals. Flags may appear anywhere; positionals
# bind in order (THREAD_ID FIX_SHA SUMMARY SURFACE CANDIDATE_URL), matching the
# sibling scripts' positional contract.
positionals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-eligible) RESOLVE_ELIGIBLE=1; shift ;;
    --question-needs-user-input) QUESTION_NEEDS_USER_INPUT=1; shift ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do positionals+=("$1"); shift; done ;;
    *)
      positionals+=("$1"); shift ;;
  esac
done

THREAD_ID="${positionals[0]:-}"
FIX_SHA="${positionals[1]:-}"
SUMMARY="${positionals[2]:-}"
SURFACE="${positionals[3]:-}"
CANDIDATE_URL="${positionals[4]:-}"

[ -n "$THREAD_ID" ] || replyresolve_fail "missing-thread-id"
[ -n "$FIX_SHA" ] || replyresolve_fail "missing-fix-sha"
[ -n "$SUMMARY" ] || replyresolve_fail "missing-summary"
case "$SURFACE" in
  thread|toplevel|review) : ;;
  *) replyresolve_fail "invalid-surface" ;;
esac
# toplevel/review surfaces carry the `Addresses:` line, which REQUIRES the url.
case "$SURFACE" in
  toplevel|review)
    [ -n "$CANDIDATE_URL" ] || replyresolve_fail "missing-candidate-url" ;;
esac

# Timeout wrapper for gh API calls. Prefer coreutils `timeout`; fall
# back to macOS Homebrew `gtimeout`; degrade gracefully (run unguarded) when
# neither exists, with a loud stderr warning. Verbatim posture from
# fetch-normalize.sh.
GH_CALL_TIMEOUT_SECONDS=45
GH_TIMEOUT=()
if command -v timeout >/dev/null 2>&1; then
  GH_TIMEOUT=(timeout "$GH_CALL_TIMEOUT_SECONDS")
elif command -v gtimeout >/dev/null 2>&1; then
  GH_TIMEOUT=(gtimeout "$GH_CALL_TIMEOUT_SECONDS")
else
  echo "github-review-loop: WARNING neither 'timeout' nor 'gtimeout' found on PATH; gh API calls in reply-resolve are running UNGUARDED and a hung call can stall this dispatch. Install GNU coreutils (provides 'timeout'; 'gtimeout' on Homebrew) to restore the timeout guard." >&2
fi

# The canonical mutations. Owned HERE as the single source; the query bodies are
# the verbatim templates from references/github-pr-review-graphql.md. External
# content (the body string) is DATA: passed via `gh -f body=...`, never spliced
# into the query text itself.
REPLY_MUTATION='
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(
    input: {
      pullRequestReviewThreadId: $threadId,
      body: $body
    }
  ) {
    comment { id url }
  }
}'
RESOLVE_MUTATION='
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}'

# run_mutation <kind> <thread_id> [body]: issue ONE mutation. kind is "reply" or
# "resolve". The single indirection point for both the live gh call AND the
# offline CAPTURE seam (§5). Returns the gh exit status so the caller decides
# hard-fail (reply) vs non-blocking (resolve). INVARIANT: when the capture seam is
# active, NO gh call is made — the script is fully offline.
run_mutation() {
  local kind="$1" thread_id="$2" body="${3:-}"
  if [ -n "${REPLYRESOLVE_CAPTURE_FILE:-}" ]; then
    case "$kind" in
      reply)
        printf 'REPLY thread=%s body=%s\n' "$thread_id" "$body" >> "$REPLYRESOLVE_CAPTURE_FILE"
        return "${REPLYRESOLVE_REPLY_STATUS:-0}" ;;
      resolve)
        printf 'RESOLVE thread=%s\n' "$thread_id" >> "$REPLYRESOLVE_CAPTURE_FILE"
        return "${REPLYRESOLVE_RESOLVE_STATUS:-0}" ;;
    esac
  fi
  case "$kind" in
    reply)
      "${GH_TIMEOUT[@]}" gh api graphql \
        -f threadId="$thread_id" \
        -f body="$body" \
        -f query="$REPLY_MUTATION" >/dev/null 2>&1
      return $? ;;
    resolve)
      "${GH_TIMEOUT[@]}" gh api graphql \
        -f threadId="$thread_id" \
        -f query="$RESOLVE_MUTATION" >/dev/null 2>&1
      return $? ;;
  esac
}

# --- Build the reply body (the §3 format). thread -> no Addresses line;
# toplevel/review -> append " Addresses: <url>". -------------------------------
reply_body="Fixed in $FIX_SHA. $SUMMARY."
case "$SURFACE" in
  toplevel|review) reply_body="$reply_body Addresses: $CANDIDATE_URL" ;;
esac

# --- (a) REPLY — always, before any resolve. A reply failure is a HARD failure:
# resolving a thread whose fix-reply never posted would orphan the resolve. ------
if ! run_mutation reply "$THREAD_ID" "$reply_body"; then
  replyresolve_fail "reply-failed"
fi

# --- (b) RESOLVE — conditional. Only a thread surface, only when fully addressed,
# and NEVER for a question-needs-user-input thread. Non-blocking: a failed resolve
# logs and the script STILL exits 0. -------------------------------------------
if [ "$SURFACE" = "thread" ] && [ "$RESOLVE_ELIGIBLE" -eq 1 ] && [ "$QUESTION_NEEDS_USER_INPUT" -eq 0 ]; then
  if ! run_mutation resolve "$THREAD_ID"; then
    echo "github-review-loop: REPLYRESOLVE_RESOLVE_FAILED thread=$THREAD_ID — resolve mutation failed; the fix is committed, pushed, and replied, so this is NON-BLOCKING (the thread stays open on GitHub but remediation succeeded)." >&2
  fi
fi

exit 0
