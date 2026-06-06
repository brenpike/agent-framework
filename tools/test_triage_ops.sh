#!/usr/bin/env bash
#
# Behavioral unit runner for the triage MECHANISM substrate (triage-backlog skill, STEP-002).
#
# OFFLINE jq/bash TEST — CI-runnable with ONLY jq + bash present (NO gh / network / auth). It
# drives the pure transform core of:
#   plugin/skills/triage-backlog/scripts/triage-ops.sh
# via its documented offline seam (TRIAGE_OPS_OFFLINE=1 + the injection flags
# --current-labels-file / --response-file / --targets), feeds canned fixtures from
# tests/triage-backlog/, and asserts the emitted JSON equals a golden fixture under
# tests/triage-backlog/expected/. Each transform (triage_palette, compute_mutex_delta,
# build_deps_add_payload, surface_dep_response, normalize_deps_read, list-issues identity) is a
# PURE function of its injected input, so every case is deterministic and offline.
#
# Comparison is canonicalized (object keys sorted via -S, arrays deep-sorted) so jq key/element
# ordering can never flake the match. The palette shape cases assert structural invariants
# (family/value counts = 36 labels, every color a 6-hex string) rather than a frozen golden, so a
# deliberate color re-shade does not falsely fail while a count drift still does.
#
# Mirrors tools/test_fetch_normalize.sh's pass/fail counter + per-case assertion + helper-fn +
# exit-nonzero-on-any-fail + scratch-tmpdir-on-trap conventions. Read-only: the only writes are
# scratch files in a disposable tmpdir removed on EXIT.
#
# Usage:
#   ./tools/test_triage_ops.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OPS="$REPO_ROOT/plugin/skills/triage-backlog/scripts/triage-ops.sh"
TB_DIR="$REPO_ROOT/tests/triage-backlog"
EXPECTED_DIR="$TB_DIR/expected"

[ -f "$OPS" ] || { echo "FAIL: script under test missing: $OPS" >&2; exit 2; }
[ -d "$TB_DIR" ] || { echo "FAIL: triage-backlog fixture dir missing: $TB_DIR" >&2; exit 2; }
[ -d "$EXPECTED_DIR" ] || { echo "FAIL: expected-output dir missing: $EXPECTED_DIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this suite" >&2; exit 2; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# canon: deep-canonicalize one JSON value into a single deterministic line. Sort object keys (-S)
# and recursively sort every array, so neither key order nor array element order can flake an
# exact-match comparison. (The script already `unique`s its delta arrays, but deep-sorting here
# makes the test robust to any future ordering change in the transform.)
canon() {
  jq -S -c '
    def deepsort:
      if type == "array" then map(deepsort) | sort
      elif type == "object" then map_values(deepsort)
      else . end;
    deepsort'
}

# run_case <case> <expected-fixture-abspath> -- <ops-arg...>
# Invoke triage-ops.sh under the OFFLINE seam with the given args, canonicalize stdout, and
# exact-match against the canonicalized expected fixture. A nonzero exit, empty, or mismatched
# output fails the case loudly.
run_case() {
  local case_name="$1" expected_fix="$2"; shift 2
  [ "$1" = "--" ] && shift
  if [ ! -f "$expected_fix" ]; then failed "$case_name" "expected fixture missing: $expected_fix"; return; fi

  local expected actual
  if ! expected="$(canon < "$expected_fix")"; then
    failed "$case_name" "could not canonicalize expected fixture $expected_fix"
    return
  fi
  if ! actual="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" "$@" 2>/dev/null | canon)"; then
    failed "$case_name" "triage-ops failed (args: $*)"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    pass "$case_name" "($(basename "$expected_fix"))"
  else
    failed "$case_name" "(args: $*)
    expected: $expected
    actual:   $actual"
  fi
}

# run_exit0_case <case> -- <ops-arg...>
# Like run_case but ONLY asserts the script exited 0 (no pipe masking status). Used to lock the
# cycle-rejection-must-not-crash invariant: a GraphQL cycle response surfaces a warning record AND
# exits 0 so a batch keeps going. Captures status WITHOUT a pipe.
run_exit0_case() {
  local case_name="$1"; shift
  [ "$1" = "--" ] && shift
  local out status
  out="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" "$@" 2>/dev/null)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "$case_name" "exit=0 (args: $*)"
  else
    failed "$case_name" "expected exit 0, got $status (args: $*; stdout: $out)"
  fi
}

# run_exit1_case <case> -- <ops-arg...>
# Asserts the script exited NONZERO (fail-closed). Used to lock the deps-add
# fail-closed invariant: a non-cycle GraphQL error, an empty/non-JSON transport
# error, or a malformed-success response MUST surface as nonzero so the caller
# never proceeds as if a dependency edge were written. Captures status WITHOUT a
# pipe so the exit code is the script's own, not jq's.
run_exit1_case() {
  local case_name="$1"; shift
  [ "$1" = "--" ] && shift
  local out status
  out="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" "$@" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    pass "$case_name" "exit=$status (args: $*)"
  else
    failed "$case_name" "expected nonzero exit, got 0 (args: $*; stdout: $out)"
  fi
}

# ── Palette shape + idempotence ───────────────────────────────────────────────────
# ensure-labels offline emits the baked palette JSON. Assert the family/value census (36 labels:
# readiness 9, type 8, effort 5, moscow 4, priority/risk/difficulty 3 each, control 1) so a label
# add/drop is caught, and assert every color is a 6-hex string so a malformed color is caught.
PALETTE="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" ensure-labels 2>/dev/null)"

assert_jq() {
  local case_name="$1" filter="$2"
  if printf '%s' "$PALETTE" | jq -e "$filter" >/dev/null 2>&1; then
    pass "$case_name" "$filter"
  else
    failed "$case_name" "palette assertion failed: $filter"
  fi
}

assert_jq "palette:total-36"        'length == 36'
assert_jq "palette:readiness-9"     '[.[] | select(.family=="readiness")] | length == 9'
assert_jq "palette:type-8"          '[.[] | select(.family=="type")] | length == 8'
assert_jq "palette:effort-5"        '[.[] | select(.family=="effort")] | length == 5'
assert_jq "palette:moscow-4"        '[.[] | select(.family=="moscow")] | length == 4'
assert_jq "palette:priority-3"      '[.[] | select(.family=="priority")] | length == 3'
assert_jq "palette:risk-3"          '[.[] | select(.family=="risk")] | length == 3'
assert_jq "palette:difficulty-3"    '[.[] | select(.family=="difficulty")] | length == 3'
assert_jq "palette:control-1"       '[.[] | select(.family=="control")] | length == 1'
assert_jq "palette:color-hex6"      'all(.[]; .color | test("^[0-9a-fA-F]{6}$"))'
# Control label triage:locked is the single human-only unmanaged label — it must exist (ensured)
# but be marked managed:false so the mutex reconcile can never select it.
assert_jq "palette:locked-unmanaged" 'any(.[]; .name=="triage:locked" and .managed==false)'
# Idempotence/determinism: a second offline emit is byte-identical to the first (no nondeterminism).
PALETTE2="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" ensure-labels 2>/dev/null)"
if [ "$(printf '%s' "$PALETTE" | canon)" = "$(printf '%s' "$PALETTE2" | canon)" ]; then
  pass "palette:idempotent-emit" "two emits identical"
else
  failed "palette:idempotent-emit" "two ensure-labels emits diverged"
fi

# ── Per-family mutex delta (remove-all-then-set) ──────────────────────────────────
# A conflicting duplicate (priority:low + priority:medium) with target priority:high: the delta
# REMOVES both stale priority values and ADDS priority:high. Foreign labels (initiative:foo,
# triage:locked) are present in the current set but MUST NOT appear in remove.
run_case "mutex:priority-conflict" "$EXPECTED_DIR/delta-priority-conflict.json" -- \
  apply-labels 7 --targets '{"priority":"high"}' \
  --current-labels-file "$TB_DIR/current-priority-conflict.json"

# ── Idempotent no-op ──────────────────────────────────────────────────────────────
# Current value already equals the target (priority:high): the family contributes NO remove and NO
# add — low-churn stability (already-correct value is not removed-and-re-added).
run_case "mutex:noop-already-correct" "$EXPECTED_DIR/delta-priority-noop.json" -- \
  apply-labels 7 --targets '{"priority":"high"}' \
  --current-labels-file "$TB_DIR/current-priority-noop.json"

# ── Multi-family + foreign-label safety ───────────────────────────────────────────
# Three target families at once; current set carries stale values, an already-correct value
# (readiness:ready), and foreign labels (initiative:alpha, wontfix, custom:thing, triage:locked).
# Golden delta proves: stale priority/type removed, new values added, readiness:ready is a no-op,
# and NO foreign label is in remove.
run_case "mutex:multi-foreign" "$EXPECTED_DIR/delta-multi-foreign.json" -- \
  apply-labels 12 --targets '{"priority":"high","type":"bug","readiness":"ready"}' \
  --current-labels-file "$TB_DIR/current-multi-foreign.json"

# Direct foreign-safety assertion: NO non-family / initiative / triage:locked label may ever be in
# the remove set, across the multi-family delta. Locks the foreign-label + triage:locked invariants
# independently of the golden file.
FOREIGN_DELTA="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" apply-labels 12 \
  --targets '{"priority":"high","type":"bug","readiness":"ready"}' \
  --current-labels-file "$TB_DIR/current-multi-foreign.json" 2>/dev/null)"
if printf '%s' "$FOREIGN_DELTA" | jq -e '
    .remove as $r
    | ([ "initiative:alpha", "wontfix", "custom:thing", "triage:locked" ]
       | all(. as $f | ($r | index($f)) == null))' >/dev/null 2>&1; then
  pass "mutex:foreign-never-removed" "no foreign/locked label in remove set"
else
  failed "mutex:foreign-never-removed" "a foreign or triage:locked label leaked into remove (delta: $FOREIGN_DELTA)"
fi

# ── Foreign label sharing a MANAGED family prefix is never removed ────────────────
# Regression for the palette-bounded remove set: a non-palette label that shares a
# managed family prefix (priority:customer under target priority:high, and
# type:legal-hold) must NOT be scheduled for removal. Only the palette-managed
# stale value (priority:low) is removed. Removing on prefix alone would clobber
# human/project labels — the contract says foreign labels are invisible.
run_case "mutex:foreign-prefix-not-removed" "$EXPECTED_DIR/delta-priority-foreign-prefix.json" -- \
  apply-labels 9 --targets '{"priority":"high"}' \
  --current-labels-file "$TB_DIR/current-priority-foreign-prefix.json"

# ── apply-labels: live path rejects --current-labels-file (security regression) ──
# STEP-R001 fix: a LIVE (non-offline) invocation supplying --current-labels-file MUST
# be rejected fail-closed (exit 2) BEFORE any gh call — the flag is a test seam only.
# Supplying it live would let a caller spoof the label set and bypass triage:locked.
# No TRIAGE_OPS_OFFLINE — this runs in live mode. The die fires before require_gh,
# so no gh dependency and the result is deterministic.
LIVE_STATUS=0
bash "$OPS" apply-labels 9 \
  --current-labels-file "$TB_DIR/current-priority-foreign-prefix.json" \
  --targets '{"priority":"high"}' >/dev/null 2>&1 || LIVE_STATUS=$?
if [ "$LIVE_STATUS" -ne 0 ]; then
  pass "apply-labels:live-current-labels-file-rejected" "exit=$LIVE_STATUS (expected nonzero)"
else
  failed "apply-labels:live-current-labels-file-rejected" "expected nonzero exit, got 0 (live path must reject --current-labels-file)"
fi

# ── deps-add GraphQL payload shape ────────────────────────────────────────────────
# Offline deps-add WITHOUT --response-file builds the GraphQL variables payload. Assert the exact
# variable keys (issueId, blockedByIssueId) with node ids passed through as DATA.
run_case "deps-add:payload-shape" "$EXPECTED_DIR/deps-add-payload.json" -- \
  deps-add --issue-id I_aaa --blocked-by-id I_bbb

# Direct key-set assertion: the payload has EXACTLY {issueId, blockedByIssueId} — no extra/missing
# variable keys (a drift in the mutation variable contract is caught).
PAYLOAD="$(TRIAGE_OPS_OFFLINE=1 bash "$OPS" deps-add --issue-id I_aaa --blocked-by-id I_bbb 2>/dev/null)"
if printf '%s' "$PAYLOAD" | jq -e '(keys | sort) == ["blockedByIssueId","issueId"]' >/dev/null 2>&1; then
  pass "deps-add:payload-key-set" "keys == issueId + blockedByIssueId"
else
  failed "deps-add:payload-key-set" "unexpected payload key set (payload: $PAYLOAD)"
fi

# ── Cycle-rejection surfacing (must not crash) ────────────────────────────────────
# A canned GraphQL cycle-rejection response via --response-file surfaces a structured WARNING record
# (status warning, kind cycle-rejected) AND the script exits 0 — a rejected dependency never crashes
# the batch.
run_case "deps-add:cycle-surface" "$EXPECTED_DIR/deps-add-cycle.json" -- \
  deps-add --response-file "$TB_DIR/deps-add-cycle-response.json"
run_exit0_case "deps-add:cycle-exit0" -- \
  deps-add --response-file "$TB_DIR/deps-add-cycle-response.json"

# ── deps-add FAIL-CLOSED on non-cycle / transport / malformed responses ───────────
# A non-cycle GraphQL error (auth/permission), an empty/non-JSON transport error, and
# a malformed-success body each MUST surface as a NONZERO exit so the caller never
# treats a failed dependency write as handled. Only the cycle rejection above is the
# recoverable exit-0 warning.
run_exit1_case "deps-add:noncycle-error-exit1" -- \
  deps-add --response-file "$TB_DIR/deps-add-noncycle-error-response.json"
run_exit1_case "deps-add:empty-transport-exit1" -- \
  deps-add --response-file "$TB_DIR/deps-add-empty-response.json"
run_exit1_case "deps-add:malformed-success-exit1" -- \
  deps-add --response-file "$TB_DIR/deps-add-malformed-success-response.json"

# ── deps-read normalize + list-issues identity ────────────────────────────────────
# A canned blockedByIssues GraphQL response normalizes into the stable deps-read schema.
run_case "deps-read:normalize" "$EXPECTED_DIR/deps-read-normalized.json" -- \
  deps-read 5 --response-file "$TB_DIR/deps-read-response.json"

# list-issues offline re-emits the injected response verbatim (identity pass-through).
run_case "list-issues:identity" "$EXPECTED_DIR/list-issues-identity.json" -- \
  list-issues --response-file "$TB_DIR/list-issues-response.json"

# ── Summary ───────────────────────────────────────────────────────────────────────
echo
echo "triage-ops: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
