#!/usr/bin/env bash
#
# Behavioral unit runner for the fetch + normalize candidate-set builder (issue #203, STEP-002).
#
# OFFLINE jq/bash TEST — CI-runnable with ONLY jq + bash present (NO tmux / gh / network). It
# drives the pure normalization core of:
#   plugin/skills/github-review-loop/scripts/fetch-normalize.sh
# via its documented test seam (--payload-file / --ci-payload-file, both bypassing the live
# `gh api graphql` / `gh pr checks` fetches), feeds canned fixtures, and asserts the emitted
# normalized JSON array equals an expected set. The normalize core is a PURE function of the
# injected payload(s) + --arg login/filter, so every case is deterministic and offline.
#
# Review-path fixtures are reused from tests/fix-history/ (verified by STEP-001 to conform to
# fetch-normalize.sh's GraphQL input contract). CI-path, connection-tripwire, and empty/malformed
# fixtures are authored under tests/fetch-normalize/. Each case pairs an input fixture with an
# expected normalized output fixture under tests/fetch-normalize/expected/, compared after
# canonicalization (object keys + array elements sorted) so jq key-ordering can never flake it.
#
# Mirrors tools/test_fix_history_classify.sh's pass/fail counter + per-case assertion +
# exit-nonzero-on-any-fail convention. Read-only: the only writes are scratch files in a
# disposable tmpdir removed on EXIT.
#
# Usage:
#   ./tools/test_fetch_normalize.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
NORMALIZE="$REPO_ROOT/plugin/skills/github-review-loop/scripts/fetch-normalize.sh"
FIX_HISTORY_DIR="$REPO_ROOT/tests/fix-history"
FN_DIR="$REPO_ROOT/tests/fetch-normalize"
EXPECTED_DIR="$FN_DIR/expected"

[ -f "$NORMALIZE" ] || { echo "FAIL: script under test missing: $NORMALIZE" >&2; exit 2; }
[ -d "$FIX_HISTORY_DIR" ] || { echo "FAIL: fix-history fixture dir missing: $FIX_HISTORY_DIR" >&2; exit 2; }
[ -d "$FN_DIR" ] || { echo "FAIL: fetch-normalize fixture dir missing: $FN_DIR" >&2; exit 2; }
[ -d "$EXPECTED_DIR" ] || { echo "FAIL: expected-output dir missing: $EXPECTED_DIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this suite" >&2; exit 2; }

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Canonicalize a normalized candidate array into a single deterministic line: sort the array by
# the union of fields that disambiguate both record families (review records and ci-check-failure
# records) and sort object keys (-S). Ordering noise across families or surfaces can never flake
# the comparison. An empty array canonicalizes to "[]".
canon() {
  jq -S -c 'sort_by((.databaseId // -1), (.url // ""), (.thread_id // ""), (.name // ""), (.surface // ""), (.classification // ""), (.item_source // ""))'
}

# run_case <case> <review-fixture-abspath> <ci-fixture-abspath|-> <reviewer-filter> <expected-fixture-abspath>
# Feed the review fixture (and optional CI fixture) through the normalize core under the OFFLINE
# test seam, canonicalize stdout, and exact-match against the canonicalized expected fixture.
# OWNER/REPO/PR_NUMBER are left empty (not required under --payload-file); SELF_LOGIN is fixed to
# "selfuser" to match the reused fix-history fixtures. A nonzero exit or empty/mismatched output
# fails the case loudly.
run_case() {
  local case_name="$1" review_fix="$2" ci_fix="$3" filt="$4" expected_fix="$5"
  if [ ! -f "$review_fix" ]; then failed "$case_name" "review fixture missing: $review_fix"; return; fi
  if [ ! -f "$expected_fix" ]; then failed "$case_name" "expected fixture missing: $expected_fix"; return; fi

  local -a ci_args=()
  if [ "$ci_fix" != "-" ]; then
    if [ ! -f "$ci_fix" ]; then failed "$case_name" "ci fixture missing: $ci_fix"; return; fi
    ci_args=(--ci-payload-file "$ci_fix")
  fi

  local expected actual
  if ! expected="$(canon < "$expected_fix")"; then
    failed "$case_name" "could not canonicalize expected fixture $expected_fix"
    return
  fi
  # The normalize core fails non-zero ONLY on a live-fetch path; under --payload-file it always
  # exits 0 (fail-open). A nonzero here is a real regression — surface it.
  if ! actual="$(bash "$NORMALIZE" --payload-file "$review_fix" "${ci_args[@]}" -- "" "" "" "$filt" selfuser 2>/dev/null | canon)"; then
    failed "$case_name" "normalize core failed on $review_fix (ci=$ci_fix filter=$filt)"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    pass "$case_name" "($(basename "$review_fix") ci=$(basename "$ci_fix") filter=$filt)"
  else
    failed "$case_name" "($(basename "$review_fix") ci=$(basename "$ci_fix") filter=$filt)
    expected: $expected
    actual:   $actual"
  fi
}

# stderr_contains <case> <review-fixture> <needle> <present|absent>
# Run the normalize core capturing ONLY stderr, and assert the needle is present or absent. Used to
# verify the connection-tripwire OVERFLOW diagnostic fires on a >50 totalCount and stays silent
# otherwise (the diagnostic is the consumer's fail-open signal; stdout candidates are unaffected).
stderr_contains() {
  local case_name="$1" review_fix="$2" needle="$3" mode="$4"
  if [ ! -f "$review_fix" ]; then failed "$case_name" "review fixture missing: $review_fix"; return; fi
  local err
  err="$(bash "$NORMALIZE" --payload-file "$review_fix" -- "" "" "" all selfuser 2>&1 1>/dev/null)"
  case "$mode" in
    present)
      if printf '%s' "$err" | grep -q "$needle"; then
        pass "$case_name" "stderr contains '$needle'"
      else
        failed "$case_name" "stderr MISSING '$needle' (got: $err)"
      fi ;;
    absent)
      if printf '%s' "$err" | grep -q "$needle"; then
        failed "$case_name" "stderr UNEXPECTEDLY contains '$needle' (got: $err)"
      else
        pass "$case_name" "stderr free of '$needle'"
      fi ;;
    *) failed "$case_name" "bad stderr_contains mode: $mode" ;;
  esac
}

# run_fail_case <case> <expected-reason> <arg...>
# Run the normalize core with the given raw args, capturing stdout + exit code WITHOUT a pipe (so
# the script's own exit status is observed, not a downstream filter's). Assert the script exited
# NON-ZERO and that stdout carries the single `FETCHNORM_ERROR=<expected-reason>` line. This is the
# fail-CLOSED asserter: it locks the RS-001 structural guarantee that a live-fetch / input error
# surfaces as exit 1 + a FETCHNORM_ERROR marker rather than being silently swallowed (the original
# #203 bug). Distinct from run_case, which treats any non-zero exit as a regression.
run_fail_case() {
  local case_name="$1" expected_reason="$2"; shift 2
  local out status
  out="$(bash "$NORMALIZE" "$@" 2>/dev/null)"
  status=$?
  if [ "$status" -eq 0 ]; then
    failed "$case_name" "expected NON-ZERO exit, got 0 (stdout: $out)"
    return
  fi
  if printf '%s\n' "$out" | grep -q "^FETCHNORM_ERROR=$expected_reason$"; then
    pass "$case_name" "exit=$status FETCHNORM_ERROR=$expected_reason"
  else
    failed "$case_name" "exit=$status but stdout missing 'FETCHNORM_ERROR=$expected_reason' (got: $out)"
  fi
}

# run_failopen_case <case> <review-fixture-abspath> <ci-fixture-abspath|-> <expected-fixture-abspath>
# Like run_case, but ALSO asserts the script exited 0 explicitly (run_case pipes stdout into canon,
# so the script's own exit status is masked by canon's). This locks the PRESERVED fail-OPEN
# guarantee: a malformed / empty / non-array injected payload yields the expected (usually empty)
# candidate set AND exit 0 — never an error. Captures stdout + status WITHOUT a pipe, then
# canonicalizes the captured buffer.
run_failopen_case() {
  local case_name="$1" review_fix="$2" ci_fix="$3" expected_fix="$4"
  if [ ! -f "$review_fix" ]; then failed "$case_name" "review fixture missing: $review_fix"; return; fi
  if [ ! -f "$expected_fix" ]; then failed "$case_name" "expected fixture missing: $expected_fix"; return; fi

  local -a ci_args=()
  if [ "$ci_fix" != "-" ]; then
    if [ ! -f "$ci_fix" ]; then failed "$case_name" "ci fixture missing: $ci_fix"; return; fi
    ci_args=(--ci-payload-file "$ci_fix")
  fi

  local raw status expected actual
  raw="$(bash "$NORMALIZE" --payload-file "$review_fix" "${ci_args[@]}" -- "" "" "" all selfuser 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    failed "$case_name" "expected exit 0 (fail-open), got $status (stdout: $raw)"
    return
  fi
  if ! expected="$(canon < "$expected_fix")"; then
    failed "$case_name" "could not canonicalize expected fixture $expected_fix"
    return
  fi
  actual="$(printf '%s' "$raw" | canon)"
  if [ "$actual" = "$expected" ]; then
    pass "$case_name" "(exit=0 $(basename "$review_fix") ci=$(basename "$ci_fix"))"
  else
    failed "$case_name" "($(basename "$review_fix") ci=$(basename "$ci_fix"))
    expected: $expected
    actual:   $actual"
  fi
}

# ── Review surfaces ───────────────────────────────────────────────────────────────
# thread surface, handled classification: a thread comment carrying a `Fixed in <sha>.` marker
# normalizes to one review record, item_source review, classification handled.
run_case "review:thread-handled" \
  "$FIX_HISTORY_DIR/case01-handled-by-marker.json" - all \
  "$EXPECTED_DIR/review-thread-handled.json"

# thread surface, handled + followup-after-fix in one thread: a comment predating the self
# fix-reply -> handled; a comment post-dating it -> followup-after-fix. Exercises both branches.
run_case "review:thread-followup-after-fix" \
  "$FIX_HISTORY_DIR/case03-followup-after-fix.json" - all \
  "$EXPECTED_DIR/review-thread-followup.json"

# toplevel surface: an addressed (self `Addresses:` url) top-level comment -> handled; the
# unaddressed one -> actionable.
run_case "review:toplevel" \
  "$FIX_HISTORY_DIR/case06-toplevel-addressed.json" - all \
  "$EXPECTED_DIR/review-toplevel.json"

# review surface: CHANGES_REQUESTED/COMMENTED summaries -> actionable; an addressed
# CHANGES_REQUESTED -> handled; APPROVED/DISMISSED emit nothing.
run_case "review:summary" \
  "$FIX_HISTORY_DIR/case07-review-summary.json" - all \
  "$EXPECTED_DIR/review-summary.json"

# ── Thread-overflow sentinel pass-through ─────────────────────────────────────────
# An overflowed unresolved thread emits BOTH the per-comment record AND the thread-overflow
# SENTINEL (id:null, databaseId:null, thread_id non-null). The sentinel passes through with only
# item_source added — never collapsed or reinterpreted.
run_case "overflow-sentinel:passthrough" \
  "$FIX_HISTORY_DIR/case05-thread-overflow.json" - all \
  "$EXPECTED_DIR/review-thread-overflow.json"

# Overflowed thread whose only visible node is self-authored: the per-comment loop emits nothing,
# so the stream is EXACTLY the thread-overflow sentinel (id:null, databaseId:null, thread_id
# non-null) — the overflow actionable signal is never silently lost.
run_case "overflow-sentinel:no-visible-match" \
  "$FIX_HISTORY_DIR/case10-thread-overflow-no-visible-match.json" - all \
  "$EXPECTED_DIR/review-overflow-no-visible.json"

# ── Connection-tripwire / >50-node fail-open (one per axis) ───────────────────────
# Each axis (reviewThreads / comments / reviews) with totalCount 51 must (a) preserve the in-page
# candidate on stdout and (b) emit the OVERFLOW diagnostic on stderr so the consumer fails open.
run_case "tripwire:threads-stdout" \
  "$FN_DIR/overflow-threads.json" - all \
  "$EXPECTED_DIR/overflow-threads.json"
stderr_contains "tripwire:threads-stderr" "$FN_DIR/overflow-threads.json" "OVERFLOW" present

run_case "tripwire:comments-stdout" \
  "$FN_DIR/overflow-comments.json" - all \
  "$EXPECTED_DIR/overflow-comments.json"
stderr_contains "tripwire:comments-stderr" "$FN_DIR/overflow-comments.json" "OVERFLOW" present

run_case "tripwire:reviews-stdout" \
  "$FN_DIR/overflow-reviews.json" - all \
  "$EXPECTED_DIR/overflow-reviews.json"
stderr_contains "tripwire:reviews-stderr" "$FN_DIR/overflow-reviews.json" "OVERFLOW" present

# Control: a payload with all totalCounts <= 50 emits NO OVERFLOW diagnostic.
stderr_contains "tripwire:no-overflow-control" "$FIX_HISTORY_DIR/case01-handled-by-marker.json" "OVERFLOW" absent

# ── CI-check candidate injection ──────────────────────────────────────────────────
# An empty review payload + a `gh pr checks --json bucket,name,description,link,state,workflow`
# array yields ONLY the bucket==fail checks as ci-check-failure records (id ALWAYS null);
# pass/pending checks are dropped.
run_case "ci:injection-only" \
  "$FN_DIR/empty-review.json" "$FN_DIR/ci-checks.json" all \
  "$EXPECTED_DIR/ci-only.json"

# Union: review records AND ci-check-failure records coexist in the one normalized array.
run_case "ci:union-with-review" \
  "$FIX_HISTORY_DIR/case01-handled-by-marker.json" "$FN_DIR/ci-checks.json" all \
  "$EXPECTED_DIR/review-plus-ci.json"

# ── Empty / malformed payload CONTENT -> [] + explicit exit 0 (PRESERVED fail-open) ─
# RS-001 hardened the LIVE-fetch / input-error path to fail CLOSED, but the malformed/empty injected
# CONTENT path MUST stay fail-OPEN. run_failopen_case asserts BOTH the empty array AND exit 0
# explicitly (run_case's pipe to canon masks the script's own exit status). This locks the
# behavior-preserving boundary: bad payload CONTENT is "nothing classified", never an error.
run_failopen_case "empty:no-records" \
  "$FN_DIR/empty-review.json" - \
  "$EXPECTED_DIR/empty.json"

run_failopen_case "malformed:fail-open" \
  "$FN_DIR/malformed.json" - \
  "$EXPECTED_DIR/empty-malformed.json"

# A non-array CI payload fed through the OFFLINE --ci-payload-file seam fails OPEN: the ci_records
# jq projects `if type=="array" then .[] else empty end`, so a non-array CI payload contributes ZERO
# CI candidates and the script exits 0. (The ci-checks-failed REJECTION lives ONLY in the LIVE
# fetch_ci_payload path, which --ci-payload-file bypasses — see report limitation note.)
run_failopen_case "ci:non-array-fail-open" \
  "$FN_DIR/empty-review.json" "$FN_DIR/ci-non-array.json" \
  "$EXPECTED_DIR/empty.json"

# ── Fail-CLOSED cluster lock (RS-001 structural fix regression guard) ──────────────
# Each case drives a live-fetch / input error through the OFFLINE seam and asserts the net observable
# RS-001 guarantees: exit NON-ZERO + a single `FETCHNORM_ERROR=<reason>` line on stdout. Before
# RS-001 these were silently swallowed (the original #203 bug); these cases ensure that can never
# regress.

# Nonexistent --payload-file: the clearest reproduction of the original bug now failing correctly.
# A path that does not exist trips read_payload_source's regular-file guard. No fixture needed.
run_fail_case "fail-closed:payload-file-not-found" "payload-file-not-found" \
  --payload-file "$FN_DIR/__does-not-exist__.json" -- "" "" "" all selfuser

# Empty inline --payload-file= : rejected as an input error, NOT silently re-routed to live GraphQL.
run_fail_case "fail-closed:empty-inline-payload-file" "missing-value-for-payload-file" \
  --payload-file= -- "" "" "" all selfuser

# Empty inline --ci-payload-file= : same input-error rejection on the CI seam.
run_fail_case "fail-closed:empty-inline-ci-payload-file" "missing-value-for-ci-payload-file" \
  --payload-file "$FN_DIR/empty-review.json" --ci-payload-file= -- "" "" "" all selfuser

# ── reviewer_filter scoping ───────────────────────────────────────────────────────
# Same payload, three filters. codex-only matches ONLY chatgpt-codex-connector (900). all matches
# any non-self author (900 + human reviewer 901). An empty filter slot defaults to codex-only.
run_case "filter:codex-only" \
  "$FIX_HISTORY_DIR/case09-reviewer-filter.json" - codex-only \
  "$EXPECTED_DIR/review-filter-codex-only.json"
run_case "filter:all" \
  "$FIX_HISTORY_DIR/case09-reviewer-filter.json" - all \
  "$EXPECTED_DIR/review-filter-all.json"
run_case "filter:default-is-codex-only" \
  "$FIX_HISTORY_DIR/case09-reviewer-filter.json" - "" \
  "$EXPECTED_DIR/review-filter-default.json"

# ── Summary ──────────────────────────────────────────────────────────────────────
echo
echo "fetch-normalize: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
