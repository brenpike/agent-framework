#!/usr/bin/env bash
#
# Brood manifest back-compat test (plan §J.3).
#
# Proves the hivemind:brood-status manifest read works on BOTH manifest
# generations without error:
#   - an OLD manifest (no manifest_version, no per-strain run:/ledger block);
#   - a NEW manifest_version: 2 manifest carrying the additive run: block.
# In both, the consumer extracts the strain's tmux_session and branch identically.
#
# NOTE: child-ledger workflow-state projection is DEFERRED to issue #161. brood-status
# no longer opens/Reads/jq-projects any child state.json, so this suite no longer
# asserts ledger-derived workflow state — only that both manifest shapes parse and
# yield identical tmux_session/branch extraction.
#
# This runner replicates the manifest parse the brood-status SKILL.md prose
# performs (sed extraction of tmux_session/branch — identical to the spawn-brood
# liveness guard's extraction). It does NOT shell out to tmux/git/gh: external
# observables are out of scope for a back-compat parse test. It is READ-ONLY: it
# never writes a manifest or a child ledger.
#
# Exits non-zero if EITHER manifest fails to parse or yields the wrong extraction.
#
# Usage:
#   ./tools/test_brood_compat.sh

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FIX_DIR="$REPO_ROOT/tests/brood"
MANIFEST_V1="$FIX_DIR/manifest-v1-old.yaml"
MANIFEST_V2="$FIX_DIR/manifest-v2-new.yaml"
SPAWN_SCRIPT="$REPO_ROOT/plugin/skills/spawn-brood/scripts/spawn-brood.sh"
INIT_SCRIPT="$REPO_ROOT/plugin/skills/init-run-ledger/scripts/init-run-ledger.sh"

for required in "$MANIFEST_V1" "$MANIFEST_V2" "$SPAWN_SCRIPT" "$INIT_SCRIPT"; do
    [[ -f "$required" ]] \
        || { echo "FAIL: required fixture missing: $required" >&2; exit 2; }
done

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "SKIP [$1] $2"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# Disposable workdir for the spawn-brood symlink-escape assertion (created lazily, removed
# on exit). The parse/parity assertions above touch only read-only fixtures, so this is only
# armed for the symlink-escape case.
WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

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

# ── Assertion 1: OLD v1 manifest parses, yields the expected session/branch ─────
# Child-ledger projection is deferred to issue #161; this asserts only that the v1
# manifest (no run: block) parses and yields identical tmux_session/branch extraction.
assert_v1_old() {
    local name="V1:old-manifest-no-ledger-fields"
    local session branch
    session="$(extract_tmux_session "$MANIFEST_V1")"
    branch="$(extract_branch "$MANIFEST_V1")"
    if [[ "$session" == "brood-api" && "$branch" == "feature/api-slice" ]]; then
        pass "$name" "v1 manifest read without error: session=$session branch=$branch"
    else
        failed "$name" "expected brood-api/feature/api-slice, got session=$session branch=$branch"
    fi
}

# ── Assertion 2: NEW v2 manifest parses, yields the expected session/branch ─────
# The additive run: block is ignored by the consumer; only tmux_session/branch are
# extracted (child-ledger projection deferred to issue #161).
assert_v2_new() {
    local name="V2:new-manifest-additive-run-block"
    local session branch
    session="$(extract_tmux_session "$MANIFEST_V2")"
    branch="$(extract_branch "$MANIFEST_V2")"
    if [[ "$session" == "brood-api" && "$branch" == "feature/api-slice" ]]; then
        pass "$name" "v2 manifest read without error: session=$session branch=$branch"
    else
        failed "$name" "expected brood-api/feature/api-slice, got session=$session branch=$branch"
    fi
}

# ── Assertion 3: generated child instructions cover every brood parent field init requires ──
# Producer/consumer parity for the task-to-init invocation path under the JSON-inputs
# interface: the child task file emitted by spawn-brood.sh instructs the child how to
# author the init-run-ledger inputs JSON. init-run-ledger.sh takes a single positional
# JSON inputs file (not CLI flags) and REJECTS a brood child unless all four parent
# fields are non-empty (init-run-ledger.sh reads .parent.brood_id, .parent.strain_id,
# .parent.run_id, .parent.manifest; kind=brood requires all four). If the generated
# instructions omit any mapping, a child that follows the injected contract blocks
# before creating its ledger. This asserts every brood parent field the initializer
# enforces is named in the spawn-brood child instructions.
assert_brood_instruction_flag_parity() {
    local name="PARITY:child-instructions-cover-init-brood-flags"
    # The parent JSON fields init-run-ledger.sh reads/enforces for parent.kind=brood,
    # paired with the stable grep token each side uses to reference the field. The init
    # token is the jq accessor (`.parent.<field>`); the instruction token is the new
    # `parent.<field>` wording emitted in the child instructions.
    local fields=( brood_id strain_id run_id manifest )
    local missing_init="" missing_instr=""
    for field in "${fields[@]}"; do
        # Confirm the initializer actually reads/enforces the field (guards against the
        # list going stale if the init contract changes).
        grep -q -- ".parent.$field" "$INIT_SCRIPT" || missing_init+=" parent.$field"
        # Confirm the generated child instructions name the field. Restrict to the
        # `printf '  - ...` instruction emission lines so a stray mention elsewhere
        # cannot satisfy the check.
        grep -E "printf '[[:space:]]*-.*parent\.$field" "$SPAWN_SCRIPT" >/dev/null \
            || missing_instr+=" parent.$field"
    done
    if [[ -z "$missing_init" && -z "$missing_instr" ]]; then
        pass "$name" "all four brood parent fields enforced by init and mapped in child instructions"
    else
        failed "$name" "init missing:[${missing_init# }] instructions missing:[${missing_instr# }]"
    fi
}

# ── Assertion 4: spawn-brood symlink-escape early-blocker ───────────────────────
# spawn-brood.sh (commit 3872551) sources the shared containment helper right after
# repo_root resolution and asserts containment for the `.hivemind/brood` and
# `.claude/worktrees` write chains BEFORE the per-strain loop, before any worktree-add /
# tmux / mkdir. A repo that commits `.hivemind` (or `.claude/worktrees`) as a symlink to an
# external dir makes the textually-derived STATE / worktree path resolve OUTSIDE the
# checkout; the depth-complete guard rejects it. This asserts the early blocker fires and
# nothing is written under the external target.
#
# DEPENDENCY GATING: spawn-brood.sh runs its tmux/claude/jq dependency checks (lines ~91-96)
# BEFORE repo_root resolution and the containment guard, exiting at the FIRST missing
# binary. On a host missing tmux or claude the script would blocker on the dep check and
# never reach the guard, so a naive run would PASS for the wrong reason (exit non-zero from
# the dep check, not the guard). To assert the GUARD specifically, gate on tmux+claude+jq all
# being present and SKIP cleanly when any is absent (mirrors test_engine.sh's dependency
# preflight). When present, the guard is the only non-zero gate the valid inputs reach.
assert_spawn_brood_symlink_escape_blocked() {
    local name="ESCAPE:spawn-brood-symlink-escape-blocked"
    # Gate: spawn-brood's dep checks (tmux/claude/jq) precede the containment guard and exit
    # at the first missing binary, so the guard is only reachable when all three are present.
    local missing=""
    for dep in tmux claude jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    if [ -n "$missing" ]; then
        skip "$name" "spawn-brood dep check precedes the containment guard; skipping (missing: $missing)"
        return
    fi

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-test.XXXXXX")"
    local gitroot="$WORKDIR/brood-git"
    mkdir -p "$gitroot"
    git -C "$gitroot" init -q
    # External dir OUTSIDE the checkout, the symlink's escape target. Symlink the gitroot's
    # `.hivemind` to it so the derived "$repo_root/.hivemind/brood" STATE path resolves
    # THROUGH the symlink to the external target — the first chain the guard checks.
    local external="$WORKDIR/brood-external"
    mkdir -p "$external"
    ln -s "$external" "$gitroot/.hivemind"

    # Minimal VALID brood inputs authored SAFELY via jq -n: one strain, canonical ISO-8601
    # brood_id, a valid base/branch, non-empty overlap_details, valid overlap_risk. Every
    # field passes pre-flight validation so the containment guard — not a malformed input — is
    # the only blocker the run reaches. The ONLY hostile element is the symlinked .hivemind.
    local inputs="$WORKDIR/brood-inputs.json"
    jq -n \
        --arg brood_id "2026-05-31T17:30:00Z" \
        --arg base "main" \
        --arg overlap_risk "low" \
        --arg overlap_details "brood compat symlink-escape test" \
        --arg strain_name "api" \
        --arg strain_desc "symlink escape test strain" \
        --arg strain_branch "feature/api-slice" \
        '{
            brood_id: $brood_id,
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc, branch: $strain_branch } ]
        }' \
        > "$inputs"

    local rc=0
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The guard must reject (non-zero) AND nothing may have been written under the external
    # escape target: no brood/ STATE dir, no manifest, no worktree. A successful escape would
    # land .hivemind/brood/manifest.yaml (and possibly worktrees) under the external target.
    local escaped=no
    if find "$external" -mindepth 1 -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" ]]; then
        pass "$name" "symlinked .hivemind rejected (exit $rc); no manifest/worktree written under external target"
    else
        failed "$name" "expected non-zero exit + no external write; rc=$rc escaped=$escaped"
    fi
}

echo '=== Brood manifest back-compat tests: brood-status reads v1 (old) and v2 (new) manifests ==='
assert_v1_old
assert_v2_new
assert_brood_instruction_flag_parity
assert_spawn_brood_symlink_escape_blocked

echo ''
echo '=== Summary ==='
echo "Brood back-compat tests: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
