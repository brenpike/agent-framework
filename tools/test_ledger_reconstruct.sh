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
  '"fix(auth): address review feedback"'
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
# Normalized fixture contains: thread(resolved) → status="fixed" thread_resolved=true,
# thread(unresolved) → status="open"; toplevel(handled) → status="fixed" (NON-thread surfaces
# cannot be GitHub-resolved, so status derives from classification, NOT thread_resolved);
# review(actionable) → status="open"; ci-check-failure → SKIPPED (item_source != "review").
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
# Non-thread surfaces (toplevel/review) carry thread_resolved:false even once addressed; status
# MUST derive from classification (handled -> fixed) so an addressed top-level/review record is
# not mis-reported "open" and does not suppress the POST-fix advisory (PR #223 P1).
assert_finding_field "toplevel:handled-status-fixed-from-classification" "$thread_ledger" \
  "IC_toplevel001handled" "status" '"fixed"'
assert_finding_field "toplevel:handled-thread-resolved-null" "$thread_ledger" \
  "IC_toplevel001handled" "thread_resolved" "null"
assert_finding_field "review:actionable-status-open-from-classification" "$thread_ledger" \
  "PRR_review001actionable" "status" '"open"'
assert_finding_field "thread:file-null" "$thread_ledger" \
  "PRRT_thread001resolved" "file" "null"
assert_finding_field "thread:line-start-null" "$thread_ledger" \
  "PRRT_thread001resolved" "line_start" "null"

# Assert ci-check-failure record was skipped: the fixture holds 4 review records (2 thread +
# 1 toplevel + 1 review) + 1 ci-check-failure; only the 4 review records fold in (findings == 4).
thread_count="$(printf '%s' "$thread_ledger" | \
  jq '.iterations[0].findings | length' 2>/dev/null)"
if [ "$thread_count" = "4" ]; then
  pass "thread:ci-record-skipped" "(findings count=$thread_count; ci-check-failure not folded)"
else
  failed "thread:ci-record-skipped" "expected 4 findings (4 review records, ci skipped), got $thread_count"
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

# ── F1 regression lock — C0 byte in commit subject ───────────────────────────────────────────
# git-log-c0-subject.txt contains a commit subject with a C0 control byte (0x08 backspace),
# a double-quote, and a backslash. Old code (awk hand-rolled JSON) collapsed to empty findings
# and exit 0 when a C0 byte appeared (F1 repro). New code: jq owns ALL JSON-string emission
# so C0 bytes are escaped (→ \b / \uXXXX) and the finding is NON-empty. This case LOCKS that:
# the output must be valid JSON, findings NON-empty, and the title correctly escaped.
run_case "c0-subject:whole-object" \
  "$LR_DIR/git-log-c0-subject.txt" - \
  "$EXPECTED_DIR/c0-subject.json"

c0_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-c0-subject.txt" 2>/dev/null)"

# Title must round-trip with the C0 byte correctly escaped (jq encodes 0x08 as \b).
assert_finding_field "c0-subject:title-escaped" "$c0_ledger" \
  "fix:dddddddddddddddddddddddddddddddddddddddd:src/fix.py:1" "title" \
  '"fix(x): address review feedback Fix\b\"bad\\path\""'

# File and line range correct.
assert_finding_field "c0-subject:file" "$c0_ledger" \
  "fix:dddddddddddddddddddddddddddddddddddddddd:src/fix.py:1" "file" '"src/fix.py"'
assert_finding_field "c0-subject:line-start" "$c0_ledger" \
  "fix:dddddddddddddddddddddddddddddddddddddddd:src/fix.py:1" "line_start" "1"
assert_finding_field "c0-subject:line-end" "$c0_ledger" \
  "fix:dddddddddddddddddddddddddddddddddddddddd:src/fix.py:1" "line_end" "3"

# findings[] MUST be non-empty (old code collapsed to []).
c0_count="$(printf '%s' "$c0_ledger" | jq '.iterations[0].findings | length' 2>/dev/null)"
if [ "$c0_count" = "1" ]; then
  pass "c0-subject:findings-non-empty" "(count=$c0_count; old code would emit [])"
else
  failed "c0-subject:findings-non-empty" "expected 1 finding, got $c0_count"
fi

# ── F2 regression lock — path containing ' b/' and a rename ──────────────────────────────────
# git-log-tricky-path.txt has two raw entries:
#   (1) modified file "foo b/bar.txt" — the path contains the literal " b/" substring
#       that old in-band ` b/` splitting would have corrupted to "bar.txt".
#   (2) rename "old name.txt" → "new dir/new name.txt" (R100 status, two NUL-delimited paths;
#       script must take the DESTINATION — the last path).
# Assert the file fields are the FULL correct paths from git's machine channel.
run_case "tricky-path:whole-object" \
  "$LR_DIR/git-log-tricky-path.txt" - \
  "$EXPECTED_DIR/tricky-path.json"

tricky_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-tricky-path.txt" 2>/dev/null)"

# The path containing " b/" must be the FULL path, not a " b/"-split fragment.
assert_finding_field "tricky-path:space-b-path" "$tricky_ledger" \
  "fix:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:foo b/bar.txt:5" "file" '"foo b/bar.txt"'

# The rename destination must be the NEW path (second NUL token), not the old path.
assert_finding_field "tricky-path:rename-destination" "$tricky_ledger" \
  "fix:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:new dir/new name.txt:1" "file" \
  '"new dir/new name.txt"'

# ── Live-parse-failed fail-CLOSED regression lock ────────────────────────────────────────────
# Lock the RS-001 live fail-closed rule: a NON-EMPTY live payload with no \x1eCOMMIT\x1f
# record marker (structurally-broken git output) must emit LEDGERRECON_ERROR=live-parse-failed
# on stderr and exit non-zero — never silently degrade to an empty "no prior fixes" ledger.
#
# Seam: LEDGERRECON_TEST_LIVE_PAYLOAD_FILE feeds a file into the LIVE branch's stream_git_log
# (the env var replaces `git log` with `cat <file>`) — mirrors FETCHNORM_LIVE_* pattern.
# This reaches the live-parse-failed gate in ledger-reconstruct.sh (§4), which the injected
# --git-log-file path (INJECTED=1) never reaches (it is fail-open by design).
# The malformed fixture is non-empty and carries no \x1eCOMMIT\x1f marker — exact repro.
live_pf_stderr="$(LEDGERRECON_TEST_LIVE_PAYLOAD_FILE="$LR_DIR/git-log-malformed.txt" \
  bash "$SCRIPT_UNDER_TEST" origin/main 2>&1 >/dev/null)"
live_pf_status=$?
if [ "$live_pf_status" -ne 0 ] && \
   printf '%s' "$live_pf_stderr" | grep -qF "LEDGERRECON_ERROR=live-parse-failed"; then
  pass "live-parse-failed:exit-nonzero-and-marker" \
    "(exit=$live_pf_status marker=LEDGERRECON_ERROR=live-parse-failed)"
else
  failed "live-parse-failed:exit-nonzero-and-marker" \
    "(exit=$live_pf_status stderr=$live_pf_stderr)"
fi

# Contrast: injected --git-log-file with the same malformed payload is FAIL-OPEN (exit 0).
# This confirms the two paths are distinct: live=fail-closed, injected=fail-open.
inj_raw="$(bash "$SCRIPT_UNDER_TEST" --git-log-file "$LR_DIR/git-log-malformed.txt" 2>/dev/null)"
inj_status=$?
if [ "$inj_status" -eq 0 ]; then
  pass "live-parse-failed:injected-contrast-exit0" \
    "(injected path stays fail-open, exit=$inj_status)"
else
  failed "live-parse-failed:injected-contrast-exit0" \
    "(expected exit 0 for injected fail-open, got $inj_status)"
fi

# ── Prior-fix qualification gate regression locks ────────────────────────────────────────────
# Lock A — non-remediation feature churn must NOT produce prior-fix findings (the false-cycling
# P1 the positive-allowlist gate closes). Two non-remediation commits (feat + test) touch the
# same file:line surface; expected: zero findings (the gate admits neither commit).
run_case "qualify:feature-churn-not-prior-fix" \
  "$LR_DIR/git-log-feature-churn.txt" - \
  "$EXPECTED_DIR/feature-churn-empty.json"

feature_churn_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-feature-churn.txt" 2>/dev/null)"

churn_count="$(printf '%s' "$feature_churn_ledger" | jq '.iterations[0].findings | length' 2>/dev/null)"
if [ "$churn_count" = "0" ]; then
  pass "qualify:feature-churn-findings-empty" "(findings|length=0; non-remediation commits excluded)"
else
  failed "qualify:feature-churn-findings-empty" "expected 0 findings, got $churn_count"
fi

# Lock B — mixed branch: ONLY a deterministic review-loop remediation commit (the literal
# "address review feedback" subject) becomes a prior-fix finding. The gate keys on that phrase
# ALONE, never on the bare conventional `fix:`/`hotfix:` type, so an ordinary engineer bug-fix
# made BEFORE the review loop cannot drive false mutation-decay / cluster signals (PR #223 P1).
# Fixture has 3 commits: feat (excluded) + fix(scope): address review feedback (QUALIFIES) +
# fix(parser): correct off-by-one (an ordinary dev bug-fix — EXCLUDED, the regression this
# lock guards). Expected: exactly ONE finding, for the review-loop commit only.
run_case "qualify:genuine-fix-detected" \
  "$LR_DIR/git-log-mixed-feature-and-fix.txt" - \
  "$EXPECTED_DIR/mixed-feature-and-fix.json"

mixed_ledger="$(bash "$SCRIPT_UNDER_TEST" \
  --git-log-file "$LR_DIR/git-log-mixed-feature-and-fix.txt" 2>/dev/null)"

# The review-loop remediation surface is present with correct fix_commit/file/status.
assert_finding_field "qualify:fix-scope-present" "$mixed_ledger" \
  "fix:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2:src/api.py:20" "fix_commit" \
  '"b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"'
assert_finding_field "qualify:fix-scope-file" "$mixed_ledger" \
  "fix:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2:src/api.py:20" "file" '"src/api.py"'
assert_finding_field "qualify:fix-scope-status" "$mixed_ledger" \
  "fix:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2:src/api.py:20" "status" '"fixed"'

# The ordinary dev `fix(parser): correct off-by-one` commit MUST be absent — it carries no
# "address review feedback" phrase, so the gate excludes it by construction.
parser_present="$(printf '%s' "$mixed_ledger" | jq -c \
  '[.iterations[0].findings[] | select(.fix_commit == "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3")] | length' 2>/dev/null)"
if [ "$parser_present" = "0" ]; then
  pass "qualify:ordinary-dev-fix-excluded" "(fix(parser) ordinary bug-fix excluded; no review-loop phrase)"
else
  failed "qualify:ordinary-dev-fix-excluded" "expected ordinary dev fix excluded, found $parser_present finding(s)"
fi

# Total: exactly 1 finding (feat excluded, ordinary dev fix excluded, only review-loop commit present).
mixed_count="$(printf '%s' "$mixed_ledger" | jq '.iterations[0].findings | length' 2>/dev/null)"
if [ "$mixed_count" = "1" ]; then
  pass "qualify:mixed-findings-count" "(findings|length=1; only the review-loop remediation commit present)"
else
  failed "qualify:mixed-findings-count" "expected 1 finding, got $mixed_count"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────────────────
echo
echo "ledger-reconstruct: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
