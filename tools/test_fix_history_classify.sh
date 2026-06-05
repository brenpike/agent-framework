#!/usr/bin/env bash
#
# Behavioral unit runner for the fix-history classification filter (issue #198, STEP-002).
#
# PURE jq TEST — CI-runnable with ONLY jq present (NO tmux / claude / gh / network). It runs the
# single-source-of-truth classification predicate:
#   plugin/skills/github-review-loop/scripts/fix-history-classify.jq
# over fixed GraphQL-payload fixtures under tests/fix-history/, and asserts the emitted classified
# stream equals an expected set. The filter is a PURE function of stdin + --arg login/--arg filter,
# so every case is deterministic and offline.
#
# Mirrors tools/test_shared_libs.sh's pass/fail counter + per-case assertion + exit-nonzero-on-any-
# fail convention. Read-only: the only writes are scratch files in a disposable tmpdir removed on EXIT.
#
# Usage:
#   ./tools/test_fix_history_classify.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FILTER="$REPO_ROOT/plugin/skills/github-review-loop/scripts/fix-history-classify.jq"
FIX_DIR="$REPO_ROOT/tests/fix-history"

[ -f "$FILTER" ] || { echo "FAIL: filter under test missing: $FILTER" >&2; exit 2; }
[ -d "$FIX_DIR" ] || { echo "FAIL: fixture dir missing: $FIX_DIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this suite" >&2; exit 2; }

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-fix-history.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; return 0; }
trap cleanup EXIT

# Canonicalize a classified stream into a single deterministic line: slurp the stream into an
# array, sort by the fields that disambiguate every record (databaseId, url, surface,
# classification), and emit compact JSON. Ordering noise across surfaces or thread nodes can never
# flake the comparison. An empty stream canonicalizes to "[]".
canon() {
  jq -s -c 'sort_by((.databaseId // -1), (.url // ""), .surface, .classification)'
}

# run_case <case> <fixture-basename> <login> <filter> <expected-canonical-json>
# Feed the fixture through the filter with the given args, canonicalize, and exact-match against
# the expected canonical JSON. A jq failure (filter error / invalid fixture) fails the case loudly.
run_case() {
  local case_name="$1" fixture="$2" login="$3" filt="$4" expected="$5"
  local path="$FIX_DIR/$fixture"
  if [ ! -f "$path" ]; then
    failed "$case_name" "fixture missing: $path"
    return
  fi
  local actual
  if ! actual="$(jq -cf "$FILTER" --arg login "$login" --arg filter "$filt" < "$path" | canon)"; then
    failed "$case_name" "jq filter failed on fixture $fixture (login=$login filter=$filt)"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    pass "$case_name" "($fixture login=$login filter=$filt)"
  else
    failed "$case_name" "($fixture login=$login filter=$filt)
    expected: $expected
    actual:   $actual"
  fi
}

# ── Case 1: handled-by-marker ────────────────────────────────────────────────────
# Non-self thread comment whose OWN body carries `Fixed in <40hex>.` → handled. No self fix-reply
# exists in the thread (latest_self_fix_id sentinel 0), so the marker branch is isolated.
run_case "case01:handled-by-marker" "case01-handled-by-marker.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":100,"url":null,"classification":"handled"}]'

# ── Case 2: handled-by-id-ordering ───────────────────────────────────────────────
# Non-self comment (id 200) with no marker; a later self `Fixed in <SHA>.` reply (id 201) sets
# latest_self_fix_id=201. 200 <= 201 → handled via the id-ordering branch. The self reply is not
# emitted as a candidate.
run_case "case02:handled-by-id-ordering" "case02-handled-by-id-ordering.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":200,"url":null,"classification":"handled"}]'

# ── Case 3: followup-after-fix ───────────────────────────────────────────────────
# Thread with a self fix-reply (id 301). Comment 300 predates it (<= 301 → handled); comment 302
# post-dates it (> 301, no marker → followup-after-fix). Exercises both branches in one thread.
run_case "case03:followup-after-fix" "case03-followup-after-fix.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":300,"url":null,"classification":"handled"},{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":302,"url":null,"classification":"followup-after-fix"}]'

# ── Case 4: no-self-fix thread ───────────────────────────────────────────────────
# Non-self comment, NO self fix-reply in the thread → latest_self_fix_id sentinel 0. A real
# databaseId (400) has no marker. Because no self fix-reply exists (latest_self_fix_id == 0), this
# is a FIRST-TIME finding on a never-fixed thread → actionable. It is NOT followup-after-fix:
# followup-after-fix requires a prior self fix-reply (latest_self_fix_id > 0) to post-date.
run_case "case04:no-self-fix-thread" "case04-no-self-fix-thread.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":400,"url":null,"classification":"actionable"}]'

# ── Case 5: thread-overflow ──────────────────────────────────────────────────────
# comments.totalCount (50) > fetched nodes length (1) → thread_overflow=true forces classification
# actionable filter-blind, EVEN for a comment whose body carries a fix marker.
run_case "case05:thread-overflow" "case05-thread-overflow.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":true,"databaseId":500,"url":null,"classification":"actionable"}]'

# ── Case 6: top-level addressed / unaddressed ────────────────────────────────────
# A self-authored top-level comment carries `Addresses: <url>` harvesting one url. The addressed
# non-self top-level comment → handled; the unaddressed one → actionable; the self comment is not
# emitted.
run_case "case06:toplevel-addressed" "case06-toplevel-addressed.json" "selfuser" "all" \
  '[{"surface":"toplevel","thread_resolved":false,"thread_overflow":false,"databaseId":null,"url":"https://github.com/o/r/pull/1#issuecomment-600","classification":"handled"},{"surface":"toplevel","thread_resolved":false,"thread_overflow":false,"databaseId":null,"url":"https://github.com/o/r/pull/1#issuecomment-601","classification":"actionable"}]'

# ── Case 7: review summaries ─────────────────────────────────────────────────────
# CHANGES_REQUESTED/COMMENTED + non-empty body, url unaddressed → actionable; an addressed
# CHANGES_REQUESTED review (self `Addresses:` harvested its url) → handled; APPROVED and DISMISSED
# emit NO record.
run_case "case07:review-summary" "case07-review-summary.json" "selfuser" "all" \
  '[{"surface":"review","thread_resolved":false,"thread_overflow":false,"databaseId":null,"url":"https://github.com/o/r/pull/1#pullrequestreview-700","classification":"handled"},{"surface":"review","thread_resolved":false,"thread_overflow":false,"databaseId":null,"url":"https://github.com/o/r/pull/1#pullrequestreview-701","classification":"actionable"},{"surface":"review","thread_resolved":false,"thread_overflow":false,"databaseId":null,"url":"https://github.com/o/r/pull/1#pullrequestreview-702","classification":"actionable"}]'

# ── Case 8: [bot] normalization ──────────────────────────────────────────────────
# A self author login carrying a trailing `[bot]` suffix (selfuser[bot]) normalizes to selfuser →
# treated as self, so its `Fixed in <SHA>.` sets latest_self_fix_id and it is NOT emitted. The
# non-self comment (id 800 <= 801) → handled. Exactly one record.
run_case "case08:bot-normalization" "case08-bot-normalization.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":800,"url":null,"classification":"handled"}]'

# ── Case 9: reviewer_filter — codex-only vs all on one payload ────────────────────
# Same payload, two filters. codex-only matches ONLY chatgpt-codex-connector (900). all matches any
# non-self author (900 + the human reviewer 901). No self fix-reply (latest_self_fix_id sentinel 0)
# → both are FIRST-TIME findings on a never-fixed thread → actionable (per case 4).
run_case "case09:reviewer-filter-codex-only" "case09-reviewer-filter.json" "selfuser" "codex-only" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":900,"url":null,"classification":"actionable"}]'
run_case "case09:reviewer-filter-all" "case09-reviewer-filter.json" "selfuser" "all" \
  '[{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":900,"url":null,"classification":"actionable"},{"surface":"thread","thread_resolved":false,"thread_overflow":false,"databaseId":901,"url":null,"classification":"actionable"}]'

# ── Summary ──────────────────────────────────────────────────────────────────────
echo
echo "fix-history-classify: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
