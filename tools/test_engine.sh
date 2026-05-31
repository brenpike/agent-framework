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
#   F. plan-steps seed   -> init-run-ledger.sh --plan-steps writes plan.steps into the new
#                           ledger (length + id round-trip).
#   G. id mismatch       -> definition.id != ledger.run.workflow -> non-zero, byte-UNCHANGED.
#   H. version mismatch  -> definition.version != ledger.run.workflow_version -> non-zero,
#                           byte-UNCHANGED.
#   I. plan-steps record  -> record-state-result.sh --plan-steps at the `plan` (cerebrate)
#                           state writes plan.steps into the ledger (length + id round-trip).
#                           PRIMARY, live writer; complements F (init-time child/resume seed).
#                           This is the AUTHORIZED plan-write case (plan.agent==cerebrate).
#   J. plan-write authz   -> record-state-result.sh --plan-steps at a NON-cerebrate state
#                           (`build`, no agent==cerebrate) is rejected: non-zero exit, ledger
#                           byte-UNCHANGED (sha256). Flag presence alone never authorizes a
#                           plan write — only a cerebrate planning state may persist plan.steps.
#   K. checkout-root anchor -> init-run-ledger.sh run from a SUBDIR of a throwaway git repo
#                           writes the ledger under <repo-root>/.hivemind/runs/<id>/state.json
#                           and NOT under <subdir>/.hivemind. Regression for the CWD-relative
#                           run_dir that misplaced the ledger and caused duplicate runs (F-E).
#   L. canonical brood id -> init-run-ledger.sh --parent-kind brood with a CANONICAL
#                           colon-bearing ISO-8601 --parent-brood-id succeeds (exit 0),
#                           PERSISTS .parent.brood_id VERBATIM (colons intact, reconciles with
#                           the manifest's canonical brood_id), and derives the sanitized run-id
#                           <dashed-brood-id>--<short>. Proves init-run-ledger accepts the
#                           canonical id spawn-brood now injects and sanitizes internally for
#                           the run path only (F-D round-3: child ledger <-> manifest reconcile).
#   M. cerebrate-name-agnostic authz -> record-state-result.sh --plan-steps at a SECOND
#                           cerebrate state whose name is NOT `plan` (review_remediation_plan,
#                           agent==hivemind:cerebrate) is ACCEPTED (exit 0, steps persisted).
#                           Proves plan-write authorization keys on agent==cerebrate, not on
#                           the literal state name (F-C authorization coverage).
#   N. intervention terminal -> record-state-result.sh reaching a human-intervention terminal
#                           (user_input_required) sets run.status=blocked, NOT complete. Guards
#                           the regression where every non-blocked/cancelled terminal mapped to
#                           complete, masking a stalled run as success (complements D, which
#                           proves a genuine done-terminal still maps to complete).
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
INIT_ENGINE="$REPO_ROOT/plugin/skills/init-run-ledger/scripts/init-run-ledger.sh"
FIXTURES_DIR="$REPO_ROOT/tests/engine"
WORKFLOW_DEF="$FIXTURES_DIR/workflow-engine-fixture.json"
LEDGER_AT_PLAN="$FIXTURES_DIR/ledger-at-plan.json"
LEDGER_AT_BUILD="$FIXTURES_DIR/ledger-at-build.json"
LEDGER_WRONG_WORKFLOW="$FIXTURES_DIR/ledger-wrong-workflow.json"
LEDGER_WRONG_VERSION="$FIXTURES_DIR/ledger-wrong-version.json"
LEDGER_AT_REMEDIATION_PLAN="$FIXTURES_DIR/ledger-at-remediation-plan.json"

# ── Dependency / fixture preflight ──────────────────────────────────────────

for dep in jq sha256sum git; do
    command -v "$dep" >/dev/null 2>&1 \
        || { echo "FAIL: required dependency '$dep' is not installed" >&2; exit 2; }
done

for required in "$ENGINE" "$INIT_ENGINE" "$WORKFLOW_DEF" "$LEDGER_AT_PLAN" \
    "$LEDGER_AT_BUILD" "$LEDGER_WRONG_WORKFLOW" "$LEDGER_WRONG_VERSION" \
    "$LEDGER_AT_REMEDIATION_PLAN"; do
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

# ── F. init-run-ledger --plan-steps seeds plan.steps ────────────────────────

assert_plan_steps_seed() {
    local name="F:plan-steps-seed"
    # Run the init engine in a disposable throwaway git repo so it writes under
    # <repo-root>/.hivemind/runs/<run-id>/state.json — NEVER a ledger into the real repo.
    # init-run-ledger now anchors the run dir to `git rev-parse --show-toplevel`, so the CWD
    # must be inside a git checkout; the printed `ledger:` line is now an ABSOLUTE path.
    local initdir="$WORKDIR/f-init"
    mkdir -p "$initdir"
    git -C "$initdir" init -q
    local rc=0 out
    out="$(cd "$initdir" && bash "$INIT_ENGINE" \
        --workflow engine-fixture \
        --workflow-version 1 \
        --start-state plan \
        --user-request "engine test plan-steps seed" \
        --normalized "engine test plan-steps seed" \
        --plan-steps '[{"id":"STEP-001","status":"pending"}]' 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc seeding plan steps (expected 0): $out"
        return
    fi

    local ledger steps_len step_id
    # `ledger:` is now an absolute checkout-root-anchored path — use it verbatim.
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    if [[ ! -f "$ledger" ]]; then
        failed "$name" "init engine did not write a ledger at $ledger"
        return
    fi
    steps_len="$(jq -r '.plan.steps | length' "$ledger")"
    step_id="$(jq -r '.plan.steps[0].id' "$ledger")"
    if [[ "$steps_len" -eq 1 && "$step_id" == "STEP-001" ]]; then
        pass "$name" "plan.steps seeded: length=1, step id round-trips (STEP-001)"
    else
        failed "$name" "expected length=1/id=STEP-001, got length=$steps_len/id=$step_id"
    fi
}

# ── G. definition.id mismatch -> non-zero, ledger byte-unchanged ────────────

assert_id_mismatch_unchanged() {
    local name="G:id-mismatch-unchanged"
    # Ledger run.workflow=other-workflow; definition id=engine-fixture. Binding guard rejects.
    local ledger="$WORKDIR/g-ledger.json"
    cp "$LEDGER_WRONG_WORKFLOW" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result ready \
        --summary "engine test id mismatch" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "id-mismatch rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── H. definition.version mismatch -> non-zero, ledger byte-unchanged ───────

assert_version_mismatch_unchanged() {
    local name="H:version-mismatch-unchanged"
    # Ledger run.workflow_version=2; definition version=1. Binding guard rejects.
    local ledger="$WORKDIR/h-ledger.json"
    cp "$LEDGER_WRONG_VERSION" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result ready \
        --summary "engine test version mismatch" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "version-mismatch rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── I. plan-steps persisted at record-time via --plan-steps ─────────────────

assert_plan_steps_record_time() {
    local name="I:plan-steps-record-time"
    # Start from a ledger at state.current=plan, record a valid plan-state result while
    # passing --plan-steps; assert the written ledger persisted the steps array.
    local ledger="$WORKDIR/i-ledger.json"
    cp "$LEDGER_AT_PLAN" "$ledger"

    local rc=0
    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state plan \
        --result ready \
        --summary "engine test plan-steps record-time" \
        --plan-steps '[{"id":"STEP-001","status":"pending"}]' >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc recording with --plan-steps (expected 0)"
        return
    fi

    local steps_len step_id
    steps_len="$(jq -r '.plan.steps | length' "$ledger")"
    step_id="$(jq -r '.plan.steps[0].id' "$ledger")"
    if [[ "$steps_len" -eq 1 && "$step_id" == "STEP-001" ]]; then
        pass "$name" "plan.steps persisted at record-time: length=1, id round-trips (STEP-001)"
    else
        failed "$name" "expected length=1/id=STEP-001, got length=$steps_len/id=$step_id"
    fi
}

# ── J. plan-write authorization: non-cerebrate state + --plan-steps rejected ─

assert_plan_write_unauthorized_unchanged() {
    local name="J:plan-write-unauthorized-unchanged"
    # Ledger at state.current=build; `build` is NOT a cerebrate state (no agent==cerebrate,
    # it carries allowed_agents:[hivemind:drone]). Recording it WITH --plan-steps must be
    # rejected and leave the ledger byte-unchanged.
    local ledger="$WORKDIR/j-ledger.json"
    cp "$LEDGER_AT_BUILD" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state build \
        --result blocked \
        --summary "engine test unauthorized plan write" \
        --plan-steps '[{"id":"STEP-001","status":"pending"}]' >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "non-cerebrate plan write rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── K. init run dir anchored to checkout root, not CWD (F-E regression) ─────

assert_init_anchored_to_checkout_root() {
    local name="K:init-anchored-to-checkout-root"
    # Throwaway git repo with a subdir; run init FROM the subdir. The ledger must land at
    # <repo-root>/.hivemind/runs/<id>/state.json and be ABSENT under <subdir>/.hivemind.
    local repo="$WORKDIR/k-repo"
    mkdir -p "$repo/sub"
    git -C "$repo" init -q
    local rc=0 out
    out="$(cd "$repo/sub" && bash "$INIT_ENGINE" \
        --workflow engine-fixture \
        --workflow-version 1 \
        --start-state plan \
        --user-request "engine test checkout-root anchor" \
        --normalized "engine test checkout-root anchor" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc from a subdir (expected 0): $out"
        return
    fi

    local run_id ledger root_ledger
    run_id="$(printf '%s\n' "$out" | sed -n 's/^run_id: //p')"
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    root_ledger="$repo/.hivemind/runs/$run_id/state.json"
    # Ledger present at the checkout root, the printed path is that absolute path, and NOTHING
    # was written under the subdir.
    if [[ -f "$root_ledger" && "$ledger" == "$root_ledger" && ! -e "$repo/sub/.hivemind" ]]; then
        pass "$name" "ledger anchored to checkout root ($root_ledger), absent under subdir"
    else
        failed "$name" "expected ledger at $root_ledger and none under sub/.hivemind; got ledger=$ledger sub_exists=$([[ -e "$repo/sub/.hivemind" ]] && echo yes || echo no)"
    fi
}

# ── L. canonical brood id persisted verbatim; run-id sanitized (F-D round-3) ──

assert_brood_child_canonical_id() {
    local name="L:brood-child-canonical-id"
    # Brood child init with the CANONICAL colon-bearing --parent-brood-id (the value spawn-brood
    # now injects as parent.brood_id, identical to the coordinator manifest's brood_id). Must:
    #   (1) succeed (exit 0) — init accepts the ISO colon form, no charset blocker,
    #   (2) PERSIST .parent.brood_id VERBATIM with colons (so child ledger <-> manifest reconcile),
    #   (3) derive the sanitized filesystem run-id <dashed-brood-id>--<short> (colons->dashes),
    #       matching the manifest's run.suggested_id form.
    local repo="$WORKDIR/l-repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    # canonical = the manifest-style colon-bearing ISO-8601 brood id; safe = its sanitized form.
    local canonical="2026-05-31T17:30:00Z" short="my-strain"
    local safe="${canonical//:/-}"
    local rc=0 out
    out="$(cd "$repo" && bash "$INIT_ENGINE" \
        --workflow engine-fixture \
        --workflow-version 1 \
        --start-state plan \
        --user-request "engine test brood child" \
        --normalized "engine test brood child" \
        --parent-kind brood \
        --parent-brood-id "$canonical" \
        --parent-strain-id "$short" \
        --parent-run-id "$safe-hatchery" \
        --parent-manifest "$repo/.hivemind/brood/manifest.yaml" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc on a canonical colon-bearing brood id (expected 0): $out"
        return
    fi

    local run_id ledger brood_id
    run_id="$(printf '%s\n' "$out" | sed -n 's/^run_id: //p')"
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    # (3) run-id is the SANITIZED dashed form, NOT the canonical colon form.
    if [[ "$run_id" != "$safe--$short" ]]; then
        failed "$name" "expected sanitized run-id $safe--$short, got $run_id"
        return
    fi
    brood_id="$(jq -r '.parent.brood_id' "$ledger")"
    # (2) .parent.brood_id is the CANONICAL colon-bearing id (reconciles with manifest brood_id).
    #     An assertion against the literal manifest-style canonical value proves child<->manifest
    #     identity: the child persists exactly what the coordinator manifest carries.
    if [[ -f "$ledger" && "$brood_id" == "$canonical" ]]; then
        pass "$name" "canonical brood id persisted verbatim (parent.brood_id=$brood_id, manifest-reconcilable); run-id sanitized to $run_id"
    else
        failed "$name" "expected ledger at $ledger with canonical parent.brood_id=$canonical (colons intact), got brood_id=$brood_id"
    fi
}

# ── M. cerebrate authz is name-agnostic (F-C authorization coverage) ────────

assert_plan_write_remediation_state_authorized() {
    local name="M:plan-write-remediation-authorized"
    # Ledger at state.current=review_remediation_plan, a SECOND cerebrate state whose name is
    # NOT `plan`. Recording it WITH --plan-steps must be ACCEPTED (agent==cerebrate authorizes
    # the write regardless of the state name) and persist the steps.
    local ledger="$WORKDIR/m-ledger.json"
    cp "$LEDGER_AT_REMEDIATION_PLAN" "$ledger"

    local rc=0
    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state review_remediation_plan \
        --result ready \
        --summary "engine test remediation-plan authorized write" \
        --plan-steps '[{"id":"STEP-001","status":"pending"}]' >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc recording a cerebrate remediation state with --plan-steps (expected 0)"
        return
    fi

    local steps_len step_id
    steps_len="$(jq -r '.plan.steps | length' "$ledger")"
    step_id="$(jq -r '.plan.steps[0].id' "$ledger")"
    if [[ "$steps_len" -eq 1 && "$step_id" == "STEP-001" ]]; then
        pass "$name" "non-'plan' cerebrate state authorized: plan.steps persisted (length=1, id=STEP-001)"
    else
        failed "$name" "expected length=1/id=STEP-001, got length=$steps_len/id=$step_id"
    fi
}

# ── N. intervention terminal -> run.status blocked (not complete) ───────────

assert_intervention_terminal_blocked() {
    local name="N:intervention-terminal-blocked"
    # Ledger at build; record needs-input -> user_input_required (a declared human-intervention
    # terminal). run.status MUST be blocked (stopped, needs attention), NOT complete.
    local ledger="$WORKDIR/n-ledger.json"
    cp "$LEDGER_AT_BUILD" "$ledger"
    local rc=0
    bash "$ENGINE" \
        --ledger "$ledger" \
        --workflow "$WORKFLOW_DEF" \
        --state build \
        --result needs-input \
        --summary "engine test intervention terminal" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc recording an intervention terminal (expected 0)"
        return
    fi

    local current run_status state_status
    current="$(jq -r '.state.current' "$ledger")"
    run_status="$(jq -r '.run.status' "$ledger")"
    state_status="$(jq -r '.state.status' "$ledger")"
    if [[ "$current" == "user_input_required" && "$run_status" == "blocked" && "$state_status" == "blocked" ]]; then
        pass "$name" "intervention terminal mapped to blocked: state.current=user_input_required, run.status=blocked"
    else
        failed "$name" "expected user_input_required/blocked/blocked, got current=$current/run.status=$run_status/state.status=$state_status"
    fi
}

# ── Drive all assertions ────────────────────────────────────────────────────

echo '=== Engine behavior tests: record-state-result.sh against tests/engine/ fixtures ==='
assert_valid_transition
assert_illegal_result_unchanged
assert_stale_state_unchanged
assert_terminal_status_update
assert_atomicity_on_write_failure
assert_plan_steps_seed
assert_id_mismatch_unchanged
assert_version_mismatch_unchanged
assert_plan_steps_record_time
assert_plan_write_unauthorized_unchanged
assert_init_anchored_to_checkout_root
assert_brood_child_canonical_id
assert_plan_write_remediation_state_authorized
assert_intervention_terminal_blocked

echo ''
echo '=== Summary ==='
echo "Engine tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
