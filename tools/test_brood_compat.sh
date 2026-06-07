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
DISCOVER_SCRIPT="$REPO_ROOT/plugin/skills/brood-status/scripts/brood-discover.sh"
COLLECT_SCRIPT="$REPO_ROOT/plugin/skills/brood-status/scripts/brood-status-collect.sh"

for required in "$MANIFEST_V1" "$MANIFEST_V2" "$SPAWN_SCRIPT" "$INIT_SCRIPT" "$PROJECT_SCRIPT" "$DISCOVER_SCRIPT" "$COLLECT_SCRIPT"; do
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

# ── Test-scoped `claude` stub (#169 — make the child-provisioning escape cases CI-runnable) ──
# CI lacks a real `claude` binary, so the six spawn-invoking cases historically SKIP at the
# spawn-brood dep gate (`command -v claude`). That left the P0 symlink-leaf containment guards
# UN-exercised in CI: deleting a guard would NOT turn CI red. To close that, this suite ships a
# SELF-INSTALLED, TEST-SCOPED `claude` shim that lets the dep gate pass on a host without a real
# claude, WITHOUT ever installing globally — the stub dir is only ever prepended to PATH inside
# the spawn-invocation subshell of each case (STEP-003), never exported suite-wide.
#
# The shim does NO real work. On invocation it: records a launch (CWD via `pwd -P`, argv, and
# which config surfaces are present relative to CWD) to a per-case launch-marker file passed via
# the HIVEMIND_STUB_MARKER env var; prints the readiness line spawn-brood polls for
# (`hivemind:overlord` — READY_SUBSTRING) so the positive case's Pass-2 capture-pane match
# succeeds without burning the 90s READY_TIMEOUT; keeps the pane alive briefly so at least one
# capture-pane poll (POLL_INTERVAL=2) reads the line; then exits 0. It uses only POSIX builtins +
# printf redirection (it runs under `tmux new-session` as a detached pty with no stdin).
#
# The marker path is UNIQUE PER CASE (each case sets HIVEMIND_STUB_MARKER to its own file), so a
# launch recorded by one case can never bleed into another case's assertions.
STUB_BIN=""
build_claude_stub() {
    # Idempotent: build once, reuse across cases. Reaped via the EXIT cleanup() below.
    [ -n "$STUB_BIN" ] && return 0
    STUB_BIN="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-compat-stub.XXXXXX")"
    cat > "$STUB_BIN/claude" <<'STUB_EOF'
#!/usr/bin/env bash
# Test-scoped `claude` stub (hivemind #169). NO real work — records the launch + exits 0.
# Reads HIVEMIND_STUB_MARKER (per-case unique) for the launch-record path.
marker="${HIVEMIND_STUB_MARKER:-}"
if [ -n "$marker" ]; then
    {
        printf 'LAUNCH\n'
        printf 'cwd=%s\n' "$(pwd -P)"
        printf 'argv=%s\n' "$*"
        if [ -f .hivemind/brood/task.md ]; then printf 'task_md=present\n'; else printf 'task_md=absent\n'; fi
        if [ -f .claude/settings.local.json ]; then printf 'settings_local=present\n'; else printf 'settings_local=absent\n'; fi
    } >> "$marker" 2>/dev/null || true
fi
# Emit the readiness chrome spawn-brood's capture-pane poll greps for (READY_SUBSTRING),
# then keep the pane alive long enough for at least one POLL_INTERVAL=2 poll to read it.
printf 'hivemind:overlord\n'
sleep 4
exit 0
STUB_EOF
    chmod +x "$STUB_BIN/claude"
    return 0
}

# spawn_deps_satisfied: the dep gate for the spawn-invoking cases. `claude` is treated as
# satisfied UNCONDITIONALLY because each case prepends the test-scoped stub (build_claude_stub)
# onto PATH for the spawn invocation — so `claude` resolves to the stub whether or not a real
# binary is present. Building the stub here (always, regardless of a real claude on PATH) makes
# the launch-marker assertions DETERMINISTIC in both envs: the stub — not a real claude — is the
# binary tmux execs, so the marker is written under the exact CWD spawn-brood launched into.
# `tmux` and `jq` remain REAL-binary checks — a host genuinely missing them still SKIPs cleanly,
# preserving local-dev parity (the suite passes when tmux/jq are genuinely absent). On any
# genuine miss echoes the missing names (space-joined) and returns 1; on full satisfaction
# echoes nothing and returns 0.
spawn_deps_satisfied() {
    local missing=""
    for dep in tmux jq; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    # claude is provided by the test-scoped stub, prebuilt at suite top-level (see the
    # build_claude_stub call after trap setup). STUB_BIN must be non-empty here — if it is
    # empty the stub failed to build, which IS a genuine claude miss. This helper runs inside a
    # command substitution, so it must NOT build the stub itself (a STUB_BIN set in a subshell
    # would not propagate to the parent) — it only verifies the prebuilt stub is present.
    [ -n "$STUB_BIN" ] || missing="${missing:+$missing }claude"
    if [ -n "$missing" ]; then
        printf '%s' "$missing"
        return 1
    fi
    return 0
}

cleanup() {
    reap_brood_sessions
    tmux kill-server 2>/dev/null || true   # tear down the private tmux server entirely
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
    # PROJ_WORKDIR is folded into WORKDIR only when WORKDIR was empty at first use; when a
    # spawn case set WORKDIR first, PROJ_WORKDIR is a separate dir and needs its own reap.
    [ -n "${PROJ_WORKDIR:-}" ] && [ "${PROJ_WORKDIR:-}" != "${WORKDIR:-}" ] && rm -rf "$PROJ_WORKDIR"
    [ -n "${TMUX_TMPDIR:-}" ] && rm -rf "$TMUX_TMPDIR"
    return 0
}
trap cleanup EXIT

# Build the test-scoped claude stub ONCE at suite top-level (#169). This MUST happen in the main
# shell — not inside spawn_deps_satisfied, which runs in a command substitution where a STUB_BIN
# assignment would be confined to the subshell and never reach the parent. STUB_BIN is reaped by
# cleanup() on EXIT. After this, $STUB_BIN is non-empty for every spawn-invoking case to prepend.
build_claude_stub

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

# The v4 brood-id-namespaced identifiers the committed fixtures carry. Both fixtures share one
# generated GUID (^brood-[0-9a-f-]+$); the per-strain branch/tmux_session are DERIVED from it
# (branch = strain/<brood-id>/<short>, tmux = <brood-id>-<short>) — no longer the old
# feature/api-slice + brood-api forms. These literals must stay in lock-step with the fixtures.
FIX_BROOD_ID="brood-1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
FIX_BRANCH="strain/${FIX_BROOD_ID}/api"
FIX_TMUX="${FIX_BROOD_ID}-api"

# ── Assertion 1: OLD v1 manifest parses, yields the expected v4 session/branch ───
# Both committed fixtures are manifest_version 4 now (the v1/v2 filenames are historical: v1 is
# the no-run-block shape, v2 carries the additive run block). This asserts the no-run-block
# fixture parses and yields the brood-id-derived tmux_session/branch, AND that manifest_version
# is 4 (version parity).
assert_v1_old() {
    local name="V1:old-manifest-no-run-block"
    local session branch version
    session="$(extract_tmux_session "$MANIFEST_V1")"
    branch="$(extract_branch "$MANIFEST_V1")"
    version="$(jq -r '.manifest_version' "$MANIFEST_V1")"
    if [[ "$session" == "$FIX_TMUX" && "$branch" == "$FIX_BRANCH" && "$version" == "4" ]]; then
        pass "$name" "v1 (no-run-block) manifest_version=4; session=$session branch=$branch"
    else
        failed "$name" "expected $FIX_TMUX/$FIX_BRANCH/v4, got session=$session branch=$branch version=$version"
    fi
}

# ── Assertion 2: NEW v2 manifest parses, yields the expected v4 session/branch ───
# The additive run: block is carried (run.suggested_id kept, run.suggested_ledger DROPPED in v4).
# Asserts the run-block fixture parses, yields the brood-id-derived session/branch, manifest_version
# is 4, AND that the dropped run.suggested_ledger is genuinely absent while run.suggested_id remains.
assert_v2_new() {
    local name="V2:new-manifest-additive-run-block"
    local session branch version sid sledger
    session="$(extract_tmux_session "$MANIFEST_V2")"
    branch="$(extract_branch "$MANIFEST_V2")"
    version="$(jq -r '.manifest_version' "$MANIFEST_V2")"
    sid="$(jq -r '.strains[0].run.suggested_id // ""' "$MANIFEST_V2")"
    sledger="$(jq -r '.strains[0].run | has("suggested_ledger")' "$MANIFEST_V2")"
    if [[ "$session" == "$FIX_TMUX" && "$branch" == "$FIX_BRANCH" && "$version" == "4" \
          && "$sid" == "${FIX_BROOD_ID}--api" && "$sledger" == "false" ]]; then
        pass "$name" "v2 manifest_version=4; session=$session branch=$branch; suggested_id kept, suggested_ledger dropped"
    else
        failed "$name" "expected v4 + $FIX_TMUX/$FIX_BRANCH + suggested_id=${FIX_BROOD_ID}--api + no suggested_ledger; got version=$version session=$session branch=$branch sid=$sid has_ledger=$sledger"
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
    # claude is provided by the test-scoped stub (#169), so only a genuine tmux/jq miss SKIPs.
    local missing=""
    missing="$(spawn_deps_satisfied)" || {
        skip "$name" "spawn-brood dep check precedes the containment guard; skipping (missing: $missing)"
        return
    }

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
    # Author the inputs UNDER $gitroot (not $WORKDIR) so the inputs READ-guard
    # (hivemind_assert_inputs_contained, spawn-brood.sh:142) PASSES and execution reaches the
    # `.hivemind/broods/<brood-id>` WRITE-CHAIN guard (spawn-brood.sh:285-286) this case targets.
    # An inputs file outside the checkout would trip the read-guard FIRST, exiting before the
    # write-chain guard ever runs — making the pass vacuous. The symlinked `.hivemind` above is the
    # only hostile element; the inputs themselves are contained and valid.
    local inputs="$gitroot/brood-inputs.json"
    jq -n \
        --arg base "main" \
        --arg overlap_risk "low" \
        --arg overlap_details "brood compat symlink-escape test" \
        --arg strain_name "api" \
        --arg strain_desc "symlink escape test strain" \
        '{
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc } ]
        }' \
        > "$inputs"

    local rc=0
    # #169: prepend the test-scoped claude stub onto PATH for THIS spawn invocation only (never
    # exported suite-wide) so spawn-brood's own `command -v claude` dep check passes on a host
    # without a real claude. This case blockers at the coordinator-side guard BEFORE the per-strain
    # loop, so the stub claude is never actually exec'd — but the PATH prefix is still required to
    # get past spawn-brood's dep gate to the guard under test. Real tmux/jq still resolve normally.
    local marker="$WORKDIR/launch-marker.txt"
    # Capture stderr to a file (not discard via 2>&1) so we can assert WHICH guard fired — the
    # write-chain guard this case targets must be the one that rejected, NOT the inputs read-guard.
    local stderr_out="$WORKDIR/spawn-stderr.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && PATH="$STUB_BIN:$PATH" HIVEMIND_STUB_MARKER="$marker" bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>"$stderr_out" || rc=$?

    # The guard must reject (non-zero) AND nothing may have been written under the external
    # escape target: no brood/ STATE dir, no manifest, no worktree. A successful escape would
    # land .hivemind/brood/manifest.json (and possibly worktrees) under the external target.
    local escaped=no
    if find "$external" -mindepth 1 -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    # ANTI-VACUITY: assert the `.hivemind/broods/<brood-id>` WRITE-CHAIN guard (spawn-brood.sh:286)
    # is the one that fired — not the inputs READ-guard. With the inputs now contained, a non-zero
    # exit could otherwise still come from the read-guard if the relocation regressed; pinning the
    # exact write-chain signature keeps the case keyed on the guard under test.
    #   - which_guard: write-chain `refusing to spawn:` AND `.hivemind/broods/` present in stderr.
    #     The `.hivemind/broods/` substring also distinguishes it from the `.claude/worktrees/`
    #     write-chain guard (spawn-brood.sh:290-291), which would fire only AFTER this one passes.
    #   - read_guard_fired: the inputs read-guard signature (spawn-brood.sh:143) must be ABSENT.
    local which_guard=no read_guard_fired=no
    if grep -q 'refusing to spawn:' "$stderr_out" 2>/dev/null \
        && grep -q '\.hivemind/broods/' "$stderr_out" 2>/dev/null; then
        which_guard=yes
    fi
    if grep -q 'refusing to read the inputs file:' "$stderr_out" 2>/dev/null; then
        read_guard_fired=yes
    fi
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$which_guard" == "yes" && "$read_guard_fired" == "no" ]]; then
        pass "$name" "symlinked .hivemind rejected by write-chain guard (exit $rc); no manifest/worktree written under external target; read-guard did not pre-empt"
    else
        failed "$name" "expected non-zero exit + no external write + write-chain guard fired + read-guard absent; rc=$rc escaped=$escaped which_guard=$which_guard read_guard_fired=$read_guard_fired stderr: $(cat "$stderr_out" 2>/dev/null)"
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
    # claude is provided by the test-scoped stub (#169), so only a genuine tmux/jq miss SKIPs.
    local missing=""
    missing="$(spawn_deps_satisfied)" || {
        skip "$name" "spawn-brood dep check precedes the read-guard; skipping (missing: $missing)"
        return
    }

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
        --arg base "main" \
        --arg overlap_risk "low" \
        --arg overlap_details "brood compat inputs-external read-guard test" \
        --arg strain_name "api" \
        --arg strain_desc "external inputs read-guard test strain" \
        '{
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc } ]
        }' \
        > "$inputs"

    local rc=0
    # #169: prepend the test-scoped claude stub onto PATH for THIS spawn invocation only (never
    # exported suite-wide) so spawn-brood's own `command -v claude` dep check passes on a host
    # without a real claude. This case blockers at the coordinator-side guard BEFORE the per-strain
    # loop, so the stub claude is never actually exec'd — but the PATH prefix is still required to
    # get past spawn-brood's dep gate to the guard under test. Real tmux/jq still resolve normally.
    local marker="$WORKDIR/launch-marker.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && PATH="$STUB_BIN:$PATH" HIVEMIND_STUB_MARKER="$marker" bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>&1 || rc=$?

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
    # claude is provided by the test-scoped stub (#169), so only a genuine tmux/jq miss SKIPs.
    local missing=""
    missing="$(spawn_deps_satisfied)" || {
        skip "$name" "spawn-brood dep check precedes the child-worktree guard; skipping (missing: $missing)"
        return
    }

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
        --arg base "evil" \
        --arg overlap_risk "low" \
        --arg overlap_details "brood compat child-worktree symlink-escape test" \
        --arg strain_name "api" \
        --arg strain_desc "child worktree symlink escape test strain" \
        '{
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc } ]
        }' \
        > "$inputs"

    local rc=0
    # #169: prepend the test-scoped claude stub onto PATH for THIS spawn invocation only (never
    # exported suite-wide) so spawn-brood's own `command -v claude` dep check passes on a host
    # without a real claude. This case blockers at the coordinator-side guard BEFORE the per-strain
    # loop, so the stub claude is never actually exec'd — but the PATH prefix is still required to
    # get past spawn-brood's dep gate to the guard under test. Real tmux/jq still resolve normally.
    local marker="$WORKDIR/launch-marker.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && PATH="$STUB_BIN:$PATH" HIVEMIND_STUB_MARKER="$marker" bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>&1 || rc=$?

    # The child-worktree guard must reject (non-zero — the single strain fails) AND nothing may
    # have been written under the external escape target. A successful escape (OLD behavior) would
    # land $external/brood/task.md (the provisioned task file) under the external target.
    local escaped=no
    if find "$external" -mindepth 1 -print 2>/dev/null | grep -q .; then
        escaped=yes
    fi
    # The offending worktree must also be removed (not left dangling for a later launch).
    # v4 namespacing: the worktree path is .claude/worktrees/<brood-id>/<short> with an
    # internally-generated brood-id. The guard removes the worktree LEAF (git worktree remove +
    # rm -rf "$wt") but leaves the now-empty <brood-id>/ PARENT dir behind — that empty parent is
    # benign and must NOT count as a leak. A real leak is a still-REGISTERED git worktree under
    # .claude/worktrees/, so ask git (ground truth) rather than scanning for any leftover dir.
    local worktree_leaked=no
    if git -C "$gitroot" worktree list --porcelain 2>/dev/null \
         | grep -E '^worktree .*/\.claude/worktrees/' | grep -q .; then
        worktree_leaked=yes
    fi
    # #169 NON-VACUITY: the child-worktree guard fires BEFORE the per-strain provisioning/launch,
    # so the stub claude must NEVER have been exec'd — the per-case launch marker must be ABSENT.
    # With the guard deleted, provisioning would proceed, tmux would exec the stub into the
    # escaping worktree, and the marker would record a launch → this flips to FAIL.
    local stub_launched=no
    [ -s "$marker" ] && stub_launched=yes
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$worktree_leaked" == "no" && "$stub_launched" == "no" ]]; then
        pass "$name" "child-worktree symlinked .hivemind rejected (exit $rc); worktree removed; no stub launch; nothing written under external target"
    else
        failed "$name" "expected non-zero exit + no external write + worktree removed + no stub launch; rc=$rc escaped=$escaped worktree_leaked=$worktree_leaked stub_launched=$stub_launched"
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
    # claude is provided by the test-scoped stub (#169), so only a genuine tmux/jq miss SKIPs.
    local missing=""
    missing="$(spawn_deps_satisfied)" || {
        skip "$name" "spawn-brood dep check precedes the leaf guard; skipping (missing: $missing)"
        return
    }

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
        --arg base "evil" \
        --arg overlap_risk "low" \
        --arg overlap_details "child-leaf-escape-task regression test" \
        --arg strain_name "api" \
        --arg strain_desc "task leaf symlink escape test strain" \
        '{
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc } ]
        }' \
        > "$inputs"

    # Capture stderr separately to assert the SPECIFIC leaf-guard rejection fired — not some
    # coincidental downstream failure. On the VULNERABLE impl the redirect follows the symlink
    # and creates $external/task.md (escaped=yes), so this case fails there; on the FIXED impl
    # the [ -L ] leaf test rejects before any write, emitting the guard's warning to stderr.
    local rc=0
    local stderr_out="$WORKDIR/spawn-stderr.txt"
    # #169: prepend the test-scoped claude stub onto PATH for THIS spawn invocation only so
    # spawn-brood's own `command -v claude` dep check passes on a host without a real claude. The
    # leaf guard fires before any tmux/child launch, so the stub claude is never exec'd here — but
    # the PATH prefix is required to reach the leaf guard. Real tmux/jq resolve normally.
    local marker="$WORKDIR/launch-marker.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && PATH="$STUB_BIN:$PATH" HIVEMIND_STUB_MARKER="$marker" bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>"$stderr_out" || rc=$?

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
    # v4 namespacing: the worktree path is .claude/worktrees/<brood-id>/<short> with an
    # internally-generated brood-id. The guard removes the worktree LEAF (git worktree remove +
    # rm -rf "$wt") but leaves the now-empty <brood-id>/ PARENT dir behind — that empty parent is
    # benign and must NOT count as a leak. A real leak is a still-REGISTERED git worktree under
    # .claude/worktrees/, so ask git (ground truth) rather than scanning for any leftover dir.
    local worktree_leaked=no
    if git -C "$gitroot" worktree list --porcelain 2>/dev/null \
         | grep -E '^worktree .*/\.claude/worktrees/' | grep -q .; then
        worktree_leaked=yes
    fi
    # #169 NON-VACUITY: the task.md leaf guard fires BEFORE the per-strain `tmux new-session`, so
    # the stub claude must NEVER have been exec'd — the per-case launch marker must be ABSENT.
    # With the leaf guard deleted, the printf redirect would follow the symlink, the strain would
    # proceed to launch, and the stub would record a launch into the marker → this flips to FAIL.
    local stub_launched=no
    [ -s "$marker" ] && stub_launched=yes
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$worktree_leaked" == "no" && "$leaf_guard_rejected" == "yes" && "$stub_launched" == "no" ]]; then
        pass "$name" "task.md symlinked leaf rejected by leaf guard (exit $rc); worktree removed; no stub launch; nothing written under external target"
    else
        failed "$name" "expected non-zero exit + leaf-guard rejection + no external write + worktree removed + no stub launch; rc=$rc escaped=$escaped leaf_guard_rejected=$leaf_guard_rejected worktree_leaked=$worktree_leaked stub_launched=$stub_launched stderr: $(cat "$stderr_out" 2>/dev/null)"
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
    # claude is provided by the test-scoped stub (#169), so only a genuine tmux/jq miss SKIPs.
    local missing=""
    missing="$(spawn_deps_satisfied)" || {
        skip "$name" "spawn-brood dep check precedes the leaf guard; skipping (missing: $missing)"
        return
    }

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
        --arg base "evil2" \
        --arg overlap_risk "low" \
        --arg overlap_details "child-leaf-escape-settings regression test" \
        --arg strain_name "api" \
        --arg strain_desc "settings leaf symlink escape test strain" \
        '{
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc } ]
        }' \
        > "$inputs"

    # Capture stderr separately to assert the SPECIFIC leaf-guard rejection fired — not some
    # coincidental downstream/pre-flight failure. On the VULNERABLE impl the cp follows the
    # symlink and writes external/settings.local.json (escaped=yes), so this case fails there;
    # on the FIXED impl the [ -L ] leaf test rejects before any write, emitting the guard's
    # warning to stderr.
    local rc=0
    local stderr_out="$WORKDIR/spawn-stderr.txt"
    # #169: prepend the test-scoped claude stub onto PATH for THIS spawn invocation only so
    # spawn-brood's own `command -v claude` dep check passes on a host without a real claude. The
    # leaf guard fires before any tmux/child launch, so the stub claude is never exec'd here — but
    # the PATH prefix is required to reach the leaf guard. Real tmux/jq resolve normally.
    local marker="$WORKDIR/launch-marker.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && PATH="$STUB_BIN:$PATH" HIVEMIND_STUB_MARKER="$marker" bash "$SPAWN_SCRIPT" "$inputs" ) >/dev/null 2>"$stderr_out" || rc=$?

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
    # v4 namespacing: the worktree path is .claude/worktrees/<brood-id>/<short> with an
    # internally-generated brood-id. The guard removes the worktree LEAF (git worktree remove +
    # rm -rf "$wt") but leaves the now-empty <brood-id>/ PARENT dir behind — that empty parent is
    # benign and must NOT count as a leak. A real leak is a still-REGISTERED git worktree under
    # .claude/worktrees/, so ask git (ground truth) rather than scanning for any leftover dir.
    local worktree_leaked=no
    if git -C "$gitroot" worktree list --porcelain 2>/dev/null \
         | grep -E '^worktree .*/\.claude/worktrees/' | grep -q .; then
        worktree_leaked=yes
    fi
    # #169 NON-VACUITY: the settings.local.json leaf guard fires BEFORE the per-strain
    # `tmux new-session`, so the stub claude must NEVER have been exec'd — the per-case launch
    # marker must be ABSENT. With the leaf guard deleted, the cp would follow the symlink, the
    # strain would proceed to launch, and the stub would record a launch → this flips to FAIL.
    local stub_launched=no
    [ -s "$marker" ] && stub_launched=yes
    if [[ "$rc" -ne 0 && "$escaped" == "no" && "$worktree_leaked" == "no" && "$leaf_guard_rejected" == "yes" && "$stub_launched" == "no" ]]; then
        pass "$name" "settings.local.json symlinked leaf rejected by leaf guard (exit $rc); worktree removed; no stub launch; nothing written under external target"
    else
        failed "$name" "expected non-zero exit + leaf-guard rejection + no external write + worktree removed + no stub launch; rc=$rc escaped=$escaped leaf_guard_rejected=$leaf_guard_rejected worktree_leaked=$worktree_leaked stub_launched=$stub_launched stderr: $(cat "$stderr_out" 2>/dev/null)"
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
    # claude is provided by the test-scoped stub (#169), so only a genuine tmux/jq miss SKIPs.
    local missing=""
    missing="$(spawn_deps_satisfied)" || {
        skip "$name" "spawn-brood dep check precedes all guards; skipping (missing: $missing)"
        return
    }

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
        --arg base "safe" \
        --arg overlap_risk "low" \
        --arg overlap_details "child-leaf-regular-ok positive test" \
        --arg strain_name "api" \
        --arg strain_desc "regular file leaf positive test strain" \
        '{
            base: $base,
            overlap_risk: $overlap_risk,
            overlap_details: $overlap_details,
            strains: [ { name: $strain_name, description: $strain_desc } ]
        }' \
        > "$inputs"

    # Capture stderr (for leaf-guard rejection inspection) AND stdout (for the brood_id / attach
    # lines, used to reap the actually-launched session below). #169: prepend the test-scoped
    # claude stub onto PATH for THIS spawn invocation only, with a per-case launch marker. Unlike
    # the negative cases, the stub IS exec'd here: the regular-file leaf passes the guard, the run
    # proceeds to `tmux new-session`, and the stub claude runs in the strain worktree, records the
    # launch to $marker, prints the readiness chrome so Pass-2 capture-pane matches, and exits 0.
    local rc=0
    local stderr_out stdout_out marker
    stderr_out="$WORKDIR/spawn-stderr.txt"
    stdout_out="$WORKDIR/spawn-stdout.txt"
    marker="$WORKDIR/launch-marker.txt"
    reap_brood_sessions  # isolate from any brood-api session a prior case leaked (pre-flight 1d collision)
    ( cd "$gitroot" && PATH="$STUB_BIN:$PATH" HIVEMIND_STUB_MARKER="$marker" bash "$SPAWN_SCRIPT" "$inputs" ) >"$stdout_out" 2>"$stderr_out" || rc=$?
    # Reap the ACTUALLY-launched session. v4 namespacing makes the session <brood-id>-api with an
    # internally-generated brood-id, which the literal `brood-api`-scoped reap_brood_sessions does
    # NOT kill. Parse the session name from the spawn stdout `attach:` line and kill it on the
    # private server so no stub session leaks past this case (the EXIT kill-server is the final
    # safety net, but reaping here keeps later cases isolated).
    local launched_session
    launched_session="$(sed -n 's/^attach: tmux attach -t \([^ ]*\).*/\1/p' "$stdout_out" 2>/dev/null | head -1)"
    [ -n "$launched_session" ] && tmux kill-session -t "$launched_session" 2>/dev/null || true

    # ANTI-FALSE-REJECT: the leaf guard emits a specific rejection message. Its ABSENCE
    # in stderr confirms no leaf-guard rejection fired — whether the run succeeded or failed
    # downstream (e.g. at the tmux/launch step), it was NOT the leaf guard.
    local leaf_guard_rejected=no
    if grep -qE 'symlinked .*(task\.md|settings\.local\.json) leaf' "$stderr_out" 2>/dev/null; then
        leaf_guard_rejected=yes
    fi
    # #169 POSITIVE NON-VACUITY: a regular-file leaf must NOT be false-rejected — the run must
    # proceed PAST the leaf guard, reach `tmux new-session`, and actually EXEC the stub claude in
    # the strain worktree. We assert that by requiring the per-case launch marker to be PRESENT
    # AND the recorded launch CWD to be the strain worktree (.claude/worktrees/<brood-id>/api under
    # the coordinator checkout). The stub records its CWD via `pwd -P` (canonicalized), so compare
    # against the canonical coordinator root. If the leaf guard wrongly rejected, no launch would
    # occur and the marker would be ABSENT → FAIL. This is the inverse of the negative cases'
    # marker-absent assertion: here a launch into the correct worktree is the proof of non-reject.
    local canon_gitroot launched_cwd stub_launched_ok=no
    canon_gitroot="$(cd "$gitroot" 2>/dev/null && pwd -P)"
    if [ -s "$marker" ]; then
        launched_cwd="$(sed -n 's/^cwd=//p' "$marker" 2>/dev/null | head -1)"
        # Expected strain worktree: <canon_gitroot>/.claude/worktrees/<brood-id>/api. The brood-id
        # is internally generated, so match the fixed prefix + the /api strain leaf rather than a
        # literal full path.
        case "$launched_cwd" in
            "$canon_gitroot/.claude/worktrees/"*/api) stub_launched_ok=yes ;;
        esac
    fi
    # ANTI-FALSE-REJECT: the leaf guard emits a specific rejection message before any tmux/launch.
    # Its ABSENCE confirms no leaf-guard rejection fired; PRESENCE of a correct stub launch confirms
    # the run reached the launch path through the guard (not false-rejected).
    if [[ "$leaf_guard_rejected" == "no" && "$stub_launched_ok" == "yes" ]]; then
        pass "$name" "regular-file task.md leaf NOT rejected (stub launched into strain worktree $launched_cwd)"
    else
        failed "$name" "expected no leaf-guard rejection + stub launched into strain worktree; rc=$rc leaf_guard_rejected=$leaf_guard_rejected stub_launched_ok=$stub_launched_ok launched_cwd=[${launched_cwd:-}] stderr: $(cat "$stderr_out")"
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
        # A seed commit is REQUIRED: the #168 ground-truth worktree discovery cases register real
        # git worktrees (`git worktree add -b <branch> <path> HEAD`) so the engine can resolve each
        # strain's worktree from `git worktree list --porcelain`; worktree-add needs a commit to
        # branch from. Configure identity locally so the commit succeeds on a bare CI checkout.
        git -C "$PROJ_WORKDIR" config user.email test@example.com
        git -C "$PROJ_WORKDIR" config user.name test
        git -C "$PROJ_WORKDIR" commit -q --allow-empty -m "proj-seed"
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

# GT_BROOD_ID: the v4 top-level brood_id every projection manifest carries. It must match
# ^brood-[0-9a-f-]+$ (the exact shape the engine validates and emits as STRAIN field 2). All
# projection manifests share this single id; per-case branch uniqueness (below) keeps the
# ground-truth worktree map unambiguous.
GT_BROOD_ID="brood-1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

# write_manifest_v4: author a manifest_version 4 brood manifest at $1 for ONE strain.
# Args: $1=path $2=strain_name $3=worktree_path(display-only) $4=branch $5=tmux_session
#       $6=status $7=suggested_id.
# v4 SHAPE: top-level brood_id (^brood-[0-9a-f-]+$) + created_at; per-strain run block carries
# run.suggested_id (the read side DERIVES the ledger path from the git-discovered worktree +
# suggested_id) — run.suggested_ledger is DROPPED. worktree_path is RETAINED but display-only:
# the engine no longer anchors the ledger on it (ground-truth worktree discovery via git).
# Every untrusted value enters jq as a --arg binding (jq does the JSON-safe escaping).
write_manifest_v4() {
    local out="$1" name="$2" wt="$3" branch="$4" sess="$5" status="$6" sid="$7"
    jq -n \
        --arg brood_id "$GT_BROOD_ID" \
        --arg name "$name" \
        --arg wt "$wt" \
        --arg branch "$branch" \
        --arg sess "$sess" \
        --arg status "$status" \
        --arg sid "$sid" \
        '{
            manifest_version: 4,
            brood_id: $brood_id,
            created_at: "2026-05-30T22:10:00Z",
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
                        suggested_id: $sid,
                        workflow_hint: "standard-delivery"
                    }
                }
            ],
            merge_order: []
        }' > "$out"
}

# gt_add_worktree: register a REAL git worktree on branch $2 at path $3 in the PROJ_WORKDIR
# checkout, so `git worktree list --porcelain` (which the engine parses keyed by branch) reports
# it as ground truth. The engine derives the ledger path UNDER this real worktree, so the worktree
# must exist on disk and be checked out on exactly the strain's branch. Quiet; idempotent-ish (the
# caller picks unique branch names per case to avoid cross-case duplicate-branch ambiguity).
gt_add_worktree() {
    local branch="$2" wtpath="$3"
    git -C "$PROJ_WORKDIR" worktree add -q -b "$branch" "$wtpath" HEAD 2>/dev/null
}

# write_ledger: author a child run-ledger JSON at $1 with run.status=$2,
# state.current=$3 via jq -n (safe construction). Parent dirs must already exist.
write_ledger() {
    local out="$1" run_status="$2" state_current="$3"
    jq -n --arg rs "$run_status" --arg sc "$state_current" \
        '{run:{status:$rs}, state:{current:$sc}}' > "$out"
}

# strain_field: split the FIRST STRAIN line of $1 (entrypoint output) on TAB and echo the field at
# 1-based index $2. NEW v4/#168 grammar (brood_id inserted as field 2 — every index after shifts
# +1 vs the pre-#168 grammar): 1=STRAIN 2=brood_id 3=name 4=worktree_path 5=branch 6=tmux_session
# 7=manifest_status 8=state_current 9=run_status.
strain_field() {
    local output="$1" idx="$2"
    printf '%s\n' "$output" | awk -F'\t' -v i="$idx" '/^STRAIN\t/ { print $i; exit }'
}

# count_strain_lines: number of STRAIN lines in $1.
count_strain_lines() {
    printf '%s\n' "$1" | grep -c '^STRAIN	' || true
}

# ── GROUND-TRUTH WORKTREE DISCOVERY (#168, locked OQ3) ───────────────────────────
# Under #168 the engine NO LONGER anchors the child ledger on the manifest's untrusted
# worktree_path (now display-only). It discovers each strain's REAL worktree from
# `git worktree list --porcelain` keyed by the strain's branch, then derives the ledger as
# <git-worktree>/.hivemind/runs/<suggested_id>/state.json. So every projection case that wants a
# ledger projected MUST register a real worktree on the strain's branch (gt_add_worktree) and place
# the ledger under it. A manifest branch with NO live worktree fails CLOSED (ledger columns MISSING),
# never falling back to the manifest worktree_path. Each case uses a UNIQUE branch so the shared
# PROJ_WORKDIR worktree map stays unambiguous (a branch on two worktrees is a duplicate -> MALFORMED).

# ── Projection 1: happy path — v4 manifest + ground-truth worktree + valid ledger ─
# Registers a real worktree on the strain branch; the ledger lives under the GT worktree at
# .hivemind/runs/<suggested_id>/state.json. Asserts exit 0, one STRAIN line, brood_id field, and
# state_current=implement_step run_status=running projected from the GT-derived ledger.
assert_proj_happy_path() {
    local name="PROJ-HAPPY:v4-manifest-ground-truth-worktree-valid-ledger"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/happy"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/happy" sid="$GT_BROOD_ID--happy"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    write_ledger "$wt/.hivemind/runs/$sid/state.json" running implement_step
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 1 \
          && "$(strain_field "$out" 2)" == "$GT_BROOD_ID" \
          && "$(strain_field "$out" 3)" == "api" \
          && "$(strain_field "$out" 4)" == "$wt" \
          && "$(strain_field "$out" 5)" == "$branch" \
          && "$(strain_field "$out" 6)" == "brood-api" \
          && "$(strain_field "$out" 7)" == "running" \
          && "$(strain_field "$out" 8)" == "implement_step" \
          && "$(strain_field "$out" 9)" == "running" ]]; then
        pass "$name" "exit 0; one STRAIN line; brood_id first; state_current=implement_step run_status=running from GT worktree"
    else
        failed "$name" "rc=$rc lines=$lines fields=[$(strain_field "$out" 2)|$(strain_field "$out" 3)|$(strain_field "$out" 4)|$(strain_field "$out" 5)|$(strain_field "$out" 6)|$(strain_field "$out" 7)|$(strain_field "$out" 8)|$(strain_field "$out" 9)]"
    fi
}

# ── Projection 2: v4 manifest with NO run block → state.current NO_LEDGER_POINTER, run.status MISSING ──
# A strain with no run block has no suggested_id, so the engine cannot derive a ledger path even
# though a live worktree exists: state.current renders the distinct NO_LEDGER_POINTER token (no
# ledger pointer exists, so started-evidence is structurally unavailable and the downstream
# started-evidence gate does not apply), while run.status stays MISSING. Static manifest fields
# still project; exit 0. Proves the no-pointer gate is suggested_id absence, not worktree absence.
assert_proj_v1_no_run_block() {
    local name="PROJ-NORUN:no-run-block-state-nopointer-run-missing"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/norun"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/norun"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    local manifest="$wd/manifest.json"
    # No run block at all -> suggested_id absent -> state.current NO_LEDGER_POINTER (run.status
    # MISSING) despite the live worktree.
    jq -n --arg brood_id "$GT_BROOD_ID" --arg wt "$wt" --arg branch "$branch" \
        '{
            manifest_version: 4,
            brood_id: $brood_id,
            created_at: "2026-05-30T22:10:00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                { name: "api", description: "test strain", worktree_path: $wt,
                  branch: $branch, tmux_session: "brood-api", status: "running" }
            ],
            merge_order: []
        }' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 3)" == "api" \
          && "$(strain_field "$out" 4)" == "$wt" \
          && "$(strain_field "$out" 8)" == "NO_LEDGER_POINTER" \
          && "$(strain_field "$out" 9)" == "MISSING" ]]; then
        pass "$name" "exit 0; static fields project; state.current NO_LEDGER_POINTER, run.status MISSING (no run block -> no suggested_id)"
    else
        failed "$name" "rc=$rc name=$(strain_field "$out" 3) wt=$(strain_field "$out" 4) state=$(strain_field "$out" 8) run=$(strain_field "$out" 9)"
    fi
}

# ── Projection 3: GT worktree + suggested_id present but ledger file absent → MISSING ─
# A live worktree + a valid suggested_id, but the derived state.json does not exist on disk →
# both scalars MISSING (genuine absence; child has not initialized its ledger yet).
assert_proj_missing_ledger_file() {
    local name="PROJ-MISSING:gt-worktree-ledger-file-absent"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/missing"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/missing" sid="$GT_BROOD_ID--missing"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"   # dir exists, state.json does NOT
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MISSING" \
          && "$(strain_field "$out" 9)" == "MISSING" ]]; then
        pass "$name" "exit 0; absent ledger file under GT worktree -> state_current/run_status MISSING"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9)"
    fi
}

# ── Projection 3b: NO live worktree for the branch → fail-closed (MISSING) ────────
# The manifest branch matches NO worktree git reports — even though the manifest carries a perfectly
# valid worktree_path and suggested_id. The engine MUST fail closed: ledger columns MISSING, and it
# must NEVER fall back to reading under the manifest's worktree_path. We prove the no-fallback by
# planting a valid ledger UNDER the manifest worktree_path and asserting its sentinel never surfaces.
assert_proj_no_live_worktree() {
    local name="PROJ-NOWT:branch-without-live-worktree-fail-closed"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/nowt"
    local wt="$wd/wt"
    # wt is a PLAIN dir (NOT a registered git worktree) carrying a valid-looking ledger whose
    # sentinel would surface IF the engine fell back to the manifest worktree_path. It must not.
    mkdir -p "$wt/.hivemind/runs/$GT_BROOD_ID--ghost"
    write_ledger "$wt/.hivemind/runs/$GT_BROOD_ID--ghost/state.json" running ghostsentinel
    local manifest="$wd/manifest.json"
    # Branch that no `git worktree add` ever registered.
    write_manifest_v4 "$manifest" "api" "$wt" "strain/$GT_BROOD_ID/ghost" "brood-api" "running" \
        "$GT_BROOD_ID--ghost"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MISSING" \
          && "$(strain_field "$out" 9)" == "MISSING" ]] \
          && ! printf '%s' "$out" | grep -q 'ghostsentinel'; then
        pass "$name" "exit 0; no live worktree -> ledger MISSING; manifest-worktree_path NOT used as fallback (sentinel absent)"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9); leaked=$(printf '%s' "$out" | grep -q ghostsentinel && echo yes || echo no)"
    fi
}

# ── Projection 3c: branch on TWO worktrees (duplicate) → MALFORMED ───────────────
# A branch git reports on more than one worktree is ambiguous ground truth. The engine records it as
# a duplicate and renders the ledger columns MALFORMED for the matching strain (never an arbitrary
# pick). We force a duplicate by adding the same branch to a second worktree path with --force.
assert_proj_duplicate_branch() {
    local name="PROJ-DUPBRANCH:branch-on-two-worktrees-malformed"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/dup"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/dup" sid="$GT_BROOD_ID--dup"
    local wt_a="$wd/wt-a" wt_b="$wd/wt-b"
    gt_add_worktree "" "$branch" "$wt_a"
    # Force a SECOND worktree checked out on the SAME branch so `git worktree list` reports the
    # branch twice. --force bypasses git's "already checked out" guard for exactly this duplicate.
    git -C "$PROJ_WORKDIR" worktree add -q --force "$wt_b" "$branch" 2>/dev/null
    mkdir -p "$wt_a/.hivemind/runs/$sid"
    write_ledger "$wt_a/.hivemind/runs/$sid/state.json" running implement_step
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt_a" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    # Only assert MALFORMED if the duplicate actually registered (git may decline on some versions).
    local dupcount; dupcount="$(git -C "$PROJ_WORKDIR" worktree list --porcelain 2>/dev/null | grep -c "branch refs/heads/$branch")"
    if [[ "$dupcount" -lt 2 ]]; then
        skip "$name" "could not register a duplicate-branch worktree on this git ($dupcount checkout(s)); cannot exercise the dup guard"
        return
    fi
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && "$(strain_field "$out" 9)" == "MALFORMED" ]]; then
        pass "$name" "exit 0; duplicate branch on two worktrees -> ledger columns MALFORMED (no arbitrary pick)"
    else
        failed "$name" "rc=$rc dupcount=$dupcount state=$(strain_field "$out" 8) run=$(strain_field "$out" 9)"
    fi
}

# ── Projection 4: malformed run.status, valid state.current → per-scalar independence ─
assert_proj_malformed_run_status() {
    local name="PROJ-MALFORMED-RUN:bad-run-status-good-state-current"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/malrun"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/malrun" sid="$GT_BROOD_ID--malrun"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    write_ledger "$wt/.hivemind/runs/$sid/state.json" frobnicate implement_step
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 9)" == "MALFORMED" \
          && "$(strain_field "$out" 8)" == "implement_step" ]]; then
        pass "$name" "exit 0; run_status=MALFORMED while state_current=implement_step (per-scalar independence)"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9)"
    fi
}

# ── Projection 5: injection state.current → MALFORMED, no side-effect ─────────────
assert_proj_injection_state_current() {
    local name="PROJ-INJECT-STATE:state-current-command-sub-neutralized"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/injstate"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/injstate" sid="$GT_BROOD_ID--injstate"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    local marker="$wd/pwn_state_marker"
    write_ledger "$wt/.hivemind/runs/$sid/state.json" running "\$(touch $marker)"
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && ! -e "$marker" ]]; then
        pass "$name" "exit 0; state_current=MALFORMED; no command-sub side-effect ($marker absent)"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) marker_exists=$([ -e "$marker" ] && echo yes || echo no)"
    fi
}

# ── Projection 6: metachar worktree_path (display-only) → field MALFORMED, no read ─
# worktree_path is DISPLAY-ONLY now; a `$(...)` metachar value fails the path display gate -> the
# worktree_path COLUMN renders MALFORMED. No live worktree is registered for this branch, so the
# ledger fails closed to MISSING. ASSERT no command-execution side-effect from the metachar path.
assert_proj_metachar_worktree() {
    local name="PROJ-INJECT-WT:metachar-display-worktree-path-neutralized"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/metawt"
    mkdir -p "$wd"
    local marker="$wd/pwn_wt_marker"
    local manifest="$wd/manifest.json"
    # worktree_path carries a command-sub payload; branch matches no live worktree (fail-closed).
    write_manifest_v4 "$manifest" "api" "/tmp/\$(touch $marker)/wt" "strain/$GT_BROOD_ID/metawt" \
        "brood-api" "running" "$GT_BROOD_ID--metawt"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 4)" == "MALFORMED" \
          && "$(strain_field "$out" 8)" == "MISSING" \
          && "$(strain_field "$out" 9)" == "MISSING" \
          && ! -e "$marker" ]]; then
        pass "$name" "exit 0; display worktree_path MALFORMED; ledger MISSING (no live worktree); no command-sub side-effect"
    else
        failed "$name" "rc=$rc wt=$(strain_field "$out" 4) state=$(strain_field "$out" 8) run=$(strain_field "$out" 9) marker_exists=$([ -e "$marker" ] && echo yes || echo no)"
    fi
}

# ── Projection 7: symlinked state.json leaf under GT worktree → MALFORMED, target NOT read ─
assert_proj_symlink_leaf() {
    local name="PROJ-SYMLINK-LEAF:symlinked-state-json-rejected"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/symleaf"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/symleaf" sid="$GT_BROOD_ID--symleaf"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    local target="$wd/external_state.json"
    write_ledger "$target" running leakedsentinel
    ln -s "$target" "$wt/.hivemind/runs/$sid/state.json"
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && "$(strain_field "$out" 9)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'leakedsentinel'; then
        pass "$name" "exit 0; symlinked leaf rejected -> MALFORMED; symlink target content not leaked"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9); leaked=$(printf '%s' "$out" | grep -q leakedsentinel && echo yes || echo no)"
    fi
}

# ── Projection 7b: present-but-UNREADABLE confined ledger leaf → MALFORMED ────────
assert_proj_unreadable_ledger() {
    local name="PROJ-UNREADABLE-LEDGER:present-but-unreadable-leaf-malformed"
    if [[ "$(id -u)" -eq 0 ]]; then
        skip "$name" "running as root: mode 000 does not block reads"
        return 0
    fi
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/unreadledger"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/unread" sid="$GT_BROOD_ID--unread"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    local leaf="$wt/.hivemind/runs/$sid/state.json"
    write_ledger "$leaf" running implement_step
    chmod 000 "$leaf"
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    chmod 644 "$leaf" 2>/dev/null || true
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && "$(strain_field "$out" 9)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'implement_step'; then
        pass "$name" "exit 0; present-but-unreadable ledger -> MALFORMED (not MISSING); content not leaked"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9); leaked=$(printf '%s' "$out" | grep -q implement_step && echo yes || echo no)"
    fi
}

# ── Projection 8: suggested_id with '/' or '..' → MALFORMED, cannot escape runs/ ──
# Only <suggested_id> is manifest-sourced in the derived ledger path
# <git-worktree>/.hivemind/runs/<suggested_id>/state.json. It is gated as a STRICT single-component
# identifier: a value containing '/' or '..' would let the derived path escape the worktree's runs/
# dir, so it is rendered MALFORMED with NO path derivation/read. We plant a valid ledger at the
# escape TARGET and assert its sentinel never surfaces.
assert_proj_suggested_id_escape() {
    local name="PROJ-ESCAPE-SID:suggested-id-path-escape-rejected"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/sidesc"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/sidesc"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    # Plant a valid ledger at the path the escaping suggested_id `../escape` would resolve to,
    # to prove the escape is blocked (sentinel must not surface).
    mkdir -p "$wt/.hivemind/escape"
    write_ledger "$wt/.hivemind/escape/state.json" running escapesentinel
    local manifest="$wd/manifest.json"
    # suggested_id contains '/' and '..' -> strict-identifier single-component gate rejects it.
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "../escape"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && "$(strain_field "$out" 9)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'escapesentinel'; then
        pass "$name" "exit 0; suggested_id '../escape' -> MALFORMED; no escape read (sentinel absent)"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9); leaked=$(printf '%s' "$out" | grep -q escapesentinel && echo yes || echo no)"
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

# ── Projection OUTENC: display field with '|' is output-encoded (no raw pipe) ─────
# The engine output-encodes display cells: a worktree_path display value containing the Markdown
# table-cell delimiter '|' must NOT be emitted as a RAW '|' (it is escaped, or the cell is MALFORMED).
# We author a worktree_path carrying a literal '|' (path-class-clean inert quoted data) and a branch
# with no live worktree (so the strain still projects, ledger MISSING). Assert no raw '|' in the cell.
assert_proj_output_encoding() {
    local name="PROJ-OUTENC:display-cell-pipe-encoded"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/outenc"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "/tmp/a|b/wt" "strain/$GT_BROOD_ID/outenc" \
        "brood-api" "running" "$GT_BROOD_ID--outenc"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local wtcell; wtcell="$(strain_field "$out" 4)"
    local raw_pipe=no
    printf '%s' "$wtcell" | grep -qF '|' && raw_pipe=yes
    # An escaped pipe '\|' contains the byte '|' too, so distinguish: raw == a '|' NOT preceded by a
    # backslash. Strip escaped pipes first, then look for any surviving bare '|'.
    local stripped; stripped="$(printf '%s' "$wtcell" | sed 's/\\|//g')"
    local bare_pipe=no
    printf '%s' "$stripped" | grep -qF '|' && bare_pipe=yes
    if [[ "$rc" -eq 0 && "$(count_strain_lines "$out")" -eq 1 && "$bare_pipe" == "no" ]]; then
        pass "$name" "exit 0; worktree_path display cell has no raw unescaped '|' (output-encoded): [$wtcell]"
    else
        failed "$name" "rc=$rc bare_pipe=$bare_pipe worktree_path cell: [$wtcell]"
    fi
}

# ── Projection NOTMPDIR: read path needs no writable TMPDIR ──────────────────────
assert_proj_no_tmpdir_needed() {
    local name="PROJ-NOTMPDIR:read-path-needs-no-writable-tmpdir"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/notmpdir"
    mkdir -p "$wd"
    local br_a="strain/$GT_BROOD_ID/ntd-api" br_b="strain/$GT_BROOD_ID/ntd-web"
    local sid_a="$GT_BROOD_ID--ntd-api" sid_b="$GT_BROOD_ID--ntd-web"
    local wt_a="$wd/wt-api" wt_b="$wd/wt-web"
    gt_add_worktree "" "$br_a" "$wt_a"
    gt_add_worktree "" "$br_b" "$wt_b"
    mkdir -p "$wt_a/.hivemind/runs/$sid_a" "$wt_b/.hivemind/runs/$sid_b"
    write_ledger "$wt_a/.hivemind/runs/$sid_a/state.json" running implement_step
    write_ledger "$wt_b/.hivemind/runs/$sid_b/state.json" complete review_step
    local manifest="$wd/manifest.json"
    jq -n \
        --arg brood_id "$GT_BROOD_ID" \
        --arg wt_a "$wt_a" --arg wt_b "$wt_b" \
        --arg br_a "$br_a" --arg br_b "$br_b" \
        --arg sid_a "$sid_a" --arg sid_b "$sid_b" \
        '{
            manifest_version: 4,
            brood_id: $brood_id,
            created_at: "2026-06-01T22:00:00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                { name: "api", description: "api strain", worktree_path: $wt_a, branch: $br_a,
                  tmux_session: "brood-api", status: "running", pr: null, merged: false,
                  rebased_after: [], run: { suggested_id: $sid_a, workflow_hint: "standard-delivery" } },
                { name: "web", description: "web strain", worktree_path: $wt_b, branch: $br_b,
                  tmux_session: "brood-web", status: "complete", pr: null, merged: false,
                  rebased_after: [], run: { suggested_id: $sid_b, workflow_hint: "standard-delivery" } }
            ],
            merge_order: []
        }' > "$manifest"

    local bad_tmpdir="$wd/no_writable_tmpdir"
    mkdir -p "$bad_tmpdir"; chmod 000 "$bad_tmpdir"
    local out rc=0
    out="$(TMPDIR="$bad_tmpdir" run_project "$manifest")" || rc=$?
    chmod 0700 "$bad_tmpdir"
    local lines; lines="$(count_strain_lines "$out")"
    local api_name web_name
    api_name="$(printf '%s\n' "$out" | awk -F'\t' '$3=="api"{print $3; exit}')"
    web_name="$(printf '%s\n' "$out" | awk -F'\t' '$3=="web"{print $3; exit}')"
    if [[ "$rc" -eq 0 && "$lines" -eq 2 && "$api_name" == "api" && "$web_name" == "web" ]]; then
        pass "$name" "exit 0; 2 STRAIN lines (api, web) with non-writable TMPDIR — no writable-temp dependency"
    else
        failed "$name" "rc=$rc lines=$lines api_name=[$api_name] web_name=[$web_name]"
    fi
}

# ── Projection SNAPSHOT: single-read consistency — both scalars from ONE snapshot ─
assert_proj_single_snapshot_consistency() {
    local name="PROJ-SNAPSHOT:single-read-both-scalars-consistent"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/snapshot"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/snap" sid="$GT_BROOD_ID--snap"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    write_ledger "$wt/.hivemind/runs/$sid/state.json" blocked review_step
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 1 \
          && "$(strain_field "$out" 8)" == "review_step" \
          && "$(strain_field "$out" 9)" == "blocked" ]]; then
        pass "$name" "exit 0; one STRAIN line; both scalars from single snapshot (state=review_step run=blocked)"
    else
        failed "$name" "rc=$rc lines=$lines state=$(strain_field "$out" 8) run=$(strain_field "$out" 9)"
    fi
}

# ── Projection 10: multi-strain — one healthy + one malformed state, independent ──
assert_proj_multi_strain() {
    local name="PROJ-MULTI:two-strains-independent-projection"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/multi"
    mkdir -p "$wd"
    local br_a="strain/$GT_BROOD_ID/multi-api" br_b="strain/$GT_BROOD_ID/multi-web"
    local sid_a="$GT_BROOD_ID--multi-api" sid_b="$GT_BROOD_ID--multi-web"
    local wt_a="$wd/wt-api" wt_b="$wd/wt-web"
    gt_add_worktree "" "$br_a" "$wt_a"
    gt_add_worktree "" "$br_b" "$wt_b"
    mkdir -p "$wt_a/.hivemind/runs/$sid_a" "$wt_b/.hivemind/runs/$sid_b"
    write_ledger "$wt_a/.hivemind/runs/$sid_a/state.json" running implement_step
    write_ledger "$wt_b/.hivemind/runs/$sid_b/state.json" running "State With Spaces"
    local manifest="$wd/manifest.json"
    jq -n \
        --arg brood_id "$GT_BROOD_ID" \
        --arg wt_a "$wt_a" --arg wt_b "$wt_b" \
        --arg br_a "$br_a" --arg br_b "$br_b" \
        --arg sid_a "$sid_a" --arg sid_b "$sid_b" \
        '{
            manifest_version: 4,
            brood_id: $brood_id,
            created_at: "2026-05-30T22:10:00Z",
            base: "main",
            overlap_risk: "low",
            strains: [
                { name: "api", description: "strain a", worktree_path: $wt_a, branch: $br_a,
                  tmux_session: "brood-api", status: "running",
                  run: { suggested_id: $sid_a, workflow_hint: "standard-delivery" } },
                { name: "web", description: "strain b", worktree_path: $wt_b, branch: $br_b,
                  tmux_session: "brood-web", status: "running",
                  run: { suggested_id: $sid_b, workflow_hint: "standard-delivery" } }
            ],
            merge_order: []
        }' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    local api_state web_state
    api_state="$(printf '%s\n' "$out" | awk -F'\t' '$3=="api"{print $8; exit}')"
    web_state="$(printf '%s\n' "$out" | awk -F'\t' '$3=="web"{print $8; exit}')"
    if [[ "$rc" -eq 0 && "$lines" -eq 2 \
          && "$api_state" == "implement_step" && "$web_state" == "MALFORMED" ]]; then
        pass "$name" "exit 0; 2 STRAIN lines; api state=implement_step, web state=MALFORMED (independent)"
    else
        failed "$name" "rc=$rc lines=$lines api_state=$api_state web_state=$web_state"
    fi
}

# ── Projection 11: PRESENT but UNPARSEABLE manifest → MANIFEST_UNREADABLE + exit 2 ─
assert_proj_unreadable_manifest() {
    local name="PROJ-UNREADABLE:present-but-invalid-json-sentinel"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/unreadable"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    printf '{"manifest_version":4,"strains":[{"name":"api",\n' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_path
    sentinel_path="$(printf '%s\n' "$out" | awk -F'\t' '/^MANIFEST_UNREADABLE\t/ { print $2; exit }')"
    if [[ "$rc" -eq 2 && "$strain_lines" -eq 0 && "$sentinel_path" == "$manifest" ]]; then
        pass "$name" "exit 2; MANIFEST_UNREADABLE sentinel emitted (path=$sentinel_path); no STRAIN lines"
    else
        failed "$name" "rc=$rc strain_lines=$strain_lines sentinel_path=[$sentinel_path]"
    fi
}

# ── Projection 12: VALID empty manifest → exit 0, no STRAIN lines, NO sentinel ───
assert_proj_valid_empty_manifest() {
    local name="PROJ-EMPTY-OK:valid-empty-manifest-exit0-no-sentinel"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/emptyok"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    jq -n --arg brood_id "$GT_BROOD_ID" '{manifest_version:4, brood_id:$brood_id, created_at:"2026-05-30T22:10:00Z", base:"main", overlap_risk:"low", strains:[], merge_order:[]}' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_seen=no
    printf '%s\n' "$out" | grep -q '^MANIFEST_UNREADABLE	' && sentinel_seen=yes
    if [[ "$rc" -eq 0 && "$strain_lines" -eq 0 && "$sentinel_seen" == "no" ]]; then
        pass "$name" "exit 0; valid empty manifest -> no STRAIN lines, no MANIFEST_UNREADABLE sentinel"
    else
        failed "$name" "rc=$rc strain_lines=$strain_lines sentinel_seen=$sentinel_seen"
    fi
}

# ── Projection 13: VALID-JSON-but-WRONG-SHAPE manifest → MANIFEST_UNREADABLE + exit 2 ─
assert_proj_wrong_shape_unreadable() {
    local name="PROJ-WRONGSHAPE:valid-json-wrong-shape-unreadable"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/wrongshape"
    mkdir -p "$wd"
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
            detail+=" [$body -> rc=$rc lines=$strain_lines sentinel=$sentinel_path]"
        fi
        i=$((i + 1))
    done
    if [[ "$all_ok" == "yes" ]]; then
        pass "$name" "all 4 wrong-shape manifests -> exit 2 + MANIFEST_UNREADABLE + 0 STRAIN lines"
    else
        failed "$name" "expected exit 2 + sentinel + 0 strains for each;$detail"
    fi
}

# ── Projection 14: object element missing `name` → projects (per-strain MALFORMED) ─
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
    # name is now field 3 (brood_id field 2). brood_id is absent in this minimal manifest -> field 2
    # renders MALFORMED; name (field 3) also MALFORMED (presentation rejects the empty name).
    if [[ "$rc" -eq 0 && "$strain_lines" -eq 1 && "$sentinel_seen" == "no" \
          && "$(strain_field "$out" 3)" == "MALFORMED" ]]; then
        pass "$name" "exit 0; one STRAIN line; name=MALFORMED; no sentinel (per-strain degradation)"
    else
        failed "$name" "rc=$rc lines=$strain_lines sentinel_seen=$sentinel_seen name=$(strain_field "$out" 3)"
    fi
}

# ── Projection BROODID: top-level brood_id validated against ^brood-[0-9a-f-]+$ ──
# brood_id is STRAIN field 2 (first data field, #168 grammar). A valid brood-<uuid> id surfaces
# verbatim; a tampered id (wrong prefix / out-of-charset body) renders the fixed token MALFORMED.
assert_proj_brood_id_field() {
    local name="PROJ-BROODID:top-level-brood-id-validated"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/broodid"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/bid"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    local m_ok="$wd/manifest-ok.json"
    write_manifest_v4 "$m_ok" "api" "$wt" "$branch" "brood-api" "running" "$GT_BROOD_ID--bid"
    local out rc=0
    out="$(run_project "$m_ok")" || rc=$?
    local ok_field; ok_field="$(strain_field "$out" 2)"
    # Tampered brood_id: not ^brood-[0-9a-f-]+$ (uppercase + colon in body) -> MALFORMED.
    local m_bad="$wd/manifest-bad.json"
    jq -n --arg wt "$wt" --arg branch "$branch" \
        '{ manifest_version:4, brood_id:"brood-NOT_HEX:body", created_at:"2026-05-30T22:10:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api",description:"d",worktree_path:$wt,branch:$branch,
                     tmux_session:"brood-api",status:"running",
                     run:{suggested_id:"x",workflow_hint:"standard-delivery"}}],
           merge_order:[] }' > "$m_bad"
    local out2 rc2=0
    out2="$(run_project "$m_bad")" || rc2=$?
    local bad_field; bad_field="$(strain_field "$out2" 2)"
    if [[ "$rc" -eq 0 && "$ok_field" == "$GT_BROOD_ID" \
          && "$rc2" -eq 0 && "$bad_field" == "MALFORMED" ]]; then
        pass "$name" "valid brood_id surfaces verbatim ($ok_field); tampered brood_id -> MALFORMED"
    else
        failed "$name" "rc=$rc ok_field=$ok_field rc2=$rc2 bad_field=$bad_field"
    fi
}

# ── Projection NUL-MANIFEST: literal-NUL manifest → MANIFEST_UNREADABLE + exit 2 ──
assert_proj_literal_nul_manifest() {
    local name="PROJ-NUL-MANIFEST:literal-nul-manifest-unreadable"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/nulmanifest"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    printf '{"strains":\000[]}' > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_path
    sentinel_path="$(printf '%s\n' "$out" | awk -F'\t' '/^MANIFEST_UNREADABLE\t/ { print $2; exit }')"
    if [[ "$rc" -eq 2 && "$strain_lines" -eq 0 && "$sentinel_path" == "$manifest" ]]; then
        pass "$name" "exit 2; literal-NUL manifest -> MANIFEST_UNREADABLE (path=$sentinel_path)"
    else
        failed "$name" "rc=$rc strain_lines=$strain_lines sentinel_path=[$sentinel_path]"
    fi
}

# ── Projection NUL-SCALAR: JSON u0000 ESCAPE in branch → branch field MALFORMED ──
assert_proj_nul_escape_branch() {
    local name="PROJ-NUL-SCALAR:json-nul-escape-branch-malformed"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/nulscalar"
    mkdir -p "$wd"
    local wt="$wd/wt"; mkdir -p "$wt"
    local manifest="$wd/manifest.json"
    python3 - "$manifest" "$wt" "$GT_BROOD_ID" <<'PY'
import sys
manifest, wt, bid = sys.argv[1], sys.argv[2], sys.argv[3]
obj = ('{"manifest_version":4,"brood_id":"%s","created_at":"2026-06-01T00:00:00Z","base":"main",'
       '"overlap_risk":"low","strains":[{"name":"api","description":"d","worktree_path":"%s",'
       '"branch":"feature/api\\u0000slice","tmux_session":"brood-api","status":"running"}],'
       '"merge_order":[]}') % (bid, wt)
open(manifest, "w").write(obj)
PY

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    # branch is now field 5. It MUST be MALFORMED, and the stripped `feature/apislice` must not appear.
    if [[ "$rc" -eq 0 && "$lines" -eq 1 && "$(strain_field "$out" 5)" == "MALFORMED" ]] \
       && ! printf '%s' "$out" | grep -q 'feature/apislice'; then
        pass "$name" "exit 0; one STRAIN line; branch=MALFORMED; control-stripped branch NOT emitted"
    else
        failed "$name" "rc=$rc lines=$lines branch=$(strain_field "$out" 5)"
    fi
}

# ── Projection MULTIDOC: two concatenated valid manifest objects → MANIFEST_UNREADABLE ─
assert_proj_multidoc_manifest() {
    local name="PROJ-MULTIDOC:two-documents-unreadable"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/multidoc"
    mkdir -p "$wd"
    local manifest="$wd/manifest.json"
    printf '%s\n%s\n' \
        '{"manifest_version":4,"strains":[{"name":"api","worktree_path":"/repo/wt","branch":"b","tmux_session":"t","status":"running"}]}' \
        '{"manifest_version":4,"strains":[{"name":"web","worktree_path":"/repo/wt2","branch":"b2","tmux_session":"t2","status":"running"}]}' \
        > "$manifest"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    local strain_lines; strain_lines="$(count_strain_lines "$out")"
    local sentinel_path
    sentinel_path="$(printf '%s\n' "$out" | awk -F'\t' '/^MANIFEST_UNREADABLE\t/ { print $2; exit }')"
    if [[ "$rc" -eq 2 && "$strain_lines" -eq 0 && "$sentinel_path" == "$manifest" ]]; then
        pass "$name" "exit 2; multi-document manifest -> MANIFEST_UNREADABLE (path=$sentinel_path)"
    else
        failed "$name" "rc=$rc strain_lines=$strain_lines sentinel_path=[$sentinel_path]"
    fi
}

# ── Projection NUL-LEDGER: literal-NUL child ledger under GT worktree → MALFORMED ─
assert_proj_literal_nul_ledger() {
    local name="PROJ-NUL-LEDGER:literal-nul-ledger-malformed"
    ensure_proj_workdir; local wd="$PROJ_WORKDIR/nulledger"
    mkdir -p "$wd"
    local branch="strain/$GT_BROOD_ID/nulledger" sid="$GT_BROOD_ID--nulledger"
    local wt="$wd/wt"
    gt_add_worktree "" "$branch" "$wt"
    mkdir -p "$wt/.hivemind/runs/$sid"
    local leaf="$wt/.hivemind/runs/$sid/state.json"
    printf '{"run":{"status":"running"},"state":{"current":"plan"}}\000' > "$leaf"
    local manifest="$wd/manifest.json"
    write_manifest_v4 "$manifest" "api" "$wt" "$branch" "brood-api" "running" "$sid"

    local out rc=0
    out="$(run_project "$manifest")" || rc=$?
    if [[ "$rc" -eq 0 \
          && "$(strain_field "$out" 8)" == "MALFORMED" \
          && "$(strain_field "$out" 9)" == "MALFORMED" ]] \
          && ! printf '%s' "$out" | grep -q 'plan'; then
        pass "$name" "exit 0; literal-NUL ledger -> both scalars MALFORMED; content not leaked"
    else
        failed "$name" "rc=$rc state=$(strain_field "$out" 8) run=$(strain_field "$out" 9)"
    fi
}

# ── Projection NESTED-WORKTREE-ANCHOR (#182): current-worktree discovery anchoring ─
# PROVES nested-brood visibility through the READ path. Under #182 the navigator anchors
# discovery on `git rev-parse --show-toplevel` (the CURRENT checkout) instead of the main
# checkout root, and brood-status-project.sh's $2 already DEFAULTS to that same anchor when
# the navigator omits it. So a child orchestrator that spawned a sub-brood under its OWN
# linked worktree is discovered when brood-status runs from inside that worktree.
#
# This case registers a REAL git linked worktree off the PROJ_WORKDIR checkout, authors a
# valid v4 manifest under <worktree>/.hivemind/broods/<brood-id>/manifest.json, then runs
# the entrypoint from WITHIN that linked worktree WITHOUT supplying $2 (so the default
# `git rev-parse --show-toplevel` resolves to the LINKED worktree root, not the main checkout).
# Asserts exit 0 (manifest PRESENT and accepted) and that the projection confines to the
# linked worktree (the strain's GT worktree + ledger live under it and project cleanly).
# PURE git + jq — no claude/tmux/gh dependency, so it runs UNCONDITIONALLY in CI.
assert_proj_nested_worktree_anchor() {
    local name="PROJ-NESTED-ANCHOR:current-worktree-discovers-nested-brood"
    ensure_proj_workdir
    # A REAL git linked worktree off the PROJ_WORKDIR checkout — this stands in for a child
    # orchestrator's own worktree (a nested hatchery). Its `git rev-parse --show-toplevel`
    # resolves to the linked worktree root, NOT the main PROJ_WORKDIR checkout.
    local child_wt="$PROJ_WORKDIR/nested-child-wt"
    git -C "$PROJ_WORKDIR" worktree add -q -b nested-child-hatchery "$child_wt" HEAD 2>/dev/null
    # The sub-brood the child spawned: manifest lives under the CHILD worktree's .hivemind/broods/,
    # exactly where spawn-brood.sh (anchored on show-toplevel) would write it.
    local brood_dir="$child_wt/.hivemind/broods/$GT_BROOD_ID"
    mkdir -p "$brood_dir"
    local branch="strain/$GT_BROOD_ID/nested" sid="$GT_BROOD_ID--nested"
    # The strain's REAL worktree, registered as ground truth so the engine derives + reads its
    # ledger; placed UNDER the child worktree so the whole projection confines beneath show-toplevel.
    local strain_wt="$child_wt/strain-wt"
    git -C "$PROJ_WORKDIR" worktree add -q -b "$branch" "$strain_wt" HEAD 2>/dev/null
    mkdir -p "$strain_wt/.hivemind/runs/$sid"
    write_ledger "$strain_wt/.hivemind/runs/$sid/state.json" running implement_step
    local manifest="$brood_dir/manifest.json"
    write_manifest_v4 "$manifest" "api" "$strain_wt" "$branch" "brood-api" "running" "$sid"

    # Run the entrypoint with cwd INSIDE the linked worktree and NO $2 override — so the helper's
    # default `git rev-parse --show-toplevel` resolves to $child_wt and the read-guard confines the
    # manifest beneath the CHILD worktree (current-worktree anchoring). If the helper still anchored
    # on the main checkout, the manifest under the linked worktree would resolve outside that root
    # and be rejected.
    local out rc=0
    out="$( cd "$child_wt" && bash "$PROJECT_SCRIPT" "$manifest" 2>/dev/null )" || rc=$?
    local lines; lines="$(count_strain_lines "$out")"
    if [[ "$rc" -eq 0 \
          && "$lines" -eq 1 \
          && "$(strain_field "$out" 2)" == "$GT_BROOD_ID" \
          && "$(strain_field "$out" 5)" == "$branch" \
          && "$(strain_field "$out" 8)" == "implement_step" \
          && "$(strain_field "$out" 9)" == "running" ]]; then
        pass "$name" "exit 0; nested-brood manifest under linked worktree accepted via default show-toplevel anchor; projection confined to worktree"
    else
        failed "$name" "rc=$rc lines=$lines fields=[$(strain_field "$out" 2)|$(strain_field "$out" 5)|$(strain_field "$out" 8)|$(strain_field "$out" 9)]"
    fi
}


# ════════════════════════════════════════════════════════════════════════════════
# brood-discover.sh (deterministic discovery/enumeration, #185, ADR-0020)
# ════════════════════════════════════════════════════════════════════════════════
# These cases drive the committed discovery entrypoint
#   bash "$DISCOVER_SCRIPT" [checkout_root]
# and assert the CONTRACT: it emits absolute manifest paths, one per line, lexicographically
# sorted; zero matches → zero lines, exit 0. They are PURE git + bash (no claude/tmux/gh dep),
# so they run UNCONDITIONALLY and pass in CI. Each builds its own throwaway git repo via mktemp
# and reaps it in a local trap, independent of WORKDIR/PROJ_WORKDIR so the discover suite is
# self-contained. The manifest BODY is irrelevant (discover never parses contents) — a non-empty
# stub file at the path suffices.

# discover_mkrepo: create a throwaway git checkout under a fresh mktemp dir, echo its root.
# Caller is responsible for reaping the returned dir's PARENT (captured separately).
discover_seed_repo() {
    local root="$1"
    git -C "$root" init -q
    git -C "$root" config user.email test@example.com
    git -C "$root" config user.name test
    git -C "$root" commit -q --allow-empty -m "discover-seed"
}

# discover_stub_manifest: write a minimal non-empty manifest stub at $1 (creating parents).
# discover never parses contents, so a stub suffices.
discover_stub_manifest() {
    mkdir -p "$(dirname "$1")"
    printf '{}\n' > "$1"
}

# ── DISCOVER-EMPTY: no .hivemind/broods → zero lines, exit 0 ─────────────────────
assert_discover_empty() {
    local name="DISCOVER-EMPTY:no-broods-zero-lines-exit-0"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-discover.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    discover_seed_repo "$root"
    local out rc=0
    out="$( cd "$root" && bash "$DISCOVER_SCRIPT" 2>/dev/null )" || rc=$?
    local lines=0; [ -n "$out" ] && lines="$(printf '%s\n' "$out" | grep -c .)"
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$lines" -eq 0 ]]; then
        pass "$name" "empty checkout → zero lines, exit 0 (navigator renders 'No broods found.')"
    else
        failed "$name" "expected exit 0 + zero lines; rc=$rc lines=$lines out=[$out]"
    fi
}

# ── DISCOVER-SORT: brood-c/brood-a/brood-b created → emitted a,b,c absolute ──────
assert_discover_sort_order() {
    local name="DISCOVER-SORT:multi-brood-lexicographic-absolute-paths"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-discover.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    discover_seed_repo "$root"
    # Create out of lexicographic order to prove the script (not creation order) sorts. The ids are
    # conforming hex-uuid-shaped brood-ids (^brood-[0-9a-fA-F-]+$) so the #185 brood-id-segment
    # allowlist admits them — exercising sort order with REAL-shaped ids, not synthetic short names.
    local id_a="brood-1111aaaa-1111-4aaa-8aaa-111111111111"
    local id_b="brood-2222bbbb-2222-4bbb-8bbb-222222222222"
    local id_c="brood-3333cccc-3333-4ccc-8ccc-333333333333"
    discover_stub_manifest "$root/.hivemind/broods/$id_c/manifest.json"
    discover_stub_manifest "$root/.hivemind/broods/$id_a/manifest.json"
    discover_stub_manifest "$root/.hivemind/broods/$id_b/manifest.json"
    local out rc=0
    out="$( cd "$root" && bash "$DISCOVER_SCRIPT" 2>/dev/null )" || rc=$?
    local expected
    expected="$(printf '%s\n%s\n%s\n' \
        "$root/.hivemind/broods/$id_a/manifest.json" \
        "$root/.hivemind/broods/$id_b/manifest.json" \
        "$root/.hivemind/broods/$id_c/manifest.json")"
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$out" == "$expected" ]]; then
        pass "$name" "three hex-uuid-shaped broods emitted as absolute paths in lexicographic order"
    else
        failed "$name" "rc=$rc; expected:[$expected] got:[$out]"
    fi
}

# ── DISCOVER-NESTED: linked worktree, NO \$1 arg → discovers nested brood via ──────
#    the script's default `git rev-parse --show-toplevel` anchor (proves #182 is now
#    script-pinned: running from inside a child worktree finds that worktree's broods).
assert_discover_nested_worktree() {
    local name="DISCOVER-NESTED:linked-worktree-default-anchor-discovers-nested-brood"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-discover.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    discover_seed_repo "$root"
    # A REAL linked worktree off the main checkout — stands in for a child orchestrator's own
    # worktree (a nested hatchery). Its show-toplevel resolves to the linked worktree root.
    local child_wt="$tmp/nested-child-wt"
    git -C "$root" worktree add -q -b nested-child-hatchery "$child_wt" HEAD 2>/dev/null
    # The sub-brood the child spawned lives under the CHILD worktree's .hivemind/broods/. Its id is
    # hex-uuid-shaped (^brood-[0-9a-fA-F-]+$) so the #185 brood-id-segment allowlist admits it.
    local nested_manifest="$child_wt/.hivemind/broods/brood-4444dddd-4444-4ddd-8ddd-444444444444/manifest.json"
    discover_stub_manifest "$nested_manifest"
    # Run from INSIDE the linked worktree with NO \$1 override, exercising the show-toplevel default.
    local out rc=0
    out="$( cd "$child_wt" && bash "$DISCOVER_SCRIPT" 2>/dev/null )" || rc=$?
    local lines=0; [ -n "$out" ] && lines="$(printf '%s\n' "$out" | grep -c .)"
    git -C "$root" worktree remove --force "$child_wt" 2>/dev/null || true
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$lines" -eq 1 && "$out" == "$nested_manifest" ]]; then
        pass "$name" "nested brood under linked worktree discovered via default show-toplevel anchor (#182 script-pinned)"
    else
        failed "$name" "rc=$rc lines=$lines; expected:[$nested_manifest] got:[$out]"
    fi
}

# ── DISCOVER-NOMANIFEST: brood dir without manifest.json is skipped ──────────────
#    (the glob matches `brood-*/manifest.json`; a manifest-less brood dir yields no match —
#    correct, not an error). Only the valid brood's manifest path is emitted.
assert_discover_dir_without_manifest_skipped() {
    local name="DISCOVER-NOMANIFEST:brood-dir-without-manifest-skipped"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-discover.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    discover_seed_repo "$root"
    # One valid brood (has manifest.json, hex-uuid-shaped id so the #185 allowlist admits it) and one
    # brood dir with NO manifest.json inside (skipped by the glob — no match — regardless of name).
    local valid_id="brood-5555eeee-5555-4eee-8eee-555555555555"
    discover_stub_manifest "$root/.hivemind/broods/$valid_id/manifest.json"
    mkdir -p "$root/.hivemind/broods/brood-6666ffff-6666-4fff-8fff-666666666666"
    local out rc=0
    out="$( cd "$root" && bash "$DISCOVER_SCRIPT" 2>/dev/null )" || rc=$?
    local expected="$root/.hivemind/broods/$valid_id/manifest.json"
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$out" == "$expected" ]]; then
        pass "$name" "manifest-less brood dir skipped by glob; only the valid brood's manifest emitted"
    else
        failed "$name" "rc=$rc; expected only:[$expected] got:[$out]"
    fi
}

# ── DISCOVER-HOSTILE-NAME: brood-id segment with shell metacharacters is skipped ──
#    (issue #185, ADR-0019 floor-at-input). brood-discover positively validates the brood-id
#    directory segment against `^brood-[0-9a-fA-F-]+$`. A directory literally named
#    `brood-$(touch evilmarker)` carries a command-substitution payload in its variable segment; if
#    its manifest path were emitted verbatim and the navigator spliced it into the LLM-authored
#    `bash brood-status-project.sh "<path>" …` command, `$(touch evilmarker)` would EXECUTE in the
#    coordinator session (double-quoting does not neutralize command-substitution in command SOURCE).
#    This case creates such a hostile dir WITHOUT shell expansion (single-quoted literal mkdir), plus
#    backtick and `;`-bearing variants, alongside one valid hex-uuid-shaped brood. It asserts:
#      (a) ONLY the valid brood's manifest path is emitted (hostile dirs absent from output);
#      (b) the `evilmarker` file was NOT created — proving nothing in any segment ever executed.
assert_discover_hostile_name_skipped() {
    local name="DISCOVER-HOSTILE-NAME:metachar-brood-id-segment-skipped-no-exec"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-discover.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    discover_seed_repo "$root"
    # One legitimate brood (hex-uuid-shaped id — admitted by the allowlist).
    local valid_id="brood-7777aaaa-7777-4aaa-8aaa-777777777777"
    discover_stub_manifest "$root/.hivemind/broods/$valid_id/manifest.json"
    # Hostile dirs created as LITERAL names (single-quoted — no shell expansion at creation time).
    # Each carries a manifest.json so the glob WOULD match it; the allowlist must drop it.
    local broods="$root/.hivemind/broods"
    mkdir -p "$broods/brood-\$(touch evilmarker)"
    discover_stub_manifest "$broods/brood-\$(touch evilmarker)/manifest.json"
    mkdir -p "$broods/brood-\`touch evilmarker\`"
    discover_stub_manifest "$broods/brood-\`touch evilmarker\`/manifest.json"
    mkdir -p "$broods/brood-x;touch evilmarker"
    discover_stub_manifest "$broods/brood-x;touch evilmarker/manifest.json"
    local out rc=0
    out="$( cd "$root" && bash "$DISCOVER_SCRIPT" 2>/dev/null )" || rc=$?
    local expected="$root/.hivemind/broods/$valid_id/manifest.json"
    # No-side-effect proof: the evilmarker file must NOT exist anywhere — neither the cwd nor the
    # broods dir — because nothing in any hostile segment was ever expanded/executed.
    local marker_created=no
    if [ -e "$root/evilmarker" ] || [ -e "$broods/evilmarker" ] || [ -e "$tmp/evilmarker" ] || [ -e ./evilmarker ]; then
        marker_created=yes
    fi
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$out" == "$expected" && "$marker_created" == "no" ]]; then
        pass "$name" "hostile metachar brood-id segments dropped by allowlist; only valid brood emitted; no payload executed"
    else
        failed "$name" "rc=$rc marker_created=$marker_created; expected only:[$expected] got:[$out]"
    fi
}


# ════════════════════════════════════════════════════════════════════════════════
# brood-status-collect.sh (collection loop + status derivation entrypoint, #186, ADR-0020)
# ════════════════════════════════════════════════════════════════════════════════
# The thin entrypoint owns discovery + per-strain observable probing + projection + status
# derivation + aggregation, emitting ONE JSON document (schema brood-status-collect/1). It is the
# IMPURE layer: jq + git are hard deps; tmux/gh degrade per-probe (a host without them yields
# dead sessions and none/unknown PRs). The PURE derivation rule table is covered exhaustively in
# tools/test_shared_libs.sh (brood-status-derive.sh); these cases prove the entrypoint produces a
# WELL-FORMED document and wires discovery->projection->aggregation correctly.
#
# CI-SAFE (#169 real-deps-or-skip): the meaningful assertions below need only git + jq — they use
# git-only observables (no live tmux session -> dead; a branch with no PR -> none/unknown), so they
# run UNCONDITIONALLY and pass in CI. No tmux/gh MOCKS are built (out of scope per #169). If git or
# jq is somehow absent, the cases SKIP cleanly. Each builds a throwaway git checkout via mktemp and
# reaps it locally, independent of WORKDIR/PROJ_WORKDIR.

COLLECT_BROOD_ID="brood-8a8a8a8a-8b8b-4c8c-8d8d-8e8e8e8e8e8e"

# collect_seed_repo: a throwaway git checkout root (real toplevel for the entrypoint's
# git rev-parse --show-toplevel anchor).
collect_seed_repo() {
    local root="$1"
    git -C "$root" init -q
    git -C "$root" config user.email test@example.com
    git -C "$root" config user.name test
    git -C "$root" commit -q --allow-empty -m "collect-seed"
}

# ── COLLECT-EMPTY: no broods → well-formed doc with empty broods + zeroed global ──
assert_collect_empty() {
    local name="COLLECT-EMPTY:no-broods-wellformed-empty-doc"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    # Well-formed JSON, schema correct, broods empty, global zeroed.
    local ok=no
    if printf '%s' "$out" | jq -e \
        '.schema=="brood-status-collect/1" and (.broods|length)==0
         and .global.total_broods==0 and .global.unreadable==0
         and .global.complete==0 and .global.total_strains==0' >/dev/null 2>&1; then
        ok=yes
    fi
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; well-formed empty doc (broods:[], global all 0)"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

# ── COLLECT-OK: one brood, one strain, git-only observables (dead session) ───────
# A real brood manifest under .hivemind/broods/<id>/manifest.json with one strain whose branch has
# a registered git worktree (so the projector derives a ledger) carrying a valid ledger. No tmux
# session is created (session -> dead) and the branch has no PR (none, or unknown if gh fails).
# Asserts: well-formed doc, one brood status=ok, one strain, session=dead, workflow_state/run_status
# projected from the ledger, derived_status present, and per-brood + global aggregates coherent.
assert_collect_ok_one_strain() {
    local name="COLLECT-OK:one-brood-one-strain-git-only-observables"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local brood_dir="$root/.hivemind/broods/$COLLECT_BROOD_ID"
    mkdir -p "$brood_dir"
    local branch="strain/$COLLECT_BROOD_ID/api" sid="$COLLECT_BROOD_ID--api"
    # A real git worktree on the strain branch so the projector resolves it as ground truth.
    local wt="$root/wt-api"
    git -C "$root" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null
    mkdir -p "$wt/.hivemind/runs/$sid"
    jq -n '{run:{status:"running"}, state:{current:"implement_step"}}' > "$wt/.hivemind/runs/$sid/state.json"
    # A no-tmux session name (dead) and a branch with no PR (none/unknown).
    jq -n \
        --arg brood_id "$COLLECT_BROOD_ID" --arg wt "$wt" --arg branch "$branch" --arg sid "$sid" \
        '{ manifest_version:4, brood_id:$brood_id, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api", description:"d", worktree_path:$wt, branch:$branch,
                     tmux_session:"\($brood_id)-api", status:"running",
                     run:{suggested_id:$sid, workflow_hint:"standard-delivery"}}],
           merge_order:[] }' > "$brood_dir/manifest.json"

    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    # Structural assertions only (PR/derived_status depend on tmux/gh presence): schema, one ok
    # brood with the right id, one strain with session=dead, projected ledger scalars, a non-empty
    # derived_status, and coherent aggregates (total_broods=1, total_strains=1).
    local ok=no
    if printf '%s' "$out" | jq -e \
        --arg id "$COLLECT_BROOD_ID" \
        '.schema=="brood-status-collect/1"
         and (.broods|length)==1
         and .broods[0].brood_id==$id
         and .broods[0].status=="ok"
         and (.broods[0].strains|length)==1
         and .broods[0].strains[0].name=="api"
         and .broods[0].strains[0].session=="dead"
         and .broods[0].strains[0].tmux_session=="\($id)-api"
         and .broods[0].strains[0].workflow_state=="implement_step"
         and .broods[0].strains[0].run_status=="running"
         and (.broods[0].strains[0].derived_status|length)>0
         and .broods[0].summary.total==1
         and .global.total_broods==1
         and .global.total_strains==1
         and .global.unreadable==0' >/dev/null 2>&1; then
        ok=yes
    fi
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; one ok brood, one strain (session=dead), ledger projected, aggregates coherent"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

# ── COLLECT-UNREADABLE: torn manifest → brood status=unreadable, isolated, counted ─
# A torn (invalid-JSON) manifest must become an `unreadable` brood entry with detail=path, NOT abort
# the run. Pair it with a valid empty brood to prove per-brood failure isolation + global counting.
assert_collect_unreadable_isolated() {
    local name="COLLECT-UNREADABLE:torn-manifest-isolated-unreadable-brood"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    # Two broods (sorted by id). First: a VALID empty manifest. Second: a TORN manifest.
    local id_a="brood-1111aaaa-1111-4aaa-8aaa-111111111111"
    local id_b="brood-2222bbbb-2222-4bbb-8bbb-222222222222"
    mkdir -p "$root/.hivemind/broods/$id_a" "$root/.hivemind/broods/$id_b"
    jq -n --arg id "$id_a" '{manifest_version:4, brood_id:$id, created_at:"2026-06-01T00:00:00Z", base:"main", overlap_risk:"low", strains:[], merge_order:[]}' \
        > "$root/.hivemind/broods/$id_a/manifest.json"
    printf '{"manifest_version":4,"strains":[{"name":"api",\n' > "$root/.hivemind/broods/$id_b/manifest.json"

    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    # Brood a is empty (status empty, 0 strains); brood b is unreadable (detail=path); both counted;
    # the run did NOT abort. global.total_broods=2, unreadable=1.
    local manifest_b="$root/.hivemind/broods/$id_b/manifest.json"
    local ok=no
    if printf '%s' "$out" | jq -e \
        --arg ida "$id_a" --arg idb "$id_b" --arg pathb "$manifest_b" \
        '.schema=="brood-status-collect/1"
         and (.broods|length)==2
         and .broods[0].brood_id==$ida and .broods[0].status=="empty"
         and .broods[1].brood_id==$idb and .broods[1].status=="unreadable"
         and .broods[1].detail==$pathb
         and .global.total_broods==2 and .global.unreadable==1' >/dev/null 2>&1; then
        ok=yes
    fi
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; empty brood + torn manifest isolated as unreadable (detail=path); both counted (total=2, unreadable=1)"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
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
assert_proj_no_live_worktree
assert_proj_duplicate_branch
assert_proj_malformed_run_status
assert_proj_injection_state_current
assert_proj_metachar_worktree
assert_proj_symlink_leaf
assert_proj_unreadable_ledger
assert_proj_suggested_id_escape
assert_proj_missing_arg
assert_proj_output_encoding
assert_proj_no_tmpdir_needed
assert_proj_multi_strain
assert_proj_unreadable_manifest
assert_proj_valid_empty_manifest
assert_proj_wrong_shape_unreadable
assert_proj_object_element_missing_name
assert_proj_brood_id_field
assert_proj_single_snapshot_consistency
assert_proj_literal_nul_manifest
assert_proj_nul_escape_branch
assert_proj_multidoc_manifest
assert_proj_literal_nul_ledger
assert_proj_nested_worktree_anchor

echo ''
echo '=== brood-discover.sh deterministic discovery tests (#185, ADR-0020) ==='
assert_discover_empty
assert_discover_sort_order
assert_discover_nested_worktree
assert_discover_dir_without_manifest_skipped
assert_discover_hostile_name_skipped

# ── COLLECT-MISSING-SENTINEL: absent tmux_session/branch → probes SKIP MISSING token ─
# A manifest strain with NO tmux_session and NO branch field. The projector emits the fixed token
# MISSING for both (absent fields). The collector MUST treat MISSING (like MALFORMED) as a
# non-probeable sentinel — it must NOT run `tmux has-session -t MISSING` or `gh pr list --head
# MISSING`, where an unrelated real session/branch/PR literally named `MISSING` would masquerade as
# this strain's observable. Assert session=dead (MISSING never probed alive) and pr.state=none
# (MISSING never probed to open/merged), regardless of any host session/branch named MISSING.
assert_collect_missing_sentinel_not_probed() {
    local name="COLLECT-MISSING-SENTINEL:absent-tmux-branch-not-probed-as-real-names"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local brood_dir="$root/.hivemind/broods/$COLLECT_BROOD_ID"
    mkdir -p "$brood_dir"
    # A strain with NO branch and NO tmux_session field -> projector emits MISSING for both.
    jq -n \
        --arg brood_id "$COLLECT_BROOD_ID" \
        '{ manifest_version:4, brood_id:$brood_id, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api", description:"d", status:"running"}],
           merge_order:[] }' > "$brood_dir/manifest.json"
    # If this host happens to have a tmux server, create a real session literally named MISSING to
    # prove the collector does NOT pick it up (probe is skipped, not run against the sentinel).
    local made_session=no
    if command -v tmux >/dev/null 2>&1 && tmux new-session -d -s MISSING 2>/dev/null; then
        made_session=yes
    fi
    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    local ok=no
    if printf '%s' "$out" | jq -e \
        --arg id "$COLLECT_BROOD_ID" \
        '.schema=="brood-status-collect/1"
         and (.broods|length)==1
         and .broods[0].brood_id==$id
         and (.broods[0].strains|length)==1
         and .broods[0].strains[0].session=="dead"
         and .broods[0].strains[0].pr.state=="none"
         and .broods[0].strains[0].pr.number==null' >/dev/null 2>&1; then
        ok=yes
    fi
    [[ "$made_session" == "yes" ]] && tmux kill-session -t MISSING 2>/dev/null || true
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; MISSING tmux_session/branch sentinels NOT probed (session=dead, pr none/null) despite a real session named MISSING"
    else
        failed "$name" "rc=$rc ok=$ok made_session=$made_session out=[$out]"
    fi
}

# ── COLLECT-BROODID-MISMATCH: manifest top-level brood_id != directory id → blocker ──
# A manifest whose top-level brood_id does NOT match its containing brood directory (e.g. copied
# into the wrong dir). The projector emits that top-level brood_id as f_brood on each STRAIN line;
# the collector MUST detect the disagreement vs the directory id and render the brood as a
# `blocker` (unattributable), counted as unreadable — NOT as a normal brood under the directory id.
assert_collect_broodid_mismatch_blocker() {
    local name="COLLECT-BROODID-MISMATCH:manifest-brood_id-ne-dir-id-blocker"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local dir_id="brood-3333cccc-3333-4ccc-8ccc-333333333333"
    local manifest_id="brood-4444dddd-4444-4ddd-8ddd-444444444444"
    local brood_dir="$root/.hivemind/broods/$dir_id"
    mkdir -p "$brood_dir"
    # Manifest carries a VALID-shape top-level brood_id that DIFFERS from the directory id.
    jq -n --arg bid "$manifest_id" \
        '{ manifest_version:4, brood_id:$bid, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api", description:"d", status:"running"}],
           merge_order:[] }' > "$brood_dir/manifest.json"

    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    local ok=no
    if printf '%s' "$out" | jq -e \
        --arg id "$dir_id" --arg got "$manifest_id" \
        '.schema=="brood-status-collect/1"
         and (.broods|length)==1
         and .broods[0].brood_id==$id
         and .broods[0].status=="blocker"
         and (.broods[0].strains|length)==0
         and (.broods[0].detail|contains($got))
         and .global.total_broods==1
         and .global.unreadable==1' >/dev/null 2>&1; then
        ok=yes
    fi
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; manifest brood_id != dir id -> blocker (unattributable), counted unreadable; projector integrity signal preserved"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

# ── COLLECT-BROODID-MISMATCH-EMPTY: strains:[] with wrong/absent top-level brood_id → blocker ──
# The integrity guard must NOT depend on STRAIN rows: the projector emits ZERO STRAIN lines for a
# VALID empty manifest (`strains:[]` -> exit 0). An empty manifest copied into the wrong brood dir
# (mismatched top-level brood_id) OR carrying an absent top-level brood_id must STILL be rendered as
# a `blocker` (unattributable), counted unreadable — never as a normal `empty` brood under the
# directory id. Covers both the mismatched and the absent/malformed zero-strain paths.
assert_collect_broodid_mismatch_empty_blocker() {
    local name="COLLECT-BROODID-MISMATCH-EMPTY:zero-strain-wrong-or-absent-brood_id-blocker"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    # Brood A: empty manifest, top-level brood_id DIFFERS from dir id.
    local id_a="brood-5555eeee-5555-4eee-8eee-555555555555"
    local mid_a="brood-6666ffff-6666-4fff-8fff-666666666666"
    mkdir -p "$root/.hivemind/broods/$id_a"
    jq -n --arg bid "$mid_a" \
        '{ manifest_version:4, brood_id:$bid, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low", strains:[], merge_order:[] }' \
        > "$root/.hivemind/broods/$id_a/manifest.json"
    # Brood B: empty manifest, top-level brood_id ABSENT entirely.
    local id_b="brood-7777aaaa-7777-4aaa-8aaa-777777777777"
    mkdir -p "$root/.hivemind/broods/$id_b"
    jq -n \
        '{ manifest_version:4, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low", strains:[], merge_order:[] }' \
        > "$root/.hivemind/broods/$id_b/manifest.json"

    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    # Both broods (sorted: id_a < id_b) must be blocker, zero strains, counted unreadable. Brood A's
    # detail names the wrong manifest id; brood B's detail says absent/malformed.
    local ok=no
    if printf '%s' "$out" | jq -e \
        --arg ida "$id_a" --arg mida "$mid_a" --arg idb "$id_b" \
        '.schema=="brood-status-collect/1"
         and (.broods|length)==2
         and .broods[0].brood_id==$ida and .broods[0].status=="blocker"
         and (.broods[0].strains|length)==0 and (.broods[0].detail|contains($mida))
         and .broods[1].brood_id==$idb and .broods[1].status=="blocker"
         and (.broods[1].strains|length)==0 and (.broods[1].detail|contains("absent/malformed"))
         and .global.total_broods==2 and .global.unreadable==2 and .global.complete==0' >/dev/null 2>&1; then
        ok=yes
    fi
    rm -rf "$tmp"
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; zero-strain wrong/absent top-level brood_id -> blocker (not empty); both counted unreadable"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

# ── COLLECT-STARTED-RUNNING: alive session + GT ledger with started workflow → running ──
# issue #213 (secondary fix), positive control. A real alive tmux session matching the strain's
# tmux_session, PLUS a GT-derived ledger carrying a present state.current (started evidence). The
# collector's derivation MUST keep this strain running-equivalent (derived_status begins with
# `running`), NOT demoted to `starting`. tmux-gated (skips when tmux is unavailable; we never drive
# claude submit — we only create an inert tmux session to make the liveness probe observe `alive`).
assert_collect_started_running() {
    local name="COLLECT-STARTED-RUNNING:alive-session-with-started-ledger-stays-running"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        skip "$name" "collect started-running case needs a real tmux session to observe alive; skipping (no tmux)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local brood_dir="$root/.hivemind/broods/$COLLECT_BROOD_ID"
    mkdir -p "$brood_dir"
    local branch="strain/$COLLECT_BROOD_ID/api" sid="$COLLECT_BROOD_ID--api"
    local sess="$COLLECT_BROOD_ID-api"
    local wt="$root/wt-api"
    git -C "$root" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null
    mkdir -p "$wt/.hivemind/runs/$sid"
    # Started evidence: a present state.current.
    jq -n '{run:{status:"running"}, state:{current:"implement_step"}}' > "$wt/.hivemind/runs/$sid/state.json"
    jq -n \
        --arg brood_id "$COLLECT_BROOD_ID" --arg wt "$wt" --arg branch "$branch" --arg sid "$sid" --arg sess "$sess" \
        '{ manifest_version:4, brood_id:$brood_id, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api", description:"d", worktree_path:$wt, branch:$branch,
                     tmux_session:$sess, status:"running",
                     run:{suggested_id:$sid, workflow_hint:"standard-delivery"}}],
           merge_order:[] }' > "$brood_dir/manifest.json"
    # An inert alive tmux session matching the strain's tmux_session (NO claude submit driven).
    local made_session=no
    if tmux new-session -d -s "$sess" 2>/dev/null; then made_session=yes; fi
    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    local ok=no
    if [[ "$made_session" == "yes" ]] && printf '%s' "$out" | jq -e \
        --arg id "$COLLECT_BROOD_ID" \
        '.schema=="brood-status-collect/1"
         and .broods[0].strains[0].session=="alive"
         and (.broods[0].strains[0].derived_status|startswith("running"))' >/dev/null 2>&1; then
        ok=yes
    fi
    [[ "$made_session" == "yes" ]] && tmux kill-session -t "$sess" 2>/dev/null || true
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$tmp"
    if [[ "$made_session" != "yes" ]]; then
        skip "$name" "could not create a tmux session (no tmux server); skipping"
        return
    fi
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; alive session + started ledger -> derived_status running (not demoted to starting)"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

# ── COLLECT-ALIVE-UNSTARTED: alive session + NO ledger on disk → starting (not running) ──
# issue #213 (secondary fix), the core regression. A live worktree on the strain branch but NO
# state.json (the child pasted its task and never submitted — no run ledger written). The projector
# emits state.current=MISSING; with a real alive tmux session, the OLD rule masked this as bare
# `running`. The collector now derives the DISTINCT transient `starting` status (non-running,
# non-complete). tmux-gated (skips when tmux is unavailable; no claude submit is ever driven).
assert_collect_alive_unstarted_starting() {
    local name="COLLECT-ALIVE-UNSTARTED:alive-session-no-ledger-derives-starting"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        skip "$name" "collect alive-unstarted case needs a real tmux session to observe alive; skipping (no tmux)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local brood_dir="$root/.hivemind/broods/$COLLECT_BROOD_ID"
    mkdir -p "$brood_dir"
    local branch="strain/$COLLECT_BROOD_ID/api" sid="$COLLECT_BROOD_ID--api"
    local sess="$COLLECT_BROOD_ID-api"
    local wt="$root/wt-api"
    git -C "$root" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null
    # GT worktree exists, but NO state.json is written (child never started its workflow).
    jq -n \
        --arg brood_id "$COLLECT_BROOD_ID" --arg wt "$wt" --arg branch "$branch" --arg sid "$sid" --arg sess "$sess" \
        '{ manifest_version:4, brood_id:$brood_id, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api", description:"d", worktree_path:$wt, branch:$branch,
                     tmux_session:$sess, status:"running",
                     run:{suggested_id:$sid, workflow_hint:"standard-delivery"}}],
           merge_order:[] }' > "$brood_dir/manifest.json"
    local made_session=no
    if tmux new-session -d -s "$sess" 2>/dev/null; then made_session=yes; fi
    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    local ok=no
    # session=alive, workflow_state MISSING (no ledger), derived_status begins with `starting`, and
    # the strain buckets OUT of running (summary.running==0) — the regression assertion.
    if [[ "$made_session" == "yes" ]] && printf '%s' "$out" | jq -e \
        --arg id "$COLLECT_BROOD_ID" \
        '.schema=="brood-status-collect/1"
         and .broods[0].strains[0].session=="alive"
         and .broods[0].strains[0].workflow_state=="MISSING"
         and (.broods[0].strains[0].derived_status|startswith("starting"))
         and .broods[0].summary.running==0' >/dev/null 2>&1; then
        ok=yes
    fi
    [[ "$made_session" == "yes" ]] && tmux kill-session -t "$sess" 2>/dev/null || true
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$tmp"
    if [[ "$made_session" != "yes" ]]; then
        skip "$name" "could not create a tmux session (no tmux server); skipping"
        return
    fi
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; alive session + no ledger -> derived_status starting (NOT running); running bucket excludes it"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

# LEGACY no-pointer fall-through: a legacy manifest has NO run:{...} block, so the projector emits
# state.current=NO_LEDGER_POINTER. Started-evidence is structurally unavailable, so the
# started-evidence gate must NOT apply: an alive legacy strain keeps its observable `running` status
# rather than being permanently demoted to `starting`. Mirrors the alive-unstarted sibling but DROPS
# the run block from the fixture. tmux-gated (skips when tmux is unavailable).
assert_collect_legacy_no_pointer_running() {
    local name="COLLECT-LEGACY-NOPOINTER:legacy-manifest-no-run-block-derives-running"
    if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "$name" "collect needs jq+git; skipping (missing dep)"
        return
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        skip "$name" "collect legacy no-pointer case needs a real tmux session to observe alive; skipping (no tmux)"
        return
    fi
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-brood-collect.XXXXXX")"
    local root="$tmp/repo"; mkdir -p "$root"
    collect_seed_repo "$root"
    local brood_dir="$root/.hivemind/broods/$COLLECT_BROOD_ID"
    mkdir -p "$brood_dir"
    local branch="strain/$COLLECT_BROOD_ID/api"
    local sess="$COLLECT_BROOD_ID-api"
    local wt="$root/wt-api"
    git -C "$root" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null
    # LEGACY manifest: NO run:{...} block (no suggested_id), so no ledger pointer exists.
    jq -n \
        --arg brood_id "$COLLECT_BROOD_ID" --arg wt "$wt" --arg branch "$branch" --arg sess "$sess" \
        '{ manifest_version:4, brood_id:$brood_id, created_at:"2026-06-01T00:00:00Z",
           base:"main", overlap_risk:"low",
           strains:[{name:"api", description:"d", worktree_path:$wt, branch:$branch,
                     tmux_session:$sess, status:"running"}],
           merge_order:[] }' > "$brood_dir/manifest.json"
    local made_session=no
    if tmux new-session -d -s "$sess" 2>/dev/null; then made_session=yes; fi
    local out rc=0
    out="$( cd "$root" && bash "$COLLECT_SCRIPT" 2>/dev/null )" || rc=$?
    local ok=no
    # session=alive, workflow_state NO_LEDGER_POINTER, derived_status begins with `running` (NOT
    # `starting`), and the running bucket counts it. startswith("running") passes with or without gh.
    if [[ "$made_session" == "yes" ]] && printf '%s' "$out" | jq -e \
        '.schema=="brood-status-collect/1"
         and .broods[0].strains[0].session=="alive"
         and .broods[0].strains[0].workflow_state=="NO_LEDGER_POINTER"
         and (.broods[0].strains[0].derived_status|startswith("running"))
         and .broods[0].summary.running>=1' >/dev/null 2>&1; then
        ok=yes
    fi
    [[ "$made_session" == "yes" ]] && tmux kill-session -t "$sess" 2>/dev/null || true
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$tmp"
    if [[ "$made_session" != "yes" ]]; then
        skip "$name" "could not create a tmux session (no tmux server); skipping"
        return
    fi
    if [[ "$rc" -eq 0 && "$ok" == "yes" ]]; then
        pass "$name" "exit 0; legacy no-pointer manifest -> NO_LEDGER_POINTER -> derived_status running (NOT starting); counted running"
    else
        failed "$name" "rc=$rc ok=$ok out=[$out]"
    fi
}

echo ''
echo '=== brood-status-collect.sh collection-loop entrypoint tests (#186, ADR-0020) ==='
assert_collect_empty
assert_collect_ok_one_strain
assert_collect_unreadable_isolated
assert_collect_missing_sentinel_not_probed
assert_collect_broodid_mismatch_blocker
assert_collect_broodid_mismatch_empty_blocker
assert_collect_started_running
assert_collect_alive_unstarted_starting
assert_collect_legacy_no_pointer_running

echo ''
echo '=== Summary ==='
echo "Brood back-compat tests: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped."
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
