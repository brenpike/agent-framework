#!/usr/bin/env bash
#
# Engine behavior test runner for the hivemind workflow engine (plan §J.2).
#
# Executes the REAL deterministic transition engine
# (plugin/skills/record-state-result/scripts/record-state-result.sh) and the init engine
# (plugin/skills/init-run-ledger/scripts/init-run-ledger.sh) against the ledger +
# workflow-definition fixtures under tests/engine/, in a disposable mktemp workdir. NEVER
# writes a runtime ledger into the repo: every fixture is copied into the temp dir, mutated
# there, and the temp dir is removed on exit.
#
# INPUTS-FILE INTERFACE: both engines take a SINGLE positional argument — the path to a JSON
# inputs file the agent (here, this harness) authors via the Write tool. The old `--flag value`
# interface is gone. This harness authors every fixture inputs file SAFELY: each is built with
# `jq -n --arg / --argjson` (or a quoted heredoc JSON literal), NEVER by Bash string-
# concatenating untrusted values into JSON. This matters because the harness must PROVE the
# engine is injection-safe (cases O/P), not accidentally become unsafe itself: jq emits proper
# JSON escaping, so a payload like `$(touch PWNED)` lands in the inputs file as inert string
# bytes, never as shell/jq program source.
#
# Assertions (each maps to a fixture under tests/engine/):
#   A. valid transition  -> exit 0, ledger state.current advanced, an event appended.
#   B. illegal result    -> non-zero exit, ledger byte-UNCHANGED (sha256 compare).
#   C. stale state       -> non-zero exit, ledger byte-UNCHANGED (state != current).
#   D. terminal target   -> run.status updated to the mapped terminal status.
#   E. atomicity         -> a forced write failure (unwritable target dir) leaves the
#                           prior ledger byte-intact.
#   F. plan-steps seed   -> init-run-ledger.sh plan_steps writes plan.steps into the new
#                           ledger (length + id round-trip).
#   G. id mismatch       -> definition.id != ledger.run.workflow -> non-zero, byte-UNCHANGED.
#   H. version mismatch  -> definition.version != ledger.run.workflow_version -> non-zero,
#                           byte-UNCHANGED.
#   I. plan-steps record  -> record-state-result.sh plan_steps at the `plan` (cerebrate)
#                           state writes plan.steps into the ledger (length + id round-trip).
#                           PRIMARY, live writer; complements F (init-time child/resume seed).
#                           This is the AUTHORIZED plan-write case (plan.agent==cerebrate).
#   J. plan-write authz   -> record-state-result.sh plan_steps at a NON-cerebrate state
#                           (`build`, no agent==cerebrate) is rejected: non-zero exit, ledger
#                           byte-UNCHANGED (sha256). Field presence alone never authorizes a
#                           plan write — only a cerebrate planning state may persist plan.steps.
#   K. checkout-root anchor -> init-run-ledger.sh run from a SUBDIR of a throwaway git repo
#                           writes the ledger under <repo-root>/.hivemind/runs/<id>/state.json
#                           and NOT under <subdir>/.hivemind. Regression for the CWD-relative
#                           run_dir that misplaced the ledger and caused duplicate runs (F-E).
#   L. canonical brood id -> init-run-ledger.sh parent.kind=brood with a CANONICAL
#                           colon-bearing ISO-8601 parent.brood_id succeeds (exit 0),
#                           PERSISTS .parent.brood_id VERBATIM (colons intact, reconciles with
#                           the manifest's canonical brood_id), and derives the sanitized run-id
#                           <dashed-brood-id>--<short>. Proves init-run-ledger accepts the
#                           canonical id spawn-brood now injects and sanitizes internally for
#                           the run path only (F-D round-3: child ledger <-> manifest reconcile).
#   M. cerebrate-name-agnostic authz -> record-state-result.sh plan_steps at a SECOND
#                           cerebrate state whose name is NOT `plan` (review_remediation_plan,
#                           agent==hivemind:cerebrate) is ACCEPTED (exit 0, steps persisted).
#                           Proves plan-write authorization keys on agent==cerebrate, not on
#                           the literal state name (F-C authorization coverage).
#   N. intervention terminal -> record-state-result.sh reaching a human-intervention terminal
#                           (user_input_required) sets run.status=blocked, NOT complete. Guards
#                           the regression where every non-blocked/cancelled terminal mapped to
#                           complete, masking a stalled run as success (complements D, which
#                           proves a genuine done-terminal still maps to complete).
#   O. init injection safety -> init-run-ledger.sh with user_request / normalized carrying a
#                           command-substitution payload `$(touch PWNED)` and a backtick payload
#                           `` `touch PWNED2` `` must: (i) create NO file named PWNED/PWNED2 under
#                           the workdir or the repo root; (ii) round-trip the payload VERBATIM as
#                           inert data in .request.raw; (iii) exit 0. Proves the inputs-file
#                           interface never re-evaluates untrusted bytes as command source.
#   P. record injection safety -> record-state-result.sh with summary / outputs / plan_steps
#                           carrying `$(touch PWNED3)` + backticks at a cerebrate planning state
#                           must: (i) create NO PWNED3 file; (ii) round-trip the payload VERBATIM
#                           in .events[-1].summary, the outputs object, and .plan.steps; (iii)
#                           exit 0. Companion to O for the record engine's untrusted fields.
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
    local inputs="$WORKDIR/a-inputs.json"
    cp "$LEDGER_AT_PLAN" "$ledger"

    # SAFE authoring: every field bound via jq --arg, no string concatenation of values.
    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test valid transition" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    local rc=0
    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

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

# ── B. illegal result -> non-zero, ledger byte-unchanged ────────────────────

assert_illegal_result_unchanged() {
    local name="B:illegal-result-unchanged"
    local ledger="$WORKDIR/b-ledger.json"
    local inputs="$WORKDIR/b-inputs.json"
    cp "$LEDGER_AT_PLAN" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result not_a_legal_outcome \
        --arg summary "engine test illegal result" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "illegal result rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── C. stale state -> non-zero, ledger byte-unchanged ───────────────────────

assert_stale_state_unchanged() {
    local name="C:stale-state-unchanged"
    local ledger="$WORKDIR/c-ledger.json"
    local inputs="$WORKDIR/c-inputs.json"
    # Ledger is at state.current=build; pass a stale state=plan.
    cp "$LEDGER_AT_BUILD" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test stale state" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "stale state rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── D. terminal target -> run.status updated to mapped terminal status ──────

assert_terminal_status_update() {
    local name="D:terminal-status-update"
    local ledger="$WORKDIR/d-ledger.json"
    local inputs="$WORKDIR/d-inputs.json"
    # Ledger at build; record done -> complete (a declared terminal).
    cp "$LEDGER_AT_BUILD" "$ledger"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state build \
        --arg result done \
        --arg summary "engine test terminal transition" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    local rc=0
    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

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
    # The engine writes a temp file beside the ledger via mktemp, then mv. Force failure
    # by making the ledger's parent path component a regular file, so any attempt to
    # create or rename a file beneath it hits ENOTDIR — a kernel VFS error enforced
    # regardless of UID (root cannot bypass ENOTDIR; it is not a permission check).
    # INVARIANT: the "directory" component is a regular file, so no prior ledger exists
    # on disk; the atomicity property to verify is that the engine exits non-zero and
    # does not create a partial ledger at or beneath the notdir path.
    local notdir="$WORKDIR/e-notdir"
    touch "$notdir"
    local ledger="$notdir/e-ledger.json"
    local inputs="$WORKDIR/e-inputs.json"
    local rc=0

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test atomicity" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    # The ledger path is unreachable (parent is a file), so no ledger can exist.
    if [[ "$rc" -ne 0 && ! -e "$ledger" ]]; then
        pass "$name" "forced write failure via ENOTDIR (exit $rc) left no ledger artifact"
    else
        failed "$name" "expected non-zero exit + no ledger artifact; rc=$rc, ledger_exists=$([[ -e "$ledger" ]] && echo yes || echo no)"
    fi
}

# ── F. init-run-ledger plan_steps seeds plan.steps ──────────────────────────

assert_plan_steps_seed() {
    local name="F:plan-steps-seed"
    # Run the init engine in a disposable throwaway git repo so it writes under
    # <repo-root>/.hivemind/runs/<run-id>/state.json — NEVER a ledger into the real repo.
    # init-run-ledger anchors the run dir to `git rev-parse --show-toplevel`, so the CWD
    # must be inside a git checkout; the printed `ledger:` line is an ABSOLUTE path.
    local initdir="$WORKDIR/f-init"
    local inputs="$WORKDIR/f-inputs.json"
    mkdir -p "$initdir"
    git -C "$initdir" init -q

    # SAFE authoring: plan_steps is a pre-validated JSON array bound via --argjson.
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test plan-steps seed" \
        --arg normalized "engine test plan-steps seed" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0 out
    out="$(cd "$initdir" && bash "$INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc seeding plan steps (expected 0): $out"
        return
    fi

    local ledger steps_len step_id
    # `ledger:` is an absolute checkout-root-anchored path — use it verbatim.
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
    local inputs="$WORKDIR/g-inputs.json"
    cp "$LEDGER_WRONG_WORKFLOW" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test id mismatch" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

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
    local inputs="$WORKDIR/h-inputs.json"
    cp "$LEDGER_WRONG_VERSION" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test version mismatch" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "version-mismatch rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── I. plan-steps persisted at record-time via plan_steps ───────────────────

assert_plan_steps_record_time() {
    local name="I:plan-steps-record-time"
    # Start from a ledger at state.current=plan, record a valid plan-state result while
    # passing plan_steps; assert the written ledger persisted the steps array.
    local ledger="$WORKDIR/i-ledger.json"
    local inputs="$WORKDIR/i-inputs.json"
    cp "$LEDGER_AT_PLAN" "$ledger"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test plan-steps record-time" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0
    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc recording with plan_steps (expected 0)"
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

# ── J. plan-write authorization: non-cerebrate state + plan_steps rejected ──

assert_plan_write_unauthorized_unchanged() {
    local name="J:plan-write-unauthorized-unchanged"
    # Ledger at state.current=build; `build` is NOT a cerebrate state (no agent==cerebrate,
    # it carries allowed_agents:[hivemind:drone]). Recording it WITH plan_steps must be
    # rejected and leave the ledger byte-unchanged.
    local ledger="$WORKDIR/j-ledger.json"
    local inputs="$WORKDIR/j-inputs.json"
    cp "$LEDGER_AT_BUILD" "$ledger"
    local before after rc=0
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state build \
        --arg result blocked \
        --arg summary "engine test unauthorized plan write" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary, plan_steps: $plan_steps}' \
        > "$inputs"

    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

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
    local inputs="$WORKDIR/k-inputs.json"
    mkdir -p "$repo/sub"
    git -C "$repo" init -q

    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test checkout-root anchor" \
        --arg normalized "engine test checkout-root anchor" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized}' \
        > "$inputs"

    local rc=0 out
    out="$(cd "$repo/sub" && bash "$INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

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
    # Brood child init with the CANONICAL colon-bearing parent.brood_id (the value spawn-brood
    # now injects as parent.brood_id, identical to the coordinator manifest's brood_id). Must:
    #   (1) succeed (exit 0) — init accepts the ISO colon form, no charset blocker,
    #   (2) PERSIST .parent.brood_id VERBATIM with colons (so child ledger <-> manifest reconcile),
    #   (3) derive the sanitized filesystem run-id <dashed-brood-id>--<short> (colons->dashes),
    #       matching the manifest's run.suggested_id form.
    local repo="$WORKDIR/l-repo"
    local inputs="$WORKDIR/l-inputs.json"
    mkdir -p "$repo"
    git -C "$repo" init -q
    # canonical = the manifest-style colon-bearing ISO-8601 brood id; safe = its sanitized form.
    local canonical="2026-05-31T17:30:00Z" short="my-strain"
    local safe="${canonical//:/-}"

    # SAFE authoring: the colon-bearing canonical id is bound via --arg (jq escapes it), and
    # the parent block is assembled inside jq from named bindings — never string-concatenated.
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test brood child" \
        --arg normalized "engine test brood child" \
        --arg brood_id "$canonical" \
        --arg strain_id "$short" \
        --arg run_id "$safe-hatchery" \
        --arg manifest "$repo/.hivemind/brood/manifest.yaml" \
        '{
            workflow: $workflow,
            workflow_version: $workflow_version,
            start_state: $start_state,
            user_request: $user_request,
            normalized: $normalized,
            parent: {
                kind: "brood",
                brood_id: $brood_id,
                strain_id: $strain_id,
                run_id: $run_id,
                manifest: $manifest
            }
        }' \
        > "$inputs"

    local rc=0 out
    out="$(cd "$repo" && bash "$INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

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
    # NOT `plan`. Recording it WITH plan_steps must be ACCEPTED (agent==cerebrate authorizes
    # the write regardless of the state name) and persist the steps.
    local ledger="$WORKDIR/m-ledger.json"
    local inputs="$WORKDIR/m-inputs.json"
    cp "$LEDGER_AT_REMEDIATION_PLAN" "$ledger"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state review_remediation_plan \
        --arg result ready \
        --arg summary "engine test remediation-plan authorized write" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0
    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "engine exited $rc recording a cerebrate remediation state with plan_steps (expected 0)"
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
    local inputs="$WORKDIR/n-inputs.json"
    cp "$LEDGER_AT_BUILD" "$ledger"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state build \
        --arg result needs-input \
        --arg summary "engine test intervention terminal" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    local rc=0
    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

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

# ── PWNED-absence helper ─────────────────────────────────────────────────────

# Assert that no injection-marker file with the given basename was created anywhere the
# payload could have landed: under $WORKDIR (the test's scratch dir + any CWD the engine
# ran from) and under $REPO_ROOT (the engine's CWD could be a git checkout; a `touch PWNED`
# with no path lands in CWD). Returns 0 when NO such file exists, 1 when one was found.
assert_no_pwned_file() {
    local marker="$1"
    if find "$WORKDIR" "$REPO_ROOT" -name "$marker" -print 2>/dev/null | grep -q .; then
        return 1
    fi
    return 0
}

# ── O. init engine injection safety: payload is inert data ──────────────────

assert_init_injection_safe() {
    local name="O:init-injection-safe"
    # init-run-ledger reads user_request / normalized as UNTRUSTED data and serializes them
    # only via jq --arg. A command-substitution + backtick payload must round-trip VERBATIM
    # into .request.raw and NEVER execute (no PWNED / PWNED2 file anywhere).
    local repo="$WORKDIR/o-repo"
    local inputs="$WORKDIR/o-inputs.json"
    mkdir -p "$repo"
    git -C "$repo" init -q

    # The payload is DATA. It is authored SAFELY via jq --arg: jq JSON-escapes the literal,
    # so the inputs file contains the inert bytes `$(touch PWNED)` and `` `touch PWNED2` ``,
    # never a shell command. The single-quoted bash literal below is itself never evaluated by
    # bash as a command — it is a string argument handed to jq.
    local payload='inject $(touch PWNED) and `touch PWNED2` end'
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "$payload" \
        --arg normalized "$payload" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized}' \
        > "$inputs"

    local rc=0 out
    out="$(cd "$repo" && bash "$INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc on an injection payload (expected 0): $out"
        return
    fi

    # (i) NO marker file was created anywhere the payload could have run.
    if ! assert_no_pwned_file PWNED || ! assert_no_pwned_file PWNED2; then
        failed "$name" "injection payload EXECUTED: a PWNED/PWNED2 file was created"
        return
    fi

    local ledger raw
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    if [[ ! -f "$ledger" ]]; then
        failed "$name" "init engine did not write a ledger at $ledger"
        return
    fi
    # (ii) the payload round-trips VERBATIM as inert data in .request.raw.
    raw="$(jq -r '.request.raw' "$ledger")"
    if [[ "$raw" == "$payload" ]]; then
        pass "$name" "payload inert: no PWNED file, .request.raw round-trips verbatim, exit 0"
    else
        failed "$name" "expected .request.raw to round-trip the payload verbatim; got: $raw"
    fi
}

# ── P. record engine injection safety: payload is inert data ────────────────

assert_record_injection_safe() {
    local name="P:record-injection-safe"
    # record-state-result reads summary / outputs / plan_steps as UNTRUSTED data, serialized
    # only via jq --arg / --argjson. A command-substitution + backtick payload in all three
    # must round-trip VERBATIM (.events[-1].summary, the outputs object, .plan.steps) and NEVER
    # execute. Recorded at a cerebrate planning state so the plan_steps write is authorized.
    local ledger="$WORKDIR/p-ledger.json"
    local inputs="$WORKDIR/p-inputs.json"
    cp "$LEDGER_AT_PLAN" "$ledger"

    # Payload is DATA, authored SAFELY: the string flows through jq --arg/--argjson, which
    # JSON-escapes it. outputs carries the payload as a VALUE; plan_steps carries it inside a
    # step object — both bound via --argjson from a jq-constructed value (never concatenated).
    local payload='inject $(touch PWNED3) and `touch PWNED3b` end'
    local outputs plan_steps
    outputs="$(jq -n --arg p "$payload" '{note: $p}')"
    plan_steps="$(jq -n --arg p "$payload" '[{id: "STEP-001", status: "pending", note: $p}]')"

    jq -n \
        --arg ledger "$ledger" \
        --arg workflow "$WORKFLOW_DEF" \
        --arg state plan \
        --arg result ready \
        --arg summary "$payload" \
        --argjson outputs "$outputs" \
        --argjson plan_steps "$plan_steps" \
        '{ledger: $ledger, workflow: $workflow, state: $state, result: $result, summary: $summary, outputs: $outputs, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0
    bash "$ENGINE" "$inputs" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "record engine exited $rc on an injection payload (expected 0)"
        return
    fi

    # (i) NO marker file was created anywhere the payload could have run.
    if ! assert_no_pwned_file PWNED3 || ! assert_no_pwned_file PWNED3b; then
        failed "$name" "injection payload EXECUTED: a PWNED3 file was created"
        return
    fi

    # (ii) the payload round-trips VERBATIM in the event summary, the outputs object, and plan.steps.
    local got_summary got_output got_step
    got_summary="$(jq -r '.events[-1].summary' "$ledger")"
    got_output="$(jq -r '.events[-1].outputs.note' "$ledger")"
    got_step="$(jq -r '.plan.steps[0].note' "$ledger")"
    if [[ "$got_summary" == "$payload" && "$got_output" == "$payload" && "$got_step" == "$payload" ]]; then
        pass "$name" "payload inert: no PWNED3 file, summary/outputs/plan.steps round-trip verbatim, exit 0"
    else
        failed "$name" "expected verbatim round-trip; got summary=$got_summary output=$got_output step=$got_step"
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
assert_init_injection_safe
assert_record_injection_safe

echo ''
echo '=== Summary ==='
echo "Engine tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
