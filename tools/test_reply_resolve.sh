#!/usr/bin/env bash
#
# Behavioral unit runner for the reply + resolve mutation-sequence builder (issue #205).
#
# OFFLINE bash TEST — CI-runnable with ONLY bash present (NO tmux / gh / network). It drives:
#   plugin/skills/github-review-loop/scripts/reply-resolve.sh
# via its documented CAPTURE seam (REPLYRESOLVE_CAPTURE_FILE, which records each mutation to a file
# INSTEAD of issuing it against gh) plus the REPLYRESOLVE_REPLY_STATUS / REPLYRESOLVE_RESOLVE_STATUS
# exit-status seams (to simulate a failed reply / failed resolve). Every case asserts the captured
# mutation log and the script's own exit status, so each case is deterministic and offline.
#
# Mirrors tools/test_fetch_normalize.sh's pass/fail counter + per-case assertion + exit-nonzero-on-any
# -fail convention. Read-only: the only writes are scratch capture files in a disposable tmpdir
# removed on EXIT.
#
# Usage:
#   ./tools/test_reply_resolve.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPLY_RESOLVE="$REPO_ROOT/plugin/skills/github-review-loop/scripts/reply-resolve.sh"

[ -f "$REPLY_RESOLVE" ] || { echo "FAIL: script under test missing: $REPLY_RESOLVE" >&2; exit 2; }

TMPDIR_TEST="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# fresh_capture <name>: return a path to a fresh, empty capture file under the tmpdir.
fresh_capture() {
  local f="$TMPDIR_TEST/$1.log"
  : > "$f"
  printf '%s' "$f"
}

# ── reply-then-resolve happy path (ordering) ───────────────────────────────────────
# A thread surface, resolve-eligible: the REPLY line must precede the RESOLVE line, and both target
# the thread id. Exit 0.
cap="$(fresh_capture happy)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" --resolve-eligible -- PRRT_aaa abc123 "Fixed the null deref" thread "" 2>&1)"
status=$?
reply_line="$(grep -n '^REPLY ' "$cap" | head -n1 | cut -d: -f1)"
resolve_line="$(grep -n '^RESOLVE ' "$cap" | head -n1 | cut -d: -f1)"
if [ "$status" -eq 0 ] && [ -n "$reply_line" ] && [ -n "$resolve_line" ] && [ "$reply_line" -lt "$resolve_line" ]; then
  pass "happy:reply-before-resolve" "REPLY(line $reply_line) precedes RESOLVE(line $resolve_line), exit 0"
else
  failed "happy:reply-before-resolve" "status=$status reply_line=$reply_line resolve_line=$resolve_line cap=$(cat "$cap") out=$out"
fi
# Reply body format for a thread surface: "Fixed in <SHA>. <summary>." with NO Addresses line.
if grep -q '^REPLY thread=PRRT_aaa body=Fixed in abc123\. Fixed the null deref\.$' "$cap"; then
  pass "happy:reply-body-thread" "thread reply body exact"
else
  failed "happy:reply-body-thread" "body mismatch: $(grep '^REPLY' "$cap")"
fi

# ── resolve-skip when an unaddressed non-self comment remains ───────────────────────
# The caller signals "not all addressed" by OMITTING --resolve-eligible. The reply is still posted;
# NO resolve is issued. Exit 0.
cap="$(fresh_capture unaddressed)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" -- PRRT_bbb def456 "Partial fix" thread "" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && grep -q '^REPLY ' "$cap" && ! grep -q '^RESOLVE ' "$cap"; then
  pass "skip:unaddressed-no-resolve" "reply posted, NO resolve, exit 0"
else
  failed "skip:unaddressed-no-resolve" "status=$status cap=$(cat "$cap") out=$out"
fi

# ── question-needs-user-input is NEVER resolved ─────────────────────────────────────
# Even with --resolve-eligible, the --question-needs-user-input marker hard-blocks resolve. The reply
# is still posted. Exit 0.
cap="$(fresh_capture question)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" --resolve-eligible --question-needs-user-input -- \
  PRRT_ccc ghi789 "Replied but awaiting answer" thread "" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && grep -q '^REPLY ' "$cap" && ! grep -q '^RESOLVE ' "$cap"; then
  pass "question:never-resolved" "reply posted, NO resolve despite eligible, exit 0"
else
  failed "question:never-resolved" "status=$status cap=$(cat "$cap") out=$out"
fi

# ── resolve-failure is non-blocking ────────────────────────────────────────────────
# A failed RESOLVE (simulated via REPLYRESOLVE_RESOLVE_STATUS=1) logs the REPLYRESOLVE_RESOLVE_FAILED
# diagnostic to stderr but the script STILL exits 0 — the reply landed and the candidate succeeded.
cap="$(fresh_capture resolvefail)"
err="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" REPLYRESOLVE_RESOLVE_STATUS=1 \
  bash "$REPLY_RESOLVE" --resolve-eligible -- PRRT_ddd jkl012 "Fix applied" thread "" 2>&1 1>/dev/null)"
status=$?
if [ "$status" -eq 0 ] && grep -q '^REPLY ' "$cap" && grep -q '^RESOLVE ' "$cap" \
   && printf '%s' "$err" | grep -q "REPLYRESOLVE_RESOLVE_FAILED"; then
  pass "resolvefail:non-blocking" "resolve attempted + failed, diagnostic on stderr, exit 0"
else
  failed "resolvefail:non-blocking" "status=$status cap=$(cat "$cap") err=$err"
fi

# ── reply-failure is a HARD failure (no resolve attempted) ──────────────────────────
# A failed REPLY (simulated via REPLYRESOLVE_REPLY_STATUS=1) exits 1 with REPLYRESOLVE_ERROR=reply
# -failed and NEVER issues a resolve (reply-before-resolve invariant: no orphaned resolve).
cap="$(fresh_capture replyfail)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" REPLYRESOLVE_REPLY_STATUS=1 \
  bash "$REPLY_RESOLVE" --resolve-eligible -- PRRT_eee mno345 "Attempted fix" thread "" 2>/dev/null)"
status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -q '^REPLYRESOLVE_ERROR=reply-failed$' \
   && ! grep -q '^RESOLVE ' "$cap"; then
  pass "replyfail:hard-fail-no-resolve" "exit=$status REPLYRESOLVE_ERROR=reply-failed, no resolve"
else
  failed "replyfail:hard-fail-no-resolve" "status=$status out=$out cap=$(cat "$cap")"
fi

# ── toplevel/review Addresses: body variant ────────────────────────────────────────
# A toplevel surface reply body appends " Addresses: <url>"; NO resolve is ever issued for a non-thread
# surface. Exit 0.
cap="$(fresh_capture toplevel)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" --resolve-eligible -- PRRT_fff pqr678 "Addressed in code" toplevel "https://github.com/o/r/pull/5#issuecomment-1" 2>&1)"
status=$?
if [ "$status" -eq 0 ] \
   && grep -q '^REPLY thread=PRRT_fff body=Fixed in pqr678\. Addressed in code\. Addresses: https://github.com/o/r/pull/5#issuecomment-1$' "$cap" \
   && ! grep -q '^RESOLVE ' "$cap"; then
  pass "toplevel:addresses-variant-no-resolve" "Addresses: line present, NO resolve for non-thread"
else
  failed "toplevel:addresses-variant-no-resolve" "status=$status cap=$(cat "$cap") out=$out"
fi

# review surface also carries the Addresses: line.
cap="$(fresh_capture reviewsurface)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" -- PRRT_ggg stu901 "Summary addressed" review "https://github.com/o/r/pull/5#pullrequestreview-9" 2>&1)"
status=$?
if [ "$status" -eq 0 ] \
   && grep -q '^REPLY thread=PRRT_ggg body=Fixed in stu901\. Summary addressed\. Addresses: https://github.com/o/r/pull/5#pullrequestreview-9$' "$cap" \
   && ! grep -q '^RESOLVE ' "$cap"; then
  pass "review:addresses-variant" "review surface Addresses: line present"
else
  failed "review:addresses-variant" "status=$status cap=$(cat "$cap") out=$out"
fi

# ── input-validation fail-closed (no mutation issued) ──────────────────────────────
# A toplevel surface with NO candidate url is an input error: REPLYRESOLVE_ERROR=missing-candidate-url,
# exit non-zero, and NO mutation captured (validation runs before any mutation).
cap="$(fresh_capture badinput)"
out="$(REPLYRESOLVE_TEST_MODE=1 REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" -- PRRT_hhh vwx234 "No url" toplevel "" 2>/dev/null)"
status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -q '^REPLYRESOLVE_ERROR=missing-candidate-url$' \
   && [ ! -s "$cap" ]; then
  pass "badinput:missing-candidate-url" "exit=$status REPLYRESOLVE_ERROR=missing-candidate-url, no mutation"
else
  failed "badinput:missing-candidate-url" "status=$status out=$out cap=$(cat "$cap")"
fi

# ── Fail-closed gate lock: CAPTURE_FILE WITHOUT TEST_MODE does NOT divert ──────────
# STEP-001 made the capture seam require BOTH REPLYRESOLVE_TEST_MODE=1 AND
# REPLYRESOLVE_CAPTURE_FILE. A stray CAPTURE_FILE ALONE must no longer divert — the
# mutation goes LIVE to gh. Offline we cannot exercise the live gh call, but we CAN
# lock the gate's observable contract: with TEST_MODE absent the capture file is
# NEVER written (the seam stayed inactive and the code fell through to the live
# path). NOTE: TEST_MODE is deliberately UNSET here — the whole point of the case.
cap="$(fresh_capture nodivert)"
REPLYRESOLVE_CAPTURE_FILE="$cap" \
  bash "$REPLY_RESOLVE" --resolve-eligible -- PRRT_iii xyz789 "No test mode" thread "" >/dev/null 2>&1
if [ ! -s "$cap" ]; then
  pass "failclosed:capture-without-testmode-no-divert" "CAPTURE_FILE alone did NOT divert (file unwritten — went live)"
else
  failed "failclosed:capture-without-testmode-no-divert" "seam diverted WITHOUT TEST_MODE — cap=$(cat "$cap")"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────
echo
echo "reply-resolve: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
