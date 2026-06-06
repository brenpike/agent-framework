#!/usr/bin/env bash
#
# Behavioral unit runner for the fix-ledger reconstruction script (issue #222, STEP-003).
#
# OFFLINE jq/bash TEST — CI-runnable with ONLY jq + bash present (NO tmux / gh / network). It
# drives the pure mapping core of:
#   plugin/skills/github-review-loop/scripts/ledger-reconstruct.sh
# via its documented offline test seam (--git-log-file / --normalized-file, both bypassing the
# live `git log` fetch), feeds canned fixtures, and asserts the emitted fix-ledger JSON equals an
# expected canonical form. The mapping core is a PURE function of the injected payloads, so every
# case is deterministic and offline.
#
# Fixtures are under tests/ledger-reconstruct/; expected outputs under
# tests/ledger-reconstruct/expected/. Each expected fixture stores the ledger with `branch: null`
# (live git state stripped) and findings sorted by `id`. The canonicalizer applies the same
# transform to actual output so jq key-order can never flake the comparison.
#
# Mirrors tools/test_fetch_normalize.sh's pass/fail counter + per-case run helper +
# exit-nonzero-on-any-fail convention. Read-only: no writes outside the script's own stdout/stderr.
#
# Usage:
#   bash tools/test_ledger_reconstruct.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugin/skills/github-review-loop/scripts/ledger-reconstruct.sh"
LR_DIR="$REPO_ROOT/tests/ledger-reconstruct"
EXPECTED_DIR="$LR_DIR/expected"

[ -f "$SCRIPT_UNDER_TEST" ] || { echo "FAIL: script under test missing: $SCRIPT_UNDER_TEST" >&2; exit 2; }
[ -d "$LR_DIR" ] || { echo "FAIL: fixture dir missing: $LR_DIR" >&2; exit 2; }
[ -d "$EXPECTED_DIR" ] || { echo "FAIL: expected-output dir missing: $EXPECTED_DIR" >&2; exit 2; }
[ -f "$LR_DIR/README.md" ] || { echo "FAIL: self-test probe target missing: $LR_DIR/README.md" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this suite" >&2; exit 2; }

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# canon <ledger-json-on-stdin>: normalize a fix-ledger object for deterministic comparison.
# Sets branch to null (live git state varies per checkout), sorts findings[] by id (-S sorts
# object keys), and emits compact JSON. An invalid/empty input canonicalizes to the empty string
# so a jq failure fails the test case loudly rather than silently matching.
canon() {
  jq -S -c '.branch = null | .iterations[0].findings |= sort_by(.id)'
}

# run_case <case> <git-log-fixture> <normalized-fixture|-> <expected-fixture>
# Feed the git-log fixture (and optional normalized-file fixture) through the offline seam,
# canonicalize stdout, and exact-match against the canonicalized expected fixture. A nonzero
# script exit or empty/mismatched output fails the case loudly.
run_case() {
  local case_name="$1" git_log_fix="$2" norm_fix="$3" expected_fix="$4"
  if [ ! -f "$git_log_fix" ]; then failed "$case_name" "git-log fixture missing: $git_log_fix"; return; fi
  if [ ! -f "$expected_fix" ]; then failed "$case_name" "expected fixture missing: $expected_fix"; return; fi

  local -a norm_args=()
  if [ "$norm_fix" != "-" ]; then
    if [ ! -f "$norm_fix" ]; then failed "$case_name" "normalized fixture missing: $norm_fix"; return; fi
    norm_args=(--normalized-file "$norm_fix")
  fi

  local expected actual
  if ! expected="$(canon < "$expected_fix")"; then
    failed "$case_name" "could not canonicalize expected fixture $expected_fix"
    return
  fi
  if ! actual="$(bash "$SCRIPT_UNDER_TEST" --git-log-file "$git_log_fix" "${norm_args[@]}" 2>/dev/null | canon)"; then
    failed "$case_name" "script or canonicalization failed (git-log=$(basename "$git_log_fix") norm=$(basename "$norm_fix"))"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    pass "$case_name" "($(basename "$git_log_fix") norm=$(basename "$norm_fix"))"
  else
    failed "$case_name" "($(basename "$git_log_fix") norm=$(basename "$norm_fix"))
    expected: $expected
    actual:   $actual"
  fi
}

# run_failopen_case <case> <git-log-fixture> <normalized-fixture|-> <expected-fixture>
# Like run_case, but ALSO asserts the script exited 0 explicitly (run_case pipes stdout into
# canon, masking the script's own exit status). Locks the injected fail-OPEN guarantee: a
# malformed or empty injected payload yields the expected (usually empty-findings) shape AND
# exit 0 — never an error. Captures stdout + status WITHOUT a pipe, then canonicalizes.
run_failopen_case() {
  local case_name="$1" git_log_fix="$2" norm_fix="$3" expected_fix="$4"
  if [ ! -f "$git_log_fix" ]; then failed "$case_name" "git-log fixture missing: $git_log_fix"; return; fi
  if [ ! -f "$expected_fix" ]; then failed "$case_name" "expected fixture missing: $expected_fix"; return; fi

  local -a norm_args=()
  if [ "$norm_fix" != "-" ]; then
    if [ ! -f "$norm_fix" ]; then failed "$case_name" "normalized fixture missing: $norm_fix"; return; fi
    norm_args=(--normalized-file "$norm_fix")
  fi

  local raw status expected actual
  raw="$(bash "$SCRIPT_UNDER_TEST" --git-log-file "$git_log_fix" "${norm_args[@]}" 2>/dev/null)"
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
    pass "$case_name" "(exit=0 $(basename "$git_log_fix") norm=$(basename "$norm_fix"))"
  else
    failed "$case_name" "($(basename "$git_log_fix") norm=$(basename "$norm_fix"))
    expected: $expected
    actual:   $actual"
  fi
}

# assert_finding_field <case> <actual-ledger-json> <finding-id> <field> <expected-value>
# Drill into a specific finding by id and assert a single field value equals the expected
# scalar (as a raw jq value — strings must include quotes). Used for targeted field assertions
# that complement the whole-object comparison in run_case.
assert_finding_field() {
  local case_name="$1" ledger="$2" finding_id="$3" field="$4" expected_val="$5"
  local actual_val
  actual_val="$(printf '%s' "$ledger" | jq -c \
    --arg id "$finding_id" --arg fld "$field" \
    '.iterations[0].findings[] | select(.id == $id) | .[$fld]' 2>/dev/null)"
  if [ "$actual_val" = "$expected_val" ]; then
    pass "$case_name" "(finding=$finding_id field=$field)"
  else
    failed "$case_name" "(finding=$finding_id field=$field) expected=$expected_val actual=$actual_val"
  fi
}

# ── commit→finding mapping ───────────────────────────────────────────────────────────────────
# One commit, two files, one hunk each. Assert findings carry correct file/line_start/line_end/
# fix_commit/id/title/status (single commit → "fixed" for all surfaces).
run_case "commit:finding-mapping" \
  "$LR_DIR/git-log-one-commit.txt" - \
  "$EXPECTED_DIR/one-commit-git-only.json"

# Whole-object comparison for the one-commit case WITH thread records folded in. This is the
# primary mapping-correctness case: exercises git-log findings AND thread record folding together.
run_case "commit:finding-mapping-with-threads" \
  "$LR_DIR/git-log-one-commit.txt" \
  "$LR_DIR/normalized-threads.json" \
  "$EXPECTED_DIR/one-commit-with-threads.json"

# Targeted field assertions for the one-commit case (complement the whole-object check above).
# Run the script once, capture the ledger, then assert individual fields.
one_commit_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-one-commit.txt" 2>/dev/null)"

assert_finding_field "commit:auth-file" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "file" '"src/auth.py"'
assert_finding_field "commit:auth-line-start" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "line_start" "10"
assert_finding_field "commit:auth-line-end" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "line_end" "13"
assert_finding_field "commit:auth-fix-commit" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "fix_commit" \
  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
assert_finding_field "commit:auth-title" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "title" \
  '"Fix null check in auth handler"'
assert_finding_field "commit:auth-status" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "status" '"fixed"'
assert_finding_field "commit:auth-fix-framing-null" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" "fix_framing" "null"
assert_finding_field "commit:db-line-start" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/db.py:5" "line_start" "5"
assert_finding_field "commit:db-line-end" "$one_commit_ledger" \
  "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/db.py:5" "line_end" "6"

# ── oscillation status ───────────────────────────────────────────────────────────────────────
# Two commits touch the same surface (src/handler.py:20..24) → both findings "cycling".
# One commit touches a unique surface (src/other.py:1..4) → "fixed".
run_case "oscillation:whole-object" \
  "$LR_DIR/git-log-oscillation.txt" - \
  "$EXPECTED_DIR/oscillation.json"

oscillation_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-oscillation.txt" 2>/dev/null)"

assert_finding_field "oscillation:first-commit-cycling" "$oscillation_ledger" \
  "fix:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:src/handler.py:20" "status" '"cycling"'
assert_finding_field "oscillation:second-commit-cycling" "$oscillation_ledger" \
  "fix:cccccccccccccccccccccccccccccccccccccccc:src/handler.py:20" "status" '"cycling"'
assert_finding_field "oscillation:unique-surface-fixed" "$oscillation_ledger" \
  "fix:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:src/other.py:1" "status" '"fixed"'

# ── thread-state merge ───────────────────────────────────────────────────────────────────────
# Normalized fixture contains: review(resolved) → status="fixed" thread_resolved=true,
# review(unresolved) → status="open", ci-check-failure → SKIPPED (item_source != "review").
# Use empty git-log so only thread records appear in findings (isolates the thread folding path).
run_case "thread:state-merge" \
  "$LR_DIR/git-log-empty.txt" \
  "$LR_DIR/normalized-threads.json" \
  "$EXPECTED_DIR/thread-state-merge.json"

thread_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-empty.txt" \
  --normalized-file "$LR_DIR/normalized-threads.json" 2>/dev/null)"

assert_finding_field "thread:resolved-status-fixed" "$thread_ledger" \
  "PRRT_thread001resolved" "status" '"fixed"'
assert_finding_field "thread:resolved-thread-resolved-true" "$thread_ledger" \
  "PRRT_thread001resolved" "thread_resolved" "true"
assert_finding_field "thread:unresolved-status-open" "$thread_ledger" \
  "PRRT_thread002open" "status" '"open"'
assert_finding_field "thread:file-null" "$thread_ledger" \
  "PRRT_thread001resolved" "file" "null"
assert_finding_field "thread:line-start-null" "$thread_ledger" \
  "PRRT_thread001resolved" "line_start" "null"

# Assert ci-check-failure record was skipped (findings count must be exactly 2).
thread_count="$(printf '%s' "$thread_ledger" | \
  jq '.iterations[0].findings | length' 2>/dev/null)"
if [ "$thread_count" = "2" ]; then
  pass "thread:ci-record-skipped" "(findings count=$thread_count; ci-check-failure not folded)"
else
  failed "thread:ci-record-skipped" "expected 2 findings (ci skipped), got $thread_count"
fi

# ── empty git-log → empty findings, exit 0 ───────────────────────────────────────────────────
# An empty git log (no commits in range) is a legitimate "no prior fixes yet" state, NOT an
# error. Script must exit 0 and emit a valid ledger with empty findings[].
run_failopen_case "empty:git-log" \
  "$LR_DIR/git-log-empty.txt" - \
  "$EXPECTED_DIR/empty-findings.json"

# ── malformed injected git-log → empty findings, exit 0 (injected fail-OPEN) ────────────────
# A malformed injected fixture yields a valid ledger shape with empty findings and exit 0.
# The fail-OPEN posture applies to INJECTED content; only a LIVE git failure would fail closed.
run_failopen_case "malformed:git-log-fail-open" \
  "$LR_DIR/git-log-malformed.txt" - \
  "$EXPECTED_DIR/empty-findings.json"

# ── Summary ──────────────────────────────────────────────────────────────────────────────────
echo
echo "ledger-reconstruct: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
