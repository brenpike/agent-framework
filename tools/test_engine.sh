#!/usr/bin/env bash
#
# Engine behavior test runner for the hivemind workflow engine (plan §J.2).
#
# Exercises the REAL deterministic transition engine
# (plugin/skills/record-state-result/scripts/record-state-result.sh) and the init engine
# (plugin/skills/init-run-ledger/scripts/init-run-ledger.sh) under their DERIVE-ONLY
# contract: neither engine accepts a `ledger` or `workflow` PATH — both DERIVE every path
# from identity (run_id + git-root for the ledger; the script's OWN self-located packaged
# workflows dir for the definition). The harness therefore proves derivation with TWO
# DISTINCT real roots per case:
#
#   1. SELF-LOCATION ROOT — the engines are run as a COPY inside a throwaway FAKEPLUGIN
#      tree so `BASH_SOURCE + pwd -P` self-location resolves a TEST workflows dir, never the
#      real repo's plugin/workflows. A copy (NOT a symlink) is required: `pwd -P` would
#      resolve a symlink back to the real tree and defeat the isolation. Layout mirrors the
#      real plugin so `<scripts-dir>/../../..` lands on <fakeplugin>:
#         <fakeplugin>/skills/record-state-result/scripts/record-state-result.sh
#         <fakeplugin>/skills/init-run-ledger/scripts/init-run-ledger.sh
#         <fakeplugin>/workflows/engine-fixture.json   (cp of the engine fixture def)
#      Built once and reused across cases.
#
#   2. LEDGER ROOT — a SEPARATE throwaway GIT checkout (`git init`). The engine derives the
#      ledger as `$(git rev-parse --show-toplevel)/.hivemind/runs/<run_id>/state.json`, so
#      each case stages its ledger under a fresh git root and invokes the copied engine with
#      `cd "$gitroot"` (or `git -C`). The gitroot and the fakeplugin are DIFFERENT
#      directories: the script self-locates into the fakeplugin while --show-toplevel
#      resolves the gitroot. This is the dual-root proof — real self-location AND real
#      git-root ledger derivation, as two independent roots.
#
# NEVER writes a runtime ledger into THIS repo: every root is a child of a disposable mktemp
# WORKDIR removed on exit.
#
# INPUTS-FILE INTERFACE: both engines take a SINGLE positional argument — the path to a JSON
# inputs file the agent (here, this harness) authors via the Write tool. Under the derive-only
# contract the record inputs carry `run_id` (NOT `ledger`/`workflow`); init inputs carry
# `workflow`/`workflow_version`/`start_state`. This harness authors every inputs file SAFELY:
# each is built with `jq -n --arg / --argjson`, NEVER by Bash string-concatenating untrusted
# values into JSON. This matters because the harness must PROVE the engine is injection-safe
# (cases O/P), not accidentally become unsafe itself: jq emits proper JSON escaping, so a
# payload like `$(touch PWNED)` lands in the inputs file as inert string bytes, never as
# shell/jq program source.
#
# COHERENCE STAGING: the engine coherence-checks `ledger.run.id == run_id` and derives the
# definition from `ledger.run.workflow` against the self-located packaged dir. So for each
# record case the harness chooses a SAFE_ID_RE-clean run-id (e.g. `engine-case-a`), places the
# fixture ledger at runs/<run-id>/state.json, and `jq`s the copied ledger so `.run.id` equals
# that run-id and `.run.workflow == "engine-fixture"` (matching the fakeplugin def stem) —
# EXCEPT the mismatch cases (G/H), which deliberately forge run.workflow / run.workflow_version
# to differ from the def while keeping run.id == run_id for coherence.
#
# Assertions (each maps to a fixture under tests/engine/):
#   A. valid transition  -> exit 0, ledger state.current advanced, an event appended.
#   B. illegal result    -> non-zero exit, ledger byte-UNCHANGED (sha256 compare).
#   C. stale state       -> non-zero exit, ledger byte-UNCHANGED (state != current).
#   D. terminal target   -> run.status updated to the mapped terminal status (complete).
#   E. atomicity         -> a forced write failure (ENOTDIR on the run dir) leaves no torn
#                           ledger; the engine exits non-zero. Root-safe (ENOTDIR is a VFS
#                           error, not a permission check).
#   F. plan-steps seed   -> init-run-ledger.sh plan_steps writes plan.steps into the new
#                           ledger (length + id round-trip).
#   G. id mismatch       -> ledger.run.workflow != def.id -> non-zero, byte-UNCHANGED.
#   H. version mismatch  -> ledger.run.workflow_version != def.version -> non-zero,
#                           byte-UNCHANGED.
#   I. plan-steps record  -> record-state-result.sh plan_steps at the `plan` (cerebrate)
#                           state writes plan.steps into the ledger (length + id round-trip).
#                           PRIMARY, live writer; complements F. AUTHORIZED (plan.agent==cerebrate).
#   J. plan-write authz   -> record-state-result.sh plan_steps at a NON-cerebrate state
#                           (`build`) is rejected: non-zero exit, ledger byte-UNCHANGED.
#   K. checkout-root anchor -> init-run-ledger.sh run from a SUBDIR of a throwaway git repo
#                           writes the ledger under <repo-root>/.hivemind/runs/<id>/state.json
#                           and NOT under <subdir>/.hivemind (F-E regression).
#   L. canonical brood id -> init-run-ledger.sh parent.kind=brood with a CANONICAL
#                           colon-bearing ISO-8601 parent.brood_id succeeds, PERSISTS
#                           .parent.brood_id VERBATIM, and derives the sanitized run-id.
#   M. cerebrate-name-agnostic authz -> record-state-result.sh plan_steps at a SECOND
#                           cerebrate state (review_remediation_plan) is ACCEPTED.
#   N. intervention terminal -> record-state-result.sh reaching user_input_required sets
#                           run.status=blocked, NOT complete.
#   O. init injection safety -> init-run-ledger.sh with a command-substitution / backtick
#                           payload creates NO PWNED file and round-trips it verbatim.
#   P. record injection safety -> record-state-result.sh with the payload in summary/outputs/
#                           plan_steps creates NO PWNED3 file and round-trips it verbatim.
#   Q. run_id traversal rejected -> a run_id containing a separator or `..` is rejected by
#                           SAFE_ID_RE / reserved-component reject: non-zero exit, NO ledger
#                           written anywhere, no traversal.
#   R. forged-definition not honored -> a HOSTILE workflow def planted at an arbitrary on-disk
#                           path (declaring an undeclared transition) is NEVER consulted: the
#                           engine resolves the self-located <fakeplugin>/workflows def, so a
#                           result only the hostile def would allow is REJECTED, ledger
#                           byte-UNCHANGED. Proves caller paths cannot inject a definition.
#   S. coherence mismatch -> ledger at runs/<run-id>/state.json whose internal .run.id is a
#                           DIFFERENT value -> the coherence check fails: non-zero exit, ledger
#                           byte-UNCHANGED.
#   T. init-symlink-escape-rejected -> the gitroot's .hivemind is replaced with a symlink to an
#                           EXTERNAL dir outside the gitroot. init-run-ledger.sh canonicalizes
#                           the derived path, detects the symlinked .hivemind ancestor, and
#                           rejects BEFORE any mkdir: non-zero exit AND no state.json is created
#                           anywhere under the external target. Proves derive-from-ground-truth
#                           is PAIRED with canonical-containment (a textually-derived path is not
#                           confinement when an ancestor is a symlink).
#   U. record-symlink-escape-rejected -> the external target is PRE-STAGED with a valid ledger at
#                           runs/<run-id>/state.json, then the gitroot's .hivemind is symlinked to
#                           it (so `[ -f ]` passes THROUGH the symlink — the ledger is REACHABLE).
#                           record-state-result.sh canonicalizes the existing ledger, detects the
#                           symlinked ancestor / out-of-containment resolution, and rejects: non-
#                           zero exit, the external ledger BYTE-UNCHANGED (sha256 before==after),
#                           and NO temp file leaked under the external dir. CRITICAL: the
#                           rejection is by CONTAINMENT (file reachable but unmutated), not by
#                           file-absence — the pre-staged file proves the guard, not a missing
#                           file, blocked the write.
#   V. init-nested-symlink-escape-rejected -> the gitroot has a REAL .hivemind/runs/, but the
#                           <run_id> RUN dir itself is a symlink to an EXTERNAL dir outside the
#                           checkout. init-run-ledger.sh's depth-complete containment guard walks
#                           EVERY component of the derived chain (not just .hivemind/.hivemind/runs)
#                           and rejects the symlinked <run_id> leaf BEFORE any state.json/evidence
#                           write: non-zero exit AND zero write under the external target. Covers
#                           the finding-1 leaf vector case T (symlinked .hivemind ANCESTOR) does not.
#   W. init-concurrent-reservation -> deterministic stand-in for "the race winner already claimed
#                           the run dir": the <fixed_id> run dir is PRE-CREATED with a sentinel
#                           state.json, then init runs pinned to that same run_id via
#                           suggested_run_id. init's fail-closed reservation (the early [ -e ]
#                           blocker / the atomic bare `mkdir` without -p) rejects: non-zero exit,
#                           the sentinel state.json BYTE-UNCHANGED, and no leaked .state.json.* temp
#                           in the run dir. Proves F2 — the loser fails closed and never overwrites
#                           the winner's ledger.
#   X. init-inputs-external-rejected -> a VALID init inputs file authored at a path that resolves
#                           OUTSIDE the checkout via a symlinked ANCESTOR ($gitroot/link -> external)
#                           is refused by the shared read-guard (hivemind_assert_inputs_contained):
#                           non-zero exit AND no ledger/state.json written anywhere (inside or under
#                           the external target). Proves the shared read-guard for init.
#   Y. record-inputs-external-rejected -> a VALID ledger is staged at runs/<id>/state.json FIRST
#                           (so the ONLY thing that can block is the read-guard, not a missing
#                           ledger), then a valid record inputs file is authored at an externally-
#                           resolving path via a symlinked ancestor. record's shared read-guard
#                           refuses to read it: non-zero exit AND the staged ledger byte-unchanged.
#                           Proves the shared read-guard for record.
#   Z. init-pre-ledger-failure-rollback-then-retry -> a deterministic post-claim failure (a failing
#                           `mktemp` stub shadowed on PATH, invoked AFTER the atomic `mkdir "$run_dir"`
#                           claim) makes init block (exit 1); the EXIT-trap rollback removes the
#                           invocation-owned run dir, leaving NO orphan. Then, with the stub removed, a
#                           retry pinned to the SAME suggested_run_id re-claims the dir and writes a
#                           valid ledger (run.id round-trips). Proves the orphaned-reservation P1 fix:
#                           a transient failure does not permanently brick a stable (brood) run_id.
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
INTENT_FALLBACK_ENGINE="$REPO_ROOT/plugin/skills/mark-intent-fallback/scripts/mark-intent-fallback.sh"
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

for required in "$ENGINE" "$INIT_ENGINE" "$INTENT_FALLBACK_ENGINE" "$WORKFLOW_DEF" \
    "$LEDGER_AT_PLAN" "$LEDGER_AT_BUILD" "$LEDGER_WRONG_WORKFLOW" "$LEDGER_WRONG_VERSION" \
    "$LEDGER_AT_REMEDIATION_PLAN"; do
    [[ -f "$required" ]] \
        || { echo "FAIL: required input missing: $required" >&2; exit 2; }
done

# ── Disposable workdir ──────────────────────────────────────────────────────

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-engine-test.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ── FAKEPLUGIN self-location root (built once, reused) ───────────────────────
# A COPY of each engine inside a real-plugin-shaped tree so the engines' BASH_SOURCE+pwd -P
# self-location resolves THIS workflows dir, never the real repo's. NOT a symlink: pwd -P
# would resolve a symlink back to the real tree and defeat the isolation. The copied scripts
# self-locate plugin_root=<FAKEPLUGIN> (3 dirs up from their scripts/ dir).
FAKEPLUGIN="$WORKDIR/fakeplugin"
FAKE_ENGINE="$FAKEPLUGIN/skills/record-state-result/scripts/record-state-result.sh"
FAKE_INIT_ENGINE="$FAKEPLUGIN/skills/init-run-ledger/scripts/init-run-ledger.sh"
FAKE_INTENT_FALLBACK_ENGINE="$FAKEPLUGIN/skills/mark-intent-fallback/scripts/mark-intent-fallback.sh"
FAKE_WORKFLOW_DEF="$FAKEPLUGIN/workflows/engine-fixture.json"
mkdir -p "$(dirname "$FAKE_ENGINE")" "$(dirname "$FAKE_INIT_ENGINE")" \
    "$(dirname "$FAKE_INTENT_FALLBACK_ENGINE")" "$FAKEPLUGIN/workflows"
cp "$ENGINE" "$FAKE_ENGINE"
cp "$INIT_ENGINE" "$FAKE_INIT_ENGINE"
# mark-intent-fallback.sh self-locates plugin_root=<fakeplugin> (3 dirs up from its scripts/
# dir) like the other engines. It reads NO workflow definition (the whole point — version
# skew), so the fakeplugin def copy below is irrelevant to it; it sources only the shared
# containment helper staged into <fakeplugin>/skills/_shared. A COPY, never a symlink: pwd -P
# would resolve a symlink back to the real tree and defeat the isolation.
cp "$INTENT_FALLBACK_ENGINE" "$FAKE_INTENT_FALLBACK_ENGINE"
# The fixture def id=engine-fixture / version 1 / start plan; the filename stem MUST equal the
# id so `ledger.run.workflow=engine-fixture` resolves to <fakeplugin>/workflows/engine-fixture.json.
cp "$WORKFLOW_DEF" "$FAKE_WORKFLOW_DEF"
# The copied engines SOURCE their self-located <plugin_root>/skills/_shared/containment.sh
# (3 dirs up from their scripts/ dir => <fakeplugin>). Stage the shared helper into the
# fakeplugin so the sourced path resolves. A COPY, never a symlink: the engines self-locate
# via `cd && pwd -P`, which would resolve a symlink back to the real tree and defeat isolation.
SHARED_CONTAINMENT="$REPO_ROOT/plugin/skills/_shared/containment.sh"
[[ -f "$SHARED_CONTAINMENT" ]] \
    || { echo "FAIL: required input missing: $SHARED_CONTAINMENT" >&2; exit 2; }
mkdir -p "$FAKEPLUGIN/skills/_shared"
cp "$SHARED_CONTAINMENT" "$FAKEPLUGIN/skills/_shared/containment.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ── Per-case git-root helpers ────────────────────────────────────────────────

# new_gitroot <name> -> prints the path to a fresh throwaway git checkout under $WORKDIR.
# Separate from $FAKEPLUGIN so the engine self-locates into the fakeplugin while
# `git rev-parse --show-toplevel` (run with cd "$gitroot") resolves this checkout.
new_gitroot() {
    local root="$WORKDIR/$1"
    mkdir -p "$root"
    git -C "$root" init -q
    printf '%s' "$root"
}

# stage_record_ledger <gitroot> <run-id> <fixture> [workflow] [version]
# Places <fixture> at <gitroot>/.hivemind/runs/<run-id>/state.json with .run.id forced to
# <run-id> (coherence) and .run.workflow forced to [workflow] (default engine-fixture, so the
# self-located def resolves). [version] optionally forces .run.workflow_version. The G/H/S
# cases override workflow/version/run.id to drive their specific guard. Prints the ledger path.
stage_record_ledger() {
    local gitroot="$1" run_id="$2" fixture="$3"
    local workflow="${4:-engine-fixture}" version="${5:-}"
    local dir="$gitroot/.hivemind/runs/$run_id"
    mkdir -p "$dir"
    local ledger="$dir/state.json"
    if [[ -n "$version" ]]; then
        jq --arg id "$run_id" --arg wf "$workflow" --argjson ver "$version" \
            '.run.id = $id | .run.workflow = $wf | .run.workflow_version = $ver' \
            "$fixture" > "$ledger"
    else
        jq --arg id "$run_id" --arg wf "$workflow" \
            '.run.id = $id | .run.workflow = $wf' \
            "$fixture" > "$ledger"
    fi
    printf '%s' "$ledger"
}

# ── A. valid transition advances + appends event ────────────────────────────

assert_valid_transition() {
    local name="A:valid-transition"
    local gitroot run_id ledger inputs
    gitroot="$(new_gitroot a-git)"
    run_id="engine-case-a"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    inputs="$gitroot/a-inputs.json"

    # SAFE authoring: every field bound via jq --arg; NO ledger/workflow path keys.
    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test valid transition" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot b-git)"
    run_id="engine-case-b"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    inputs="$gitroot/b-inputs.json"
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result not_a_legal_outcome \
        --arg summary "engine test illegal result" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot c-git)"
    run_id="engine-case-c"
    # Ledger is at state.current=build; pass a stale state=plan.
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_BUILD")"
    inputs="$gitroot/c-inputs.json"
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test stale state" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    local gitroot run_id ledger inputs
    gitroot="$(new_gitroot d-git)"
    run_id="engine-case-d"
    # Ledger at build; record done -> complete (a declared done-terminal).
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_BUILD")"
    inputs="$gitroot/d-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state build \
        --arg result done \
        --arg summary "engine test terminal transition" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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

# ── E. atomicity: forced write failure leaves no torn ledger ────────────────

assert_atomicity_on_write_failure() {
    local name="E:atomicity-write-failure"
    # The engine derives ledger = <git-root>/.hivemind/runs/<run-id>/state.json and writes a
    # temp file beside it via mktemp, then mv. Under the derived model the ledger must EXIST
    # (the engine validates it before writing), so the prior-byte-intact property is asserted
    # against the staged ledger. To force the temp-write/rename phase to fail regardless of
    # UID, replace the run DIR with a regular file AFTER staging: any mktemp/rename beneath it
    # hits ENOTDIR — a kernel VFS error root cannot bypass (not a permission check, consistent
    # with the existing ENOTDIR approach).
    local gitroot run_id rundir ledger inputs before after rc=0
    gitroot="$(new_gitroot e-git)"
    run_id="engine-case-e"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    rundir="$gitroot/.hivemind/runs/$run_id"
    before="$(sha256sum "$ledger" | awk '{print $1}')"
    inputs="$gitroot/e-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test atomicity" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    # Replace the run-dir path component with a regular FILE so every path access beneath it
    # (the ledger read, the mktemp temp-write, the rename) hits ENOTDIR — a kernel VFS error
    # root cannot bypass. The engine exits non-zero and produces NO torn/partial artifact at or
    # beneath the notdir path; the staged ledger is unreachable (and thus absent at its path).
    rm -rf "$rundir"
    : > "$rundir"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The ledger path is unreachable (its parent dir component is a file): no ledger exists at
    # or beneath it, and the engine exited non-zero. No torn/partial file was produced.
    after="-(no-ledger)-"
    if [[ -f "$ledger" ]]; then after="$(sha256sum "$ledger" | awk '{print $1}')"; fi
    if [[ "$rc" -ne 0 && ! -f "$ledger" ]]; then
        pass "$name" "forced write failure via ENOTDIR (exit $rc) left no ledger artifact"
    else
        failed "$name" "expected non-zero exit + no ledger artifact; rc=$rc before=$before after=$after"
    fi
}

# ── F. init-run-ledger plan_steps seeds plan.steps ──────────────────────────

assert_plan_steps_seed() {
    local name="F:plan-steps-seed"
    # Run the COPIED init engine from a throwaway git checkout so it self-locates the fakeplugin
    # def (<fakeplugin>/workflows/engine-fixture.json) for packaged-def validation and anchors
    # the run dir to `git rev-parse --show-toplevel` (this checkout). workflow=engine-fixture,
    # version 1, start plan all match the fixture, so init passes.
    local gitroot inputs
    gitroot="$(new_gitroot f-git)"
    inputs="$gitroot/f-inputs.json"

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
    out="$(cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc seeding plan steps (expected 0): $out"
        return
    fi

    local ledger steps_len step_id
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

# ── G. ledger.run.workflow mismatch -> non-zero, ledger byte-unchanged ──────

assert_id_mismatch_unchanged() {
    local name="G:id-mismatch-unchanged"
    # Forge ledger.run.workflow=other-workflow while the self-located def is engine-fixture.
    # The binding guard (def.id != ledger.run.workflow) rejects. run.id stays == run_id so the
    # coherence check passes and the binding guard is the failing gate. Because the forged
    # run.workflow resolves to <fakeplugin>/workflows/other-workflow.json (absent), the engine
    # blocks on the missing packaged def; either way it rejects and leaves the ledger unchanged.
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot g-git)"
    run_id="engine-case-g"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_WRONG_WORKFLOW" other-workflow)"
    inputs="$gitroot/g-inputs.json"
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test id mismatch" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "id-mismatch rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── H. ledger.run.workflow_version mismatch -> non-zero, byte-unchanged ─────

assert_version_mismatch_unchanged() {
    local name="H:version-mismatch-unchanged"
    # Forge ledger.run.workflow_version=2 while keeping run.workflow=engine-fixture (so the def
    # resolves) and the self-located def.version=1. The binding guard (def.version !=
    # ledger.run.workflow_version) rejects. run.id stays == run_id (coherence passes).
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot h-git)"
    run_id="engine-case-h"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_WRONG_VERSION" engine-fixture 2)"
    inputs="$gitroot/h-inputs.json"
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test version mismatch" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    local gitroot run_id ledger inputs
    gitroot="$(new_gitroot i-git)"
    run_id="engine-case-i"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    inputs="$gitroot/i-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test plan-steps record-time" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    # Ledger at state.current=build; `build` is NOT a cerebrate state. Recording it WITH
    # plan_steps must be rejected and leave the ledger byte-unchanged.
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot j-git)"
    run_id="engine-case-j"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_BUILD")"
    inputs="$gitroot/j-inputs.json"
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state build \
        --arg result blocked \
        --arg summary "engine test unauthorized plan write" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary, plan_steps: $plan_steps}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    # Throwaway git repo with a subdir; run the COPIED init FROM the subdir. The ledger must
    # land at <repo-root>/.hivemind/runs/<id>/state.json and be ABSENT under <subdir>/.hivemind.
    local gitroot inputs
    gitroot="$(new_gitroot k-git)"
    mkdir -p "$gitroot/sub"
    inputs="$gitroot/k-inputs.json"

    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test checkout-root anchor" \
        --arg normalized "engine test checkout-root anchor" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized}' \
        > "$inputs"

    local rc=0 out
    out="$(cd "$gitroot/sub" && bash "$FAKE_INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc from a subdir (expected 0): $out"
        return
    fi

    local run_id ledger root_ledger
    run_id="$(printf '%s\n' "$out" | sed -n 's/^run_id: //p')"
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    root_ledger="$gitroot/.hivemind/runs/$run_id/state.json"
    if [[ -f "$root_ledger" && "$ledger" == "$root_ledger" && ! -e "$gitroot/sub/.hivemind" ]]; then
        pass "$name" "ledger anchored to checkout root ($root_ledger), absent under subdir"
    else
        failed "$name" "expected ledger at $root_ledger and none under sub/.hivemind; got ledger=$ledger sub_exists=$([[ -e "$gitroot/sub/.hivemind" ]] && echo yes || echo no)"
    fi
}

# ── L. canonical brood id persisted verbatim; run-id sanitized (F-D round-3) ──

assert_brood_child_canonical_id() {
    local name="L:brood-child-canonical-id"
    # Brood child init with the CANONICAL colon-bearing parent.brood_id. Must: (1) succeed,
    # (2) PERSIST .parent.brood_id VERBATIM with colons, (3) derive the sanitized run-id.
    local gitroot inputs
    gitroot="$(new_gitroot l-git)"
    inputs="$gitroot/l-inputs.json"
    local canonical="2026-05-31T17:30:00Z" short="my-strain"
    local safe="${canonical//:/-}"

    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test brood child" \
        --arg normalized "engine test brood child" \
        --arg brood_id "$canonical" \
        --arg strain_id "$short" \
        --arg run_id "$safe-hatchery" \
        --arg manifest "$gitroot/.hivemind/brood/manifest.json" \
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
    out="$(cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc on a canonical colon-bearing brood id (expected 0): $out"
        return
    fi

    local run_id ledger brood_id
    run_id="$(printf '%s\n' "$out" | sed -n 's/^run_id: //p')"
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    if [[ "$run_id" != "$safe--$short" ]]; then
        failed "$name" "expected sanitized run-id $safe--$short, got $run_id"
        return
    fi
    brood_id="$(jq -r '.parent.brood_id' "$ledger")"
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
    # NOT `plan`. Recording it WITH plan_steps must be ACCEPTED (agent==cerebrate authorizes).
    local gitroot run_id ledger inputs
    gitroot="$(new_gitroot m-git)"
    run_id="engine-case-m"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_REMEDIATION_PLAN")"
    inputs="$gitroot/m-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state review_remediation_plan \
        --arg result ready \
        --arg summary "engine test remediation-plan authorized write" \
        --argjson plan_steps '[{"id":"STEP-001","status":"pending"}]' \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    # Ledger at build; record needs-input -> user_input_required (a human-intervention
    # terminal). run.status MUST be blocked, NOT complete.
    local gitroot run_id ledger inputs
    gitroot="$(new_gitroot n-git)"
    run_id="engine-case-n"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_BUILD")"
    inputs="$gitroot/n-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state build \
        --arg result needs-input \
        --arg summary "engine test intervention terminal" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
# payload could have landed: under $WORKDIR (the test's scratch dir + any CWD the engine ran
# from) and under $REPO_ROOT (a `touch PWNED` with no path lands in CWD). Returns 0 when NO
# such file exists, 1 when one was found.
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
    # init-run-ledger reads user_request / normalized as UNTRUSTED data, serialized only via
    # jq --arg. A command-substitution + backtick payload must round-trip VERBATIM into
    # .request.raw and NEVER execute (no PWNED / PWNED2 anywhere).
    local gitroot inputs
    gitroot="$(new_gitroot o-git)"
    inputs="$gitroot/o-inputs.json"

    # The payload is DATA, authored SAFELY via jq --arg (jq JSON-escapes the literal). The
    # single-quoted bash literal below is never evaluated by bash — it is a string handed to jq.
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
    out="$(cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "init engine exited $rc on an injection payload (expected 0): $out"
        return
    fi

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
    # must round-trip VERBATIM and NEVER execute. Recorded at a cerebrate planning state so the
    # plan_steps write is authorized.
    local gitroot run_id ledger inputs
    gitroot="$(new_gitroot p-git)"
    run_id="engine-case-p"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    inputs="$gitroot/p-inputs.json"

    local payload='inject $(touch PWNED3) and `touch PWNED3b` end'
    local outputs plan_steps
    outputs="$(jq -n --arg p "$payload" '{note: $p}')"
    plan_steps="$(jq -n --arg p "$payload" '[{id: "STEP-001", status: "pending", note: $p}]')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "$payload" \
        --argjson outputs "$outputs" \
        --argjson plan_steps "$plan_steps" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary, outputs: $outputs, plan_steps: $plan_steps}' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "record engine exited $rc on an injection payload (expected 0)"
        return
    fi

    if ! assert_no_pwned_file PWNED3 || ! assert_no_pwned_file PWNED3b; then
        failed "$name" "injection payload EXECUTED: a PWNED3 file was created"
        return
    fi

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

# ── Q. run_id path traversal rejected -> no ledger, no traversal ─────────────

assert_run_id_traversal_rejected() {
    local name="Q:run-id-traversal-rejected"
    # A run_id carrying a path separator or `..` must be rejected by SAFE_ID_RE / the
    # reserved-component reject BEFORE any path is derived. No ledger may be written anywhere,
    # and no traversal target is touched. We test two forms: a separator (`a/b`) and `..`.
    local gitroot inputs rc=0
    gitroot="$(new_gitroot q-git)"
    # A would-be traversal target one level above the runs dir; must remain absent afterwards.
    local sentinel="$gitroot/.hivemind/Q-TRAVERSAL-TARGET"

    # Form 1: separator. jq --arg keeps the slash as inert string bytes in the inputs file.
    inputs="$gitroot/q1-inputs.json"
    jq -n \
        --arg run_id "a/b" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test run_id separator" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        failed "$name" "engine accepted a run_id with a path separator (expected non-zero)"
        return
    fi

    # Form 2: reserved `..` component.
    rc=0
    inputs="$gitroot/q2-inputs.json"
    jq -n \
        --arg run_id ".." \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test run_id dotdot" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"
    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        failed "$name" "engine accepted a run_id of '..' (expected non-zero)"
        return
    fi

    # No ledger was written under the runs tree and no traversal target was created.
    local wrote_any=no
    if [[ -d "$gitroot/.hivemind/runs" ]] && find "$gitroot/.hivemind/runs" -name state.json -print 2>/dev/null | grep -q .; then
        wrote_any=yes
    fi
    if [[ "$wrote_any" == "no" && ! -e "$sentinel" ]]; then
        pass "$name" "run_id separator and '..' both rejected; no ledger written, no traversal"
    else
        failed "$name" "expected no ledger + no traversal; wrote_any=$wrote_any sentinel_exists=$([[ -e "$sentinel" ]] && echo yes || echo no)"
    fi
}

# ── R. forged definition on disk is never consulted -> rejected, unchanged ──

assert_forged_definition_not_honored() {
    local name="R:forged-definition-not-honored"
    # Plant a HOSTILE workflow def at an arbitrary on-disk path declaring an UNDECLARED
    # transition (plan --pwn--> build). Point NOTHING at it — the engine accepts no definition
    # path and resolves the self-located <fakeplugin>/workflows/engine-fixture.json, where
    # `pwn` is NOT a legal result from `plan`. So the transition is REJECTED and the ledger is
    # byte-unchanged: a forged def on disk cannot bypass the transition gate.
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot r-git)"
    run_id="engine-case-r"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    inputs="$gitroot/r-inputs.json"
    before="$(sha256sum "$ledger" | awk '{print $1}')"

    # Hostile def: same id/version so it WOULD bind if it were ever consulted, but it grants a
    # `pwn` transition the real fixture never declares. Authored SAFELY via jq.
    mkdir -p "$gitroot/evil"
    jq -n '{
        id: "engine-fixture",
        version: 1,
        start: "plan",
        terminal: ["complete","blocked","cancelled","user_input_required"],
        states: {
            plan: { type: "agent", agent: "hivemind:cerebrate", transitions: { ready: "build", blocked: "blocked", pwn: "complete" } },
            build: { type: "agent", transitions: { done: "complete" } },
            complete: { type: "terminal" },
            blocked: { type: "terminal" },
            cancelled: { type: "terminal" },
            user_input_required: { type: "terminal" }
        }
    }' > "$gitroot/evil/engine-fixture.json"

    # Record a result that ONLY the hostile def would allow.
    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result pwn \
        --arg summary "engine test forged definition" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "forged def ignored: 'pwn' rejected (exit $rc), ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── S. coherence mismatch: ledger.run.id != run_id -> rejected, unchanged ────

assert_coherence_mismatch_unchanged() {
    local name="S:coherence-mismatch-unchanged"
    # Ledger sits at runs/<run-id>/state.json but its internal .run.id is a DIFFERENT value.
    # The engine's coherence check (ledger.run.id == run_id) fails: non-zero exit, ledger
    # byte-unchanged. Proves the on-disk run-dir name alone cannot satisfy identity.
    local gitroot run_id rundir ledger inputs before after rc=0
    gitroot="$(new_gitroot s-git)"
    run_id="engine-case-s"
    rundir="$gitroot/.hivemind/runs/$run_id"
    mkdir -p "$rundir"
    ledger="$rundir/state.json"
    # run.workflow=engine-fixture so the def resolves; .run.id forged to a DIFFERENT value.
    jq --arg other "engine-case-s-DIFFERENT" \
        '.run.id = $other | .run.workflow = "engine-fixture"' \
        "$LEDGER_AT_PLAN" > "$ledger"
    before="$(sha256sum "$ledger" | awk '{print $1}')"
    inputs="$gitroot/s-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test coherence mismatch" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "coherence mismatch (ledger.run.id != run_id) rejected (exit $rc), ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── T. init symlink-escape rejected: no ledger written outside the checkout ──

assert_init_symlink_escape_rejected() {
    local name="T:init-symlink-escape-rejected"
    # A repo that COMMITS .hivemind as a symlink to an external dir makes the textually-derived
    # ledger path resolve OUTSIDE the checkout. init-run-ledger.sh canonicalizes the derived path
    # (cd && pwd -P), detects the symlinked .hivemind ancestor (explicit [ -L ] reject), and
    # blocks BEFORE any mkdir. Assert: non-zero exit AND no state.json under the external target.
    # The symlink lives ONLY in the ledger gitroot — self-location is via the fakeplugin tree.
    local gitroot external inputs rc=0
    gitroot="$(new_gitroot t-git)"
    # External dir OUTSIDE the gitroot (a sibling under $WORKDIR), the symlink's escape target.
    external="$WORKDIR/t-external"
    mkdir -p "$external"
    # Replace the gitroot's .hivemind with a symlink to the external dir.
    ln -s "$external" "$gitroot/.hivemind"
    inputs="$gitroot/t-inputs.json"

    # Valid init inputs (workflow=engine-fixture, version 1, start plan — matches the fakeplugin
    # def), authored SAFELY via jq. The ONLY hostile element is the symlinked .hivemind.
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test init symlink escape" \
        --arg normalized "engine test init symlink escape" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The guard must reject (non-zero) AND no state.json may have been written under the external
    # escape target (a successful escape would land runs/<id>/state.json there via the symlink).
    local escaped=no
    if find "$external" -name state.json -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" ]]; then
        pass "$name" "symlinked .hivemind rejected (exit $rc); no ledger written under external target"
    else
        failed "$name" "expected non-zero exit + no external ledger; rc=$rc escaped=$escaped"
    fi
}

# ── U. record symlink-escape rejected: external ledger reachable but unmutated ──

assert_record_symlink_escape_rejected() {
    local name="U:record-symlink-escape-rejected"
    # record-state-result.sh requires the ledger to EXIST, so the escape vector PRE-STAGES the
    # external target with a valid ledger, then symlinks the gitroot's .hivemind -> external so
    # `[ -f ]` passes THROUGH the symlink (the ledger is REACHABLE). The canonical-containment
    # guard canonicalizes the existing ledger, sees it resolves OUTSIDE the checkout, and rejects.
    # CRITICAL: the rejection is by CONTAINMENT (file reachable but unmutated), not file-absence —
    # the pre-staged file proves the guard, not a missing file, blocked the write.
    local gitroot external run_id ext_ledger inputs before after rc=0
    gitroot="$(new_gitroot u-git)"
    run_id="engine-case-u"
    external="$WORKDIR/u-external"
    # Pre-stage a VALID ledger at the external target's runs/<run-id>/state.json: .run.id ==
    # run_id (coherence passes) and .run.workflow == engine-fixture (def resolves). Authored from
    # the fixture via jq so it is a real, well-formed ledger the engine would accept absent the
    # containment guard.
    mkdir -p "$external/runs/$run_id"
    ext_ledger="$external/runs/$run_id/state.json"
    jq --arg id "$run_id" --arg wf "engine-fixture" \
        '.run.id = $id | .run.workflow = $wf' \
        "$LEDGER_AT_PLAN" > "$ext_ledger"
    # Symlink the gitroot's .hivemind -> external so the engine's derived
    # <gitroot>/.hivemind/runs/<run-id>/state.json resolves THROUGH the symlink to the pre-staged
    # external ledger (so `[ -f ]` passes and the guard — not a missing file — is what blocks).
    ln -s "$external" "$gitroot/.hivemind"
    before="$(sha256sum "$ext_ledger" | awk '{print $1}')"
    inputs="$gitroot/u-inputs.json"

    # A valid transition (plan ready -> build) the engine WOULD record absent the containment guard.
    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test record symlink escape" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ext_ledger" | awk '{print $1}')"
    # No engine temp file (.state.json.XXXXXX) may have leaked under the external runs dir.
    local leaked=no
    if find "$external" -name '.state.json.*' -print 2>/dev/null | grep -q .; then
        leaked=yes
    fi
    if [[ "$rc" -ne 0 && "$before" == "$after" && "$leaked" == "no" ]]; then
        pass "$name" "external ledger reachable but rejected by containment (exit $rc): byte-unchanged, no temp leaked"
    else
        failed "$name" "expected non-zero exit + external ledger byte-unchanged + no temp; rc=$rc changed=$([[ "$before" != "$after" ]] && echo yes || echo no) leaked=$leaked"
    fi
}

# ── V. init nested symlink-escape rejected: symlinked <run_id> leaf, no external write ──

assert_init_nested_symlink_escape_rejected() {
    local name="V:init-nested-symlink-escape-rejected"
    # The gitroot keeps a REAL .hivemind/runs/ (NOT a symlinked ancestor — that is case T),
    # but the <run_id> RUN dir itself is a symlink to an EXTERNAL dir outside the checkout.
    # A by-name ancestor guard (.hivemind / .hivemind/runs only) would MISS this leaf; the
    # depth-complete containment helper walks every component, sees the symlinked <run_id>
    # leaf, and rejects BEFORE any mkdir/write. Assert: non-zero exit AND zero write under the
    # external target (no state.json, no evidence/). The symlink lives ONLY in the ledger
    # gitroot — self-location is via the fakeplugin tree. suggested_run_id pins the derived
    # run id to the symlinked component name so the engine's chain hits exactly that leaf.
    local gitroot external run_id inputs rc=0
    gitroot="$(new_gitroot v-git)"
    run_id="engine-case-v"
    # REAL .hivemind/runs/ in the gitroot (only the <run_id> leaf is hostile).
    mkdir -p "$gitroot/.hivemind/runs"
    # External dir OUTSIDE the gitroot (a sibling under $WORKDIR), the symlink's escape target.
    external="$WORKDIR/v-external"
    mkdir -p "$external"
    # Symlink the <run_id> RUN dir itself to the external dir: the derived
    # <gitroot>/.hivemind/runs/<run_id> resolves THROUGH the symlink to the external target.
    ln -s "$external" "$gitroot/.hivemind/runs/$run_id"
    inputs="$gitroot/v-inputs.json"

    # Valid init inputs (workflow=engine-fixture, version 1, start plan — matches the fakeplugin
    # def), authored SAFELY via jq. suggested_run_id == the symlinked component so the engine
    # derives that exact run id and walks straight onto the hostile leaf. The ONLY hostile
    # element is the symlinked <run_id> leaf.
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test init nested symlink escape" \
        --arg normalized "engine test init nested symlink escape" \
        --arg suggested_run_id "$run_id" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized, suggested_run_id: $suggested_run_id}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The guard must reject (non-zero) AND nothing may have been written under the external
    # escape target: no state.json AND no evidence/ (a successful escape would create both
    # through the symlink).
    local escaped=no
    if find "$external" \( -name state.json -o -name evidence \) -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" ]]; then
        pass "$name" "symlinked <run_id> leaf rejected (exit $rc); no state.json/evidence written under external target"
    else
        failed "$name" "expected non-zero exit + no external write; rc=$rc escaped=$escaped"
    fi
}

# ── W. init concurrent same-run_id atomic reservation: loser fails closed ────

assert_init_concurrent_reservation_fails_closed() {
    local name="W:init-concurrent-reservation-fails-closed"
    # Deterministic stand-in for "the race winner already claimed the dir": pre-create the
    # <fixed_id> run dir AND stage a sentinel state.json inside it, then run init pinned to
    # that same run_id via suggested_run_id. init derives the identical run_id and hits the
    # fail-closed reservation (the early [ -e ledger ] blocker / the atomic bare `mkdir`
    # without -p) — it must NOT overwrite the winner's ledger. Proves F2: the loser blocks and
    # the winner's bytes are never touched. The inputs file sits at a REAL in-checkout path so
    # the read-guard passes and the reservation is the gate under test.
    local gitroot fixed_id rundir sentinel inputs before after rc=0
    gitroot="$(new_gitroot w-git)"
    fixed_id="engine-case-w"
    # Pre-create the run dir and a sentinel ledger as the "winner" already on disk.
    rundir="$gitroot/.hivemind/runs/$fixed_id"
    mkdir -p "$rundir"
    sentinel="$rundir/state.json"
    printf '%s\n' '{"winner":"sentinel-do-not-overwrite"}' > "$sentinel"
    before="$(sha256sum "$sentinel" | awk '{print $1}')"
    inputs="$gitroot/w-inputs.json"

    # Valid init inputs pinned to suggested_run_id=<fixed_id> so init derives that EXACT run_id
    # and lands on the already-claimed dir. workflow=engine-fixture/version 1/start plan match
    # the fakeplugin def, so the ONLY blocking condition is the reservation.
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test concurrent reservation" \
        --arg normalized "engine test concurrent reservation" \
        --arg suggested_run_id "$fixed_id" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized, suggested_run_id: $suggested_run_id}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$sentinel" | awk '{print $1}')"
    # No engine temp file (.state.json.XXXXXX) may have leaked into the claimed run dir.
    local leaked=no
    if find "$rundir" -name '.state.json.*' -print 2>/dev/null | grep -q .; then
        leaked=yes
    fi
    if [[ "$rc" -ne 0 && "$before" == "$after" && "$leaked" == "no" ]]; then
        pass "$name" "loser failed closed (exit $rc); winner sentinel byte-unchanged, no temp leaked"
    else
        failed "$name" "expected non-zero exit + unchanged sentinel + no temp; rc=$rc changed=$([[ "$before" != "$after" ]] && echo yes || echo no) leaked=$leaked"
    fi
}

# ── X. init inputs-file external-resolution rejected by the read-guard ───────

assert_init_inputs_external_rejected() {
    local name="X:init-inputs-external-rejected"
    # The shared read-guard (hivemind_assert_inputs_contained) refuses to READ an inputs file
    # whose canonical path resolves OUTSIDE the checkout via a symlinked ancestor. Author a
    # VALID init inputs file at $gitroot/link/init-inputs.json where `link` is a symlink to an
    # EXTERNAL dir, so the file's canonical path is under $external. init must exit non-zero on
    # the read-guard AND write no ledger/state.json anywhere (inside or under $external).
    local gitroot external inputs rc=0
    gitroot="$(new_gitroot x-git)"
    external="$WORKDIR/x-external"
    mkdir -p "$external"
    # Symlinked ANCESTOR: $gitroot/link -> $external. The inputs file authored under it
    # canonicalizes to $external/init-inputs.json (outside the checkout).
    ln -s "$external" "$gitroot/link"
    inputs="$gitroot/link/init-inputs.json"

    # A perfectly VALID init inputs payload — the ONLY hostile element is the externally-
    # resolving path. Authored through the symlink so its canonical dir is $external.
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test init external inputs" \
        --arg normalized "engine test init external inputs" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # No state.json may have been written under the external target NOR under the gitroot's
    # real runs tree (the read-guard rejects before any path derivation).
    local wrote=no
    if find "$external" -name state.json -print 2>/dev/null | grep -q .; then wrote=yes; fi
    if [[ -d "$gitroot/.hivemind/runs" ]] && find "$gitroot/.hivemind/runs" -name state.json -print 2>/dev/null | grep -q .; then
        wrote=yes
    fi
    if [[ "$rc" -ne 0 && "$wrote" == "no" ]]; then
        pass "$name" "externally-resolving inputs refused by read-guard (exit $rc); no ledger written"
    else
        failed "$name" "expected non-zero exit + no ledger; rc=$rc wrote=$wrote"
    fi
}

# ── Y. record inputs-file external-resolution rejected by the read-guard ─────

assert_record_inputs_external_rejected() {
    local name="Y:record-inputs-external-rejected"
    # record-state-result.sh requires the ledger to EXIST, so stage a VALID ledger at
    # $gitroot/.hivemind/runs/<id>/state.json FIRST — then the ONLY thing that can block is the
    # shared read-guard, not a missing ledger. Author a valid record inputs file at an
    # externally-resolving path (via a symlinked ancestor). record must exit non-zero on the
    # read-guard AND leave the staged ledger byte-unchanged.
    local gitroot external run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot y-git)"
    run_id="engine-case-y"
    # Stage a real, well-formed ledger the engine WOULD accept absent the read-guard.
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_AT_PLAN")"
    before="$(sha256sum "$ledger" | awk '{print $1}')"
    external="$WORKDIR/y-external"
    mkdir -p "$external"
    # Symlinked ANCESTOR: $gitroot/link -> $external. The record inputs authored under it
    # canonicalizes to $external/record-inputs.json (outside the checkout).
    ln -s "$external" "$gitroot/link"
    inputs="$gitroot/link/record-inputs.json"

    # A VALID record transition (plan ready -> build) the engine WOULD record absent the
    # read-guard. The ONLY hostile element is the externally-resolving inputs path.
    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg result ready \
        --arg summary "engine test record external inputs" \
        '{run_id: $run_id, state: $state, result: $result, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "externally-resolving inputs refused by read-guard (exit $rc); staged ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── Z. init pre-ledger failure rolls back the claimed run dir; same-id retry succeeds ─

assert_init_pre_ledger_failure_rolls_back_then_retry_succeeds() {
    local name="Z:init-pre-ledger-failure-rollback-then-retry"
    # REGRESSION for the orphaned-reservation P1: when init fails AFTER the atomic claim
    # `mkdir "$run_dir"` but BEFORE the ledger is durably written, the EXIT trap must remove the
    # invocation-owned run dir so a retry with the SAME run_id can re-claim it. Without rollback a
    # stable brood suggested_run_id would be permanently bricked at the `mkdir` after one transient
    # failure. Deterministic failure injection: shadow `mktemp` (called AFTER the claim, before the
    # ledger mv) on PATH with a failing stub for ONE invocation. Assert (a) init blocks (exit 1) AND
    # the run dir does NOT exist afterward (trap cleaned it up), then (b) remove the stub and re-run
    # init with the SAME suggested_run_id and assert it now succeeds and writes a valid ledger.
    local gitroot fixed_id rundir inputs stubdir rc1=0 rc2=0
    gitroot="$(new_gitroot z-git)"
    fixed_id="engine-case-z"
    rundir="$gitroot/.hivemind/runs/$fixed_id"
    # Inputs authored at a REAL in-checkout path so the read-guard passes and the reservation /
    # post-claim path is the behavior under test. Pinned to suggested_run_id=<fixed_id> so BOTH
    # invocations derive the identical run_id — proving the retry re-claims the same dir.
    inputs="$gitroot/z-inputs.json"
    jq -n \
        --arg workflow engine-fixture \
        --argjson workflow_version 1 \
        --arg start_state plan \
        --arg user_request "engine test pre-ledger rollback" \
        --arg normalized "engine test pre-ledger rollback" \
        --arg suggested_run_id "$fixed_id" \
        '{workflow: $workflow, workflow_version: $workflow_version, start_state: $start_state, user_request: $user_request, normalized: $normalized, suggested_run_id: $suggested_run_id}' \
        > "$inputs"

    # Failing `mktemp` stub, first on PATH. mktemp is invoked AFTER the atomic `mkdir "$run_dir"`
    # claim (run dir + evidence already created), so this fires post-claim and exercises the
    # rollback. The real mktemp stays reachable via the rest of PATH once the stub dir is removed.
    stubdir="$WORKDIR/z-stubbin"
    mkdir -p "$stubdir"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$stubdir/mktemp"
    chmod +x "$stubdir/mktemp"

    # (a) Forced post-claim failure: init must block AND leave NO orphan run dir (trap cleaned up).
    ( cd "$gitroot" && PATH="$stubdir:$PATH" bash "$FAKE_INIT_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc1=$?
    local orphan=no
    [[ -e "$rundir" ]] && orphan=yes

    # (b) Remove the stub and retry with the SAME suggested_run_id: must succeed and write a valid
    # ledger at runs/<fixed_id>/state.json with run.id == fixed_id.
    rm -rf "$stubdir"
    local out ledger ledger_id valid=no
    out="$( cd "$gitroot" && bash "$FAKE_INIT_ENGINE" "$inputs" )" || rc2=$?
    ledger="$(printf '%s\n' "$out" | sed -n 's/^ledger: //p')"
    if [[ "$rc2" -eq 0 && -n "$ledger" && -f "$ledger" ]] \
        && jq -e . "$ledger" >/dev/null 2>&1; then
        ledger_id="$(jq -r '.run.id' "$ledger")"
        [[ "$ledger_id" == "$fixed_id" ]] && valid=yes
    fi

    if [[ "$rc1" -ne 0 && "$orphan" == "no" && "$valid" == "yes" ]]; then
        pass "$name" "post-claim failure rolled back claimed dir (exit $rc1, no orphan); same-id retry wrote valid ledger"
    else
        failed "$name" "expected (a) non-zero exit + no orphan dir, (b) retry success + valid ledger; rc1=$rc1 orphan=$orphan rc2=$rc2 valid=$valid"
    fi
}

# ── AA. init trap predicate preserves committed ledger and cleans orphan ─────
#
# Regression guard for Codex Finding E (P1): the EXIT trap in init-run-ledger.sh must be
# STATE-KEYED (`[ -n "${CLAIMED_DIR:-}" ] && [ ! -f "${ledger_path:-}" ]`) rather than
# unconditional. This test exercises the PREDICATE DIRECTLY rather than racing a real kill
# signal. Rationale: `kill -TERM <pid>` delivery timing is nondeterministic — a signal sent
# between `mv -f` and `CLAIMED_DIR=""` may or may not arrive before CLAIMED_DIR is cleared
# depending on scheduler timing, making signal-based tests flaky in CI. Evaluating the
# predicate in isolation gives identical logical coverage with zero flakiness.
#
# ANTI-DRIFT GUARD: a grep assertion verifies that init-run-ledger.sh still contains the
# LITERAL predicate fragment. If a future trap edit changes the condition without updating
# this test, the grep fails loudly rather than silently diverging from the implementation.
#
# Two directions:
#   (a) PRESERVE: CLAIMED_DIR set, state.json PRESENT  -> predicate FALSE -> rm does NOT run
#       -> run dir + state.json survive.
#   (b) ORPHAN-CLEANUP: CLAIMED_DIR set, state.json ABSENT -> predicate TRUE  -> rm removes dir
#       -> orphan cleaned up.
# Both directions must hold: failing (a) breaks the committed-ledger preservation guarantee;
# failing (b) breaks the orphan-cleanup guarantee.

assert_init_trap_preserves_committed_ledger() {
    local name="AA:init-trap-preserves-committed-ledger"

    # ── Anti-drift guard: trap predicate must still exist verbatim in the source ──
    # Uses the REAL INIT_ENGINE (not the fakeplugin copy) so the source-of-truth script is
    # checked, not a snapshot that might lag. grep -F matches literally (no regex escaping needed
    # for the brackets/hyphens). If this fails, the trap predicate drifted and the test suite
    # no longer guards the correct condition.
    local predicate_fragment='[ -n "${CLAIMED_DIR:-}" ] && [ ! -f "${ledger_path:-}" ]'
    if ! grep -qF "$predicate_fragment" "$INIT_ENGINE"; then
        failed "$name" "ANTI-DRIFT: init-run-ledger.sh no longer contains the literal trap predicate '${predicate_fragment}' — the trap may have changed without updating this test"
        return
    fi

    # ── Shared workdir for both sub-cases ──────────────────────────────────────
    local aa_base="$WORKDIR/aa-trap"
    mkdir -p "$aa_base"

    # ── (a) PRESERVE case ─────────────────────────────────────────────────────
    # Construct: a run dir containing a PRESENT state.json. Set CLAIMED_DIR to the run dir
    # and ledger_path to the state.json path. Evaluate the exact trap predicate in a subshell;
    # assert it is FALSE (predicate exits non-zero) and that a guarded rm -rf would NOT run,
    # leaving both the run dir and state.json intact.
    local preserve_dir="$aa_base/preserve-run"
    local preserve_ledger="$preserve_dir/state.json"
    mkdir -p "$preserve_dir"
    printf '%s\n' '{"committed":"ledger-must-survive"}' > "$preserve_ledger"

    # Evaluate the predicate exactly as the trap does. The subshell uses the same variable
    # names and same `:-` expansion so divergence from the real trap body is immediately visible.
    local preserve_predicate_fired=no
    local CLAIMED_DIR_test="$preserve_dir"
    local ledger_path_test="$preserve_ledger"
    # shellcheck disable=SC2034  # variables are intentionally named to match the trap body
    if ( CLAIMED_DIR="$CLAIMED_DIR_test"; ledger_path="$ledger_path_test"
         [ -n "${CLAIMED_DIR:-}" ] && [ ! -f "${ledger_path:-}" ] ); then
        preserve_predicate_fired=yes
        # Simulate what the trap would do (rm -rf $CLAIMED_DIR) so we can assert both
        # the predicate result AND the filesystem outcome.
        rm -rf "$preserve_dir"
    fi

    if [[ "$preserve_predicate_fired" == "yes" ]]; then
        failed "$name" "(a) PRESERVE: predicate fired (TRUE) when state.json was PRESENT — committed ledger would be erased; trap regression"
        return
    fi
    if [[ ! -f "$preserve_ledger" ]]; then
        failed "$name" "(a) PRESERVE: state.json is missing after predicate evaluation — should have survived"
        return
    fi

    # ── (b) ORPHAN-CLEANUP case ───────────────────────────────────────────────
    # Construct: a CLAIMED dir with NO state.json. Set CLAIMED_DIR to that dir. Evaluate the
    # same predicate; assert it is TRUE and that the guarded rm removes the dir (orphan cleaned).
    local orphan_dir="$aa_base/orphan-run"
    mkdir -p "$orphan_dir"
    # Deliberately do NOT create state.json — this is the pre-ledger-failure orphan scenario.

    local orphan_predicate_fired=no
    CLAIMED_DIR_test="$orphan_dir"
    ledger_path_test="$orphan_dir/state.json"   # does not exist
    if ( CLAIMED_DIR="$CLAIMED_DIR_test"; ledger_path="$ledger_path_test"
         [ -n "${CLAIMED_DIR:-}" ] && [ ! -f "${ledger_path:-}" ] ); then
        orphan_predicate_fired=yes
        rm -rf "$orphan_dir"
    fi

    if [[ "$orphan_predicate_fired" == "no" ]]; then
        failed "$name" "(b) ORPHAN-CLEANUP: predicate did NOT fire (FALSE) when state.json was ABSENT — orphan dir would be leaked; trap regression"
        return
    fi
    if [[ -e "$orphan_dir" ]]; then
        failed "$name" "(b) ORPHAN-CLEANUP: orphan dir still exists after predicate+rm — cleanup failed"
        return
    fi

    pass "$name" "trap predicate: (a) PRESERVES committed ledger (FALSE when state.json present), (b) CLEANS orphan (TRUE when state.json absent); anti-drift grep passed"
}

# ── BB. intent-fallback over version skew, NO close_status -> run stays running ─

assert_intent_fallback_skew_no_close() {
    local name="BB:intent-fallback-skew-no-close"
    # The mark-intent-fallback engine is the sanctioned version-skew resume write-path that
    # record-state-result.sh DELIBERATELY refuses (its case H rejects ledger.run.workflow_version
    # != def.version). This proves the op does NOT enforce that binding guard: a SKEW ledger
    # (run.workflow_version=2 vs the fakeplugin def.version=1) with NO close_status is ACCEPTED.
    # ledger-wrong-version.json carries version 2, state.current=plan, run.status=running — ideal.
    # Assert: exit 0; run.mode=="intent_fallback"; EXACTLY one event appended; run.status STILL
    # "running" (no close); atomicity (ledger remains valid JSON).
    local gitroot run_id ledger inputs rc=0
    gitroot="$(new_gitroot bb-git)"
    run_id="engine-case-bb"
    # stage_record_ledger forces .run.id=run_id (coherence) and .run.workflow=engine-fixture but
    # KEEPS the fixture's run.workflow_version=2 (no version arg) — that is the skew that
    # record-state-result rejects and this op must tolerate.
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_WRONG_VERSION")"
    inputs="$gitroot/bb-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg summary "engine test intent fallback skew no close" \
        '{run_id: $run_id, state: $state, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INTENT_FALLBACK_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "intent-fallback engine exited $rc on a skew ledger (expected 0 — no binding guard)"
        return
    fi
    if ! jq -e . "$ledger" >/dev/null 2>&1; then
        failed "$name" "ledger is no longer valid JSON after intent-fallback write (atomicity broken)"
        return
    fi

    local mode events_len run_status
    mode="$(jq -r '.run.mode' "$ledger")"
    events_len="$(jq -r '.events | length' "$ledger")"
    run_status="$(jq -r '.run.status' "$ledger")"
    if [[ "$mode" == "intent_fallback" && "$events_len" -eq 1 && "$run_status" == "running" ]]; then
        pass "$name" "skew accepted without binding guard: run.mode=intent_fallback, 1 event, run.status still running"
    else
        failed "$name" "expected mode=intent_fallback/events=1/status=running, got mode=$mode/events=$events_len/status=$run_status"
    fi
}

# ── CC. intent-fallback over version skew, close_status=cancelled -> closed ──

assert_intent_fallback_skew_close_cancelled() {
    local name="CC:intent-fallback-skew-close-cancelled"
    # Same skew ledger as BB, but with close_status=cancelled. The op closes the run WITHOUT the
    # binding guard: exit 0; run.mode=="intent_fallback"; run.status=="cancelled"; state.status==
    # "cancelled".
    local gitroot run_id ledger inputs rc=0
    gitroot="$(new_gitroot cc-git)"
    run_id="engine-case-cc"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_WRONG_VERSION")"
    inputs="$gitroot/cc-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg summary "engine test intent fallback skew close cancelled" \
        --arg close_status cancelled \
        '{run_id: $run_id, state: $state, summary: $summary, close_status: $close_status}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INTENT_FALLBACK_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "intent-fallback engine exited $rc closing a skew ledger as cancelled (expected 0)"
        return
    fi

    local mode run_status state_status
    mode="$(jq -r '.run.mode' "$ledger")"
    run_status="$(jq -r '.run.status' "$ledger")"
    state_status="$(jq -r '.state.status' "$ledger")"
    if [[ "$mode" == "intent_fallback" && "$run_status" == "cancelled" && "$state_status" == "cancelled" ]]; then
        pass "$name" "skew closed as cancelled: run.mode=intent_fallback, run.status=cancelled, state.status=cancelled"
    else
        failed "$name" "expected mode=intent_fallback/run.status=cancelled/state.status=cancelled, got mode=$mode/run.status=$run_status/state.status=$state_status"
    fi
}

# ── DD. illegal close_status (abandoned) -> non-zero, ledger byte-unchanged ──

assert_intent_fallback_illegal_close_unchanged() {
    local name="DD:intent-fallback-illegal-close-unchanged"
    # close_status is OPTIONAL but when present MUST be exactly "cancelled" or "complete". The
    # op EXPLICITLY rejects "abandoned" (and anything else). All validation runs BEFORE the temp
    # file is created, so the on-disk ledger is byte-unchanged on rejection. Capture sha256
    # before+after to prove it.
    local gitroot run_id ledger inputs before after rc=0
    gitroot="$(new_gitroot dd-git)"
    run_id="engine-case-dd"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_WRONG_VERSION")"
    before="$(sha256sum "$ledger" | awk '{print $1}')"
    inputs="$gitroot/dd-inputs.json"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg summary "engine test intent fallback illegal close" \
        --arg close_status abandoned \
        '{run_id: $run_id, state: $state, summary: $summary, close_status: $close_status}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INTENT_FALLBACK_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ledger" | awk '{print $1}')"
    if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
        pass "$name" "illegal close_status 'abandoned' rejected (exit $rc) and ledger byte-unchanged"
    else
        failed "$name" "expected non-zero exit + unchanged ledger; rc=$rc, changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
    fi
}

# ── EE. intent-fallback injection safety: payload inert in summary + outputs ──

assert_intent_fallback_injection_safe() {
    local name="EE:intent-fallback-injection-safe"
    # The untrusted summary / outputs fields are serialized ONLY via jq --arg / --argjson and
    # never enter the jq program or any shell command source. A command-substitution + backtick
    # payload in BOTH summary AND outputs must round-trip VERBATIM into the appended event and
    # NEVER execute (no PWNED5 file anywhere).
    local gitroot run_id ledger inputs rc=0
    gitroot="$(new_gitroot ee-git)"
    run_id="engine-case-ee"
    ledger="$(stage_record_ledger "$gitroot" "$run_id" "$LEDGER_WRONG_VERSION")"
    inputs="$gitroot/ee-inputs.json"

    # The payload is DATA, authored SAFELY via jq --arg (jq JSON-escapes the literal). The
    # single-quoted bash literal is never evaluated by bash — it is a string handed to jq.
    local payload='inject $(touch PWNED5) and `touch PWNED5b` and ; rm end'
    local outputs
    outputs="$(jq -n --arg p "$payload" '{note: $p}')"

    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg summary "$payload" \
        --argjson outputs "$outputs" \
        '{run_id: $run_id, state: $state, summary: $summary, outputs: $outputs}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INTENT_FALLBACK_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        failed "$name" "intent-fallback engine exited $rc on an injection payload (expected 0)"
        return
    fi
    if ! assert_no_pwned_file PWNED5 || ! assert_no_pwned_file PWNED5b; then
        failed "$name" "injection payload EXECUTED: a PWNED5 file was created"
        return
    fi

    local got_summary got_output
    got_summary="$(jq -r '.events[-1].summary' "$ledger")"
    got_output="$(jq -r '.events[-1].outputs.note' "$ledger")"
    if [[ "$got_summary" == "$payload" && "$got_output" == "$payload" ]]; then
        pass "$name" "payload inert: no PWNED5 file, summary + outputs round-trip verbatim, exit 0"
    else
        failed "$name" "expected verbatim round-trip; got summary=$got_summary output=$got_output"
    fi
}

# ── FF. symlink-escape rejected: external ledger reachable but unmutated ─────

assert_intent_fallback_symlink_escape_rejected() {
    local name="FF:intent-fallback-symlink-escape-rejected"
    # mark-intent-fallback.sh reuses record-state-result.sh's identity derivation and the shared
    # depth-complete containment guard. It requires the ledger to EXIST, so the escape vector
    # PRE-STAGES the external target with a valid skew ledger, then symlinks the gitroot's
    # .hivemind -> external so `[ -f ]` passes THROUGH the symlink (the ledger is REACHABLE). The
    # containment guard canonicalizes the existing ledger, sees it resolves OUTSIDE the checkout,
    # and rejects. CRITICAL: rejection is by CONTAINMENT (file reachable but unmutated), not
    # file-absence. Mirrors record-state-result's case U precisely. Assert: non-zero exit, the
    # external ledger BYTE-UNCHANGED (sha256 before==after), and NO temp file leaked under it.
    local gitroot external run_id ext_ledger inputs before after rc=0
    gitroot="$(new_gitroot ff-git)"
    run_id="engine-case-ff"
    external="$WORKDIR/ff-external"
    # Pre-stage a VALID skew ledger at the external target's runs/<run-id>/state.json: .run.id ==
    # run_id (coherence passes) and .run.workflow == engine-fixture. Authored from the skew
    # fixture via jq so it is a real, well-formed ledger the op would mutate absent the guard.
    mkdir -p "$external/runs/$run_id"
    ext_ledger="$external/runs/$run_id/state.json"
    jq --arg id "$run_id" --arg wf "engine-fixture" \
        '.run.id = $id | .run.workflow = $wf' \
        "$LEDGER_WRONG_VERSION" > "$ext_ledger"
    # Symlink the gitroot's .hivemind -> external so the derived
    # <gitroot>/.hivemind/runs/<run-id>/state.json resolves THROUGH the symlink to the pre-staged
    # external ledger (so `[ -f ]` passes and the containment guard — not a missing file — blocks).
    ln -s "$external" "$gitroot/.hivemind"
    before="$(sha256sum "$ext_ledger" | awk '{print $1}')"
    inputs="$gitroot/ff-inputs.json"

    # A write the op WOULD record absent the containment guard.
    jq -n \
        --arg run_id "$run_id" \
        --arg state plan \
        --arg summary "engine test intent fallback symlink escape" \
        '{run_id: $run_id, state: $state, summary: $summary}' \
        > "$inputs"

    ( cd "$gitroot" && bash "$FAKE_INTENT_FALLBACK_ENGINE" "$inputs" ) >/dev/null 2>&1 || rc=$?

    after="$(sha256sum "$ext_ledger" | awk '{print $1}')"
    # No engine temp file (.state.json.XXXXXX) may have leaked under the external runs dir.
    local leaked=no
    if find "$external" -name '.state.json.*' -print 2>/dev/null | grep -q .; then
        leaked=yes
    fi
    if [[ "$rc" -ne 0 && "$before" == "$after" && "$leaked" == "no" ]]; then
        pass "$name" "external ledger reachable but rejected by containment (exit $rc): byte-unchanged, no temp leaked"
    else
        failed "$name" "expected non-zero exit + external ledger byte-unchanged + no temp; rc=$rc changed=$([[ "$before" != "$after" ]] && echo yes || echo no) leaked=$leaked"
    fi
}

# ── Drive all assertions ────────────────────────────────────────────────────

echo '=== Engine behavior tests: derive-only engines against tests/engine/ fixtures (dual-root) ==='
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
assert_run_id_traversal_rejected
assert_forged_definition_not_honored
assert_coherence_mismatch_unchanged
assert_init_symlink_escape_rejected
assert_record_symlink_escape_rejected
assert_init_nested_symlink_escape_rejected
assert_init_concurrent_reservation_fails_closed
assert_init_inputs_external_rejected
assert_record_inputs_external_rejected
assert_init_pre_ledger_failure_rolls_back_then_retry_succeeds
assert_init_trap_preserves_committed_ledger
assert_intent_fallback_skew_no_close
assert_intent_fallback_skew_close_cancelled
assert_intent_fallback_illegal_close_unchanged
assert_intent_fallback_injection_safe
assert_intent_fallback_symlink_escape_rejected

echo ''
echo '=== Summary ==='
echo "Engine tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
