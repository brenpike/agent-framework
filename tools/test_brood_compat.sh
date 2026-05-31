#!/usr/bin/env bash
#
# Brood manifest back-compat test (plan §J.3).
#
# Proves the hivemind:brood-status status-derivation logic reads BOTH manifest
# generations without error:
#   - an OLD manifest (no manifest_version, no per-strain run:/ledger block) ->
#     Ledger = unknown, Workflow State = unknown (derivation falls back to
#     external observables alone);
#   - a NEW manifest_version: 2 manifest whose per-strain run.suggested_ledger
#     points at a PRESENT child JSON run ledger -> Ledger = present, Workflow
#     State = the child ledger's state.current.
#
# This runner replicates the manifest parse the brood-status SKILL.md prose
# performs (sed extraction of tmux_session/branch — identical to the spawn-brood
# liveness guard's extraction — plus run.suggested_ledger discovery and a jq read
# of the child ledger). It does NOT shell out to tmux/git/gh: external observables
# are out of scope for a back-compat parse test. It is READ-ONLY: it never writes
# a manifest or a child ledger.
#
# Exits non-zero if EITHER manifest fails to parse or derives the wrong shape.
#
# Usage:
#   ./tools/test_brood_compat.sh

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FIX_DIR="$REPO_ROOT/tests/brood"
MANIFEST_V1="$FIX_DIR/manifest-v1-old.yaml"
MANIFEST_V2="$FIX_DIR/manifest-v2-new.yaml"

command -v jq >/dev/null 2>&1 \
    || { echo "FAIL: required dependency 'jq' is not installed" >&2; exit 2; }

for required in "$MANIFEST_V1" "$MANIFEST_V2"; do
    [[ -f "$required" ]] \
        || { echo "FAIL: required fixture missing: $required" >&2; exit 2; }
done

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# extract_tmux_session: pull the first strain's tmux_session value the SAME way the
# spawn-brood liveness guard and brood-status prose extract it (a double-quoted YAML
# line). Mirrors the producer/consumer parity the manifest contract relies on.
extract_tmux_session() {
    sed -n 's/^[[:space:]]*tmux_session:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" | head -1
}

# extract_branch: pull the first strain's branch value from its |- block scalar (the
# value is on the line FOLLOWING the `branch: |-` key, indented).
extract_branch() {
    awk '
        /^[[:space:]]*branch:[[:space:]]*\|-[[:space:]]*$/ { grab=1; next }
        grab { gsub(/^[[:space:]]+/, ""); print; exit }
    ' "$1"
}

# extract_suggested_ledger: pull the first strain run.suggested_ledger value (value on
# the line following `suggested_ledger: |-`). Empty if the field is absent (v1 manifest).
extract_suggested_ledger() {
    awk '
        /^[[:space:]]*suggested_ledger:[[:space:]]*\|-[[:space:]]*$/ { grab=1; next }
        grab { gsub(/^[[:space:]]+/, ""); print; exit }
    ' "$1"
}

# derive_ledger_state: given a manifest, resolve the first strain ledger status and
# workflow state per the brood-status status-derivation priority (ledger-bridge step).
# Echoes "<ledger_status> <workflow_state>".
derive_ledger_state() {
    local manifest="$1"
    local ledger_path
    ledger_path="$(extract_suggested_ledger "$manifest")"
    if [[ -z "$ledger_path" ]]; then
        echo "unknown unknown"   # v1 manifest: no run: block at all
        return 0
    fi
    if [[ ! -f "$ledger_path" ]]; then
        echo "missing unknown"
        return 0
    fi
    local current
    current="$(jq -r '.state.current // "unknown"' "$ledger_path")"
    echo "present $current"
}

# ── Assertion 1: OLD v1 manifest parses, derives unknown/unknown ────────────────
assert_v1_old() {
    local name="V1:old-manifest-no-ledger-fields"
    local session branch result
    session="$(extract_tmux_session "$MANIFEST_V1")"
    branch="$(extract_branch "$MANIFEST_V1")"
    result="$(derive_ledger_state "$MANIFEST_V1")"
    if [[ "$session" == "brood-api" && "$branch" == "feature/api-slice" && "$result" == "unknown unknown" ]]; then
        pass "$name" "v1 manifest read without error: session=$session branch=$branch ledger/state=$result"
    else
        failed "$name" "expected brood-api/feature/api-slice/'unknown unknown', got session=$session branch=$branch result='$result'"
    fi
}

# ── Assertion 2: NEW v2 manifest parses, derives present/<state.current> ─────────
assert_v2_new() {
    local name="V2:new-manifest-ledger-present"
    # The v2 fixture's suggested_ledger is a TESTS_BROOD_DIR placeholder so the present
    # child ledger resolves regardless of checkout location. Substitute it into a temp
    # copy (READ-ONLY toward the committed fixture; the temp copy is disposable).
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/brood-compat-v2.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    sed "s#TESTS_BROOD_DIR#$FIX_DIR#" "$MANIFEST_V2" > "$tmp"

    local session branch result
    session="$(extract_tmux_session "$tmp")"
    branch="$(extract_branch "$tmp")"
    result="$(derive_ledger_state "$tmp")"
    if [[ "$session" == "brood-api" && "$branch" == "feature/api-slice" && "$result" == "present implement_step" ]]; then
        pass "$name" "v2 manifest read without error: session=$session branch=$branch ledger/state=$result"
    else
        failed "$name" "expected brood-api/feature/api-slice/'present implement_step', got session=$session branch=$branch result='$result'"
    fi
}

echo '=== Brood manifest back-compat tests: brood-status reads v1 (old) and v2 (new) manifests ==='
assert_v1_old
assert_v2_new

echo ''
echo '=== Summary ==='
echo "Brood back-compat tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
