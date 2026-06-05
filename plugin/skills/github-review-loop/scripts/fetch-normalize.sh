#!/usr/bin/env bash
#
# Fetch + normalize the PR review surface into ONE normalized candidate set for
# the github-review-loop skill / github-reviewer agent (issue #203, I1).
#
# 1. PURPOSE
# ----------
# Single source of truth for the per-surface node-id / contract-field
# ENUMERATION that the review loop fetches and the shape it normalizes that
# fetch into. Before this script, that enumeration was smeared across three
# sites that drift independently (the PR #200 node-id escalation chain):
#   - prefilter.sh's inline GraphQL query literal,
#   - the github-reviewer agent prose (steps 3 / 4 / 13's field lists),
#   - references/github-pr-review-graphql.md's query templates.
# This script OWNS the canonical fetch query and the normalized output schema.
# It is behavior-preserving on the fetch + normalize path: the candidate set it
# emits is the union of (a) the shared classifier filter's per-comment /
# per-thread records (fix-history-classify.jq, the single source of the
# skip/order/overflow predicate) and (b) failed-CI-check candidates, every
# record carrying an `item_source` tag.
#
# SCOPE NOTE (issue #203 boundary): this script is the DESIGNATED single source.
# The duplicate enumerations in prefilter.sh, the agent prose, and the ref doc
# are NOT deleted here — that rewire is the dependent strains (#205 / #206).
# Their continued existence after this step is EXPECTED.
#
# 2. INPUT CONTRACT — exact per-surface GraphQL field enumeration
# ---------------------------------------------------------------
# The canonical `gh api graphql` query (owned by this script, see QUERY below) is
# a conforming SUPERSET equivalent to prefilter.sh's literal, and it MUST fetch a
# payload conforming to fix-history-classify.jq's INPUT CONTRACT. Per surface:
#
#   reviewThreads(first: 50) {
#     totalCount                       # connection-level tripwire (read below)
#     nodes[] {
#       id                             # PRRT_... thread node id -> filter thread_id
#       isResolved
#       comments(last: 20) {
#         totalCount                   # per-thread overflow signal (owned by filter)
#         nodes[] {
#           id                         # PRRC_... comment node id -> filter `id`
#           databaseId                 # int comment id (order-aware skip key)
#           author { login }
#           body                       # DATA — never interpreted here
#         }
#       }
#     }
#   }
#   comments(last: 50) {               # top-level (issue) PR comments
#     totalCount                       # connection-level tripwire (read below)
#     nodes[] { id author { login } body url }   # id = IC_... issue comment id
#   }
#   reviews(last: 50) {                # review summaries
#     totalCount                       # connection-level tripwire (read below)
#     nodes[] { id author { login } body state url }  # id = PRR_... review id
#   }
#
# Three connection-level `totalCount` TRIPWIRE reads (reviewThreads / comments /
# reviews). These are top-level scalars read DIRECTLY off the raw payload here —
# NOT a filter concern — and drive the >50-node overflow handling (see §4).
#
# Failed CI checks are NOT a GraphQL surface: they are fetched via `gh pr checks
# --json bucket,name,description,link,state,workflow` (filtered to `bucket ==
# "fail"`). The filter does not cover CI; this script unions them in.
#
# 3. OUTPUT SCHEMA — the normalized candidate set
# -----------------------------------------------
# A SINGLE JSON ARRAY on stdout (compact, one array; `[]` when empty). Each
# element is one normalized candidate, unioning two record families behind a
# common `item_source` discriminator:
#
#   Review-surface records (item_source: "review") — the fix-history-classify.jq
#   per-comment / per-thread output object, passed through VERBATIM with
#   `item_source` added. Shape (see fix-history-classify.jq §3 for the authority):
#     {
#       "item_source":     "review",
#       "surface":         "thread" | "toplevel" | "review",
#       "thread_resolved": bool,
#       "thread_overflow": bool,
#       "thread_id":       <string>|null,   # PRRT_... (thread surface) else null
#       "id":              <string>|null,    # PRRC_/IC_/PRR_ node id; null ONLY
#                                            #   for the thread-overflow sentinel
#       "databaseId":      <int>|null,       # null off-thread + for the sentinel
#       "url":             <string>|null,    # null on thread surface
#       "classification":  "handled" | "actionable" | "followup-after-fix"
#     }
#
#   CI-check-failure records (item_source: "ci-check-failure") — one per failed
#   check. NO GraphQL node id (CI checks are not review nodes):
#     {
#       "item_source": "ci-check-failure",
#       "id":          null,                 # CI candidates carry NO node id
#       "name":        <string>,             # check name
#       "description": <string>,             # used as the candidate body
#       "link":        <string>|null,        # check details url
#       "state":       <string>,             # raw gh state (e.g. FAILURE)
#       "workflow":    <string>|null
#     }
#
# Consumers project this set exactly as today: review records by `classification`
# (actionable / followup-after-fix -> candidate; handled -> skip; the
# databaseId-null thread-surface record is the overflow SENTINEL -> thread-level
# inspection); ci-check-failure records -> fix candidates with `description` as
# body. This script does NOT collapse to a SKIP/DISPATCH decision — that
# projection stays with each consumer (prefilter keeps its binary collapse).
#
# 4. BEHAVIOR-PRESERVING INVARIANTS
# ---------------------------------
#   - FAIL-OPEN on a malformed / empty / unparseable payload: the normalize core
#     emits an empty candidate set (`[]`) rather than erroring, so a consumer
#     treats a broken fetch as "nothing classified" exactly as the filter's
#     empty-stream behavior. (The LIVE-fetch path still fails non-zero on a gh
#     error so a real fetch failure is never silently swallowed — see §5.)
#   - >50-node connection overflow is NOT silently dropped. The three
#     connection-level totalCounts are emitted on stderr as a diagnostic
#     OVERFLOW notice AND surfaced to the caller via the trailing exit/marker
#     posture (see §5). This script does NOT itself decide DISPATCH — it
#     preserves the raw signal so the consumer's existing >50 fail-open logic
#     (prefilter's bash tripwire) stays the authority. The overflow read mirrors
#     prefilter.sh: each totalCount defaults to 0 when absent.
#   - Thread-overflow SENTINEL pass-through: the filter's databaseId-null,
#     thread_id-non-null thread-surface record is passed through UNTOUCHED (only
#     `item_source` is added). It is never collapsed, deduped, or reinterpreted.
#   - CI candidates carry NO node id (`id: null`) — they are not review nodes and
#     must never be routed to a `node(id:)` body refetch.
#   - Missing `timeout` / `gtimeout` -> degrade gracefully with a loud stderr
#     warning and run the gh calls UNGUARDED (mirrors prefilter.sh / issue #159).
#
# 5. INVOCATION + TEST SEAM
# -------------------------
# Pure normalization core over an INJECTED raw payload, with the live fetch as a
# thin outer shell that is BYPASSED under test (designed for offline fixtures
# exactly like test_fix_history_classify.sh). Positional + flag args:
#
#   $1  OWNER             base-repo owner            (required for LIVE fetch)
#   $2  REPO              base-repo name             (required for LIVE fetch)
#   $3  PR_NUMBER         integer PR number          (required for LIVE fetch)
#   $4  REVIEWER_FILTER   "codex-only" | "all" | "<login>" (default codex-only)
#   $5  SELF_LOGIN        viewer login               (required — self strip)
#
#   --payload-file <path>     read the raw GraphQL JSON from <path> instead of
#                             running the live `gh api graphql` fetch. Use `-`
#                             for stdin. BYPASSES the live GraphQL fetch.
#   --ci-payload-file <path>  read the raw `gh pr checks --json ...` JSON from
#                             <path> instead of running the live `gh pr checks`.
#                             Use `-` for stdin. BYPASSES the live CI fetch.
#                             Absent under --payload-file -> NO CI candidates
#                             (offline review-only fixture).
#
#   When --payload-file is supplied the GraphQL fetch is skipped and
#   OWNER/REPO/PR_NUMBER are NOT required (the offline core only needs
#   SELF_LOGIN + REVIEWER_FILTER for the filter args). STEP-002 feeds canned
#   GraphQL fixtures through --payload-file (and optional canned CI JSON through
#   --ci-payload-file) and asserts the emitted normalized array.
#
# Markers / exit posture (mirrors prefilter.sh's fail-open):
#   - stdout: the single normalized JSON array (always, on success).
#   - exit 0 on success (including the fail-open empty-set case).
#   - FETCHNORM_ERROR=<reason> on stdout + exit 1 ONLY on a LIVE-fetch failure
#     (gh error, missing shared filter, bad input) — never on a merely-empty or
#     malformed injected payload (that is the fail-open empty-set path).
#   - OVERFLOW diagnostic emitted on stderr when any connection totalCount > 50.

set -u

OWNER=""
REPO=""
PR_NUMBER=""
REVIEWER_FILTER=""
SELF_LOGIN=""
PAYLOAD_FILE=""
CI_PAYLOAD_FILE=""

fetchnorm_fail() {
  echo "FETCHNORM_ERROR=$1"
  exit 1
}

# Parse flags and collect positionals. Flags may appear anywhere; positionals
# bind in order (OWNER REPO PR_NUMBER REVIEWER_FILTER SELF_LOGIN), matching the
# sibling scripts' positional contract.
positionals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload-file)
      [ "$#" -ge 2 ] || fetchnorm_fail "missing-value-for-payload-file"
      PAYLOAD_FILE="$2"; shift 2 ;;
    --payload-file=*)
      PAYLOAD_FILE="${1#--payload-file=}"; shift ;;
    --ci-payload-file)
      [ "$#" -ge 2 ] || fetchnorm_fail "missing-value-for-ci-payload-file"
      CI_PAYLOAD_FILE="$2"; shift 2 ;;
    --ci-payload-file=*)
      CI_PAYLOAD_FILE="${1#--ci-payload-file=}"; shift ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do positionals+=("$1"); shift; done ;;
    *)
      positionals+=("$1"); shift ;;
  esac
done

OWNER="${positionals[0]:-}"
REPO="${positionals[1]:-}"
PR_NUMBER="${positionals[2]:-}"
REVIEWER_FILTER="${positionals[3]:-}"
SELF_LOGIN="${positionals[4]:-}"

# REVIEWER_FILTER defaults to codex-only when empty; any non-empty string is
# accepted as a login form (codex-only | all | <login>). Mirrors prefilter.sh.
[ -n "$REVIEWER_FILTER" ] || REVIEWER_FILTER="codex-only"
# SELF_LOGIN is required on every path: without it the shared filter cannot strip
# self-authored comments and the self-echo storm re-emerges. Mirrors prefilter.
[ -n "$SELF_LOGIN" ] || fetchnorm_fail "missing-self-login"

# Resolve the shared classifier filter RELATIVE to this script's own location,
# matching prefilter.sh: this script runs as a sibling of fix-history-classify.jq
# so ${BASH_SOURCE[0]}'s dir is the correct resolution, NOT ${CLAUDE_PLUGIN_ROOT}.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY_FILTER="$SCRIPT_DIR/fix-history-classify.jq"
[ -f "$CLASSIFY_FILTER" ] || fetchnorm_fail "missing-filter"

# Timeout wrapper for gh API calls (issue #159). Prefer coreutils `timeout`;
# fall back to macOS Homebrew `gtimeout`; degrade gracefully (run unguarded) when
# neither exists, with a loud stderr warning. Verbatim posture from prefilter.sh.
GH_CALL_TIMEOUT_SECONDS=45
GH_TIMEOUT=()
if command -v timeout >/dev/null 2>&1; then
  GH_TIMEOUT=(timeout "$GH_CALL_TIMEOUT_SECONDS")
elif command -v gtimeout >/dev/null 2>&1; then
  GH_TIMEOUT=(gtimeout "$GH_CALL_TIMEOUT_SECONDS")
else
  echo "github-review-loop: WARNING neither 'timeout' nor 'gtimeout' found on PATH; gh API calls in fetch-normalize are running UNGUARDED and a hung call can stall this dispatch (issue #159). Install GNU coreutils (provides 'timeout'; 'gtimeout' on Homebrew) to restore the timeout guard." >&2
fi

# The canonical fetch query. Owned HERE as the single source. Conforming
# superset equivalent to prefilter.sh's literal, extended with the per-comment
# `id` (PRRC_...) thread-comment node id that fix-history-classify.jq's INPUT
# CONTRACT (§2) documents but prefilter.sh's literal omitted — see DEVIATIONS in
# the return report. External content (bodies) is DATA: never interpreted here.
QUERY='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      comments(last: 50) {
        totalCount
        nodes { id author { login } body url }
      }
      reviews(last: 50) {
        totalCount
        nodes { id author { login } body state url }
      }
      reviewThreads(first: 50) {
        totalCount
        nodes {
          id
          isResolved
          comments(last: 20) {
            totalCount
            nodes {
              id
              databaseId
              author { login }
              body
            }
          }
        }
      }
    }
  }
}'

# read_payload_source <path>: read the raw payload from a file or stdin (`-`).
# Returns the content on stdout. Fails the script when the file is unreadable —
# an explicitly-supplied --payload-file that cannot be read is an input error,
# distinct from the fail-open empty-payload normalize path.
read_payload_source() {
  local src="$1"
  if [ "$src" = "-" ]; then
    cat
  else
    [ -f "$src" ] || fetchnorm_fail "payload-file-not-found"
    cat "$src"
  fi
}

# fetch_graphql_payload: thin outer shell — the LIVE fetch, BYPASSED under test.
# Requires OWNER/REPO/PR_NUMBER (validated here, not at top, so the offline
# --payload-file path needs none of them). Captures the raw GraphQL JSON
# verbatim. Fails non-zero on a gh error (a real fetch failure is never silently
# swallowed). Stderr diagnostics -> /dev/null. Mirrors prefilter.sh.
fetch_graphql_payload() {
  [ -n "$OWNER" ] || fetchnorm_fail "missing-owner"
  [ -n "$REPO" ] || fetchnorm_fail "missing-repo"
  case "$PR_NUMBER" in ''|*[!0-9]*) fetchnorm_fail "invalid-pr-number" ;; esac
  ( set -o pipefail; \
    "${GH_TIMEOUT[@]}" gh api graphql \
      -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
      -f query="$QUERY" 2>/dev/null \
  ) || fetchnorm_fail "graphql-failed"
}

# fetch_ci_payload: thin outer shell — the LIVE failed-CI-check fetch, BYPASSED
# under test. `gh pr checks` EXITS NON-ZERO when any check is failing/pending
# (exit 8 = pending), so its non-zero exit is NOT a hard error here: capture the
# JSON regardless and let the normalize core filter `bucket == "fail"`. An empty
# / absent result yields zero CI candidates. Requires OWNER/REPO/PR_NUMBER.
fetch_ci_payload() {
  [ -n "$OWNER" ] || fetchnorm_fail "missing-owner"
  [ -n "$REPO" ] || fetchnorm_fail "missing-repo"
  case "$PR_NUMBER" in ''|*[!0-9]*) fetchnorm_fail "invalid-pr-number" ;; esac
  "${GH_TIMEOUT[@]}" gh pr checks "$PR_NUMBER" --repo "$OWNER/$REPO" \
    --json bucket,name,description,link,state,workflow 2>/dev/null || true
}

# --- Resolve the two raw payloads (live fetch OR injected fixture) ----------
if [ -n "$PAYLOAD_FILE" ]; then
  graphql_payload="$(read_payload_source "$PAYLOAD_FILE")"
else
  graphql_payload="$(fetch_graphql_payload)"
fi

if [ -n "$CI_PAYLOAD_FILE" ]; then
  ci_payload="$(read_payload_source "$CI_PAYLOAD_FILE")"
elif [ -z "$PAYLOAD_FILE" ]; then
  # Live path: fetch CI checks too. Offline review-only path (--payload-file with
  # no --ci-payload-file) deliberately yields NO CI candidates.
  ci_payload="$(fetch_ci_payload)"
else
  ci_payload=""
fi

# --- Overflow tripwire: read the three connection totalCounts DIRECTLY off the
# raw payload (filter does not emit them), each defaulting to 0 when absent so a
# malformed/empty payload behaves like a 0-node page. Mirrors prefilter.sh. Emit
# an OVERFLOW diagnostic on stderr (never silently drop) when any exceeds 50; the
# consumer's existing >50 fail-open stays the authority. ------------------------
totals="$(printf '%s' "$graphql_payload" | jq -r '
  .data.repository.pullRequest as $pr |
  "THREADS_TOTAL=" + (($pr.reviewThreads.totalCount // 0) | tostring),
  "COMMENTS_TOTAL=" + (($pr.comments.totalCount // 0) | tostring),
  "REVIEWS_TOTAL=" + (($pr.reviews.totalCount // 0) | tostring)
' 2>/dev/null)"

threads_total=0
comments_total=0
reviews_total=0
while IFS= read -r line; do
  case "$line" in
    THREADS_TOTAL=*) threads_total="${line#THREADS_TOTAL=}" ;;
    COMMENTS_TOTAL=*) comments_total="${line#COMMENTS_TOTAL=}" ;;
    REVIEWS_TOTAL=*) reviews_total="${line#REVIEWS_TOTAL=}" ;;
  esac
done <<EOF
$totals
EOF
case "$threads_total" in ''|*[!0-9]*) threads_total=0 ;; esac
case "$comments_total" in ''|*[!0-9]*) comments_total=0 ;; esac
case "$reviews_total" in ''|*[!0-9]*) reviews_total=0 ;; esac

if [ "$threads_total" -gt 50 ] || [ "$comments_total" -gt 50 ] || [ "$reviews_total" -gt 50 ]; then
  echo "github-review-loop: OVERFLOW one or more connection totalCounts exceed 50 (reviewThreads=$threads_total comments=$comments_total reviews=$reviews_total); in-page classification is untrustworthy on the overflowed axis — the consumer must fail open (DISPATCH) per its >50 tripwire (issue #203 invariant)." >&2
fi

# --- Review-surface records: pipe the raw GraphQL payload through the shared
# classifier filter (the single source of skip/order/overflow semantics), then
# tag each emitted record with item_source: "review". FAIL-OPEN: a malformed /
# empty / unparseable payload yields an empty review-record set (NOT an error) —
# the normalize core never errors on a bad injected payload. -------------------
review_records="$(printf '%s' "$graphql_payload" \
  | jq -c -f "$CLASSIFY_FILTER" --arg login "$SELF_LOGIN" --arg filter "$REVIEWER_FILTER" 2>/dev/null \
  | jq -c '. + {item_source: "review"}' 2>/dev/null)"
# A jq failure (e.g. malformed payload) leaves review_records empty -> the slurp
# below canonicalizes to an empty array. This is the fail-open empty-set path.

# --- CI-check-failure records: project the raw `gh pr checks --json` array down
# to failed checks only (bucket == "fail"), normalizing each into a CI candidate
# carrying NO node id (id: null). A malformed / empty CI payload yields zero CI
# candidates (fail-open). The raw gh output is a JSON array of check objects. ----
ci_records="$(printf '%s' "$ci_payload" | jq -c '
  if type == "array" then .[] else empty end
  | select(.bucket == "fail")
  | {
      item_source: "ci-check-failure",
      id: null,
      name: (.name // ""),
      description: (.description // ""),
      link: (.link // null),
      state: (.state // ""),
      workflow: (.workflow // null)
    }
' 2>/dev/null)"

# --- Union the two record families into ONE normalized JSON array on stdout.
# `jq -s` slurps the (possibly empty) newline-delimited record streams; an empty
# stream slurps to []. The two slurps are concatenated. Always emits exactly one
# compact array, `[]` when both families are empty (the fail-open shape). -------
printf '%s\n%s\n' "$review_records" "$ci_records" \
  | jq -s -c '[ .[] ]'

exit 0
