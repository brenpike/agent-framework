#!/usr/bin/env bash
#
# Engine behavior test runner for the hivemind workflow engine (plan §J.2).
#
# Executes the REAL deterministic transition engine
# (plugin/skills/record-state-result/scripts/record-state-result.sh) against the
# ledger + workflow-definition fixtures under tests/engine/, in a disposable mktemp
# workdir. NEVER writes a runtime ledger into the repo: every fixture is copied into
# the temp dir, mutated there, and the temp dir is removed on exit.
#
# Assertions (each maps to a fixture under tests/engine/):
#   A. valid transition  -> exit 0, ledger state.current advanced, an event appended.
#   B. illegal --result  -> non-zero exit, ledger byte-UNCHANGED (sha256 compare).
#   C. stale --state     -> non-zero exit, ledger byte-UNCHANGED (state != current).
#   D. terminal target   -> run.status updated to the mapped terminal status.
#   E. atomicity         -> a forced write failure (unwritable target dir) leaves the
#                           prior ledger byte-intact.
#
# Prints PASS/FAIL per assertion. Exits non-zero if ANY assertion FAILs.
#
# Usage:
#   ./tools/test_engine.sh

set -euo pipefail

# ── Path setup ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENGINE="$REPO_ROOT/plugin/skills/record-state-result/scripts/record-state-result.sh"
FIXTURES_DIR="$REPO_ROOT/tests/engine"
WORKFLOW_DEF="$FIXTURES_DIR/workflow-engine-fixture.json"
LEDGER_AT_PLAN="$FIXTURES_DIR/ledger-at-plan.json"
LEDGER_AT_BUILD="$FIXTURES_DIR/ledger-at-build.json"

# ── Dependency / fixture preflight ──────────────────────────────────────────

for dep in jq sha256sum; do
    command -v "$dep" >/dev/null 2>&1 \
        || { echo "FAIL: required dependency '$dep' is not installed" >&2; exit 2; }
done

for required in "$ENGINE" "$WORKFLOW_DEF" "$LEDGER_AT_PLAN" "$LEDGER_AT_BUILD"; do
    [[ -f "$required" ]] \
        || { echo "FAIL: required input missing: $required" >&2; exit 2; }
done

# ── Disposable workdir ──────────────────────────────────────────────────────

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-engine-test.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ── A. valid transition advances + appends event ────────────────────────────

assert_valid_transition() {
    local name="A:valid-transition"
    local ledger="$WORKDIR/a-ledger.json"
    cp "$LEDGER_AT_PLAN" "$ledger"

    local rc=0
    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result ready \
        --summary "engine test valid transition" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc on a legal transition (expected 0)"
        return
    fi

    local current events_len
    current="$(jq -r '.state.current' "$ledger")"
    events_len="$(jq -r '.events | length' "$ledger")"
    if [[ "$current" == "build" && "$events_len" -eq 1 ]]; then
        pass "$name" "state.current advanced plan->build and 1 event appended"
    else
        failed "$name" "expected current=build/events=1, got current=$current/events=$events_len"
    fi
}

# ── B. illegal --result -> non-zero, ledger byte-unchanged ──────────────────

assert_illegal_result_unchanged() {
    local name="B:illegal-result-unchanged"
    local ledger="$WORKDIR/b-ledger.json"
    cp "$LEDGER_AT_PLAN" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result not_a_legal_outcome \
        --summary "engine test illegal result" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "illegal result rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── C. stale --state -> non-zero, ledger byte-unchanged ─────────────────────

assert_stale_state_unchanged() {
    local name="C:stale-state-unchanged"
    local ledger="$WORKDIR/c-ledger.json"
    # Ledger is at state.current=build; pass a stale --state=plan.
    cp "$LEDGER_AT_BUILD" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result ready \
        --summary "engine test stale state" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "stale --state rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── D. terminal target -> run.status updated to mapped terminal status ──────

assert_terminal_status_update() {
    local name="D:terminal-status-update"
    local ledger="$WORKDIR/d-ledger.json"
    # Ledger at build; record done -> complete (a declared terminal).
    cp "$LEDGER_AT_BUILD" "$ledger"
    local rc=0
    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state build \
        --result done \
        --summary "engine test terminal transition" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc recording a terminal transition (expected 0)"
        return
    fi

    local current run_status state_status
    current="$(jq -r '.state.current' "$ledger")"
    run_status="$(jq -r '.run.status' "$ledger")"
    state_status="$(jq -r '.state.status' "$ledger")"
    if [[ "$current" == "complete" && "$run_status" == "complete" && "$state_status" == "complete" ]]; then
        pass "$name" "terminal reached: state.current=complete, run.status=complete"
    else
        failed "$name" "expected complete/complete/complete, got current=$current/run.status=$run_status/state.status=$state_status"
    fi
}

# ── E. atomicity: forced write failure leaves prior ledger byte-intact ──────

assert_atomicity_on_write_failure() {
    local name="E:atomicity-write-failure"
    # The engine writes a temp file beside the ledger via mktemp, then mv. Make the
    # ledger's parent directory unwritable so BOTH the temp-file create and the rename
    # cannot occur — the on-disk ledger must remain byte-intact.
    local subdir="$WORKDIR/e-readonly"
    mkdir -p "$subdir"
    local ledger="$subdir/e-ledger.json"
    cp "$LEDGER_AT_PLAN" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    chmod a-w "$subdir"
    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result ready \
        --summary "engine test atomicity" >/dev/null 2>&1 || rc=$?
    # Restore write permission so cleanup() can remove the dir.
    chmod u+w "$subdir"

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "forced write failure (exit $rc) left prior ledger byte-intact"
    else
        failed "$name" "expected non-zero exit + intact ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── Drive all assertions ────────────────────────────────────────────────────

echo '=== Engine behavior tests: record-state-result.sh against tests/engine/ fixtures ==='
assert_valid_transition
assert_illegal_result_unchanged
assert_stale_state_unchanged
assert_terminal_status_update
assert_atomicity_on_write_failure

echo ''
echo '=== Summary ==='
echo "Engine tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
