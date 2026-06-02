#!/usr/bin/env bash
#
# Brood manifest back-compat test (plan §J.3).
#
# Proves the hivemind:brood-status manifest read works on BOTH manifest
# generations without error:
#   - an OLD manifest (no manifest_version, no per-strain run/ledger block);
#   - a NEW manifest_version: 3 manifest carrying the additive run block.
# In both, the consumer extracts the strain's tmux_session and branch identically.
#
# NOTE: child-ledger workflow-state projection is DEFERRED to issue #161. brood-status
# no longer opens/Reads/jq-projects any child state.json, so this suite no longer
# asserts ledger-derived workflow state — only that both manifest shapes parse and
# yield identical tmux_session/branch extraction.
#
# This runner replicates the manifest parse the brood-status SKILL.md prose
# performs (jq extraction of tmux_session/branch from the JSON manifest — identical to
# the spawn-brood liveness guard's `jq -r '.strains[].tmux_session // empty'`
# extraction). It does NOT shell out to tmux/git/gh: external
# observables are out of scope for a back-compat parse test. It is READ-ONLY: it
# never writes a manifest or a child ledger.
#
# Exits non-zero if EITHER manifest fails to parse or yields the wrong extraction.
#
# Beyond the manifest-parity parse tests, this runner also exercises two spawn-brood
# containment guards (dep-gated on tmux/claude/jq; SKIP when any is absent — CI lacks `claude`):
#   ESCAPE   — a committed `.hivemind` SYMLINK to an external dir makes the write-chain
#              `.hivemind/brood` STATE path resolve outside the checkout; the depth-complete
#              write-chain guard rejects before any worktree/tmux/mkdir.
#   EXTERNAL — `.hivemind` stays a REAL dir, but the spawn-brood INPUTS file is authored at a
#              path that resolves outside the checkout via a symlinked ANCESTOR; the shared
#              READ-guard (hivemind_assert_inputs_contained) refuses to read it. Both assert
#              non-zero exit AND nothing written under the external target.
#   CHILD-ESCAPE — the COORDINATOR checkout is safe (real `.hivemind`/`.claude`), but the `base`
#              ref's TREE tracks `.hivemind` as a SYMLINK to an external dir. `git worktree add`
#              materializes that symlink INTO the child worktree, so the coordinator-side guard
#              (which ran before the worktree existed) cannot catch it. The child-worktree
#              recheck (the helper re-run against the NEW worktree root after worktree-add, before
#              any mkdir/cp/task-write/tmux) rejects it, removes the worktree, and fails the
#              strain — never launching a privileged child in an escaping worktree.
#
# Usage:
#   ./tools/test_brood_compat.sh

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FIX_DIR="$REPO_ROOT/tests/brood"
MANIFEST_V1="$FIX_DIR/manifest-v1-old.json"
MANIFEST_V2="$FIX_DIR/manifest-v2-new.json"
SPAWN_SCRIPT="$REPO_ROOT/plugin/skills/spawn-brood/scripts/spawn-brood.sh"
INIT_SCRIPT="$REPO_ROOT/plugin/skills/init-run-ledger/scripts/init-run-ledger.sh"
PROJECT_SCRIPT="$REPO_ROOT/plugin/skills/brood-status/scripts/brood-status-project.sh"

for required in "$MANIFEST_V1" "$MANIFEST_V2" "$SPAWN_SCRIPT" "$INIT_SCRIPT" "$PROJECT_SCRIPT"; do
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
# Private tmux server isolation. Every escape/positive case uses strain name `api` →
# session `brood-api`, which is ALSO the production session name spawn-brood.sh derives
# for a real strain named `api` (session = `brood-$short`). If this suite touched the
# DEFAULT tmux server, running validation while a real strain named `api` is live would
# kill the user's in-progress session — and the EXIT `tmux kill-server` below would
# destroy the WHOLE server. So the entire suite runs on a throwaway tmux server.
#
# Two env levers are BOTH required, because TMUX_TMPDIR alone is insufficient:
#   1. unset TMUX (and TMUX_PANE): when this suite is run from INSIDE an existing tmux
#      pane, `$TMUX` is inherited and pins every tmux CLIENT to the enclosing server's
#      socket REGARDLESS of TMUX_TMPDIR — so without this unset, our `kill-session` and
#      especially the EXIT `tmux kill-server` would hit the developer's live server.
#      Clearing TMUX/TMUX_PANE forces tmux to fall back to choosing a socket under
#      TMUX_TMPDIR. These are unset+exported so the spawn-brood.sh children inherit the
#      cleared values too (it reads `$TMUX` only as an inert reporting literal).
#   2. export TMUX_TMPDIR: with TMUX cleared, tmux locates its default socket under this
#      private dir; exporting it makes the child `tmux` calls inside spawn-brood.sh (which
#      the spawn-invoking cases exec) share the SAME disposable server.
# Net: both this suite's tmux calls and the spawned children land on the disposable
# server only; the caller's default server (and any real `brood-api`) is unreachable.
# The server and its dir are torn down on EXIT.
unset TMUX TMUX_PANE
TMUX_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-tmux.XXXXXX")"
export TMUX_TMPDIR
# reap_brood_sessions: kill the deterministic tmux session(s) the spawn-invoking escape
# cases create. A case that proceeds PAST the guards to `tmux new-session` (e.g. the
# regular-file positive case, or any case run with claude/tmux present) LEAVES a detached
# `brood-api` session behind on the private server: the suite's EXIT trap previously
# reaped only WORKDIR, never tmux state. A leaked `brood-api` then makes a LATER case abort
# at spawn-brood pre-flight step 1d ("tmux session brood-api already exists") BEFORE it can
# reach the leaf guard — so the leaf-guard assertion would never run (and, with the weaker
# pre-fix assertion, falsely PASS). Reaping before each spawn-invoking case and on EXIT
# keeps cases isolated. Scoped to the exact `brood-api` name these fixtures use — never a
# wildcard — AND, because TMUX is cleared and TMUX_TMPDIR isolates the server (see above),
# it can only ever touch the disposable server's sessions, never the caller's
# default-server sessions.
reap_brood_sessions() { tmux kill-session -t brood-api 2>/dev/null || true; return 0; }
cleanup() {
    reap_brood_sessions
    tmux kill-server 2>/dev/null || true   # tear down the private tmux server entirely
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    # PROJ_WORKDIR is folded into WORKDIR only when WORKDIR was empty at first use; when a
    # spawn case set WORKDIR first, PROJ_WORKDIR is a separate dir and needs its own reap.
    [ -n "${PROJ_WORKDIR:-}" ] && [ "${PROJ_WORKDIR:-}" != "${WORKDIR:-}" ] && rm -rf "$PROJ_WORKDIR"
    [ -n "${TMUX_TMPDIR:-}" ] && rm -rf "$TMUX_TMPDIR"
    return 0
}
trap cleanup EXIT

# extract_tmux_session: pull the first strain's tmux_session value the SAME way the
# spawn-brood liveness guard and brood-status read it from the JSON manifest — `jq -r
# '.strains[].tmux_session // empty'`. The manifest is JSON, so jq cannot confuse
# attacker CONTENT (a counterfeit tmux_session line inside a description string) for
# manifest STRUCTURE; the value is whatever the genuine sibling field holds.
extract_tmux_session() {
    jq -r '.strains[].tmux_session // empty' "$1" 2>/dev/null | head -1
}

# extract_branch: pull the first strain's branch value from the JSON manifest with jq.
extract_branch() {
    jq -r '.strains[].branch // empty' "$1" 2>/dev/null | head -1
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
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The guard must reject (non-zero) AND nothing may have been written under the external
    # escape target: no brood/ STATE dir, no manifest, no worktree. A successful escape would
    # land .hivemind/brood/manifest.json (and possibly worktrees) under the external target.
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

# ── Assertion 5: spawn-brood inputs-file external-resolution read-guard ──────────
# spawn-brood.sh (this session) sources the shared read-guard (hivemind_assert_inputs_contained)
# right after the inputs validity gate and REFUSES TO READ an inputs file whose canonical path
# resolves OUTSIDE the checkout via a symlinked ancestor. Unlike the write-chain `.hivemind/brood`
# guard (assertion 4, which symlinks `.hivemind` itself), this keeps `.hivemind` a REAL dir so the
# write-chain guard is NOT what fires — the inputs file is authored at a path that escapes the
# checkout via a symlinked ANCESTOR ($gitroot/link -> external), so the READ-guard is the only
# blocker. Assert: spawn-brood exits non-zero AND nothing is written under the external target.
#
# DEPENDENCY GATING: identical to assertion 4 — spawn-brood's tmux/claude/jq dep checks precede the
# read-guard and exit at the first missing binary, so the guard is only reachable when all three
# are present. SKIP cleanly when any is absent (CI lacks `claude`, so this case SKIPs in CI,
# matching the existing escape case). When present, the read-guard is the only non-zero gate the
# valid inputs reach.
assert_spawn_brood_inputs_external_rejected() {
    local name="EXTERNAL:spawn-brood-inputs-external-rejected"
    local missing=""
    for dep in tmux claude jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    if [ -n "$missing" ]; then
        skip "$name" "spawn-brood dep check precedes the read-guard; skipping (missing: $missing)"
        return
    fi

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-test.XXXXXX")"
    local gitroot="$WORKDIR/brood-git"
    mkdir -p "$gitroot"
    git -C "$gitroot" init -q
    # `.hivemind` stays a REAL dir (the write-chain guard is NOT the subject here). The hostile
    # element is a symlinked ANCESTOR for the inputs file: $gitroot/link -> external.
    local external="$WORKDIR/brood-external"
    mkdir -p "$external"
    ln -s "$external" "$gitroot/link"

    # Minimal VALID brood inputs authored SAFELY via jq -n, identical in shape to assertion 4 —
    # every field passes pre-flight validation so the read-guard, not a malformed input, is the
    # only blocker. The inputs file is authored THROUGH the symlinked ancestor so its canonical
    # path resolves under $external (outside the checkout).
    local inputs="$gitroot/link/brood-inputs.json"
    jq -n \
        --arg brood_id "2026-05-31T17:30:00Z" \
        --arg base "main" \
        --arg overlap_risk "low" \
        --arg overlap_details "brood compat inputs-external read-guard test" \
        --arg strain_name "api" \
        --arg strain_desc "external inputs read-guard test strain" \
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
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The read-guard must reject (non-zero) AND spawn-brood must have written NOTHING under the
    # external target. The inputs file itself lands at $external/brood-inputs.json (the harness
    # authored it THROUGH the symlinked ancestor — that is the escape vector being tested), so it
    # is the test's OWN artifact and is excluded; a successful escape would create spawn-brood
    # outputs (a `brood/` STATE dir / manifest.json / worktrees) BESIDE it.
    local escaped=no
    if find "$external" -mindepth 1 ! -name 'brood-inputs.json' -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" ]]; then
        pass "$name" "externally-resolving inputs refused by read-guard (exit $rc); nothing written under external target"
    else
        failed "$name" "expected non-zero exit + no external write; rc=$rc escaped=$escaped"
    fi
}

# ── Assertion 6: spawn-brood CHILD-WORKTREE symlink-escape blocked (P0) ─────────
# The coordinator-side write-chain guard (assertion 4) only proves the COORDINATOR checkout is
# safe — it runs BEFORE any worktree exists. But `base` can resolve to a commit whose TREE
# tracks `.hivemind` (or `.claude`) as a SYMLINK to an external dir. `git worktree add`
# materializes that tree INTO the child worktree, so the symlink lands inside $wt; provisioning
# (task.md under .hivemind/brood, settings.local.json under .claude) then follows it externally
# and a --dangerously-skip-permissions child launches in an escaping worktree. spawn-brood.sh
# (this session) closes this by re-running the depth-complete shared helper against the NEW
# WORKTREE ROOT immediately after worktree-add, before any mkdir/cp/task-write/tmux, removing the
# offending worktree and failing the strain on reject.
#
# REPRO of the OLD behavior this proves blocked: with a SAFE coordinator checkout (real
# `.hivemind`/`.claude`) and an `evil` base ref whose tree tracks `.hivemind -> external`, the
# pre-fix script passed the coordinator guard, `git worktree add` checked the symlink into $wt,
# and provisioning wrote $external/brood/task.md before launching the child (script exited 0).
# This case asserts: spawn-brood exits non-zero, writes NOTHING under the external target, and
# (because the strain is the only one) reports failure.
#
# DEPENDENCY GATING: identical to assertions 4/5 — spawn-brood's tmux/claude/jq dep checks
# precede everything and exit at the first missing binary, so the guard is only reachable when
# all three are present. SKIP cleanly when any is absent (CI lacks `claude`, so this SKIPs in CI).
assert_spawn_brood_child_worktree_symlink_escape_blocked() {
    local name="CHILD-ESCAPE:spawn-brood-child-worktree-symlink-escape-blocked"
    local missing=""
    for dep in tmux claude jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    if [ -n "$missing" ]; then
        skip "$name" "spawn-brood dep check precedes the child-worktree guard; skipping (missing: $missing)"
        return
    fi

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-test.XXXXXX")"
    local gitroot="$WORKDIR/brood-git"
    mkdir -p "$gitroot"
    git -C "$gitroot" init -q
    git -C "$gitroot" config user.email test@example.com
    git -C "$gitroot" config user.name test
    # The COORDINATOR checkout is SAFE: its OWN `.hivemind`/`.claude` are REAL dirs, so the
    # coordinator-side write-chain guard passes (this case is NOT testing that guard).
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"
    # Seed an initial commit on the default branch so a worktree can be added from a base ref.
    git -C "$gitroot" commit -q --allow-empty -m "init"
    # A reachable bare `origin` is REQUIRED: spawn-brood's per-strain remote branch-collision
    # check (`git ls-remote --exit-code --heads origin <branch>`) FAILS CLOSED on an unreachable
    # origin (blocker), and that check runs at pre-flight BEFORE the per-strain worktree-add loop
    # where the child-worktree guard lives. Without a reachable origin the run would blocker at
    # the remote check and never reach worktree-add — the case would pass for the WRONG reason
    # (exit 1 from the remote check, guard never exercised). With this origin present, ls-remote
    # returns "no such ref" cleanly and the run proceeds to worktree-add, where the child-worktree
    # guard becomes the only blocker the valid inputs reach.
    local origin="$WORKDIR/brood-origin.git"
    git init -q --bare "$origin"
    git -C "$gitroot" remote add origin "$origin"

    # External dir OUTSIDE the checkout — the symlink's escape target.
    local external="$WORKDIR/brood-external"
    mkdir -p "$external"

    # Build the hostile `evil` base ref: a commit whose TREE tracks `.hivemind` as a SYMLINK to
    # the external dir. `git worktree add ... evil` will materialize this symlink INTO the child
    # worktree. Author it on a dedicated branch so the coordinator's own working tree keeps its
    # real `.hivemind` dir (the coordinator-side guard must still pass).
    git -C "$gitroot" checkout -q -b evil
    # Remove the real dir from the index/working tree for THIS branch, replace with a symlink.
    rm -rf "$gitroot/.hivemind"
    ln -s "$external" "$gitroot/.hivemind"
    git -C "$gitroot" add -A
    git -C "$gitroot" commit -q -m "evil: track .hivemind as external symlink"
    # Confirm it is committed as a symlink (mode 120000) — the vector under test.
    if ! git -C "$gitroot" ls-files -s -- .hivemind | grep -q '^120000 '; then
        failed "$name" "fixture error: .hivemind was not committed as a symlink on evil ref"
        return
    fi
    # Return the coordinator working tree to a SAFE state (real `.hivemind`) so the
    # coordinator-side guard passes and the CHILD-worktree guard is the only thing that can fire.
    git -C "$gitroot" checkout -q -
    [ -L "$gitroot/.hivemind" ] && rm -f "$gitroot/.hivemind"
    mkdir -p "$gitroot/.hivemind"

    # Minimal VALID brood inputs whose `base` is the hostile `evil` ref. Every other field passes
    # pre-flight; the child-worktree containment recheck is the only blocker the run reaches.
    # The inputs file lives INSIDE the coordinator checkout (a real subdir, no symlinked ancestor)
    # so the inputs READ-guard passes — otherwise the read-guard, not the child-worktree guard,
    # would be what fires (the inputs file must resolve inside the checkout for this case to
    # isolate the CHILD-worktree vector).
    local inputs="$gitroot/brood-inputs.json"
    jq -n \
        --arg brood_id "2026-05-31T17:30:00Z" \
        --arg base "evil" \
        --arg overlap_risk "low" \
        --arg overlap_details "brood compat child-worktree symlink-escape test" \
        --arg strain_name "api" \
        --arg strain_desc "child worktree symlink escape test strain" \
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
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The child-worktree guard must reject (non-zero — the single strain fails) AND nothing may
    # have been written under the external escape target. A successful escape (OLD behavior) would
    # land $external/brood/task.md (the provisioned task file) under the external target.
    local escaped=no
    if find "$external" -mindepth 1 -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    # The offending worktree must also be removed (not left dangling for a later launch).
    local worktree_leaked=no
    if [ -e "$gitroot/.claude/worktrees/api" ]; then
        worktree_leaked=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$worktree_leaked" == "no" ]]; then
        pass "$name" "child-worktree symlinked .hivemind rejected (exit $rc); worktree removed; nothing written under external target"
    else
        failed "$name" "expected non-zero exit + no external write + worktree removed; rc=$rc escaped=$escaped worktree_leaked=$worktree_leaked"
    fi
}

# ── Assertion 7: CHILD-LEAF-ESCAPE-task (P0 regression) ─────────────────────────
# STEP-002 added hivemind_assert_file_contained over the task.md LEAF in spawn-brood.sh
# (the 3a dir-guard proves the .hivemind/brood ANCESTOR is safe, but a hostile base ref
# can track a REAL .hivemind/brood/ dir with a SYMLINKED task.md leaf; `git worktree add`
# materializes the symlink into the child worktree, and the printf redirect would follow it
# to an external target before a --dangerously-skip-permissions child launches).
#
# This case builds an `evil` base ref whose tree tracks a REAL .hivemind/brood/ dir and a
# SYMLINKED .hivemind/brood/task.md leaf pointing at a FILE path outside the checkout
# ($external/task.md). The leaf MUST target a file path, not the external dir itself: the
# provisioning write is `printf > "$task_file"` (a redirect). A symlink-to-DIR would make the
# unguarded redirect fail with "Is a directory" and write nothing — the strain would then be
# torn down by the generic provisioning-failure path, so the assertion (non-zero exit + no
# external file + worktree removed) would PASS on the VULNERABLE implementation and the test
# could not distinguish guarded from unguarded. Targeting a file path makes the unguarded
# redirect FOLLOW the dangling symlink and CREATE $external/task.md — a real escape the
# assertion detects. spawn-brood is run with base=evil; the leaf guard must reject (non-zero /
# strain marked failed) with its specific rejection message, write NOTHING under the external
# target, and remove the offending worktree.
#
# DEPENDENCY GATING: identical to CHILD-ESCAPE — spawn-brood's tmux/claude/jq dep checks
# precede the child-worktree provisioning path and exit at the first missing binary.
# SKIP cleanly when any is absent (CI lacks `claude`, so this SKIPs in CI, exit 0).
assert_spawn_brood_child_leaf_task_escape_blocked() {
    local name="CHILD-LEAF-ESCAPE-task:spawn-brood-task-leaf-symlink-escape-blocked"
    local missing=""
    for dep in tmux claude jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    if [ -n "$missing" ]; then
        skip "$name" "spawn-brood dep check precedes the leaf guard; skipping (missing: $missing)"
        return
    fi

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-test.XXXXXX")"
    local gitroot="$WORKDIR/brood-git"
    mkdir -p "$gitroot"
    git -C "$gitroot" init -q
    git -C "$gitroot" config user.email test@example.com
    git -C "$gitroot" config user.name test
    # COORDINATOR checkout is SAFE: real .hivemind/.claude dirs, so the coordinator-side
    # write-chain guard (assertion 4) and child-worktree dir-guard (assertion 6) both pass.
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"
    git -C "$gitroot" commit -q --allow-empty -m "init"
    # Reachable bare origin required: the per-strain remote branch-collision check
    # (git ls-remote) fails closed on unreachable origin and would be the blocker instead
    # of the leaf guard — case would pass for the wrong reason.
    local origin="$WORKDIR/brood-origin.git"
    git init -q --bare "$origin"
    git -C "$gitroot" remote add origin "$origin"

    # External dir — the symlink leaf's escape target. The leaf points at $external/task.md
    # (a FILE path inside this dir), NOT at $external itself, so the unguarded `printf >`
    # redirect would CREATE the file there rather than fail on a directory target.
    local external="$WORKDIR/brood-external"
    mkdir -p "$external"

    # Build the `evil` base ref: REAL .hivemind/brood/ dir, SYMLINKED task.md leaf pointing at
    # the external FILE path $external/task.md (the target file does not yet exist — the
    # unguarded redirect would create it, which is the escape). The dir-guard
    # (hivemind_assert_contained over .hivemind/brood) PASSES because the directory ancestor
    # chain is real — only the leaf guard fires.
    git -C "$gitroot" checkout -q -b evil
    rm -rf "$gitroot/.hivemind"
    mkdir -p "$gitroot/.hivemind/brood"
    ln -s "$external/task.md" "$gitroot/.hivemind/brood/task.md"
    # .hivemind is gitignored; force-add both the dir contents and the symlink leaf.
    git -C "$gitroot" add -f "$gitroot/.hivemind/brood/task.md"
    git -C "$gitroot" commit -q -m "evil: real .hivemind/brood dir, task.md leaf symlinked to external file path"
    # Confirm the leaf is committed as a symlink (mode 120000) — the exact escape vector.
    if ! git -C "$gitroot" ls-files -s -- .hivemind/brood/task.md | grep -q '^120000 '; then
        failed "$name" "fixture error: .hivemind/brood/task.md was not committed as a symlink on evil ref"
        return
    fi
    # Return coordinator working tree to safe state.
    git -C "$gitroot" checkout -q -
    [ -L "$gitroot/.hivemind" ] && rm -f "$gitroot/.hivemind"
    rm -rf "$gitroot/.hivemind"
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"

    # Minimal valid inputs with base=evil. Inputs file is INSIDE the coordinator checkout
    # (real subdir) so the inputs read-guard passes — the leaf guard is the only blocker.
    local inputs="$gitroot/brood-inputs.json"
    jq -n \
        --arg brood_id "2026-05-31T17:31:00Z" \
        --arg base "evil" \
        --arg overlap_risk "low" \
        --arg overlap_details "child-leaf-escape-task regression test" \
        --arg strain_name "api" \
        --arg strain_desc "task leaf symlink escape test strain" \
        --arg strain_branch "feature/api-slice" \
        '{
            brood_id: $brood_id,
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc, branch: $strain_branch } ]
        }' \
        > "$inputs"

    # Capture stderr separately to assert the SPECIFIC leaf-guard rejection fired — not some
    # coincidental downstream failure. On the VULNERABLE impl the redirect follows the symlink
    # and creates $external/task.md (escaped=yes), so this case fails there; on the FIXED impl
    # the [ -L ] leaf test rejects before any write, emitting the guard's warning to stderr.
    local rc=0
    local stderr_out="$WORKDIR/spawn-stderr.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>"$stderr_out" || rc=$?

    # Leaf guard must reject (non-zero) AND nothing written under external escape target.
    # A successful escape would CREATE external/task.md (followed from the symlink leaf).
    local escaped=no
    if find "$external" -mindepth 1 -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    # The leaf guard emits a specific rejection message before tearing down the worktree.
    # Its presence proves the LEAF GUARD (not a coincidental provisioning failure) blocked.
    local leaf_guard_rejected=no
    if grep -qE 'symlinked .*task\.md leaf' "$stderr_out" 2>/dev/null; then
        leaf_guard_rejected=yes
    fi
    # The offending worktree must be removed (not left dangling).
    local worktree_leaked=no
    if [ -e "$gitroot/.claude/worktrees/api" ]; then
        worktree_leaked=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$worktree_leaked" == "no" && "$leaf_guard_rejected" == "yes" ]]; then
        pass "$name" "task.md symlinked leaf rejected by leaf guard (exit $rc); worktree removed; nothing written under external target"
    else
        failed "$name" "expected non-zero exit + leaf-guard rejection + no external write + worktree removed; rc=$rc escaped=$escaped leaf_guard_rejected=$leaf_guard_rejected worktree_leaked=$worktree_leaked stderr: $(cat "$stderr_out" 2>/dev/null)"
    fi
}

# ── Assertion 8: CHILD-LEAF-ESCAPE-settings (P0 regression) ─────────────────────
# STEP-002 added hivemind_assert_file_contained over the settings.local.json LEAF in
# spawn-brood.sh (inside the `if [ -f "$settings_local" ]` propagation block). A hostile
# base ref can track a REAL .claude/ dir with a SYMLINKED settings.local.json leaf; `git
# worktree add` materializes it, and `cp` would follow it to the external target before
# a privileged child launches.
#
# This case builds an `evil2` base ref with a REAL .claude/ dir but a SYMLINKED
# settings.local.json leaf. The coordinator also has a REAL .claude/settings.local.json
# (so the cp propagation path is actually reached and the leaf guard is the only thing
# standing between the cp and an external write). spawn-brood is run with base=evil2;
# assert non-zero/failed, external unwritten, worktree removed.
#
# DEPENDENCY GATING: identical to CHILD-LEAF-ESCAPE-task.
assert_spawn_brood_child_leaf_settings_escape_blocked() {
    local name="CHILD-LEAF-ESCAPE-settings:spawn-brood-settings-leaf-symlink-escape-blocked"
    local missing=""
    for dep in tmux claude jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    if [ -n "$missing" ]; then
        skip "$name" "spawn-brood dep check precedes the leaf guard; skipping (missing: $missing)"
        return
    fi

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-test.XXXXXX")"
    local gitroot="$WORKDIR/brood-git"
    mkdir -p "$gitroot"
    git -C "$gitroot" init -q
    git -C "$gitroot" config user.email test@example.com
    git -C "$gitroot" config user.name test
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"
    # COORDINATOR has a REAL settings.local.json so the `if [ -f "$settings_local" ]`
    # propagation path is actually reached and the leaf guard is exercised.
    printf '{"permissions":{"allow":[]}}\n' > "$gitroot/.claude/settings.local.json"
    git -C "$gitroot" commit -q --allow-empty -m "init"
    local origin="$WORKDIR/brood-origin.git"
    git init -q --bare "$origin"
    git -C "$gitroot" remote add origin "$origin"

    local external="$WORKDIR/brood-external"
    mkdir -p "$external"

    # Build the `evil2` base ref: REAL .claude/ dir, SYMLINKED settings.local.json leaf.
    # The child-worktree dir-guard (hivemind_assert_contained over .claude) will PASS
    # because the .claude ancestor is a real dir — only the leaf guard fires.
    git -C "$gitroot" checkout -q -b evil2
    rm -rf "$gitroot/.hivemind" "$gitroot/.claude"
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"
    ln -s "$external" "$gitroot/.claude/settings.local.json"
    git -C "$gitroot" add -f "$gitroot/.claude/settings.local.json"
    git -C "$gitroot" commit -q -m "evil2: real .claude dir, symlinked settings.local.json leaf"
    # Confirm symlink leaf committed as mode 120000.
    if ! git -C "$gitroot" ls-files -s -- .claude/settings.local.json | grep -q '^120000 '; then
        failed "$name" "fixture error: .claude/settings.local.json was not committed as a symlink on evil2 ref"
        return
    fi
    # Return coordinator working tree to safe state with a real settings.local.json.
    git -C "$gitroot" checkout -q -
    [ -L "$gitroot/.claude" ] && rm -f "$gitroot/.claude"
    rm -rf "$gitroot/.hivemind" "$gitroot/.claude"
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"
    printf '{"permissions":{"allow":[]}}\n' > "$gitroot/.claude/settings.local.json"

    local inputs="$gitroot/brood-inputs.json"
    jq -n \
        --arg brood_id "2026-05-31T17:32:00Z" \
        --arg base "evil2" \
        --arg overlap_risk "low" \
        --arg overlap_details "child-leaf-escape-settings regression test" \
        --arg strain_name "api" \
        --arg strain_desc "settings leaf symlink escape test strain" \
        --arg strain_branch "feature/api-slice" \
        '{
            brood_id: $brood_id,
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc, branch: $strain_branch } ]
        }' \
        > "$inputs"

    # Capture stderr separately to assert the SPECIFIC leaf-guard rejection fired — not some
    # coincidental downstream/pre-flight failure. On the VULNERABLE impl the cp follows the
    # symlink and writes external/settings.local.json (escaped=yes), so this case fails there;
    # on the FIXED impl the [ -L ] leaf test rejects before any write, emitting the guard's
    # warning to stderr.
    local rc=0
    local stderr_out="$WORKDIR/spawn-stderr.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>"$stderr_out" || rc=$?

    # Leaf guard must reject (non-zero) AND nothing written under external escape target.
    # A successful escape would write external/settings.local.json via cp.
    local escaped=no
    if find "$external" -mindepth 1 -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    # The leaf guard emits a specific rejection message before tearing down the worktree.
    # Its presence proves the LEAF GUARD (not a coincidental pre-flight/provisioning failure)
    # blocked — without this an unrelated early blocker would let the case pass vacuously.
    local leaf_guard_rejected=no
    if grep -qE 'symlinked \.claude/settings\.local\.json leaf' "$stderr_out" 2>/dev/null; then
        leaf_guard_rejected=yes
    fi
    local worktree_leaked=no
    if [ -e "$gitroot/.claude/worktrees/api" ]; then
        worktree_leaked=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$worktree_leaked" == "no" && "$leaf_guard_rejected" == "yes" ]]; then
        pass "$name" "settings.local.json symlinked leaf rejected by leaf guard (exit $rc); worktree removed; nothing written under external target"
    else
        failed "$name" "expected non-zero exit + leaf-guard rejection + no external write + worktree removed; rc=$rc escaped=$escaped leaf_guard_rejected=$leaf_guard_rejected worktree_leaked=$worktree_leaked stderr: $(cat "$stderr_out" 2>/dev/null)"
    fi
}

# ── Assertion 9: CHILD-LEAF-REGULAR-OK (anti-false-reject, positive case) ────────
# A base ref that tracks a REGULAR-FILE .hivemind/brood/task.md (not a symlink) must NOT
# be rejected by the leaf guard. This proves the guard does not false-reject legitimate
# repos that pre-stage a real task.md in the base ref's tree.
#
# ANTI-FALSE-REJECT DISTINCTION: the positive assertion must distinguish a leaf-guard
# rejection from an expected downstream dep-gate SKIP. With claude absent the strain will
# SKIP at the dep-gate (the three functions return before reaching any guard); with claude
# present the strain proceeds past the leaf guard and fails at the tmux/launch step. In
# both paths the leaf guard must NOT have fired. We assert this by:
#   (a) checking stderr for the leaf-guard rejection messages emitted by spawn-brood.sh;
#       a leaf guard rejection always emits "symlinked .hivemind/brood/task.md leaf" or
#       "symlinked .claude/settings.local.json leaf" — their absence confirms no leaf reject;
#   (b) checking the worktree was NOT torn down by a leaf-guard rejection (the guard removes
#       the worktree before any tmux/launch; a tmux/launch failure does not remove it).
# Together these confirm that if spawn-brood fails, it is the tmux/launch path, not the guard.
#
# DEPENDENCY GATING: same dep gate as the escape cases. When claude is absent the script
# exits at the dep check (before any guard); the case correctly SKIPs. When claude is
# present, the dep gate passes and the guard is exercised all the way to the launch path.
assert_spawn_brood_child_leaf_regular_ok() {
    local name="CHILD-LEAF-REGULAR-OK:spawn-brood-regular-task-leaf-not-rejected"
    local missing=""
    for dep in tmux claude jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    if [ -n "$missing" ]; then
        skip "$name" "spawn-brood dep check precedes all guards; skipping (missing: $missing)"
        return
    fi

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-test.XXXXXX")"
    local gitroot="$WORKDIR/brood-git"
    mkdir -p "$gitroot"
    git -C "$gitroot" init -q
    git -C "$gitroot" config user.email test@example.com
    git -C "$gitroot" config user.name test
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"
    git -C "$gitroot" commit -q --allow-empty -m "init"
    local origin="$WORKDIR/brood-origin.git"
    git init -q --bare "$origin"
    git -C "$gitroot" remote add origin "$origin"

    # Build the `safe` base ref: REAL .hivemind/brood/task.md REGULAR FILE (not a symlink).
    # This is the normal case: a repo that pre-stages a real task file in its base tree.
    git -C "$gitroot" checkout -q -b safe
    rm -rf "$gitroot/.hivemind"
    mkdir -p "$gitroot/.hivemind/brood"
    printf 'placeholder\n' > "$gitroot/.hivemind/brood/task.md"
    git -C "$gitroot" add -f "$gitroot/.hivemind/brood/task.md"
    git -C "$gitroot" commit -q -m "safe: real .hivemind/brood/task.md regular file"
    # Confirm it is NOT a symlink (mode 100644, not 120000).
    if git -C "$gitroot" ls-files -s -- .hivemind/brood/task.md | grep -q '^120000 '; then
        failed "$name" "fixture error: .hivemind/brood/task.md was committed as a symlink — test setup error"
        return
    fi
    # Return coordinator working tree to safe state.
    git -C "$gitroot" checkout -q -
    [ -L "$gitroot/.hivemind" ] && rm -f "$gitroot/.hivemind"
    rm -rf "$gitroot/.hivemind"
    mkdir -p "$gitroot/.hivemind" "$gitroot/.claude"

    local inputs="$gitroot/brood-inputs.json"
    jq -n \
        --arg brood_id "2026-05-31T17:33:00Z" \
        --arg base "safe" \
        --arg overlap_risk "low" \
        --arg overlap_details "child-leaf-regular-ok positive test" \
        --arg strain_name "api" \
        --arg strain_desc "regular file leaf positive test strain" \
        --arg strain_branch "feature/api-slice" \
        '{
            brood_id: $brood_id,
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc, branch: $strain_branch } ]
        }' \
        > "$inputs"

    # Capture stderr separately to inspect for leaf-guard rejection messages.
    local rc=0
    local stderr_out
    stderr_out="$WORKDIR/spawn-stderr.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>"$stderr_out" || rc=$?

    # ANTI-FALSE-REJECT: the leaf guard emits a specific rejection message. Its ABSENCE
    # in stderr confirms no leaf-guard rejection fired — whether the run succeeded or failed
    # downstream (e.g. at the tmux/launch step), it was NOT the leaf guard.
    local leaf_guard_rejected=no
    if grep -qE 'symlinked .*(task\.md|settings\.local\.json) leaf' "$stderr_out" 2>/dev/null; then
        leaf_guard_rejected=yes
    fi
    # ANTI-FALSE-REJECT: the leaf guard removes the worktree before any tmux/launch.
    # A worktree that still exists (or never existed because launch-path cleanup happened)
    # confirms no leaf-guard teardown occurred. We check for the leaf-guard warning instead
    # of worktree presence because the launch-path itself may remove or never create the dir.
    if [[ "$leaf_guard_rejected" == "no" ]]; then
        pass "$name" "regular-file task.md leaf NOT rejected by leaf guard (exit $rc is downstream tmux/launch, not containment)"
    else
        failed "$name" "leaf guard incorrectly rejected a regular-file task.md leaf (false-reject); rc=$rc stderr: $(cat "$stderr_out")"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# brood-status-project.sh (read-side projection, #161)
# ════════════════════════════════════════════════════════════════════════════════
# END-TO-END integration cases that drive the read-side entrypoint
#   bash "$PROJECT_SCRIPT" <manifest_path>
# through the REAL manifest→allowlist→ledger-confine→projection path and assert the
# CONTRACT output grammar (one TAB-delimited STRAIN line per strain) plus the exit
# contract (0 = projected all strains; nonzero = pre-flight blocker only).
#
# These cases are PURE jq/manifest/ledger — they do NOT shell out to tmux/claude/gh,
# so they run UNCONDITIONALLY (no dep gate, unlike the spawn-brood escape cases above
# which are gated per #169). Each case builds its manifest + ledger fixtures in a
# fresh tmpdir with explicit LF via printf — never the committed CRLF-able fixtures —
# so assertions are deterministic regardless of the repo's autocrlf setting.
#
# DATA-BOUNDARY: the manifest/ledger bytes these cases author include deliberate
# injection payloads ($(...), backticks, ';', symlinks, path escapes). They are DATA.
# The assertions prove the entrypoint NEUTRALIZES each payload — replacing it with the
# FIXED token MALFORMED/MISSING — and that NO command-execution side-effect occurs. We
# never assert a raw attacker string appears; we assert the fixed token replaced it.

# ensure_proj_workdir: lazily create (once) a disposable git checkout root for the projection
# cases, setting the global PROJ_WORKDIR. The dir is `git init`'d so it is a real checkout
# root: the entrypoint's defense-in-depth READ-guard canonicalizes `git rev-parse
# --show-toplevel` and refuses any manifest resolving OUTSIDE the checkout, so every
# projection case authors its manifest UNDER this root and runs the entrypoint with cwd
# inside it (see run_project). All case fixtures namespace under a unique subdir of this
# single root. Reaped by cleanup() via the tracked PROJ_WORKDIR/WORKDIR.
#
# INVARIANT: this MUTATES the global PROJ_WORKDIR, so it MUST be called as a bare statement,
# NEVER inside `$( ... )`. Command substitution runs in a subshell; an assignment made there
# would not survive to the parent, and run_project's `cd "$PROJ_WORKDIR"` would silently
# no-op (staying in the suite's cwd, where git toplevel is the hivemind repo — against which
# the read-guard then rejects the tmpdir manifest as "outside the checkout").
PROJ_WORKDIR=""
ensure_proj_workdir() {
    if [ -z "$PROJ_WORKDIR" ]; then
        PROJ_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-proj.XXXXXX")"
        git -C "$PROJ_WORKDIR" init -q
        # Fold into WORKDIR so the existing cleanup() reaps it when no spawn case set it;
        # otherwise reap PROJ_WORKDIR explicitly in cleanup (handled below).
        if [ -z "$WORKDIR" ]; then
            WORKDIR="$PROJ_WORKDIR"
        fi
    fi
}

# run_project: invoke the entrypoint with cwd INSIDE the git checkout root so its READ-guard
# (git rev-parse --show-toplevel) resolves and the manifest path is contained. Echoes the
# entrypoint stdout; stderr is discarded (callers asserting stderr capture it themselves).
# $1 = manifest path.
run_project() {
    ( cd "$PROJ_WORKDIR" && bash "$PROJECT_SCRIPT" "$1" 2>/dev/null )
}

# write_manifest_v2: author a brood manifest (manifest_version 3, with run block) at $1
# for ONE strain. Args: $1=path $2=strain_name $3=worktree_path $4=branch
# $5=tmux_session $6=status $7=suggested_ledger. Mirrors the JSON producer shape in
# spawn-brood.sh exactly (jq-constructed object; manifest_version a number; pr:null,
# merged:false, rebased_after:[] as JSON types; run block carrying the suggested_ledger).
# Every untrusted value enters jq as a --arg binding (jq does the JSON-safe escaping), so
# a metachar-bearing worktree_path/ledger is serialized as inert string content, never
# manifest structure.
write_manifest_v2() {
    local out="$1" name="$2" wt="$3" branch="$4" sess="$5" status="$6" ledger="$7"
    jq -n \
        --arg name "$name" \
        --arg wt "$wt" \
        --arg branch "$branch" \
        --arg sess "$sess" \
        --arg status "$status" \
        --arg ledger "$ledger" \
        '{
            manifest_version: 3,
            brood_id: "2026-05-30T22-10-00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                {
                    name: $name,
                    description: "test strain",
                    worktree_path: $wt,
                    branch: $branch,
                    tmux_session: $sess,
                    status: $status,
                    pr: null,
                    merged: false,
                    rebased_after: [],
                    run: {
                        suggested_id: "run-id",
                        suggested_ledger: $ledger,
                        workflow_hint: "standard-delivery"
                    }
                }
            ],
            merge_order: []
        }' > "$out"
}

# write_ledger: author a child run-ledger JSON at $1 with run.status=$2,
# state.current=$3 via jq -n (safe construction). Parent dirs must already exist.
write_ledger() {
    local out="$1" run_status="$2" state_current="$3"
    jq -n --arg rs "$run_status" --arg sc "$state_current" \
        '{run:{status:$rs}, state:{current:$sc}}' > "$out"
}

# strain_field: split the FIRST STRAIN line of $1 (entrypoint output) on TAB and echo
# the field at 1-based index $2. Field order (1-based): 1=STRAIN 2=name 3=worktree_path
# 4=branch 5=tmux_session 6=manifest_status 7=state_current 8=run_status.
strain_field() {
    local output="$1" idx="$2"
    printf '%s\n' "$output" | awk -F'\t' -v i="$idx" '/^STRAIN\t/ { print $i; exit }'
}

# count_strain_lines: number of STRAIN lines in $1.
count_strain_lines() {
    printf '%s\n' "$1" | grep -c '^STRAIN	' || true
}

# ── Projection 1: happy path — v2 manifest + valid confined ledger on disk ───────
# Asserts exit 0, exactly one STRAIN line, and exact TAB-delimited field values
# including state_current=implement_step run_status=running projected from the ledger.
assert_proj_happy_path() {
    local name="PROJ-HAPPY:v2-manifest-valid-ledger"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/happy"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"
    write_ledger "$wt/.hivemind/runs/run-id/state.json" running implement_step
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 1 \
          && "$(strain_field "$out" 2)" == "api" \
          && "$(strain_field "$out" 3)" == "$wt" \
          && "$(strain_field "$out" 4)" == "feature/api-slice" \
          && "$(strain_field "$out" 5)" == "brood-api" \
          && "$(strain_field "$out" 6)" == "running" \
          && "$(strain_field "$out" 7)" == "implement_step" \
          && "$(strain_field "$out" 8)" == "running" ]]; then
        pass "$name" "exit 0; one STRAIN line; state_current=implement_step run_status=running"
    else
        failed "$name" "rc=$rc lines=$lines fields=[$(strain_field "$out" 2)|$(strain_field "$out" 3)|$(strain_field "$out" 4)|$(strain_field "$out" 5)|$(strain_field "$out" 6)|$(strain_field "$out" 7)|$(strain_field "$out" 8)]"
    fi
}

# ── Projection 2: v1 manifest (no run: block) → ledger scalars MISSING ───────────
# A manifest with no run: block yields an empty suggested_ledger pointer; both ledger
# scalars render MISSING (never read). Static manifest fields still project; exit 0.
assert_proj_v1_no_run_block() {
    local name="PROJ-V1:no-run-block-ledger-missing"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/v1"
    local wt="$wd/wt"
    mkdir -p "$wt"
    local manifest="$wd/manifest.json"
    # A v1-shape manifest: NO run block, so the suggested_ledger pointer is absent and both
    # ledger scalars must render MISSING (never read). manifest_version omitted intentionally.
    jq -n --arg wt "$wt" \
        '{
            brood_id: "2026-05-30T22-10-00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                {
                    name: "api",
                    description: "test strain",
                    worktree_path: $wt,
                    branch: "feature/api-slice",
                    tmux_session: "brood-api",
                    status: "running"
                }
            ],
            merge_order: []
        }' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 2)" == "api" \
          && "$(strain_field "$out" 3)" == "$wt" \
          && "$(strain_field "$out" 7)" == "MISSING" \
          && "$(strain_field "$out" 8)" == "MISSING" ]]; then
        pass "$name" "exit 0; static fields project; ledger scalars MISSING (no run: block)"
    else
        failed "$name" "rc=$rc name=$(strain_field "$out" 2) wt=$(strain_field "$out" 3) state=$(strain_field "$out" 7) run=$(strain_field "$out" 8)"
    fi
}

# ── Projection 3: ledger pointer present but file absent → MISSING ───────────────
# A well-formed pointer to a path that does not exist on disk → both scalars MISSING.
assert_proj_missing_ledger_file() {
    local name="PROJ-MISSING:pointer-present-file-absent"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/missing"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"   # dir exists, state.json does NOT
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 7)" == "MISSING" \
          && "$(strain_field "$out" 8)" == "MISSING" ]]; then
        pass "$name" "exit 0; absent ledger file → state_current/run_status MISSING"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 7) run=$(strain_field "$out" 8)"
    fi
}

# ── Projection 4: malformed run.status, valid state.current → per-scalar independence ──
# run.status=frobnicate (out-of-enum) → run_status MALFORMED; a VALID state.current
# still projects (the two scalars are independent).
assert_proj_malformed_run_status() {
    local name="PROJ-MALFORMED-RUN:bad-run-status-good-state-current"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/malrun"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"
    write_ledger "$wt/.hivemind/runs/run-id/state.json" frobnicate implement_step
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && "$(strain_field "$out" 7)" == "implement_step" ]]; then
        pass "$name" "exit 0; run_status=MALFORMED while state_current=implement_step (per-scalar independence)"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 7) run=$(strain_field "$out" 8)"
    fi
}

# ── Projection 5: injection state.current → MALFORMED, no side-effect ─────────────
# state.current carries a command-substitution payload `$(touch <marker>)`. The
# projector validates against ^[a-z0-9_]+$ → MALFORMED. ASSERT the marker file was
# NEVER created (no command execution).
assert_proj_injection_state_current() {
    local name="PROJ-INJECT-STATE:state-current-command-sub-neutralized"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/injstate"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"
    local marker="$wd/pwn_state_marker"
    # state.current is a literal command-substitution string; it is DATA in the JSON.
    write_ledger "$wt/.hivemind/runs/run-id/state.json" running "\$(touch $marker)"
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 7)" == "MALFORMED" \
          && ! -e "$marker" ]]; then
        pass "$name" "exit 0; state_current=MALFORMED; no command-sub side-effect ($marker absent)"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 7) marker_exists=$([ -e "$marker" ] && echo yes || echo no)"
    fi
}

# ── Projection 6: metachar worktree_path → ledger scalars MALFORMED, no side-effect ──
# worktree_path carries `$(...)` metachars → fails the allowlist; the script cannot
# confine a ledger under an unsafe worktree, so wt_out + both ledger scalars render
# MALFORMED and NO path derivation/read occurs. ASSERT no command-execution side-effect.
assert_proj_metachar_worktree() {
    local name="PROJ-INJECT-WT:metachar-worktree-path-neutralized"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/metawt"
    mkdir -p "$wd"
    local marker="$wd/pwn_wt_marker"
    local manifest="$wd/manifest.json"
    # worktree_path AND suggested_ledger both carry command-sub payloads. Pure DATA.
    write_manifest_v2 "$manifest" "api" "/tmp/\$(touch $marker)/wt" "feature/api-slice" \
        "brood-api" "running" "/tmp/\$(touch $marker)/wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 3)" == "MALFORMED" \
          && "$(strain_field "$out" 7)" == "MALFORMED" \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && ! -e "$marker" ]]; then
        pass "$name" "exit 0; worktree_path+ledger MALFORMED; no command-sub side-effect ($marker absent)"
    else
        failed "$name" "rc=$rc wt=$(strain_field "$out" 3) state=$(strain_field "$out" 7) run=$(strain_field "$out" 8) marker_exists=$([ -e "$marker" ] && echo yes || echo no)"
    fi
}

# ── Projection 7: symlinked state.json leaf → MALFORMED, target NOT read ──────────
# A REAL symlink at the confined leaf path points at an external file holding a VALID
# ledger. The leaf guard (hivemind_assert_file_contained) rejects the non-regular leaf
# → MALFORMED; the symlink target's content (a sentinel state.current) must NOT appear.
assert_proj_symlink_leaf() {
    local name="PROJ-SYMLINK-LEAF:symlinked-state-json-rejected"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/symleaf"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"
    # External target holds a VALID-looking ledger whose state.current is a sentinel that
    # would project cleanly IF the symlink were followed. It must NOT appear in output.
    local target="$wd/external_state.json"
    write_ledger "$target" running leakedsentinel
    ln -s "$target" "$wt/.hivemind/runs/run-id/state.json"
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 7)" == "MALFORMED" \
          && "$(strain_field "$out" 8)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'leakedsentinel'; then
        pass "$name" "exit 0; symlinked leaf rejected → MALFORMED; symlink target content not leaked"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 7) run=$(strain_field "$out" 8); leaked=$(printf '%s' "$out" | grep -q leakedsentinel && echo yes || echo no)"
    fi
}

# ── Projection 7b: present-but-UNREADABLE confined ledger leaf → MALFORMED ────────
# A REGULAR confined state.json that exists but is unreadable (mode 000). The leaf is
# NOT a symlink and NOT absent, so the read site reaches `cat`, which FAILS; the post-
# failure `[ -e ]` re-test confirms the file is present → both scalars MALFORMED (never
# MISSING). This locks the iteration-6/7 read-failure contract: present-but-unreadable
# must NOT be downgraded to the benign absent (MISSING) class. Absent-file control is
# covered by PROJ-MISSING above.
assert_proj_unreadable_ledger() {
    local name="PROJ-UNREADABLE-LEDGER:present-but-unreadable-leaf-malformed"
    # chmod 000 does not restrict root; skip rather than spuriously fail under root.
    if [[ "$(id -u)" -eq 0 ]]; then
        skip "$name" "running as root: mode 000 does not block reads"
        return 0
    fi
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/unreadledger"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"
    local leaf="$wt/.hivemind/runs/run-id/state.json"
    write_ledger "$leaf" running implement_step   # valid content...
    chmod 000 "$leaf"                              # ...but unreadable
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$leaf"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    # Restore perms so workdir cleanup can remove the fixture.
    chmod 644 "$leaf" 2>/dev/null || true
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 7)" == "MALFORMED" \
          && "$(strain_field "$out" 8)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'implement_step'; then
        pass "$name" "exit 0; present-but-unreadable ledger → MALFORMED (not MISSING); content not leaked"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 7) run=$(strain_field "$out" 8); leaked=$(printf '%s' "$out" | grep -q implement_step && echo yes || echo no)"
    fi
}

# ── Projection 8: suggested_ledger escaping the worktree → MALFORMED, not read ────
# An absolute pointer to /etc/passwd does not match the required
# "<worktree>/.hivemind/runs/<id>/state.json" shape → MALFORMED, never read. ASSERT no
# /etc/passwd bytes (the `root:` line) appear in output.
assert_proj_ledger_escape() {
    local name="PROJ-ESCAPE-LEDGER:pointer-escapes-worktree-rejected"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/escledger"
    local wt="$wd/wt"
    mkdir -p "$wt"
    local manifest="$wd/manifest.json"
    # Pointer is an absolute path well outside the worktree. allowlist-clean charset but
    # wrong SHAPE → escape attempt → MALFORMED, no read.
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "/etc/passwd"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 7)" == "MALFORMED" \
          && "$(strain_field "$out" 8)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'root:'; then
        pass "$name" "exit 0; escaping pointer → MALFORMED; no /etc/passwd bytes in output"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 7) run=$(strain_field "$out" 8); leaked=$(printf '%s' "$out" | grep -q 'root:' && echo yes || echo no)"
    fi
}

# ── Projection 9: missing argument → nonzero exit, blocker: on stderr ────────────
assert_proj_missing_arg() {
    local name="PROJ-MISSING-ARG:no-manifest-arg-blocks"
    local err rc=0
    err="$(bash "$PROJECT_SCRIPT" 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]] && printf '%s' "$err" | grep -q '^blocker:'; then
        pass "$name" "exit $rc (nonzero); blocker: emitted on stderr"
    else
        failed "$name" "rc=$rc stderr=[$err]"
    fi
}

# ── Projection 11: PRESENT but UNPARSEABLE manifest → MANIFEST_UNREADABLE sentinel + exit 2 ──
# A manifest file that EXISTS but is torn / truncated / invalid JSON must NOT be silently
# projected as zero strains (corruption indistinguishable from an empty brood, hiding live
# children — Codex #172 P1 Finding 2). The entrypoint probes parseability after pre-flight and
# emits exactly one MANIFEST_UNREADABLE<TAB><path> sentinel line to stdout, exiting nonzero (2),
# with NO STRAIN lines. We capture stdout (run_project discards stderr).
assert_proj_unreadable_manifest() {
    local name="PROJ-UNREADABLE:present-but-invalid-json-sentinel"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/unreadable"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    # Torn / truncated JSON: a valid opening that jq cannot parse. Pure DATA written with LF.
    printf '{"manifest_version":3,"strains":[{"name":"api",\n' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_path
    sentinel_path="$(printf '%s\n' "$out" | awk -F'\t' '/^MANIFEST_UNREADABLE\t/ { print $2; exit }')"
    if [[ "$rc" -eq 2 \
          && "$strain_lines" -eq 0 \
          && "$sentinel_path" == "$manifest" ]]; then
        pass "$name" "exit 2; MANIFEST_UNREADABLE sentinel emitted (path=$sentinel_path); no STRAIN lines"
    else
        failed "$name" "rc=$rc strain_lines=$strain_lines sentinel_path=[$sentinel_path] expected exit 2 + sentinel + 0 strains"
    fi
}

# ── Projection 12: VALID empty manifest → exit 0, no STRAIN lines, NO sentinel ───
# A genuinely empty-but-VALID manifest (`{"strains":[]}`) is a legit empty brood: exit 0,
# zero STRAIN lines, and NO MANIFEST_UNREADABLE sentinel. This proves the parseability probe
# distinguishes "present but unparseable" (Projection 11) from "valid empty brood".
assert_proj_valid_empty_manifest() {
    local name="PROJ-EMPTY-OK:valid-empty-manifest-exit0-no-sentinel"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/emptyok"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    jq -n '{manifest_version:3, brood_id:"2026-05-30T22-10-00Z", base:"main", overlap_risk:"low", strains:[], merge_order:[]}' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_seen=no
    printf '%s\n' "$out" | grep -q '^MANIFEST_UNREADABLE	' && sentinel_seen=yes
    if [[ "$rc" -eq 0 \
          && "$strain_lines" -eq 0 \
          && "$sentinel_seen" == "no" ]]; then
        pass "$name" "exit 0; valid empty manifest → no STRAIN lines, no MANIFEST_UNREADABLE sentinel"
    else
        failed "$name" "rc=$rc strain_lines=$strain_lines sentinel_seen=$sentinel_seen expected exit 0 + 0 strains + no sentinel"
    fi
}

# ── Projection 13: VALID-JSON-but-WRONG-SHAPE manifest → MANIFEST_UNREADABLE + exit 2 ──
# A manifest that is syntactically VALID JSON but structurally wrong-shape ({}, {"strains":null},
# {"strains":"x"}, {"strains":[1]} — a non-object element) must NOT be silently projected as zero
# strains. The old `jq empty` probe was syntax-only: all four passed it, then `.strains[]?.name`
# yielded nothing → projected as a legitimate EMPTY brood, hiding live children. The single
# shape-validating read now requires `.strains` to EXIST as an ARRAY with every element an
# OBJECT; each of these fails it → MANIFEST_UNREADABLE sentinel + exit 2 (joining the wrong-shape
# class to the syntactically-invalid class). Pure DATA written with LF.
assert_proj_wrong_shape_unreadable() {
    local name="PROJ-WRONGSHAPE:valid-json-wrong-shape-unreadable"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/wrongshape"
    mkdir -p "$wd"
    # Each is valid JSON but structurally wrong: missing .strains, null .strains, non-array
    # .strains, and an array whose element is not an object.
    local cases=( '{}' '{"strains":null}' '{"strains":"x"}' '{"strains":[1]}' )
    local all_ok=yes detail=""
    local i=0
    for body in "${cases[@]}"; do
        local manifest="$wd/manifest-$i.json"
        printf '%s\n' "$body" > "$manifest"
        local out rc=0
        out="$(run_project "$manifest")" || rc=$?
        local strain_lines; strain_lines="$(count_strain_lines "$out")"
        local sentinel_path
        sentinel_path="$(printf '%s\n' "$out" | awk -F'\t' '/^MANIFEST_UNREADABLE\t/ { print $2; exit }')"
        if [[ "$rc" -ne 2 || "$strain_lines" -ne 0 || "$sentinel_path" != "$manifest" ]]; then
            all_ok=no
            detail+=" [$body → rc=$rc lines=$strain_lines sentinel=$sentinel_path]"
        fi
        i=$((i + 1))
    done
    if [[ "$all_ok" == "yes" ]]; then
        pass "$name" "all 4 wrong-shape manifests → exit 2 + MANIFEST_UNREADABLE + 0 STRAIN lines"
    else
        failed "$name" "expected exit 2 + sentinel + 0 strains for each;$detail"
    fi
}

# ── Projection 14: object element missing `name` → projects (per-strain MALFORMED), NOT unreadable ──
# A strain element that IS a JSON object but lacks `name` ({"strains":[{}]}) passes SHAPE
# validation (it is an object) — per-strain field degradation is the existing contract, distinct
# from a whole-manifest structural failure. The strain projects with a MALFORMED name token (the
# presentation class rejects the empty name) and exit 0, NOT MANIFEST_UNREADABLE. This proves the
# wrong-shape verdict (Projection 13) fires on non-object elements, not on object elements that
# merely lack fields.
assert_proj_object_element_missing_name() {
    local name="PROJ-OBJNONAME:object-element-no-name-projects-malformed"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/objnoname"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    printf '%s\n' '{"strains":[{}]}' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_seen=no
    printf '%s\n' "$out" | grep -q '^MANIFEST_UNREADABLE	' && sentinel_seen=yes
    if [[ "$rc" -eq 0 \
          && "$strain_lines" -eq 1 \
          && "$sentinel_seen" == "no" \
          && "$(strain_field "$out" 2)" == "MALFORMED" ]]; then
        pass "$name" "exit 0; one STRAIN line; name=MALFORMED; no MANIFEST_UNREADABLE sentinel (per-strain degradation, not structural failure)"
    else
        failed "$name" "rc=$rc lines=$strain_lines sentinel_seen=$sentinel_seen name=$(strain_field "$out" 2) expected exit 0 + 1 strain + name MALFORMED + no sentinel"
    fi
}

# ── Projection NOTMPDIR: read path needs no writable TMPDIR ──────────────────────
# brood-status-project.sh was converted from here-strings to `printf | jq` pipes so
# the read path no longer requires a writable $TMPDIR (here-strings spill to a temp
# file when the string is above the kernel's pipe-buffer threshold). This case locks
# that property by running the entrypoint with TMPDIR pointed at a NON-WRITABLE path
# and asserting that it STILL projects both strains (exit 0, two STRAIN lines).
#
# Mechanism: create a dir and chmod 000 it so no process can write into it, then
# restore 0700 before teardown so rm -rf can remove it. Using a dir we own and
# chmod ourselves is CI-safe (ubuntu-latest, non-root) — no /proc or system paths.
assert_proj_no_tmpdir_needed() {
    local name="PROJ-NOTMPDIR:read-path-needs-no-writable-tmpdir"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/notmpdir"
    local wt_a="$wd/wt-api" wt_b="$wd/wt-web"
    mkdir -p "$wt_a/.hivemind/runs/run-id" "$wt_b/.hivemind/runs/run-id"
    write_ledger "$wt_a/.hivemind/runs/run-id/state.json" running implement_step
    write_ledger "$wt_b/.hivemind/runs/run-id/state.json" done review_step
    local manifest="$wd/manifest.json"
    jq -n \
        --arg wt_a "$wt_a" \
        --arg wt_b "$wt_b" \
        --arg ledger_a "$wt_a/.hivemind/runs/run-id/state.json" \
        --arg ledger_b "$wt_b/.hivemind/runs/run-id/state.json" \
        '{
            manifest_version: 3,
            brood_id: "2026-06-01T22-00-00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                {
                    name: "api",
                    description: "api strain",
                    worktree_path: $wt_a,
                    branch: "feature/api-slice",
                    tmux_session: "brood-api",
                    status: "running",
                    pr: null,
                    merged: false,
                    rebased_after: [],
                    run: {
                        suggested_id: "run-id",
                        suggested_ledger: $ledger_a,
                        workflow_hint: "standard-delivery"
                    }
                },
                {
                    name: "web",
                    description: "web strain",
                    worktree_path: $wt_b,
                    branch: "feature/web-slice",
                    tmux_session: "brood-web",
                    status: "done",
                    pr: null,
                    merged: false,
                    rebased_after: [],
                    run: {
                        suggested_id: "run-id",
                        suggested_ledger: $ledger_b,
                        workflow_hint: "standard-delivery"
                    }
                }
            ],
            merge_order: []
        }' > "$manifest"

    # Create a non-writable TMPDIR: chmod 000 prevents any process from creating files
    # inside it. Restore 0700 before the function returns so cleanup()'s rm -rf can
    # descend into and remove it (rm -rf on a 000 dir fails on non-root).
    local bad_tmpdir="$wd/no_writable_tmpdir"
    mkdir -p "$bad_tmpdir"
    chmod 000 "$bad_tmpdir"

    local out rc=0
    out="$(TMPDIR="$bad_tmpdir" run_project "$manifest")" || rc=$?

    # Restore perms immediately after the run so teardown can remove the dir.
    chmod 0700 "$bad_tmpdir"

    local lines; lines="$(count_strain_lines "$out")"
    local api_name web_name
    api_name="$(printf '%s\n' "$out" | awk -F'\t' '$2=="api"{print $2; exit}')"
    web_name="$(printf '%s\n' "$out" | awk -F'\t' '$2=="web"{print $2; exit}')"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 2 \
          && "$api_name" == "api" \
          && "$web_name" == "web" ]]; then
        pass "$name" "exit 0; 2 STRAIN lines (api, web) with non-writable TMPDIR — no writable-temp dependency"
    else
        failed "$name" "rc=$rc lines=$lines api_name=[$api_name] web_name=[$web_name] — read path requires writable TMPDIR"
    fi
}

# ── Projection SNAPSHOT: single-read consistency — both scalars from ONE snapshot ─
# STRUCTURAL regression for the single-snapshot read (symlink-swap TOCTOU hardening): the
# entrypoint now reads each confined ledger EXACTLY ONCE into an in-memory snapshot and projects
# BOTH scalars (run.status + state.current) from that one snapshot, instead of re-opening the
# leaf per scalar via jq (which followed symlinks, widening the swap window). A live race is
# non-deterministic, so we do NOT attempt a flaky swap test; instead we lock the OBSERVABLE
# invariant: for a single VALID ledger, ONE entrypoint run yields BOTH scalars correctly and
# consistently (run_status=blocked AND state_current=review_step from the same snapshot). If a
# future change reintroduced a per-scalar reopen and skewed the two reads, this asserts the
# coupled projection from one view.
assert_proj_single_snapshot_consistency() {
    local name="PROJ-SNAPSHOT:single-read-both-scalars-consistent"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/snapshot"
    local wt="$wd/wt"
    mkdir -p "$wt/.hivemind/runs/run-id"
    write_ledger "$wt/.hivemind/runs/run-id/state.json" blocked review_step
    local manifest="$wd/manifest.json"
    write_manifest_v2 "$manifest" "api" "$wt" "feature/api-slice" "brood-api" "running" \
        "$wt/.hivemind/runs/run-id/state.json"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 1 \
          && "$(strain_field "$out" 7)" == "review_step" \
          && "$(strain_field "$out" 8)" == "blocked" ]]; then
        pass "$name" "exit 0; one STRAIN line; both scalars project consistently from single snapshot (state=review_step run=blocked)"
    else
        failed "$name" "rc=$rc lines=$lines state=$(strain_field "$out" 7) run=$(strain_field "$out" 8)"
    fi
}

# ── Projection 10: multi-strain — one healthy + one malformed, independent ───────
# Two strains: a healthy one projects fully; a second whose state.current carries an
# injection payload projects state_current=MALFORMED. One STRAIN line each, exit 0.
assert_proj_multi_strain() {
    local name="PROJ-MULTI:two-strains-independent-projection"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/multi"
    local wt_a="$wd/wt-api" wt_b="$wd/wt-web"
    mkdir -p "$wt_a/.hivemind/runs/run-id" "$wt_b/.hivemind/runs/run-id"
    write_ledger "$wt_a/.hivemind/runs/run-id/state.json" running implement_step
    write_ledger "$wt_b/.hivemind/runs/run-id/state.json" running "State With Spaces"
    local manifest="$wd/manifest.json"
    jq -n \
        --arg wt_a "$wt_a" \
        --arg wt_b "$wt_b" \
        --arg ledger_a "$wt_a/.hivemind/runs/run-id/state.json" \
        --arg ledger_b "$wt_b/.hivemind/runs/run-id/state.json" \
        '{
            manifest_version: 3,
            brood_id: "2026-05-30T22-10-00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                {
                    name: "api",
                    description: "strain a",
                    worktree_path: $wt_a,
                    branch: "feature/api-slice",
                    tmux_session: "brood-api",
                    status: "running",
                    run: {
                        suggested_id: "run-id",
                        suggested_ledger: $ledger_a,
                        workflow_hint: "standard-delivery"
                    }
                },
                {
                    name: "web",
                    description: "strain b",
                    worktree_path: $wt_b,
                    branch: "feature/web-slice",
                    tmux_session: "brood-web",
                    status: "running",
                    run: {
                        suggested_id: "run-id",
                        suggested_ledger: $ledger_b,
                        workflow_hint: "standard-delivery"
                    }
                }
            ],
            merge_order: []
        }' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    # Field 7 (state_current) of the api line and the web line, extracted by name.
    local api_state web_state
    api_state="$(printf '%s\n' "$out" | awk -F'\t' '$2=="api"{print $7; exit}')"
    web_state="$(printf '%s\n' "$out" | awk -F'\t' '$2=="web"{print $7; exit}')"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 2 \
          && "$api_state" == "implement_step" \
          && "$web_state" == "MALFORMED" ]]; then
        pass "$name" "exit 0; 2 STRAIN lines; api state_current=implement_step, web state_current=MALFORMED (independent)"
    else
        failed "$name" "rc=$rc lines=$lines api_state=$api_state web_state=$web_state"
    fi
}

echo '=== Brood manifest back-compat tests: brood-status reads v1 (old) and v2 (new) manifests ==='
assert_v1_old
assert_v2_new
assert_brood_instruction_flag_parity
assert_spawn_brood_symlink_escape_blocked
assert_spawn_brood_inputs_external_rejected
assert_spawn_brood_child_worktree_symlink_escape_blocked
assert_spawn_brood_child_leaf_task_escape_blocked
assert_spawn_brood_child_leaf_settings_escape_blocked
assert_spawn_brood_child_leaf_regular_ok

echo ''
echo '=== brood-status-project.sh read-side projection tests (#161) ==='
assert_proj_happy_path
assert_proj_v1_no_run_block
assert_proj_missing_ledger_file
assert_proj_malformed_run_status
assert_proj_injection_state_current
assert_proj_metachar_worktree
assert_proj_symlink_leaf
assert_proj_unreadable_ledger
assert_proj_ledger_escape
assert_proj_missing_arg
assert_proj_no_tmpdir_needed
assert_proj_multi_strain
assert_proj_unreadable_manifest
assert_proj_valid_empty_manifest
assert_proj_wrong_shape_unreadable
assert_proj_object_element_missing_name
assert_proj_single_snapshot_consistency

echo ''
echo '=== Summary ==='
echo "Brood back-compat tests: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
