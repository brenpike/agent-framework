#!/usr/bin/env bash
#
# Behavioral unit runner for the non-thread EYES reaction marker (issue #265).
#
# OFFLINE bash TEST — CI-runnable with ONLY bash present (NO tmux / gh / network). It drives:
#   plugin/skills/github-review-loop/scripts/react-marker.sh
# via its documented CAPTURE seam (REACTMARKER_TEST_MODE=1 + REACTMARKER_CAPTURE_FILE, which records
# each reaction to a file INSTEAD of issuing it against gh) plus the REACTMARKER_REACT_STATUS
# exit-status seam (to simulate a failed live mutation). Every case asserts the captured reaction log
# (line format: REACT node=<NODE_ID> content=EYES) and the script's own exit status / REACTMARKER_ERROR
# reason token, so each case is deterministic and offline.
#
# Mirrors tools/test_reply_resolve.sh's pass/fail counter + per-case assertion + exit-nonzero-on-any
# -fail convention. Read-only: the only writes are scratch capture files in a disposable tmpdir
# removed on EXIT.
#
# Production-shaped node ids are used deliberately (IC_... for toplevel IssueComment, PRR_... for a
# review PullRequestReview) — NOT fake placeholder ids — so validation-order bugs cannot hide behind
# a non-production shape.
#
# Usage:
#   ./tools/test_react_marker.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REACT_MARKER="$REPO_ROOT/plugin/skills/github-review-loop/scripts/react-marker.sh"

[ -f "$REACT_MARKER" ] || { echo "FAIL: script under test missing: $REACT_MARKER" >&2; exit 2; }

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

# Real production-shaped reviewer node ids. IC_ = toplevel IssueComment; PRR_ = review PullRequestReview.
TOPLEVEL_NODE="IC_kwDOABCDEF4AbCdEf"
REVIEW_NODE="PRR_kwDOABCDEF4AbCdEf"

# ── toplevel surface reacts with EYES over a real IC_ node ──────────────────────────
# A toplevel IssueComment is Reactable: exactly ONE capture line `REACT node=IC_... content=EYES`,
# exit 0.
cap="$(fresh_capture toplevel)"
out="$(REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$cap" \
  bash "$REACT_MARKER" "$TOPLEVEL_NODE" toplevel "https://github.com/o/r/pull/5#issuecomment-1" 2>&1)"
status=$?
line_count="$(grep -c '^REACT ' "$cap")"
if [ "$status" -eq 0 ] && [ "$line_count" -eq 1 ] \
   && grep -qx "REACT node=$TOPLEVEL_NODE content=EYES" "$cap"; then
  pass "toplevel:react-eyes" "one REACT line for IC_ node, content=EYES, exit 0"
else
  failed "toplevel:react-eyes" "status=$status line_count=$line_count cap=$(cat "$cap") out=$out"
fi

# ── review surface reacts with EYES over a real PRR_ node ───────────────────────────
# A review PullRequestReview is also Reactable: exactly ONE capture line
# `REACT node=PRR_... content=EYES`, exit 0.
cap="$(fresh_capture review)"
out="$(REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$cap" \
  bash "$REACT_MARKER" "$REVIEW_NODE" review "https://github.com/o/r/pull/5#pullrequestreview-9" 2>&1)"
status=$?
line_count="$(grep -c '^REACT ' "$cap")"
if [ "$status" -eq 0 ] && [ "$line_count" -eq 1 ] \
   && grep -qx "REACT node=$REVIEW_NODE content=EYES" "$cap"; then
  pass "review:react-eyes" "one REACT line for PRR_ node, content=EYES, exit 0"
else
  failed "review:react-eyes" "status=$status line_count=$line_count cap=$(cat "$cap") out=$out"
fi

# ── thread surface is a SILENT NO-OP (#265) ─────────────────────────────────────────
# Threads converge via reply-resolve.sh's resolveReviewThread; react-marker NEVER reacts to a thread
# node: ZERO capture lines, zero stdout, exit 0. (NODE_ID is supplied to prove the no-op is
# surface-driven, not input-driven.)
cap="$(fresh_capture thread)"
out="$(REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$cap" \
  bash "$REACT_MARKER" "$TOPLEVEL_NODE" thread "https://github.com/o/r/pull/5#discussion_r1" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && [ ! -s "$cap" ] && [ -z "$out" ]; then
  pass "thread:silent-no-op" "no reaction captured, zero stdout, exit 0"
else
  failed "thread:silent-no-op" "status=$status cap=$(cat "$cap") out=$out"
fi

# ── unmapped surface fails CLOSED (no reaction issued) ──────────────────────────────
# An unknown surface (e.g. `bogus`) is not in the surface->delivery map: REACTMARKER_ERROR=
# unmapped-surface, exit non-zero, and NO reaction captured (dispatch never falls back to react).
cap="$(fresh_capture badsurface)"
out="$(REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$cap" \
  bash "$REACT_MARKER" "$TOPLEVEL_NODE" bogus "" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qx 'REACTMARKER_ERROR=unmapped-surface' \
   && [ ! -s "$cap" ]; then
  pass "badsurface:unmapped-surface" "exit=$status REACTMARKER_ERROR=unmapped-surface, no reaction"
else
  failed "badsurface:unmapped-surface" "status=$status out=$out cap=$(cat "$cap")"
fi

# ── missing node id on a mutating surface fails CLOSED ──────────────────────────────
# An empty NODE_ID ($1) on a mutating surface (toplevel) trips the surface-scoped required-input
# guard: REACTMARKER_ERROR=missing-node-id, exit non-zero, no reaction captured.
cap="$(fresh_capture missingnode)"
out="$(REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$cap" \
  bash "$REACT_MARKER" "" toplevel "https://github.com/o/r/pull/5#issuecomment-1" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qx 'REACTMARKER_ERROR=missing-node-id' \
   && [ ! -s "$cap" ]; then
  pass "missingnode:missing-node-id" "exit=$status REACTMARKER_ERROR=missing-node-id, no reaction"
else
  failed "missingnode:missing-node-id" "status=$status out=$out cap=$(cat "$cap")"
fi

# ── react mutation failure is a HARD failure ────────────────────────────────────────
# A failed REACT (simulated via REACTMARKER_REACT_STATUS=1 under the capture seam, which returns that
# status from run_reaction) routes through react_marker_fail: REACTMARKER_ERROR=react-failed, exit
# non-zero. The capture line is still written (the seam appends BEFORE returning the forced status),
# so the failure is on the mutation result, not the dispatch.
cap="$(fresh_capture reactfail)"
out="$(REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$cap" REACTMARKER_REACT_STATUS=1 \
  bash "$REACT_MARKER" "$TOPLEVEL_NODE" toplevel "https://github.com/o/r/pull/5#issuecomment-1" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qx 'REACTMARKER_ERROR=react-failed'; then
  pass "reactfail:react-failed" "exit=$status REACTMARKER_ERROR=react-failed"
else
  failed "reactfail:react-failed" "status=$status out=$out cap=$(cat "$cap")"
fi

# ── Fail-closed gate lock: CAPTURE_FILE WITHOUT TEST_MODE does NOT divert ────────────
# The capture seam requires BOTH REACTMARKER_TEST_MODE=1 AND REACTMARKER_CAPTURE_FILE. A stray
# CAPTURE_FILE ALONE must NOT divert — the mutation goes LIVE to gh. We assert the gate's observable
# contract: with TEST_MODE absent the capture file is NEVER written (the seam stayed inactive and the
# code fell through to the live path). NOTE: TEST_MODE is deliberately UNSET here.
#
# OFFLINE INVARIANT: with TEST_MODE unset, run_reaction falls through to the LIVE `gh api graphql`
# path. Without a stub that would invoke the REAL gh CLI when present (network call / 45s timeout)
# despite this suite being offline. We prepend a stub `gh` to PATH that records it was reached
# (proving the code went live) and exits non-zero, so no real CLI runs. Asserting the stub was
# reached AND the capture file stayed empty locks BOTH halves of the contract: the seam did NOT
# divert (cap empty) and the live path WAS taken (stub reached).
cap="$(fresh_capture nodivert)"
gh_stub_dir="$TMPDIR_TEST/nodivert-stubbin"
gh_stub_marker="$TMPDIR_TEST/nodivert-gh-reached"
mkdir -p "$gh_stub_dir"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf reached > %q\n' "$gh_stub_marker"
  printf '%s\n' 'exit 1'
} > "$gh_stub_dir/gh"
chmod +x "$gh_stub_dir/gh"
PATH="$gh_stub_dir:$PATH" REACTMARKER_CAPTURE_FILE="$cap" \
  bash "$REACT_MARKER" "$TOPLEVEL_NODE" toplevel "https://github.com/o/r/pull/5#issuecomment-1" >/dev/null 2>&1
if [ ! -s "$cap" ] && [ -f "$gh_stub_marker" ]; then
  pass "failclosed:capture-without-testmode-no-divert" "CAPTURE_FILE alone did NOT divert (cap empty); live gh path reached (stub invoked)"
else
  failed "failclosed:capture-without-testmode-no-divert" "diverted or live-path-not-reached — cap=$(cat "$cap") stub_reached=$([ -f "$gh_stub_marker" ] && echo yes || echo no)"
fi

# ── Capture-append failure is a HARD failure, NOT a false success (#265 regression) ──
# When the seam is ACTIVE (TEST_MODE=1 + CAPTURE_FILE) but the capture path is UNWRITABLE, the append
# fails. With set -e deliberately omitted (P18 floor), an UNGUARDED append would be silently ignored
# and run_reaction would still return the default-0 simulated status — reporting marker SUCCESS while
# NOTHING was captured and the live gh mutation was bypassed. The `|| return 1` guard converts that
# into react-failed. Assert: exit non-zero, REACTMARKER_ERROR=react-failed, and the live gh path is
# NOT reached (a stub gh on PATH must stay un-invoked — the seam stayed engaged and hard-failed on
# the append, never falling through to live). REACTMARKER_REACT_STATUS is left at its default 0 so
# the ONLY failure source under test is the append itself.
#
# The write must fail INDEPENDENT of permissions: `chmod 000` does not stop root (the validation
# suite runs as root in the container), so a permission-based unwritable dir would let the append
# SUCCEED and silently invert this assertion. Instead point the capture file under a NONEXISTENT
# parent — the `>>` redirect then fails with ENOENT for every user, root included.
bad_cap="$TMPDIR_TEST/nonexistent-parent-dir/cap.log"
gh_stub_dir2="$TMPDIR_TEST/capfail-stubbin"
gh_stub_marker2="$TMPDIR_TEST/capfail-gh-reached"
mkdir -p "$gh_stub_dir2"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf reached > %q\n' "$gh_stub_marker2"
  printf '%s\n' 'exit 0'
} > "$gh_stub_dir2/gh"
chmod +x "$gh_stub_dir2/gh"
out="$(PATH="$gh_stub_dir2:$PATH" REACTMARKER_TEST_MODE=1 REACTMARKER_CAPTURE_FILE="$bad_cap" \
  bash "$REACT_MARKER" "$TOPLEVEL_NODE" toplevel "https://github.com/o/r/pull/5#issuecomment-1" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qx 'REACTMARKER_ERROR=react-failed' \
   && [ ! -f "$gh_stub_marker2" ]; then
  pass "capfail:append-failure-hard-fails" "unwritable capture -> exit=$status REACTMARKER_ERROR=react-failed, live gh NOT reached"
else
  failed "capfail:append-failure-hard-fails" "status=$status out=$out gh_reached=$([ -f "$gh_stub_marker2" ] && echo yes || echo no)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────
echo
echo "react-marker: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
