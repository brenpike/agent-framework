#!/usr/bin/env bash
#
# Shared-library unit runner for the brood-status read-side projection (issue #161).
#
# PURE UNIT TESTS — CI-runnable with ONLY jq present (NO tmux / claude / gh). Exercises the
# three sourced libraries the brood-status-project.sh entrypoint composes:
#   - plugin/skills/_shared/allowlist.sh      (identifier / path / presentation)
#   - plugin/skills/_shared/manifest-json.sh  (hivemind_manifest_strain_names / _field)
#   - plugin/skills/_shared/ledger-project.sh (hivemind_project_run_status / _state_current)
#
# Each lib is SOURCED (these are sourced fragments, not executables) and its functions called
# directly. Mirrors tools/test_brood_compat.sh's pass/fail counter + exit-nonzero-on-failure
# convention. Read-only: the only writes are small inline JSON fixtures in a disposable tmpdir
# removed on EXIT.
#
# Usage:
#   ./tools/test_shared_libs.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SHARED_DIR="$REPO_ROOT/plugin/skills/_shared"
FIX_DIR="$REPO_ROOT/tests/brood"
LEDGER_PRESENT="$FIX_DIR/child-ledger-present.json"

CLASSIFY_FILTER="$REPO_ROOT/plugin/skills/github-review-loop/scripts/fix-history-classify.jq"
FN_REVIEW_HANDLED="$REPO_ROOT/tests/fix-history/case01-handled-by-marker.json"
FN_EXPECTED_REVIEW="$REPO_ROOT/tests/fetch-normalize/expected/review-thread-handled.json"
FN_CI_CHECKS="$REPO_ROOT/tests/fetch-normalize/ci-checks.json"
FN_EXPECTED_CI="$REPO_ROOT/tests/fetch-normalize/expected/ci-only.json"
FN_OVERFLOW_THREADS="$REPO_ROOT/tests/fetch-normalize/overflow-threads.json"
FN_MALFORMED="$REPO_ROOT/tests/fetch-normalize/malformed.json"

for required in "$LEDGER_PRESENT" \
                "$SHARED_DIR/allowlist.sh" "$SHARED_DIR/manifest-json.sh" "$SHARED_DIR/ledger-project.sh" \
                "$SHARED_DIR/brood-status-derive.sh" "$SHARED_DIR/containment.sh" \
                "$SHARED_DIR/ledger-reconstruct-parse.sh" "$SHARED_DIR/ledger-reconstruct-fold.sh" \
                "$SHARED_DIR/fetch-normalize-core.sh" \
                "$CLASSIFY_FILTER" \
                "$FN_REVIEW_HANDLED" "$FN_EXPECTED_REVIEW" "$FN_CI_CHECKS" "$FN_EXPECTED_CI" \
                "$FN_OVERFLOW_THREADS" "$FN_MALFORMED"; do
  [ -f "$required" ] || { echo "FAIL: required fixture/lib missing: $required" >&2; exit 2; }
done

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this suite" >&2; exit 2; }

# Source the libs under test.
# shellcheck source=/dev/null
. "$SHARED_DIR/allowlist.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/manifest-json.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/ledger-project.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/brood-status-derive.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/containment.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/ledger-reconstruct-parse.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/ledger-reconstruct-fold.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/fetch-normalize-core.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Disposable tmpdir for inline JSON ledger fixtures and side-effect probes.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-shared-libs.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; return 0; }
trap cleanup EXIT

# assert_eq <case> <expected> <actual> [msg]
assert_eq() {
  local case_name="$1" expected="$2" actual="$3" msg="${4:-}"
  if [ "$expected" = "$actual" ]; then
    pass "$case_name" "${msg:+$msg }(== '$expected')"
  else
    failed "$case_name" "${msg:+$msg }expected '$expected', got '$actual'"
  fi
}

# ── Section 1: allowlist.sh — three value classes sharing one security floor ─────
echo '=== allowlist.sh: identifier / path / presentation ==='

# Side-effect probe: any payload referencing PWN_MARKER must NOT touch it (proves the
# validators never eval/expand command substitution). Cleared once, asserted once at the end.
PWN_MARKER="$WORKDIR/pwn-marker"
rm -f "$PWN_MARKER"

# ── Class 1: identifier (strictest, ^[A-Za-z0-9._/-]+$). ──
for v in "feat/x" "brood-auth" "/abs/path-1.json" "a.b_c" "2026-05-30T22-10-00Z--api"; do
  if hivemind_assert_identifier "$v"; then
    pass "id:accept" "accepted identifier '$v'"
  else
    failed "id:accept" "rejected an identifier that should be safe: '$v'"
  fi
done
# identifier REJECTS space and the path-class inert bytes (those belong to the wider classes).
for v in "" "-rf" "a..b" "x\$(touch $PWN_MARKER)" "\`touch $PWN_MARKER\`" "a b" "a;b" "a#b" "a=b" "a~b" "a!b"; do
  if hivemind_assert_identifier "$v"; then
    failed "id:reject" "accepted a value identifier must reject: '$v'"
  else
    pass "id:reject" "rejected non-identifier '$v'"
  fi
done

# ── Class 2: path (identifier charset PLUS space and inert bytes # = ~ !). ──
# Space-bearing ACCEPTS (the Codex #172 P1 case): a real checkout root with a space.
for v in "/home/me/hive review/wt" "/repo/.claude/worktrees/api" "/home/me/hive#review/wt" "/a/b=c~d!e/wt" "feat/x"; do
  if hivemind_assert_path "$v"; then
    pass "path:accept" "accepted path '$v'"
  else
    failed "path:accept" "rejected a path that should be safe: '$v'"
  fi
done
# path is FLOOR-ONLY (#177/#168 doctrine): the shared floor IS the complete boundary. It STILL
# rejects exactly the floor bytes — command-sub ($/backtick), '..', leading '-', framing bytes
# (TAB/LF/CR), and empty — because those are the only bytes that could break the quoted-data uses
# (`cd "$dir"`, jq --arg, pwd -P). Nothing else is enumerated.
tab=$'\t'; nl=$'\n'; cr=$'\r'; vt=$'\v'; ff=$'\f'
for v in "" "-rf" "/a/../b" "x\$(touch $PWN_MARKER)" "\`touch $PWN_MARKER\`" "a${tab}b" "a${nl}b" "a${cr}b"; do
  if hivemind_assert_path "$v"; then
    failed "path:reject" "accepted a value the path floor must reject: '$v'"
  else
    pass "path:reject" "rejected unsafe path '$v'"
  fi
done
# FLOOR-ONLY CONSEQUENCE (#177 doctrine, locked under #168): bytes that are NOT in the floor are
# ACCEPTED as inert quoted path data — including shell-structural bytes like `; | > & ( )` and the
# non-framing C0 controls VT (\v) / FF (\f). These can never break a command word because a path is
# only ever used as quoted data, never re-parsed; enumerating them was the #177 false-reject
# treadmill. This block LOCKS that they pass (a future re-add of a per-byte charset rule to the path
# class would regress here). Markdown-cell safety for `|` is the render-boundary encoder's job, not
# this class's. (Framing bytes TAB/LF/CR are still floor-rejected above — only the NON-framing
# controls VT/FF pass.)
for v in "a;b" 'a|b' 'a>b' 'a&b' '/a/(b)/wt' "a${vt}b" "a${ff}b"; do
  if hivemind_assert_path "$v"; then
    pass "path:floor-only-inert-accept" "floor-only path accepts inert non-floor byte: '$v'"
  else
    failed "path:floor-only-inert-accept" "floor-only path wrongly rejected inert non-floor byte '$v' (per-byte charset re-added?)"
  fi
done

# ── Class 3: presentation (positive allowlist; display-only name). ──
# Space-bearing display name ACCEPTS — this is what lets `api worker` render not MALFORMED.
# The permitted set is: A-Za-z0-9 space . _ - / ( ) : , + @ # = ~ !
# `|` is NOT in the permitted set (Markdown table-cell injector — excluded by construction,
# no explicit carve-out required). `;` is also not permitted (shell-structural, not needed).
#
# PRODUCER CONTRACT: these ACCEPT cases are ALSO the spawn-brood.sh strain-name launch gate.
# spawn-brood.sh calls hivemind_assert_presentation at the name-validation point and hard-
# blocks (exit 1, no child launched) on any name outside this class. Producer and consumer
# share this single validator — the tests below document both roles simultaneously.
for v in "api worker" "api" "api-slice" "api/v2" "feature (2)" "a.b_c" "a#b" "a (worker)" "a/b-c.d_e"; do
  if hivemind_assert_presentation "$v"; then
    pass "pres:accept" "accepted presentation value '$v'"
  else
    failed "pres:accept" "rejected a presentation value that should render: '$v'"
  fi
done
# PRODUCER CONTRACT: these REJECT cases are ALSO names that spawn-brood.sh must never launch.
# Each entry proves a class of invalid strain name is hard-blocked at the producer before any
# child session is created — `api & web`, `a;b`, `a|b`, and non-ASCII names all fall here.
# presentation enforces the shared floor (command-sub, '..', leading '-', framing) AND rejects
# bytes not in the positive allowlist — each entry below proves a treadmill byte is closed BY
# CONSTRUCTION (the byte is simply absent from the allowlist), not by a specific carve-out.
esc=$'\033'; del=$'\177'; bidi=$'\xe2\x80\xae'
for v in \
  "" "-x" "a..b" \
  "x\$(touch $PWN_MARKER)" "\`touch $PWN_MARKER\`" \
  "a${tab}b" "a${nl}b" "a${cr}b" \
  "a${esc}b" "a${vt}b" "a${ff}b" "a${del}b" \
  "a${bidi}b" \
  'a|b' 'a<b' 'a>b' 'a;b' 'a&b' "api & web"; do
  if hivemind_assert_presentation "$v"; then
    failed "pres:reject" "accepted a value the presentation allowlist must reject: '$v'"
  else
    pass "pres:reject" "rejected non-allowlist presentation value '$v'"
  fi
done

# No payload across ANY class created the marker (proves no command substitution ran).
if [ -e "$PWN_MARKER" ]; then
  failed "allow:no-side-effect" "a command-sub payload created the side-effect marker $PWN_MARKER"
else
  pass "allow:no-side-effect" "no command-sub payload created a side-effect file"
fi

# ── Section 2: manifest-json.sh ─────────────────────────────────────────────────
echo ''
echo '=== manifest-json.sh: hivemind_manifest_strain_names / hivemind_manifest_field ==='
#
# JSON manifests are built inline in WORKDIR so this section is self-contained (the shared
# JSON manifest fixtures under tests/brood/ are owned by STEP-004). Each fixture mirrors the
# shape spawn-brood.sh's jq emitter writes (manifest_version 3): a top-level object with a
# `strains` array; each strain carries name/worktree_path/branch/tmux_session/status and a
# nested `run` object.

# v3 manifest with a single "api" strain carrying a full run block.
MANIFEST_V3="$WORKDIR/manifest-v3.json"
jq -n '{
  manifest_version: 3,
  brood_id: "2026-05-30T22-10-00Z",
  strains: [
    {
      name: "api",
      description: "Implement the API slice.",
      worktree_path: "/repo/.claude/worktrees/api",
      branch: "feature/api-slice",
      tmux_session: "brood-api",
      status: "running",
      pr: null, merged: false, rebased_after: [],
      run: {
        suggested_id: "2026-05-30T22-10-00Z--api",
        suggested_ledger: "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json",
        workflow_hint: "standard-delivery"
      }
    }
  ],
  merge_order: []
}' > "$MANIFEST_V3"

assert_eq "manifest:v3-names" "api" \
  "$(hivemind_manifest_strain_names "$MANIFEST_V3")" "v3 strain names"
assert_eq "manifest:v3-worktree" "/repo/.claude/worktrees/api" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "worktree_path")" "v3 worktree_path"
assert_eq "manifest:v3-branch" "feature/api-slice" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "branch")" "v3 branch"
assert_eq "manifest:v3-tmux" "brood-api" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "tmux_session")" "v3 tmux_session"
assert_eq "manifest:v3-status" "running" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "status")" "v3 status"
assert_eq "manifest:v3-suggested-id" "2026-05-30T22-10-00Z--api" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "run.suggested_id")" "v3 run.suggested_id"
assert_eq "manifest:v3-suggested-ledger" "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "run.suggested_ledger")" "v3 run.suggested_ledger"
assert_eq "manifest:v3-workflow-hint" "standard-delivery" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "workflow_hint")" "v3 workflow_hint"

# run.* prefix parity: bare field name resolves the same as the run.-prefixed name.
assert_eq "manifest:v3-suggested-ledger-bare" "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "api" "suggested_ledger")" "v3 suggested_ledger (bare name)"

# A v1-shape manifest (no run block): static fields extract, run.* fields are empty.
MANIFEST_NORUN="$WORKDIR/manifest-norun.json"
jq -n '{
  manifest_version: 3,
  strains: [
    { name: "api", worktree_path: "/repo/.claude/worktrees/api",
      branch: "feature/api-slice", tmux_session: "brood-api", status: "running" }
  ]
}' > "$MANIFEST_NORUN"
assert_eq "manifest:norun-names" "api" \
  "$(hivemind_manifest_strain_names "$MANIFEST_NORUN")" "no-run strain names"
assert_eq "manifest:norun-branch" "feature/api-slice" \
  "$(hivemind_manifest_field "$MANIFEST_NORUN" "api" "branch")" "no-run branch"
assert_eq "manifest:norun-suggested-ledger-empty" "" \
  "$(hivemind_manifest_field "$MANIFEST_NORUN" "api" "run.suggested_ledger")" "no run block → empty"

# Absent strain → empty.
assert_eq "manifest:absent-strain" "" \
  "$(hivemind_manifest_field "$MANIFEST_V3" "nope" "branch")" "absent strain yields empty"

# Absent / unparseable manifest → empty, never an error (caller treats as no fields).
assert_eq "manifest:absent-file-names" "" \
  "$(hivemind_manifest_strain_names "$WORKDIR/does-not-exist.json")" "absent manifest → no names"
TORN_MANIFEST="$WORKDIR/torn-manifest.json"
printf '{"strains":[{"name":"api"\n' > "$TORN_MANIFEST"
assert_eq "manifest:torn-names" "" \
  "$(hivemind_manifest_strain_names "$TORN_MANIFEST")" "torn manifest → no names"
assert_eq "manifest:torn-field" "" \
  "$(hivemind_manifest_field "$TORN_MANIFEST" "api" "branch")" "torn manifest → empty field"

# ── Hostile-content containment (the WHOLE POINT of the JSON flip) ───────────────
# A strain `description` string carries untrusted issue-sourced free text. The text embeds
# counterfeit `status: failed`, a `worktree_path:` line, and a command-substitution payload.
# Because the manifest is JSON parsed by jq, the description is JUST A STRING VALUE — jq can
# never re-parse its bytes as sibling keys. The genuine fields MUST be returned unchanged and
# no command substitution can run. This is the injection class that the YAML reader had to
# defend against with block-scalar-aware awk, now DEAD BY CONSTRUCTION.
MANIFEST_HOSTILE="$WORKDIR/manifest-hostile.json"
HOSTILE_DESC='Implement the API slice.
status: failed
worktree_path: /attacker/escape
$(touch '"$PWN_MARKER"')
- name: injected-strain'
jq -n --arg d "$HOSTILE_DESC" '{
  manifest_version: 3,
  strains: [
    {
      name: "api",
      description: $d,
      worktree_path: "/repo/.claude/worktrees/api",
      branch: "feature/api-slice",
      tmux_session: "brood-api",
      status: "running",
      run: { suggested_ledger: "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json" }
    }
  ]
}' > "$MANIFEST_HOSTILE"

# The hostile description's injected `- name:` line is NOT a second strain.
assert_eq "manifest:hostile-names" "api" \
  "$(hivemind_manifest_strain_names "$MANIFEST_HOSTILE")" "injected name in description string is not a strain"
# Genuine status wins over the counterfeit "status: failed" inside the description string.
assert_eq "manifest:hostile-status" "running" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "status")" "counterfeit status in description is inert"
assert_eq "manifest:hostile-worktree" "/repo/.claude/worktrees/api" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "worktree_path")" "counterfeit worktree_path in description is inert"
assert_eq "manifest:hostile-branch" "feature/api-slice" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "branch")" "genuine branch returned"
assert_eq "manifest:hostile-ledger" "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "run.suggested_ledger")" "genuine run.suggested_ledger returned"
# The command-substitution payload in the description never ran (re-uses the Section 1 marker).
if [ -e "$PWN_MARKER" ]; then
  failed "manifest:hostile-no-side-effect" "description command-sub payload created $PWN_MARKER"
else
  pass "manifest:hostile-no-side-effect" "description command-sub payload did not execute"
fi

# ── Single-snapshot content helpers: shape validation + index extraction ─────────
# hivemind_manifest_validate_shape folds the old `jq empty` syntax probe into a shape check:
# `.strains` must EXIST as an ARRAY with every element an OBJECT. The content-snapshot helpers
# (count_snapshot / field_at) operate on the in-memory snapshot the engine reads ONCE.

# A valid full manifest passes shape validation.
V3_CONTENT="$(cat "$MANIFEST_V3")"
if hivemind_manifest_validate_shape "$V3_CONTENT"; then
  pass "shape:v3-valid" "full v3 manifest passes shape validation"
else
  failed "shape:v3-valid" "full v3 manifest rejected by shape validation"
fi
# A valid EMPTY manifest ({"strains":[]}) passes (all() over an empty array is true) — legit
# empty brood, NOT unreadable.
if hivemind_manifest_validate_shape '{"strains":[]}'; then
  pass "shape:empty-valid" "valid empty manifest passes shape validation"
else
  failed "shape:empty-valid" "valid empty manifest wrongly rejected by shape validation"
fi
# Wrong-shape / invalid manifests must FAIL shape validation: missing .strains, null .strains,
# non-array .strains, non-object element, and syntactically-invalid JSON (folds the old jq empty).
for bad in '{}' '{"strains":null}' '{"strains":"x"}' '{"strains":[1]}' '{"strains":[{"name":"a"}'; do
  if hivemind_manifest_validate_shape "$bad"; then
    failed "shape:reject" "wrong-shape/invalid manifest wrongly passed shape validation: $bad"
  else
    pass "shape:reject" "wrong-shape/invalid manifest rejected: $bad"
  fi
done
# An object element MISSING `name` still passes shape (it is an object) — per-strain field
# degradation is the contract, not a whole-manifest structural failure.
if hivemind_manifest_validate_shape '{"strains":[{}]}'; then
  pass "shape:object-no-name" "object element missing name passes shape (per-strain degradation, not structural)"
else
  failed "shape:object-no-name" "object element missing name wrongly rejected by shape validation"
fi

# Strain count from the in-memory snapshot.
assert_eq "snapshot:v3-count" "1" \
  "$(hivemind_manifest_strain_count_snapshot "$V3_CONTENT")" "v3 strain count from snapshot"
assert_eq "snapshot:empty-count" "0" \
  "$(hivemind_manifest_strain_count_snapshot '{"strains":[]}')" "empty manifest strain count from snapshot"

# Index-based field extraction against the snapshot resolves the same values as the path-based
# pair, selecting by position rather than by name.
assert_eq "snapshot:v3-field-branch" "feature/api-slice" \
  "$(hivemind_manifest_field_at "$V3_CONTENT" 0 "branch")" "field_at branch at index 0"
assert_eq "snapshot:v3-field-worktree" "/repo/.claude/worktrees/api" \
  "$(hivemind_manifest_field_at "$V3_CONTENT" 0 "worktree_path")" "field_at worktree_path at index 0"
assert_eq "snapshot:v3-field-ledger" "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json" \
  "$(hivemind_manifest_field_at "$V3_CONTENT" 0 "run.suggested_ledger")" "field_at run.suggested_ledger at index 0"
# An object element missing `name`/run fields → field_at yields empty (// empty), never an error.
assert_eq "snapshot:objnoname-field" "" \
  "$(hivemind_manifest_field_at '{"strains":[{}]}' 0 "branch")" "field_at on fieldless object → empty"

# ── Section 3: ledger-project.sh ────────────────────────────────────────────────
echo ''
echo '=== ledger-project.sh: hivemind_project_run_status / hivemind_project_state_current ==='

# Valid fixture: status=running, state.current=implement_step.
assert_eq "ledger:valid-status" "running" \
  "$(hivemind_project_run_status "$LEDGER_PRESENT")" "valid run.status from fixture"
assert_eq "ledger:valid-state" "implement_step" \
  "$(hivemind_project_state_current "$LEDGER_PRESENT")" "valid state.current from fixture"

# status outside the enum → MALFORMED.
bad_status="$WORKDIR/bad-status.json"
printf '{"run":{"status":"frobnicate"},"state":{"current":"plan"}}\n' > "$bad_status"
assert_eq "ledger:status-out-of-enum" "MALFORMED" \
  "$(hivemind_project_run_status "$bad_status")" "status outside enum"
# ...but the state.current on the SAME file is good → per-scalar independence.
assert_eq "ledger:independence-state-good" "plan" \
  "$(hivemind_project_state_current "$bad_status")" "good state.current despite bad status (independence)"

# state.current with uppercase / space / metachars → MALFORMED; run.status good → independence.
for bad_state in "Implement_Step" "implement step" "x\$(touch /tmp/should-not-run)"; do
  bad_state_file="$WORKDIR/bad-state.json"
  jq -n --arg s "$bad_state" '{run:{status:"running"},state:{current:$s}}' > "$bad_state_file"
  assert_eq "ledger:state-malformed" "MALFORMED" \
    "$(hivemind_project_state_current "$bad_state_file")" "malformed state '$bad_state'"
  assert_eq "ledger:independence-status-good" "running" \
    "$(hivemind_project_run_status "$bad_state_file")" "good run.status despite bad state (independence)"
done

# state.current > 64 chars → MALFORMED (even though all-lowercase a-z0-9_).
long_state="$WORKDIR/long-state.json"
long_val="$(printf 'a%.0s' $(seq 1 65))"   # 65 lowercase 'a' chars
jq -n --arg s "$long_val" '{run:{status:"complete"},state:{current:$s}}' > "$long_state"
assert_eq "ledger:state-too-long" "MALFORMED" \
  "$(hivemind_project_state_current "$long_state")" "state.current 65 chars (>64 cap)"
# Exactly 64 chars must PASS (boundary).
ok_state="$WORKDIR/ok-state.json"
ok_val="$(printf 'a%.0s' $(seq 1 64))"
jq -n --arg s "$ok_val" '{run:{status:"complete"},state:{current:$s}}' > "$ok_state"
assert_eq "ledger:state-64-ok" "$ok_val" \
  "$(hivemind_project_state_current "$ok_state")" "state.current exactly 64 chars passes"

# Absent file → MISSING for both scalars.
assert_eq "ledger:absent-file-status" "MISSING" \
  "$(hivemind_project_run_status "$WORKDIR/does-not-exist.json")" "absent file run.status"
assert_eq "ledger:absent-file-state" "MISSING" \
  "$(hivemind_project_state_current "$WORKDIR/does-not-exist.json")" "absent file state.current"

# Present-but-UNREADABLE file → MALFORMED for both scalars (distinct from the absent-file
# MISSING case above). The wrapper passes its leading [ -f ] guard, then `cat` FAILS; the
# post-failure [ -e ] re-test confirms presence → MALFORMED, never MISSING. mode 000 does
# not restrict root, so guard the assertions.
if [ "$(id -u)" -ne 0 ]; then
  unreadable="$WORKDIR/unreadable.json"
  printf '{"run":{"status":"running"},"state":{"current":"plan"}}\n' > "$unreadable"
  chmod 000 "$unreadable"
  assert_eq "ledger:unreadable-status" "MALFORMED" \
    "$(hivemind_project_run_status "$unreadable")" "present-but-unreadable run.status → MALFORMED"
  assert_eq "ledger:unreadable-state" "MALFORMED" \
    "$(hivemind_project_state_current "$unreadable")" "present-but-unreadable state.current → MALFORMED"
  chmod 644 "$unreadable" 2>/dev/null || true
fi

# Field present in a parseable file but empty/absent → MISSING (distinct from MALFORMED).
empty_fields="$WORKDIR/empty-fields.json"
printf '{"run":{},"state":{}}\n' > "$empty_fields"
assert_eq "ledger:empty-status" "MISSING" \
  "$(hivemind_project_run_status "$empty_fields")" "absent run.status field → MISSING"
assert_eq "ledger:empty-state" "MISSING" \
  "$(hivemind_project_state_current "$empty_fields")" "absent state.current field → MISSING"

# Unparseable / torn JSON → MALFORMED for both scalars.
torn="$WORKDIR/torn.json"
printf '{"run":{"status":"run\n' > "$torn"   # truncated mid-object
assert_eq "ledger:torn-status" "MALFORMED" \
  "$(hivemind_project_run_status "$torn")" "torn JSON run.status"
assert_eq "ledger:torn-state" "MALFORMED" \
  "$(hivemind_project_state_current "$torn")" "torn JSON state.current"

# Each enum value round-trips.
for st in running complete blocked cancelled; do
  enum_file="$WORKDIR/enum-$st.json"
  printf '{"run":{"status":"%s"},"state":{"current":"plan"}}\n' "$st" > "$enum_file"
  assert_eq "ledger:enum-$st" "$st" \
    "$(hivemind_project_run_status "$enum_file")" "enum value $st"
done

# ── Section 3b: hivemind_read_confined_state_current — two-line confined read ────
echo ''
echo '=== ledger-project.sh: hivemind_read_confined_state_current (two-line confined read) ==='
#
# AUTHORITATIVE regression tests for the shared confined read primitive. This function is the
# SINGLE source of the 6-layer hardened confined read consumed by both spawn-brood and
# brood-status-project.sh. Each case builds a real temp worktree + ledger under WORKDIR and
# asserts the two-line output (line1=state.current, line2=run.status).
#
# Parse helper — safe under set -u: reads exactly two lines from the function's stdout.
# Usage: { IFS= read -r rcc_s; IFS= read -r rcc_r; } < <(hivemind_read_confined_state_current ...)
# then assert_eq on $rcc_s / $rcc_r.

# 3b-1: valid ledger — both scalars present and well-formed.
rcc1_wt="$WORKDIR/rcc1/checkout"
rcc1_run_id="2026-01-01T00-00-00Z--test"
rcc1_rel=".hivemind/runs/$rcc1_run_id/state.json"
mkdir -p "$rcc1_wt/.hivemind/runs/$rcc1_run_id"
printf '{"state":{"current":"implement_step"},"run":{"status":"running"}}\n' \
  > "$rcc1_wt/$rcc1_rel"
{ IFS= read -r rcc_s; IFS= read -r rcc_r; } \
  < <(hivemind_read_confined_state_current "$rcc1_wt" "$rcc1_rel")
assert_eq "rcc:valid-state"  "implement_step" "$rcc_s" "valid ledger: line1 = state.current"
assert_eq "rcc:valid-status" "running"        "$rcc_r" "valid ledger: line2 = run.status"

# 3b-2: absent leaf — no state.json written yet → MISSING / MISSING.
rcc2_wt="$WORKDIR/rcc2/checkout"
rcc2_run_id="2026-01-01T00-00-00Z--test"
rcc2_rel=".hivemind/runs/$rcc2_run_id/state.json"
mkdir -p "$rcc2_wt/.hivemind/runs/$rcc2_run_id"
# Do NOT create the leaf — child has not yet written its ledger.
{ IFS= read -r rcc_s; IFS= read -r rcc_r; } \
  < <(hivemind_read_confined_state_current "$rcc2_wt" "$rcc2_rel")
assert_eq "rcc:absent-state"  "MISSING" "$rcc_s" "absent leaf: line1 = MISSING"
assert_eq "rcc:absent-status" "MISSING" "$rcc_r" "absent leaf: line2 = MISSING"

# 3b-3: symlinked leaf — state.json is a symlink → MALFORMED / MALFORMED.
# hivemind_assert_file_contained fires [ -L ] on the leaf; any symlink leaf is rejected
# before the read (LAYER 1).
rcc3_wt="$WORKDIR/rcc3/checkout"
rcc3_ext="$WORKDIR/rcc3/external"
rcc3_run_id="2026-01-01T00-00-00Z--test"
rcc3_rel=".hivemind/runs/$rcc3_run_id/state.json"
mkdir -p "$rcc3_wt/.hivemind/runs/$rcc3_run_id" "$rcc3_ext"
printf '{"state":{"current":"implement_step"},"run":{"status":"running"}}\n' \
  > "$rcc3_ext/real-state.json"
ln -s "$rcc3_ext/real-state.json" "$rcc3_wt/$rcc3_rel"
{ IFS= read -r rcc_s; IFS= read -r rcc_r; } \
  < <(hivemind_read_confined_state_current "$rcc3_wt" "$rcc3_rel" 2>/dev/null)
assert_eq "rcc:symlink-leaf-state"  "MALFORMED" "$rcc_s" "symlinked leaf: line1 = MALFORMED"
assert_eq "rcc:symlink-leaf-status" "MALFORMED" "$rcc_r" "symlinked leaf: line2 = MALFORMED"

# 3b-4: NUL-bearing ledger — file exists, otherwise valid JSON, but contains a literal NUL byte.
# hivemind_path_has_nul fires at LAYER 4, before the $(...) read strips the NUL → MALFORMED.
rcc4_wt="$WORKDIR/rcc4/checkout"
rcc4_run_id="2026-01-01T00-00-00Z--test"
rcc4_rel=".hivemind/runs/$rcc4_run_id/state.json"
mkdir -p "$rcc4_wt/.hivemind/runs/$rcc4_run_id"
printf '{"state":{"current":"implement_step"},"run":{"status":"running"}}\000' \
  > "$rcc4_wt/$rcc4_rel"
{ IFS= read -r rcc_s; IFS= read -r rcc_r; } \
  < <(hivemind_read_confined_state_current "$rcc4_wt" "$rcc4_rel")
assert_eq "rcc:nul-ledger-state"  "MALFORMED" "$rcc_s" "NUL-bearing ledger: line1 = MALFORMED"
assert_eq "rcc:nul-ledger-status" "MALFORMED" "$rcc_r" "NUL-bearing ledger: line2 = MALFORMED"

# 3b-5: ancestor-symlink escape — a directory component of the ledger chain is a symlink that
# resolves outside the worktree. hivemind_assert_file_contained walks every existing ancestor
# and rejects on the first symlinked component (LAYER 1), so both scalars are MALFORMED.
# NOTE: faithfully constructing a post-read ITEM-4 ancestor-swap race in a unit test is
# impractical (it requires a concurrent writer between LAYER 1 and the cat). This case instead
# asserts the LAYER 1 pre-read ancestor-symlink containment-reject path, which is the structural
# defence (the ITEM-4 post-read check bounds the residual window that LAYER 1 cannot close).
rcc5_wt="$WORKDIR/rcc5/checkout"
rcc5_ext="$WORKDIR/rcc5/external"
rcc5_run_id="2026-01-01T00-00-00Z--test"
rcc5_rel=".hivemind/runs/$rcc5_run_id/state.json"
mkdir -p "$rcc5_wt" "$rcc5_ext/runs/$rcc5_run_id"
# .hivemind itself is a symlink to the external dir — every ancestor walk hits it and rejects.
ln -s "$rcc5_ext" "$rcc5_wt/.hivemind"
printf '{"state":{"current":"implement_step"},"run":{"status":"running"}}\n' \
  > "$rcc5_wt/$rcc5_rel"
{ IFS= read -r rcc_s; IFS= read -r rcc_r; } \
  < <(hivemind_read_confined_state_current "$rcc5_wt" "$rcc5_rel" 2>/dev/null)
assert_eq "rcc:ancestor-escape-state"  "MALFORMED" "$rcc_s" "ancestor symlink escape: line1 = MALFORMED"
assert_eq "rcc:ancestor-escape-status" "MALFORMED" "$rcc_r" "ancestor symlink escape: line2 = MALFORMED"

# 3b-6: present-but-unreadable leaf → MALFORMED / MALFORMED.
# Technique: place a DIRECTORY at the state.json path (not chmod 000, which is bypassed by
# root). `cat -- <dir>` fails (Is a directory), [ -e ] confirms presence → MALFORMED.
# This is root-safe: no filesystem permission required; a directory is never a regular file.
rcc6_wt="$WORKDIR/rcc6/checkout"
rcc6_run_id="2026-01-01T00-00-00Z--test"
rcc6_rel=".hivemind/runs/$rcc6_run_id/state.json"
# mkdir -p creates the full chain INCLUDING the leaf, making state.json itself a directory.
mkdir -p "$rcc6_wt/$rcc6_rel"
{ IFS= read -r rcc_s; IFS= read -r rcc_r; } \
  < <(hivemind_read_confined_state_current "$rcc6_wt" "$rcc6_rel" 2>/dev/null)
assert_eq "rcc:dir-leaf-state"  "MALFORMED" "$rcc_s" "dir-typed leaf (present-but-unreadable): line1 = MALFORMED"
assert_eq "rcc:dir-leaf-status" "MALFORMED" "$rcc_r" "dir-typed leaf (present-but-unreadable): line2 = MALFORMED"

# ── Section 4: NUL / control-byte rejection + single-document discipline (Codex #172) ──
echo ''
echo '=== NUL + control-byte + single-document (Codex #172 root cluster) ==='
#
# ROOT (documented at each fix site): bash command substitution `$(...)` SILENTLY STRIPS NUL
# bytes, so a value validated AFTER a `$(...)` round-trip differs from what jq produced. Defended
# at TWO layers: (1) FILE-LEVEL — reject any manifest/ledger file containing a LITERAL NUL byte
# before it is read into a shell var (hivemind_path_has_nul); (2) SCALAR-LEVEL — every jq field
# projection whose output bash consumes rejects a value containing ANY C0 control byte INSIDE jq
# (so a JSON ` ` escape jq -r would decode to a real NUL is caught while the bytes are intact).
# Plus: jq accepts a STREAM of documents, so shape validation now requires EXACTLY ONE document.

# ── 4a. hivemind_path_has_nul: byte-accurate literal-NUL detection ──
nul_file="$WORKDIR/has-nul.bin"
printf '{"run":{"status":"running"}}\000\n' > "$nul_file"   # literal NUL embedded via \000
clean_file="$WORKDIR/no-nul.json"
printf '{"run":{"status":"running"}}\n' > "$clean_file"
if hivemind_path_has_nul "$nul_file"; then
  pass "nul:detect-present" "hivemind_path_has_nul detects a literal NUL byte"
else
  failed "nul:detect-present" "hivemind_path_has_nul missed a literal NUL byte"
fi
if hivemind_path_has_nul "$clean_file"; then
  failed "nul:detect-absent" "hivemind_path_has_nul false-positived on a clean file"
else
  pass "nul:detect-absent" "hivemind_path_has_nul reports no NUL on a clean file"
fi

# ── 4b. Ledger wrapper: a ledger file with a LITERAL NUL → MALFORMED (both scalars) ──
# The on-disk JSON is otherwise valid; the trailing literal NUL would be stripped by the `$(...)`
# read, so the file-level guard must reject it as MALFORMED before any read.
nul_ledger="$WORKDIR/nul-ledger.json"
printf '{"run":{"status":"running"},"state":{"current":"plan"}}\000' > "$nul_ledger"
assert_eq "ledger:literal-nul-status" "MALFORMED" \
  "$(hivemind_project_run_status "$nul_ledger")" "literal-NUL ledger run.status → MALFORMED"
assert_eq "ledger:literal-nul-state" "MALFORMED" \
  "$(hivemind_project_state_current "$nul_ledger")" "literal-NUL ledger state.current → MALFORMED"

# ── 4c. Scalar-level: a JSON ` ` ESCAPE (valid JSON) → field projects EMPTY, not stripped ──
# The FILE has no literal NUL (the escape is 6 ASCII bytes \u0000), so the file-level check misses
# it; the in-jq control-byte gate must reject it so bash never receives a NUL-stripped value. The
# branch value `feature/api\u0000-slice` must NOT project as the trusted-looking `feature/api-slice`.
nulesc_content="$(printf '%s' '{"strains":[{"name":"api","branch":"feature/api\u0000-slice","worktree_path":"/repo/wt","status":"running"}]}')"
assert_eq "scalar:nul-escape-branch-empty" "" \
  "$(hivemind_manifest_field_at "$nulesc_content" 0 "branch")" "JSON \\u0000 escape in branch → field_at empty (NOT control-stripped)"
# A clean branch on the same shape still projects.
clean_content="$(printf '%s' '{"strains":[{"name":"api","branch":"feature/api-slice","worktree_path":"/repo/wt","status":"running"}]}')"
assert_eq "scalar:clean-branch-projects" "feature/api-slice" \
  "$(hivemind_manifest_field_at "$clean_content" 0 "branch")" "clean branch still projects via field_at"
# A mid-range control escape (TAB, \u0009) is also rejected — proves the whole C0 range, not just NUL.
tabesc_content="$(printf '%s' '{"strains":[{"name":"api","branch":"feat\u0009x","worktree_path":"/repo/wt","status":"running"}]}')"
assert_eq "scalar:tab-escape-branch-empty" "" \
  "$(hivemind_manifest_field_at "$tabesc_content" 0 "branch")" "JSON \\u0009 (TAB) escape in branch → field_at empty"
# A scalar NUL escape in a ledger state.current → MALFORMED (the in-jq charset gate sees it intact).
nulesc_state="$(printf '%s' '{"run":{"status":"running"},"state":{"current":"impl\u0000ement"}}')"
assert_eq "scalar:nul-escape-state-malformed" "MALFORMED" \
  "$(hivemind_project_state_current_content "$nulesc_state")" "JSON \\u0000 escape in state.current → MALFORMED"

# ── 4d. Single-document discipline: a multi-document file FAILS shape validation ──
# jq accepts a STREAM of concatenated JSON documents; shape validation must require EXACTLY ONE.
# Two valid manifest objects concatenated → length>1 → rejected (would otherwise project as empty).
multidoc="$(printf '%s\n%s\n' '{"strains":[{"name":"api"}]}' '{"strains":[{"name":"web"}]}')"
if hivemind_manifest_validate_shape "$multidoc"; then
  failed "multidoc:reject" "two concatenated manifest documents wrongly passed shape validation"
else
  pass "multidoc:reject" "two concatenated manifest documents rejected by shape validation (single-document required)"
fi
# A single valid document still passes (regression guard for the slurp predicate).
if hivemind_manifest_validate_shape "$V3_CONTENT"; then
  pass "multidoc:single-ok" "single valid manifest document still passes shape validation after slurp"
else
  failed "multidoc:single-ok" "slurp predicate wrongly rejected a single valid manifest document"
fi
# count + field_at over the single document remain correct under the slurp (regression).
assert_eq "multidoc:single-count" "1" \
  "$(hivemind_manifest_strain_count_snapshot "$V3_CONTENT")" "slurp count over single document"
assert_eq "multidoc:single-field" "feature/api-slice" \
  "$(hivemind_manifest_field_at "$V3_CONTENT" 0 "branch")" "slurp field_at over single document"

# ── Section 5: #168 brood-namespacing + #178 hardening contract regressions ──────
echo ''
echo '=== #168/#178: floor-only path class + content projectors + field_at exit-code contract ==='

# ── 5a. path class is FLOOR-ONLY (#177/#168): formerly-rejected inert bytes now PASS ──
# allowlist.sh hivemind_assert_path is the FLOOR-ONLY class: any byte that survives the shared
# security floor is accepted as quoted path data. The bytes `+ @ , %` were rejected by the OLD
# per-byte charset enumeration (the #177 whack-a-mole treadmill); under floor-only they must now
# PASS. This is the doctrine guard — a future re-add of per-byte charset rules to the path class
# would fail these.
for v in "/a/b+c/wt" "/a/b@c/wt" "/a/b,c/wt" "/a/b%c/wt" "/home/me/a+b@c,d%e/wt"; do
  if hivemind_assert_path "$v"; then
    pass "path:floor-only-accept" "floor-only path accepts formerly-rejected inert byte: '$v'"
  else
    failed "path:floor-only-accept" "floor-only path wrongly rejected inert-byte path '$v' (per-byte charset re-added?)"
  fi
done
# The floor itself is NEVER relaxed by floor-only: command-sub ($/backtick), '..', leading '-',
# framing bytes (TAB/LF/CR), and empty must STILL reject under the path class.
ptab=$'\t'; pnl=$'\n'; pcr=$'\r'
for v in "" "-x" "/a/../b" "a\$b" "a\`b" "a${ptab}b" "a${pnl}b" "a${pcr}b"; do
  if hivemind_assert_path "$v"; then
    failed "path:floor-still-rejects" "floor-only path accepted a value the floor must reject: '$v'"
  else
    pass "path:floor-still-rejects" "floor still rejects under path class: '$v'"
  fi
done
# identifier remains STRICT: the same inert bytes the path class now accepts are STILL rejected by
# the identifier class (no floor-only loosening of the strict class).
for v in "a+b" "a@b" "a,b" "a%b"; do
  if hivemind_assert_identifier "$v"; then
    failed "id:still-strict" "identifier wrongly accepted an inert byte (must stay strict): '$v'"
  else
    pass "id:still-strict" "identifier stays strict; rejects inert byte: '$v'"
  fi
done
# presentation STILL rejects the Markdown-cell delimiter `|` by construction (not in the
# positive allowlist; render-boundary owns the escape).
if hivemind_assert_presentation 'api|web'; then
  failed "pres:pipe-rejected" "presentation wrongly accepted '|' (Markdown-cell injector)"
else
  pass "pres:pipe-rejected" "presentation rejects '|' by construction"
fi

# ── 5b. #178 F1: content projectors require EXACTLY ONE document ──────────────────
# The _content projectors SLURP and require length==1. TWO concatenated valid ledger objects →
# MALFORMED (both run.status + state.current), because the embedded newline of a two-document
# emission would corrupt the one-line STRAIN frame. Single valid → value. Empty → MISSING.
two_ledgers="$(printf '%s\n%s\n' \
  '{"run":{"status":"running"},"state":{"current":"plan"}}' \
  '{"run":{"status":"complete"},"state":{"current":"review"}}')"
assert_eq "f1:multidoc-run-status" "MALFORMED" \
  "$(hivemind_project_run_status_content "$two_ledgers")" "two concatenated ledger docs → run.status MALFORMED"
assert_eq "f1:multidoc-state-current" "MALFORMED" \
  "$(hivemind_project_state_current_content "$two_ledgers")" "two concatenated ledger docs → state.current MALFORMED"
# A SINGLE valid document still projects its scalars (regression guard for the slurp predicate).
one_ledger='{"run":{"status":"blocked"},"state":{"current":"implement_step"}}'
assert_eq "f1:single-run-status" "blocked" \
  "$(hivemind_project_run_status_content "$one_ledger")" "single ledger doc → run.status value"
assert_eq "f1:single-state-current" "implement_step" \
  "$(hivemind_project_state_current_content "$one_ledger")" "single ledger doc → state.current value"
# Empty content → MISSING (nothing to report), for both scalars.
assert_eq "f1:empty-run-status" "MISSING" \
  "$(hivemind_project_run_status_content "")" "empty content → run.status MISSING"
assert_eq "f1:empty-state-current" "MISSING" \
  "$(hivemind_project_state_current_content "")" "empty content → state.current MISSING"

# ── 5c. #178 F3: non-string manifest scalars → field_at exit 2 (MALFORMED), NOT coerced ──
# Every supported manifest field is a STRING in a well-formed manifest. A present NON-STRING scalar
# (branch:123, tmux_session:true, status:123) is a tamper indicator: hivemind_manifest_field_at must
# exit 2 (the caller renders MALFORMED) and emit NOTHING — never coerce 123→"123" / true→"true".
# We assert the EXIT CODE explicitly (the contract is out-of-band) AND that stdout is empty.
nonstring_branch='{"strains":[{"name":"api","branch":123,"tmux_session":"brood-api","status":"running"}]}'
out="$(hivemind_manifest_field_at "$nonstring_branch" 0 "branch")"; rc=$?
assert_eq "f3:branch-number-rc" "2" "$rc" "branch:123 → field_at exit 2 (MALFORMED, not coerced)"
assert_eq "f3:branch-number-empty" "" "$out" "branch:123 → field_at emits nothing (no coercion to \"123\")"
nonstring_tmux='{"strains":[{"name":"api","branch":"strain/brood-x/api","tmux_session":true,"status":"running"}]}'
out="$(hivemind_manifest_field_at "$nonstring_tmux" 0 "tmux_session")"; rc=$?
assert_eq "f3:tmux-bool-rc" "2" "$rc" "tmux_session:true → field_at exit 2 (MALFORMED, not coerced)"
assert_eq "f3:tmux-bool-empty" "" "$out" "tmux_session:true → field_at emits nothing (no coercion to \"true\")"
nonstring_status='{"strains":[{"name":"api","branch":"strain/brood-x/api","tmux_session":"brood-api","status":123}]}'
out="$(hivemind_manifest_field_at "$nonstring_status" 0 "status")"; rc=$?
assert_eq "f3:status-number-rc" "2" "$rc" "status:123 → field_at exit 2 (MALFORMED, not coerced)"
assert_eq "f3:status-number-empty" "" "$out" "status:123 → field_at emits nothing (no coercion)"

# ── 5d. #178 F2: field_at exit-code contract — present/absent/rejected are DISTINCT ──
# The exit-code contract: 0 = present+valid (value on stdout), 1 = ABSENT (→MISSING),
# 2 = present-but-INVALID (→MALFORMED). A REJECTED value (control byte / multi-document) is exit 2
# and must NEVER be collapsed into the absent exit 1. We assert the exit codes EXPLICITLY.
# Present + valid → exit 0, value on stdout.
valid_field='{"strains":[{"name":"api","branch":"strain/brood-x/api","tmux_session":"brood-api","status":"running"}]}'
out="$(hivemind_manifest_field_at "$valid_field" 0 "branch")"; rc=$?
assert_eq "f2:present-valid-rc" "0" "$rc" "present+valid branch → field_at exit 0"
assert_eq "f2:present-valid-value" "strain/brood-x/api" "$out" "present+valid branch → value on stdout"
# ABSENT field (key missing) → exit 1 (MISSING), nothing on stdout.
absent_field='{"strains":[{"name":"api","tmux_session":"brood-api","status":"running"}]}'
out="$(hivemind_manifest_field_at "$absent_field" 0 "branch")"; rc=$?
assert_eq "f2:absent-rc" "1" "$rc" "absent branch key → field_at exit 1 (MISSING)"
assert_eq "f2:absent-empty" "" "$out" "absent branch key → nothing on stdout"
# Explicit JSON null → exit 1 (MISSING).
null_field='{"strains":[{"name":"api","branch":null,"tmux_session":"brood-api","status":"running"}]}'
out="$(hivemind_manifest_field_at "$null_field" 0 "branch")"; rc=$?
assert_eq "f2:null-rc" "1" "$rc" "branch:null → field_at exit 1 (MISSING)"
# Empty string → exit 1 (MISSING) per the contract (absent-or-empty).
emptystr_field='{"strains":[{"name":"api","branch":"","tmux_session":"brood-api","status":"running"}]}'
out="$(hivemind_manifest_field_at "$emptystr_field" 0 "branch")"; rc=$?
assert_eq "f2:emptystr-rc" "1" "$rc" "branch:\"\" → field_at exit 1 (MISSING)"
# REJECTED: a JSON control-byte ESCAPE (valid JSON; the FILE bytes hold the literal 6-char
# ASCII escape \\u0000, no real NUL) -> exit 2. jq -r would decode \\u0000 to a real NUL that
# $(...) would strip; the in-jq [[:cntrl:]] gate rejects it INSIDE jq while the bytes are intact.
# This rejected value is exit 2 -- NEVER collapsed into the absent exit 1. printf %b is NOT used:
# the \\u in the double-quoted format emits a literal backslash+u so jq receives the JSON escape
# and decodes it at projection time.
ctrl_field="$(printf '{"strains":[{"name":"api","branch":"strain/brood-x\\u0000api","tmux_session":"brood-api","status":"running"}]}')"
out="$(hivemind_manifest_field_at "$ctrl_field" 0 "branch")"; rc=$?
assert_eq "f2:control-escape-rc" "2" "$rc" "branch with u0000 control escape -> field_at exit 2 (REJECTED, not MISSING)"
assert_eq "f2:control-escape-empty" "" "$out" "control-escape branch -> nothing on stdout (never the NUL-stripped token)"
# REJECTED: a multi-document snapshot (length != 1) → exit 2 (not exit 1).
multidoc_field="$(printf '%s\n%s\n' \
  '{"strains":[{"name":"api","branch":"strain/brood-x/api","tmux_session":"brood-api","status":"running"}]}' \
  '{"strains":[{"name":"web","branch":"strain/brood-x/web","tmux_session":"brood-web","status":"running"}]}')"
out="$(hivemind_manifest_field_at "$multidoc_field" 0 "branch")"; rc=$?
assert_eq "f2:multidoc-rc" "2" "$rc" "multi-document snapshot → field_at exit 2 (REJECTED, not MISSING)"
# REGRESSION: rejected (exit 2) is distinct from absent (exit 1) — assert they differ on the same field.
if [ "$rc" -ne 1 ]; then
  pass "f2:rejected-not-collapsed" "a rejected value's exit code (2) is never the absent exit code (1)"
else
  failed "f2:rejected-not-collapsed" "a rejected value collapsed into the absent exit code (1)"
fi

# ── Section 6: brood-status-derive.sh — pure status derivation + aggregation (#186) ─
echo ''
echo '=== brood-status-derive.sh: status derivation, bucket classification, aggregation (#186) ==='
#
# PURE determinism coverage for the collection loop's derivation. This is the PRIMARY test of the
# rule table ported out of SKILL.md steps 2..5 — it runs with no tmux/gh/git, exercising every
# row of the failed-precedence + tmux x PR table, the bucket classifier, and both aggregators.

# ── 6a. hivemind_derive_strain_status — the FULL rule table ──
# SIGNATURE (issue #213, 6-arity): <manifest_status> <session_alive> <pr_state> <pr_number>
#   <state_current> <run_status>. The last two are tier-3 child-ledger started-evidence tokens; an
# alive session derives `running` ONLY with a present, non-MISSING/non-MALFORMED state.current,
# otherwise it demotes to the transient `starting` status. The dead/failed rows ignore them.
STARTED="implement_step"   # a present, non-sentinel state.current = ground-truth started evidence.

# failed-precedence (manifest_status=failed beats tmux): alive vs dead. Ledger tokens are ignored
# under failed-precedence (use MISSING to prove they cannot resurrect a failed strain to starting).
assert_eq "derive:failed-alive" "failed (injection failed; session alive for debug)" \
  "$(hivemind_derive_strain_status failed 1 none "" MISSING MISSING)" "failed + alive -> injection-failed debug"
assert_eq "derive:failed-dead" "failed (session ended, no PR)" \
  "$(hivemind_derive_strain_status failed 0 none "" MISSING MISSING)" "failed + dead -> session ended"
# failed-precedence holds even when a PR is open (manifest failed wins over the table).
assert_eq "derive:failed-alive-pr-open" "failed (injection failed; session alive for debug)" \
  "$(hivemind_derive_strain_status failed 1 open 7 MISSING MISSING)" "failed + alive ignores PR state"

# tmux x PR observable table (manifest_status NOT failed; use the literal status spawn-brood writes).
# Alive rows carry started-evidence (STARTED) so they derive `running` (not the demoted `starting`).
assert_eq "derive:alive-none" "running" \
  "$(hivemind_derive_strain_status running 1 none "" "$STARTED" running)" "alive + started + none -> running"
assert_eq "derive:alive-open" "running (PR #42 open)" \
  "$(hivemind_derive_strain_status running 1 open 42 "$STARTED" running)" "alive + started + open -> running (PR #N open)"
assert_eq "derive:dead-merged" "complete" \
  "$(hivemind_derive_strain_status running 0 merged 13 "$STARTED" complete)" "dead + merged -> complete"
assert_eq "derive:dead-open" "blocked (session ended, PR #99 still open)" \
  "$(hivemind_derive_strain_status running 0 open 99 "$STARTED" running)" "dead + open -> blocked"
assert_eq "derive:dead-none" "failed (session ended, no PR)" \
  "$(hivemind_derive_strain_status running 0 none "" "$STARTED" running)" "dead + none -> failed"

# unknown-PR handling: gh failed. Treated like none for derivation (the cell shows unknown via the
# renderer; status derives from tmux + best-known PR). alive+unknown -> running; dead+unknown -> failed.
assert_eq "derive:alive-unknown" "running" \
  "$(hivemind_derive_strain_status running 1 unknown "" "$STARTED" running)" "alive + started + unknown PR -> running (unknown ~ none)"
assert_eq "derive:dead-unknown" "failed (session ended, no PR)" \
  "$(hivemind_derive_strain_status running 0 unknown "" "$STARTED" running)" "dead + unknown PR -> failed (unknown ~ none)"

# ── 6a-bis. started-evidence gate (issue #213): alive session demotes to `starting` without it ──
STARTING="starting (session alive, workflow not yet started)"
# alive + started-evidence-present -> running (the positive control; mirrors derive:alive-none).
assert_eq "derive:alive-started-running" "running" \
  "$(hivemind_derive_strain_status running 1 none "" "$STARTED" running)" "alive + present state.current -> running"
# alive + MISSING state.current (child pasted but never submitted; no ledger) -> starting, NOT running.
assert_eq "derive:alive-missing-starting" "$STARTING" \
  "$(hivemind_derive_strain_status running 1 none "" MISSING MISSING)" "alive + MISSING state.current -> starting (not running)"
# alive + MALFORMED state.current (fail-closed) -> starting, NOT running.
assert_eq "derive:alive-malformed-starting" "$STARTING" \
  "$(hivemind_derive_strain_status running 1 none "" MALFORMED MISSING)" "alive + MALFORMED state.current -> starting (fail-closed, not running)"
# alive + empty state.current -> starting (defensive: empty is treated as no started-evidence).
assert_eq "derive:alive-empty-starting" "$STARTING" \
  "$(hivemind_derive_strain_status running 1 none "" "" "")" "alive + empty state.current -> starting"
# The started-evidence gate does NOT promote a DEAD session: dead+merged stays complete even with no
# state.current (the gate only DEMOTES alive sessions; it never touches the dead branch).
assert_eq "derive:dead-merged-no-evidence" "complete" \
  "$(hivemind_derive_strain_status running 0 merged 13 MISSING MISSING)" "dead + merged + MISSING -> complete (gate never touches dead branch)"
# alive + started-evidence + open PR -> running (PR #N open), NOT starting (evidence present).
assert_eq "derive:alive-started-open" "running (PR #7 open)" \
  "$(hivemind_derive_strain_status running 1 open 7 "$STARTED" running)" "alive + started + open -> running (PR #N open)"

# ── legacy no-pointer fall-through: NO_LEDGER_POINTER bypasses the started-evidence gate ──
# A legacy manifest has no run.suggested_id, so the projector emits NO_LEDGER_POINTER for
# state.current. Started-evidence is structurally unavailable, so the gate must NOT apply: an alive
# legacy strain keeps its observable status. This is the regression assertion.
assert_eq "derive:alive-nopointer-running" "running" \
  "$(hivemind_derive_strain_status running 1 none "" NO_LEDGER_POINTER MISSING)" "alive + NO_LEDGER_POINTER + no PR -> running (legacy fall-through, NOT starting)"
# alive legacy strain + open PR -> running (PR #N open) (gate still bypassed; observable status kept).
assert_eq "derive:alive-nopointer-open" "running (PR #7 open)" \
  "$(hivemind_derive_strain_status running 1 open 7 NO_LEDGER_POINTER MISSING)" "alive + NO_LEDGER_POINTER + open PR -> running (PR #N open)"
# dead legacy strain (session never resurrected) -> failed terminal; NO_LEDGER_POINTER never touches the dead branch.
assert_eq "derive:dead-nopointer-failed" "failed (session ended, no PR)" \
  "$(hivemind_derive_strain_status running 0 none "" NO_LEDGER_POINTER MISSING)" "dead + NO_LEDGER_POINTER + no PR -> failed (session ended, no PR)"

# ── 6b. hivemind_classify_status_bucket — every derived status maps to a bucket ──
assert_eq "bucket:complete" "complete" \
  "$(hivemind_classify_status_bucket "complete")" "complete -> complete bucket"
assert_eq "bucket:running" "running" \
  "$(hivemind_classify_status_bucket "running")" "running -> running bucket"
assert_eq "bucket:running-pr" "running" \
  "$(hivemind_classify_status_bucket "running (PR #42 open)")" "running (PR #N open) -> running bucket"
assert_eq "bucket:blocked" "blocked_failed" \
  "$(hivemind_classify_status_bucket "blocked (session ended, PR #99 still open)")" "blocked -> blocked_failed"
assert_eq "bucket:failed" "blocked_failed" \
  "$(hivemind_classify_status_bucket "failed (session ended, no PR)")" "failed -> blocked_failed"
assert_eq "bucket:failed-debug" "blocked_failed" \
  "$(hivemind_classify_status_bucket "failed (injection failed; session alive for debug)")" "failed-debug -> blocked_failed"
# issue #213: the new `starting` status buckets OUT of running and is NOT complete -> blocked_failed,
# so the three-bucket summary keeps summing to total.
assert_eq "bucket:starting" "blocked_failed" \
  "$(hivemind_classify_status_bucket "starting (session alive, workflow not yet started)")" "starting -> blocked_failed (out of running, not complete)"
# Conservative default: an unexpected string counts against completion, never silently dropped.
assert_eq "bucket:unexpected" "blocked_failed" \
  "$(hivemind_classify_status_bucket "weird")" "unexpected status -> blocked_failed (conservative)"

# ── 6c. hivemind_aggregate_brood_summary — per-brood {complete,running,blocked_failed,total} ──
# Zero strains (empty brood) -> all zero.
assert_eq "brood-agg:empty" "0 0 0 0" \
  "$(hivemind_aggregate_brood_summary)" "no buckets -> 0 0 0 0"
# Mixed: 2 complete, 1 running, 2 blocked_failed -> total 5.
assert_eq "brood-agg:mixed" "2 1 2 5" \
  "$(hivemind_aggregate_brood_summary complete running complete blocked_failed blocked_failed)" "mixed buckets"
# All complete.
assert_eq "brood-agg:all-complete" "3 0 0 3" \
  "$(hivemind_aggregate_brood_summary complete complete complete)" "all complete"
# An unrecognized bucket token counts into blocked_failed (never dropped from total).
assert_eq "brood-agg:unknown-bucket" "1 0 1 2" \
  "$(hivemind_aggregate_brood_summary complete bogus)" "unknown bucket -> blocked_failed, still counted"
# issue #213: a `starting` strain (classified blocked_failed) is counted in total, so the summary
# still sums (1 complete + 1 running + 2 blocked_failed = 4). Proves no strain is dropped.
assert_eq "brood-agg:with-starting" "1 1 2 4" \
  "$(hivemind_aggregate_brood_summary complete running blocked_failed blocked_failed)" "starting bucketed blocked_failed -> summary sums to total"

# ── 6d. hivemind_aggregate_global — {total_broods,unreadable,complete,total_strains} ──
# Records are "<is_unreadable>:<complete>:<total>".
# Zero broods (No broods found) -> all zero.
assert_eq "global-agg:empty" "0 0 0 0" \
  "$(hivemind_aggregate_global)" "no records -> 0 0 0 0"
# Single ok brood: 2 of 3 complete.
assert_eq "global-agg:single" "1 0 2 3" \
  "$(hivemind_aggregate_global "0:2:3")" "single brood 2/3 complete"
# Multiple broods + one unreadable: 3 broods, 1 unreadable, complete 2+1, strains 3+2 (unreadable=0/0).
assert_eq "global-agg:multi-with-unreadable" "3 1 3 5" \
  "$(hivemind_aggregate_global "0:2:3" "0:1:2" "1:0:0")" "3 broods (1 unreadable); 3 of 5 complete"
# All unreadable -> total_broods counts them, unreadable counts them, zero strains/complete.
assert_eq "global-agg:all-unreadable" "2 2 0 0" \
  "$(hivemind_aggregate_global "1:0:0" "1:0:0")" "two unreadable broods -> 2 broods, 2 unreadable, 0/0"

# ── Section 7: containment.sh ───────────────────────────────────────────────────
echo ''
echo '=== containment.sh: hivemind_assert_contained / _file_contained / _inputs_contained ==='
#
# PURE BASH — no jq/tmux/claude/git required. Every fixture is a real-disk dir/symlink tree
# built under WORKDIR and cleaned up by the existing EXIT trap. Each case gets its OWN
# per-case subdir so fixtures never leak between cases.

# ── 7a. hivemind_assert_contained — dir-chain depth-completeness ─────────────────

# Helper: compute the canonical path for a directory that exists on disk.
# Usage: canon_dir <dir>
canon_dir() { cd "$1" 2>/dev/null && pwd -P; }

# 7a-1: nonexistent leaf chain inside a real checkout → accept.
c7a1="$WORKDIR/c7a1/checkout"
mkdir -p "$c7a1"
c7a1_root="$(canon_dir "$c7a1")"
run_id_7a1="2026-01-01T00-00-00Z--run1"
c7a1_out="$(hivemind_assert_contained "$c7a1" ".hivemind/runs/$run_id_7a1")"
c7a1_rc=$?
assert_eq "c7a:nonexistent-leaf-rc" "0" "$c7a1_rc" "nonexistent leaf chain → return 0"
assert_eq "c7a:nonexistent-leaf-root" "$c7a1_root" "$c7a1_out" "nonexistent leaf chain → echoes canonical root"

# 7a-2: partial ancestors exist (mkdir .hivemind/runs), leaf absent → accept.
c7a2="$WORKDIR/c7a2/checkout"
mkdir -p "$c7a2/.hivemind/runs"
c7a2_root="$(canon_dir "$c7a2")"
c7a2_out="$(hivemind_assert_contained "$c7a2" ".hivemind/runs/run-leaf-absent")"
c7a2_rc=$?
assert_eq "c7a:partial-ancestors-rc" "0" "$c7a2_rc" "partial ancestors real, leaf absent → return 0"
assert_eq "c7a:partial-ancestors-root" "$c7a2_root" "$c7a2_out" "partial ancestors real → echoes canonical root"

# 7a-3: leaf-depth symlink — .hivemind/runs is real, leaf is a symlink to external dir → reject.
c7a3="$WORKDIR/c7a3/checkout"
c7a3_ext="$WORKDIR/c7a3/external"
mkdir -p "$c7a3/.hivemind/runs" "$c7a3_ext"
ln -s "$c7a3_ext" "$c7a3/.hivemind/runs/symlinked-run"
c7a3_out="$(hivemind_assert_contained "$c7a3" ".hivemind/runs/symlinked-run" 2>/dev/null)"
c7a3_rc=$?
if [ "$c7a3_rc" -ne 0 ]; then
  pass "c7a:leaf-symlink-reject" "symlinked leaf → non-zero return"
else
  failed "c7a:leaf-symlink-reject" "symlinked leaf must reject; got return 0"
fi

# 7a-4: ancestor-depth symlink — .hivemind itself is a symlink to external dir → reject.
c7a4="$WORKDIR/c7a4/checkout"
c7a4_ext="$WORKDIR/c7a4/external"
mkdir -p "$c7a4" "$c7a4_ext"
ln -s "$c7a4_ext" "$c7a4/.hivemind"
c7a4_out="$(hivemind_assert_contained "$c7a4" ".hivemind/runs/any-run" 2>/dev/null)"
c7a4_rc=$?
if [ "$c7a4_rc" -ne 0 ]; then
  pass "c7a:ancestor-symlink-reject" "symlinked ancestor .hivemind → non-zero return"
else
  failed "c7a:ancestor-symlink-reject" "symlinked ancestor .hivemind must reject; got return 0"
fi

# 7a-5: deepest-existing prefix resolves outside root via symlinked component → reject.
# .hivemind/runs is real but symlinked TO the external dir, so canonicalization of that
# prefix yields a path outside the checkout.
c7a5="$WORKDIR/c7a5/checkout"
c7a5_ext="$WORKDIR/c7a5/external"
mkdir -p "$c7a5/.hivemind" "$c7a5_ext"
ln -s "$c7a5_ext" "$c7a5/.hivemind/runs"
c7a5_out="$(hivemind_assert_contained "$c7a5" ".hivemind/runs/some-run" 2>/dev/null)"
c7a5_rc=$?
if [ "$c7a5_rc" -ne 0 ]; then
  pass "c7a:outside-prefix-reject" "prefix resolves outside checkout → non-zero return"
else
  failed "c7a:outside-prefix-reject" "prefix outside checkout must reject; got return 0"
fi

# 7a-6: sibling-prefix .hivemind-evil is a real dir and must be independently contained
# (trailing-slash guard prevents .hivemind-evil from prefix-matching .hivemind).
c7a6="$WORKDIR/c7a6/checkout"
mkdir -p "$c7a6/.hivemind-evil"
c7a6_root="$(canon_dir "$c7a6")"
c7a6_out="$(hivemind_assert_contained "$c7a6" ".hivemind-evil/data")"
c7a6_rc=$?
assert_eq "c7a:sibling-prefix-rc" "0" "$c7a6_rc" "sibling-prefix .hivemind-evil real dir → accept"
assert_eq "c7a:sibling-prefix-root" "$c7a6_root" "$c7a6_out" "sibling-prefix → echoes canonical root"
# Also confirm that a SYMLINKED .hivemind-evil rejects independently (no bleed from .hivemind).
c7a6_ext="$WORKDIR/c7a6/external"
mkdir -p "$c7a6_ext"
ln -s "$c7a6_ext" "$c7a6/.hivemind-evil-link"
c7a6b_out="$(hivemind_assert_contained "$c7a6" ".hivemind-evil-link/data" 2>/dev/null)"
c7a6b_rc=$?
if [ "$c7a6b_rc" -ne 0 ]; then
  pass "c7a:sibling-symlinked-reject" "symlinked sibling .hivemind-evil-link → non-zero return"
else
  failed "c7a:sibling-symlinked-reject" "symlinked sibling must reject independently; got return 0"
fi

# 7a-7: un-canonicalizable root (raw_repo_root does not exist) → non-zero, empty stdout.
c7a7_out="$(hivemind_assert_contained "$WORKDIR/c7a7/does-not-exist" ".hivemind/runs/x" 2>/dev/null)"
c7a7_rc=$?
if [ "$c7a7_rc" -ne 0 ]; then
  pass "c7a:bad-root-rc" "non-existent root → non-zero return"
else
  failed "c7a:bad-root-rc" "non-existent root must reject; got return 0"
fi
assert_eq "c7a:bad-root-empty-stdout" "" "$c7a7_out" "non-existent root → empty stdout"

# ── 7b. hivemind_assert_file_contained — regular-or-absent leaf ──────────────────

# 7b-1: non-existent leaf, parent dirs real → accept.
c7b1="$WORKDIR/c7b1/checkout"
mkdir -p "$c7b1/.hivemind/brood"
c7b1_root="$(canon_dir "$c7b1")"
c7b1_out="$(hivemind_assert_file_contained "$c7b1" ".hivemind/brood/task.md")"
c7b1_rc=$?
assert_eq "c7b:nonexistent-leaf-rc" "0" "$c7b1_rc" "file: non-existent leaf → return 0"
assert_eq "c7b:nonexistent-leaf-root" "$c7b1_root" "$c7b1_out" "file: non-existent leaf → canonical root"

# 7b-2: regular-file leaf exists → accept.
c7b2="$WORKDIR/c7b2/checkout"
mkdir -p "$c7b2/.hivemind/brood"
: > "$c7b2/.hivemind/brood/task.md"
c7b2_root="$(canon_dir "$c7b2")"
c7b2_out="$(hivemind_assert_file_contained "$c7b2" ".hivemind/brood/task.md")"
c7b2_rc=$?
assert_eq "c7b:regular-file-rc" "0" "$c7b2_rc" "file: regular-file leaf → return 0"
assert_eq "c7b:regular-file-root" "$c7b2_root" "$c7b2_out" "file: regular-file leaf → canonical root"

# 7b-3: single-component leaf (bare filename at checkout root, nonexistent) → accept.
c7b3="$WORKDIR/c7b3/checkout"
mkdir -p "$c7b3"
c7b3_root="$(canon_dir "$c7b3")"
c7b3_out="$(hivemind_assert_file_contained "$c7b3" "task.md")"
c7b3_rc=$?
assert_eq "c7b:single-component-rc" "0" "$c7b3_rc" "file: single-component nonexistent leaf → return 0"
assert_eq "c7b:single-component-root" "$c7b3_root" "$c7b3_out" "file: single-component → canonical root"

# 7b-4: symlink leaf pointing at a non-existent target (dangling) → reject.
c7b4="$WORKDIR/c7b4/checkout"
mkdir -p "$c7b4/.hivemind/brood"
ln -s "$WORKDIR/c7b4/nowhere" "$c7b4/.hivemind/brood/task.md"
c7b4_out="$(hivemind_assert_file_contained "$c7b4" ".hivemind/brood/task.md" 2>/dev/null)"
c7b4_rc=$?
if [ "$c7b4_rc" -ne 0 ]; then
  pass "c7b:dangling-symlink-reject" "file: dangling symlink leaf → non-zero return"
else
  failed "c7b:dangling-symlink-reject" "file: dangling symlink leaf must reject; got return 0"
fi

# 7b-5: directory leaf — leaf path is a directory → reject.
c7b5="$WORKDIR/c7b5/checkout"
mkdir -p "$c7b5/.claude/settings.local.json"
c7b5_out="$(hivemind_assert_file_contained "$c7b5" ".claude/settings.local.json" 2>/dev/null)"
c7b5_rc=$?
if [ "$c7b5_rc" -ne 0 ]; then
  pass "c7b:directory-leaf-reject" "file: directory leaf → non-zero return"
else
  failed "c7b:directory-leaf-reject" "file: directory leaf must reject; got return 0"
fi

# 7b-6: FIFO leaf — gated on mkfifo availability (skip if absent).
c7b6="$WORKDIR/c7b6/checkout"
mkdir -p "$c7b6/.hivemind/brood"
if command -v mkfifo >/dev/null 2>&1; then
  mkfifo "$c7b6/.hivemind/brood/task.md"
  c7b6_out="$(hivemind_assert_file_contained "$c7b6" ".hivemind/brood/task.md" 2>/dev/null)"
  c7b6_rc=$?
  if [ "$c7b6_rc" -ne 0 ]; then
    pass "c7b:fifo-leaf-reject" "file: FIFO leaf → non-zero return"
  else
    failed "c7b:fifo-leaf-reject" "file: FIFO leaf must reject; got return 0"
  fi
else
  pass "c7b:fifo-leaf-reject" "file: FIFO leaf test skipped (mkfifo absent)"
fi

# 7b-7: symlinked-parent chain — .hivemind symlinked, leaf .hivemind/brood/task.md → reject.
c7b7="$WORKDIR/c7b7/checkout"
c7b7_ext="$WORKDIR/c7b7/external"
mkdir -p "$c7b7" "$c7b7_ext/brood"
ln -s "$c7b7_ext" "$c7b7/.hivemind"
c7b7_out="$(hivemind_assert_file_contained "$c7b7" ".hivemind/brood/task.md" 2>/dev/null)"
c7b7_rc=$?
if [ "$c7b7_rc" -ne 0 ]; then
  pass "c7b:symlinked-parent-reject" "file: symlinked parent .hivemind → non-zero return"
else
  failed "c7b:symlinked-parent-reject" "file: symlinked parent chain must reject; got return 0"
fi

# ── 7c. hivemind_assert_inputs_contained — symlinked-ancestor read-guard ─────────

# 7c-1: inputs file at a real path inside the checkout → accept.
c7c1="$WORKDIR/c7c1/checkout"
mkdir -p "$c7c1/.hivemind"
c7c1_root="$(canon_dir "$c7c1")"
c7c1_inputs="$c7c1/.hivemind/spawn-inputs.json"
: > "$c7c1_inputs"
c7c1_out="$(hivemind_assert_inputs_contained "$c7c1" "$c7c1_inputs")"
c7c1_rc=$?
assert_eq "c7c:real-inputs-rc" "0" "$c7c1_rc" "inputs: real path inside checkout → return 0"
assert_eq "c7c:real-inputs-root" "$c7c1_root" "$c7c1_out" "inputs: real path → canonical root"

# 7c-2: inputs file whose canonical dir escapes via a symlinked ancestor → reject.
c7c2="$WORKDIR/c7c2/checkout"
c7c2_ext="$WORKDIR/c7c2/external"
mkdir -p "$c7c2" "$c7c2_ext"
ln -s "$c7c2_ext" "$c7c2/link"
c7c2_inputs="$c7c2/link/spawn-inputs.json"
: > "$c7c2_inputs"
c7c2_out="$(hivemind_assert_inputs_contained "$c7c2" "$c7c2_inputs" 2>/dev/null)"
c7c2_rc=$?
if [ "$c7c2_rc" -ne 0 ]; then
  pass "c7c:symlinked-ancestor-reject" "inputs: symlinked ancestor → non-zero return"
else
  failed "c7c:symlinked-ancestor-reject" "inputs: symlinked ancestor must reject; got return 0"
fi

# 7c-3: un-canonicalizable root → non-zero, empty stdout.
c7c3_fake_root="$WORKDIR/c7c3/does-not-exist"
c7c3_inputs="$WORKDIR/c7c3/some-file.json"
mkdir -p "$WORKDIR/c7c3"
: > "$c7c3_inputs"
c7c3_out="$(hivemind_assert_inputs_contained "$c7c3_fake_root" "$c7c3_inputs" 2>/dev/null)"
c7c3_rc=$?
if [ "$c7c3_rc" -ne 0 ]; then
  pass "c7c:bad-root-rc" "inputs: non-existent root → non-zero return"
else
  failed "c7c:bad-root-rc" "inputs: non-existent root must reject; got return 0"
fi
assert_eq "c7c:bad-root-empty-stdout" "" "$c7c3_out" "inputs: non-existent root → empty stdout"

# 7c-4: sibling-named external dir must not prefix-match the checkout root (trailing-slash guard).
# The external dir shares a prefix with the checkout root (e.g. /tmp/X/checkout-evil vs /tmp/X/checkout)
# but is distinct. An inputs file there must be rejected.
c7c4_base="$WORKDIR/c7c4"
c7c4_root="$c7c4_base/checkout"
c7c4_evil="$c7c4_base/checkout-evil"
mkdir -p "$c7c4_root" "$c7c4_evil"
c7c4_inputs="$c7c4_evil/spawn-inputs.json"
: > "$c7c4_inputs"
c7c4_out="$(hivemind_assert_inputs_contained "$c7c4_root" "$c7c4_inputs" 2>/dev/null)"
c7c4_rc=$?
if [ "$c7c4_rc" -ne 0 ]; then
  pass "c7c:sibling-no-prefix-match" "inputs: sibling-named external dir must not prefix-match → non-zero return"
else
  failed "c7c:sibling-no-prefix-match" "inputs: sibling-named dir prefix-matched checkout root (trailing-slash guard broken)"
fi

# 7c-5: inputs-file LEAF is a symlink to an external target → reject (leaf read oracle closed).
# The leaf itself is a symlink ([ -L ] fires), even though every dir component is contained.
c7c5="$WORKDIR/c7c5/checkout"
c7c5_ext="$WORKDIR/c7c5/external"
mkdir -p "$c7c5/.hivemind" "$c7c5_ext"
: > "$c7c5_ext/secret.json"
c7c5_inputs="$c7c5/.hivemind/spawn-inputs.json"
ln -s "$c7c5_ext/secret.json" "$c7c5_inputs"
c7c5_out="$(hivemind_assert_inputs_contained "$c7c5" "$c7c5_inputs" 2>/dev/null)"
c7c5_rc=$?
if [ "$c7c5_rc" -ne 0 ]; then
  pass "c7c:symlinked-leaf-reject" "inputs: symlinked leaf → non-zero return"
else
  failed "c7c:symlinked-leaf-reject" "inputs: symlinked leaf must reject; got return 0"
fi
assert_eq "c7c:symlinked-leaf-empty-stdout" "" "$c7c5_out" "inputs: symlinked leaf → empty stdout"

# 7c-6: inputs-file LEAF is a DANGLING symlink (target does not exist) → still reject.
# Proves [ -L ] fires regardless of target existence.
c7c6="$WORKDIR/c7c6/checkout"
c7c6_ext="$WORKDIR/c7c6/external"
mkdir -p "$c7c6/.hivemind" "$c7c6_ext"
c7c6_inputs="$c7c6/.hivemind/spawn-inputs.json"
ln -s "$c7c6_ext/missing.json" "$c7c6_inputs"
c7c6_out="$(hivemind_assert_inputs_contained "$c7c6" "$c7c6_inputs" 2>/dev/null)"
c7c6_rc=$?
if [ "$c7c6_rc" -ne 0 ]; then
  pass "c7c:dangling-symlinked-leaf-reject" "inputs: dangling symlinked leaf → non-zero return"
else
  failed "c7c:dangling-symlinked-leaf-reject" "inputs: dangling symlinked leaf must reject; got return 0"
fi
assert_eq "c7c:dangling-symlinked-leaf-empty-stdout" "" "$c7c6_out" "inputs: dangling symlinked leaf → empty stdout"

# ── 7d. hivemind_assert_ledger_contained — symlinked-ledger-leaf read-guard ──────
# 7d-1: real regular-file ledger inside the checkout .hivemind/runs/<id>/ → accept.
c7d1="$WORKDIR/c7d1/checkout"
mkdir -p "$c7d1/.hivemind/runs/run-1"
c7d1_root="$(canon_dir "$c7d1")"
c7d1_ledger="$c7d1/.hivemind/runs/run-1/state.json"
: > "$c7d1_ledger"
c7d1_out="$(hivemind_assert_ledger_contained "$c7d1" "$c7d1_ledger")"
c7d1_rc=$?
assert_eq "c7d:real-ledger-rc" "0" "$c7d1_rc" "ledger: real regular-file ledger inside checkout → return 0"
assert_eq "c7d:real-ledger-root" "$c7d1_root" "$c7d1_out" "ledger: real ledger → canonical root"

# 7d-2: ledger LEAF is a symlink to an external target → reject (leaf read oracle closed).
# Every dir component is contained; only the leaf symlink ([ -L ] fires) escapes.
c7d2="$WORKDIR/c7d2/checkout"
c7d2_ext="$WORKDIR/c7d2/external"
mkdir -p "$c7d2/.hivemind/runs/run-1" "$c7d2_ext"
: > "$c7d2_ext/secret.json"
c7d2_ledger="$c7d2/.hivemind/runs/run-1/state.json"
ln -s "$c7d2_ext/secret.json" "$c7d2_ledger"
c7d2_out="$(hivemind_assert_ledger_contained "$c7d2" "$c7d2_ledger" 2>/dev/null)"
c7d2_rc=$?
if [ "$c7d2_rc" -ne 0 ]; then
  pass "c7d:symlinked-leaf-reject" "ledger: symlinked leaf → non-zero return"
else
  failed "c7d:symlinked-leaf-reject" "ledger: symlinked leaf must reject; got return 0"
fi
assert_eq "c7d:symlinked-leaf-empty-stdout" "" "$c7d2_out" "ledger: symlinked leaf → empty stdout"

# 7d-3: ledger LEAF is a DANGLING symlink (target does not exist) → still reject.
# Proves [ -L ] fires regardless of target existence.
c7d3="$WORKDIR/c7d3/checkout"
c7d3_ext="$WORKDIR/c7d3/external"
mkdir -p "$c7d3/.hivemind/runs/run-1" "$c7d3_ext"
c7d3_ledger="$c7d3/.hivemind/runs/run-1/state.json"
ln -s "$c7d3_ext/missing.json" "$c7d3_ledger"
c7d3_out="$(hivemind_assert_ledger_contained "$c7d3" "$c7d3_ledger" 2>/dev/null)"
c7d3_rc=$?
if [ "$c7d3_rc" -ne 0 ]; then
  pass "c7d:dangling-symlinked-leaf-reject" "ledger: dangling symlinked leaf → non-zero return"
else
  failed "c7d:dangling-symlinked-leaf-reject" "ledger: dangling symlinked leaf must reject; got return 0"
fi
assert_eq "c7d:dangling-symlinked-leaf-empty-stdout" "" "$c7d3_out" "ledger: dangling symlinked leaf → empty stdout"

# 7d-4: ledger ANCESTOR is a symlink resolving outside the checkout → reject.
# The runs/<id> dir is reached through a symlinked .hivemind that escapes the root.
c7d4="$WORKDIR/c7d4/checkout"
c7d4_ext="$WORKDIR/c7d4/external"
mkdir -p "$c7d4" "$c7d4_ext/runs/run-1"
ln -s "$c7d4_ext" "$c7d4/.hivemind"
c7d4_ledger="$c7d4/.hivemind/runs/run-1/state.json"
: > "$c7d4_ledger"
c7d4_out="$(hivemind_assert_ledger_contained "$c7d4" "$c7d4_ledger" 2>/dev/null)"
c7d4_rc=$?
if [ "$c7d4_rc" -ne 0 ]; then
  pass "c7d:symlinked-ancestor-reject" "ledger: symlinked ancestor escaping root → non-zero return"
else
  failed "c7d:symlinked-ancestor-reject" "ledger: symlinked ancestor must reject; got return 0"
fi

# ── Section 8: ledger-reconstruct-parse.sh — git_log_to_findings (PURE parse) ────
echo ''
echo '=== ledger-reconstruct-parse.sh: git_log_to_findings (git-log fix-surface parse) ==='
#
# DIRECT unit coverage for the lifted PURE git-log parse stage. git_log_to_findings reads the
# machine-channel git-log payload on STDIN and emits a JSON ARRAY of fix-surface findings (one per
# commit/file/hunk). It reads the caller-shell globals US (0x1e record start) / RS (0x1f field sep)
# the entrypoint defines BEFORE sourcing — so this section SETS them first, mirroring the entrypoint
# variable contract verbatim. Ground-truth inputs/outputs reuse the entrypoint oracle's canned
# git-log fixtures (tests/ledger-reconstruct/) so these unit assertions agree with the 49-case
# behavioral suite. Payloads are streamed from disposable WORKDIR files (US/RS/NUL bytes built via
# printf) so NUL delimiters survive the read.
US=$'\x1e'; RS=$'\x1f'; BASE=origin/main

# 8a: qualifying remediation commit — one commit, two files (auth/db), one hunk each → two findings
# with FACTUAL `status: "fixed"`, correct id/file/line arithmetic. The subject carries the literal
# `address review feedback` phrase, so the prior-fix qualification gate ADMITS it.
parse_one="$WORKDIR/parse-one-commit.txt"
printf '%sCOMMIT%saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa%sfix(auth): address review feedback\x00\n' "$US" "$RS" "$RS" > "$parse_one"
printf ':100644 100644 000aaaa 111aaaa M\x00src/auth.py\x00:100644 100644 000bbbb 111bbbb M\x00src/db.py\x00\x00' >> "$parse_one"
printf 'diff --git a/src/auth.py b/src/auth.py\n@@ -10,3 +10,4 @@\n+x\n' >> "$parse_one"
printf 'diff --git a/src/db.py b/src/db.py\n@@ -5 +5,2 @@\n+y\n' >> "$parse_one"
parse_one_out="$(git_log_to_findings < "$parse_one")"
assert_eq "parse:qualify-count" "2" \
  "$(printf '%s' "$parse_one_out" | jq -c 'length')" "qualifying remediation commit → 2 findings (one per file/hunk)"
assert_eq "parse:qualify-auth-id" "fix:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:src/auth.py:10" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[0].id')" "auth finding id"
assert_eq "parse:qualify-auth-status" "fixed" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[0].status')" "auth finding status is FACTUAL fixed"
assert_eq "parse:qualify-auth-title" "fix(auth): address review feedback" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[0].title')" "auth finding title = subject"
assert_eq "parse:qualify-db-file" "src/db.py" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[1].file')" "db finding file (machine channel)"

# 8b: @@ hunk line arithmetic — new-side `+c,d` → line_start=c, line_end=c+d-1; a bare `+c` (no
# count) → d defaults to 1 → line_end==line_start. auth `@@ -10,3 +10,4 @@` → 10..13;
# db `@@ -5 +5,2 @@` → 5..6.
assert_eq "parse:hunk-auth-start" "10" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[0].line_start')" "auth @@ +10,4 → line_start 10"
assert_eq "parse:hunk-auth-end" "13" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[0].line_end')" "auth @@ +10,4 → line_end 13 (10+4-1)"
assert_eq "parse:hunk-db-start" "5" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[1].line_start')" "db @@ +5,2 → line_start 5"
assert_eq "parse:hunk-db-end" "6" \
  "$(printf '%s' "$parse_one_out" | jq -r '.[1].line_end')" "db @@ +5,2 → line_end 6 (5+2-1)"

# 8c: prior-fix qualification gate — a NON-qualifying subject (ordinary `fix(parser):` dev bug-fix
# with NO `address review feedback` phrase) emits ZERO findings. The gate keys ONLY on the literal
# review-loop phrase, never on the bare conventional type.
parse_nonqual="$WORKDIR/parse-nonqual.txt"
printf '%sCOMMIT%sc3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3%sfix(parser): correct off-by-one\x00\n' "$US" "$RS" "$RS" > "$parse_nonqual"
printf ':100644 100644 000p1 111p2 M\x00src/parser.py\x00\x00' >> "$parse_nonqual"
printf 'diff --git a/src/parser.py b/src/parser.py\n@@ -5,3 +5,3 @@\n+z\n' >> "$parse_nonqual"
assert_eq "parse:gate-reject-nonqualifying" "[]" \
  "$(git_log_to_findings < "$parse_nonqual")" "non-remediation fix subject → gate rejects → []"

# 8d: C0-control-byte-in-subject escaping — subject carries 0x08 backspace, a double-quote, and a
# backslash. jq owns ALL string emission, so the C0 byte is escaped (→ \b) and the finding is
# NON-empty (old hand-rolled-JSON code collapsed to [] on a C0 byte). Title must round-trip escaped.
parse_c0="$WORKDIR/parse-c0.txt"
printf '%sCOMMIT%sdddddddddddddddddddddddddddddddddddddddd%sfix(x): address review feedback Fix\x08"bad\\path"\x00\n' "$US" "$RS" "$RS" > "$parse_c0"
printf ':100644 100644 000fix1 111fix1 M\x00src/fix.py\x00\x00' >> "$parse_c0"
printf 'diff --git a/src/fix.py b/src/fix.py\n@@ -1 +1,3 @@\n+a\n' >> "$parse_c0"
parse_c0_out="$(git_log_to_findings < "$parse_c0")"
assert_eq "parse:c0-count" "1" \
  "$(printf '%s' "$parse_c0_out" | jq -c 'length')" "C0-byte subject → finding NON-empty (jq escapes the byte)"
assert_eq "parse:c0-title-escaped" '"fix(x): address review feedback Fix\b\"bad\\path\""' \
  "$(printf '%s' "$parse_c0_out" | jq -c '.[0].title')" "C0 0x08 escaped to \\b; quote/backslash escaped (jq -c form)"

# 8e: ` b/`-bearing path + rename destination — entry (1) modifies a file whose path contains the
# literal " b/" substring (old in-band ` b/` splitting would have corrupted it); entry (2) is a
# rename (R100, two NUL-delimited paths) — the parser must take the DESTINATION (last path).
parse_tricky="$WORKDIR/parse-tricky.txt"
printf '%sCOMMIT%seeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee%sfix(paths): address review feedback\x00\n' "$US" "$RS" "$RS" > "$parse_tricky"
printf ':100644 100644 000fbb1 111fbb1 M\x00foo b/bar.txt\x00:100644 100644 000old1 111new1 R100\x00old name.txt\x00new dir/new name.txt\x00\x00' >> "$parse_tricky"
printf 'diff --git a/placeholder b/placeholder\n@@ -5 +5,2 @@\n+e\n' >> "$parse_tricky"
printf 'diff --git a/old name.txt b/new dir/new name.txt\n@@ -1 +1,4 @@\n+r\n' >> "$parse_tricky"
parse_tricky_out="$(git_log_to_findings < "$parse_tricky")"
assert_eq "parse:space-b-path" "foo b/bar.txt" \
  "$(printf '%s' "$parse_tricky_out" | jq -r '.[0].file')" "' b/'-bearing path is FULL, not split"
assert_eq "parse:rename-destination" "new dir/new name.txt" \
  "$(printf '%s' "$parse_tricky_out" | jq -r '.[1].file')" "rename → DESTINATION path (last NUL token)"

# 8f: malformed input → `[]` fail-open coercion. A payload with no \x1eCOMMIT\x1f record marker is
# garbage; git_log_to_findings yields `[]` (INJECTED FAIL-OPEN), never an error.
parse_malformed="$WORKDIR/parse-malformed.txt"
printf 'this is not a valid git log payload\nno commit headers here\n@@not-a-real-hunk\n' > "$parse_malformed"
assert_eq "parse:malformed-fail-open" "[]" \
  "$(git_log_to_findings < "$parse_malformed")" "malformed payload (no COMMIT marker) → [] fail-open"

# ── Section 9: ledger-reconstruct-fold.sh — fold / gate / wrap (PURE) ────────────
echo ''
echo '=== ledger-reconstruct-fold.sh: normalized_to_findings / normalized_live_parse_gate / reconstruct_ledger ==='
#
# DIRECT unit coverage for the lifted fold/gate/wrap stage. These functions read the caller-shell
# global BASE (reconstruct_ledger only) — set verbatim per the entrypoint contract. US/RS were set
# in Section 8 above; BASE is (re)asserted here so this section stands on its own.
US=$'\x1e'; RS=$'\x1f'; BASE=origin/main

# 9a: normalized_to_findings — per-surface status derivation. Reuses the entrypoint oracle's
# normalized-threads payload (4 review records + 1 ci-check-failure). Folding rules:
#   thread(resolved=true) → status fixed, thread_resolved true;
#   thread(resolved=false) → status open (thread_resolved // null → null);
#   toplevel(handled) → status fixed FROM classification (non-thread cannot be GitHub-resolved);
#   review(actionable) → status open FROM classification;
#   ci-check-failure → SKIPPED (item_source != "review").
NORM_THREADS='[
  {"id":"PRRT_thread001resolved","thread_id":"PRRT_thread001resolved","item_source":"review","classification":"handled","thread_resolved":true,"surface":"thread"},
  {"id":"PRRT_thread002open","thread_id":"PRRT_thread002open","item_source":"review","classification":"actionable","thread_resolved":false,"surface":"thread"},
  {"id":"IC_toplevel001handled","thread_id":null,"item_source":"review","classification":"handled","thread_resolved":false,"surface":"toplevel"},
  {"id":"PRR_review001actionable","thread_id":null,"item_source":"review","classification":"actionable","thread_resolved":false,"surface":"review"},
  {"id":null,"item_source":"ci-check-failure","name":"policy-check","state":"FAILURE"}
]'
fold_out="$(normalized_to_findings "$NORM_THREADS")"
assert_eq "fold:review-only-count" "4" \
  "$(printf '%s' "$fold_out" | jq -c 'length')" "4 review records fold; ci-check-failure skipped"
assert_eq "fold:thread-resolved-status" "fixed" \
  "$(printf '%s' "$fold_out" | jq -r '.[] | select(.id=="PRRT_thread001resolved") | .status')" "resolved thread → status fixed"
assert_eq "fold:thread-resolved-flag" "true" \
  "$(printf '%s' "$fold_out" | jq -c '.[] | select(.id=="PRRT_thread001resolved") | .thread_resolved')" "resolved thread → thread_resolved true"
assert_eq "fold:thread-unresolved-status" "open" \
  "$(printf '%s' "$fold_out" | jq -r '.[] | select(.id=="PRRT_thread002open") | .status')" "unresolved thread → status open"
assert_eq "fold:toplevel-handled-status" "fixed" \
  "$(printf '%s' "$fold_out" | jq -r '.[] | select(.id=="IC_toplevel001handled") | .status')" "toplevel(handled) → status fixed from classification"
assert_eq "fold:toplevel-thread-resolved-null" "null" \
  "$(printf '%s' "$fold_out" | jq -c '.[] | select(.id=="IC_toplevel001handled") | .thread_resolved')" "toplevel → thread_resolved null (non-thread)"
assert_eq "fold:review-actionable-status" "open" \
  "$(printf '%s' "$fold_out" | jq -r '.[] | select(.id=="PRR_review001actionable") | .status')" "review(actionable) → status open from classification"
# Non-array / unparseable payload → [] fail-open coercion (INJECTED path).
assert_eq "fold:non-array-coerce" "[]" \
  "$(normalized_to_findings '{"not":"an array"}')" "non-array payload → [] fail-open coercion"

# 9b: normalized_live_parse_gate — LIVE FAIL-CLOSED return codes.
#   empty payload (zero bytes) → 0 (legitimate "no thread findings");
#   non-empty parseable JSON array → 0;
#   non-array / garbage → non-zero AND emits LEDGERRECON_ERROR=normalized-parse-failed on stderr.
normalized_live_parse_gate ""; gate_empty_rc=$?
assert_eq "gate:empty-rc0" "0" "$gate_empty_rc" "empty live payload → exit 0 (no thread findings)"
normalized_live_parse_gate '[{"id":"x"}]'; gate_array_rc=$?
assert_eq "gate:array-rc0" "0" "$gate_array_rc" "non-empty JSON array → exit 0"
gate_garbage_err="$(normalized_live_parse_gate 'this is not json' 2>&1 >/dev/null)"; gate_garbage_rc=$?
if [ "$gate_garbage_rc" -ne 0 ]; then
  pass "gate:garbage-rc-nonzero" "garbage payload → non-zero exit (fail closed)"
else
  failed "gate:garbage-rc-nonzero" "garbage payload must fail closed; got exit 0"
fi
if printf '%s' "$gate_garbage_err" | grep -qF "LEDGERRECON_ERROR=normalized-parse-failed"; then
  pass "gate:garbage-marker" "garbage payload emits LEDGERRECON_ERROR=normalized-parse-failed"
else
  failed "gate:garbage-marker" "expected normalized-parse-failed marker; got: $gate_garbage_err"
fi
# A non-empty, parseable, but NON-array JSON value (object) also fails closed with the marker.
gate_obj_err="$(normalized_live_parse_gate '{"a":1}' 2>&1 >/dev/null)"; gate_obj_rc=$?
if [ "$gate_obj_rc" -ne 0 ]; then
  pass "gate:object-rc-nonzero" "non-array JSON object → non-zero exit (fail closed)"
else
  failed "gate:object-rc-nonzero" "non-array JSON object must fail closed; got exit 0"
fi
if printf '%s' "$gate_obj_err" | grep -qF "LEDGERRECON_ERROR=normalized-parse-failed"; then
  pass "gate:object-marker" "non-array object emits LEDGERRECON_ERROR=normalized-parse-failed"
else
  failed "gate:object-marker" "expected normalized-parse-failed marker for object; got: $gate_obj_err"
fi

# 9c: reconstruct_ledger — top-level fix-ledger JSON shape. Wraps the two finding families
# (git + thread) into one iteration. BASE flows into both top-level `base` and the iteration's
# `review_base_ref`. Findings array is the concatenation ($git_findings + $thread_findings).
recon_out="$(reconstruct_ledger '[{"id":"g1"}]' '[{"id":"t1"}]')"
assert_eq "recon:base" "origin/main" \
  "$(printf '%s' "$recon_out" | jq -r '.base')" "BASE flows into top-level base"
assert_eq "recon:max-iterations" "10" \
  "$(printf '%s' "$recon_out" | jq -r '.max_iterations')" "max_iterations is 10"
assert_eq "recon:iteration-count" "1" \
  "$(printf '%s' "$recon_out" | jq -c '.iterations | length')" "exactly one iteration"
assert_eq "recon:iteration-number" "1" \
  "$(printf '%s' "$recon_out" | jq -r '.iterations[0].iteration')" "iteration number is 1"
assert_eq "recon:verdict" "needs-attention" \
  "$(printf '%s' "$recon_out" | jq -r '.iterations[0].verdict')" "iteration verdict needs-attention"
assert_eq "recon:review-base-ref" "origin/main" \
  "$(printf '%s' "$recon_out" | jq -r '.iterations[0].review_base_ref')" "BASE flows into review_base_ref"
assert_eq "recon:findings-merge" "g1 t1" \
  "$(printf '%s' "$recon_out" | jq -r '[.iterations[0].findings[].id] | join(" ")')" "git + thread findings concatenated"
# Empty families → valid ledger with empty findings (the fail-open shape).
recon_empty="$(reconstruct_ledger '[]' '[]')"
assert_eq "recon:empty-findings" "0" \
  "$(printf '%s' "$recon_empty" | jq -c '.iterations[0].findings | length')" "empty families → empty findings (fail-open shape)"

# ── Section 10: fetch-normalize-core.sh — normalize core + overflow tripwire (PURE) ─
echo ''
echo '=== fetch-normalize-core.sh: build_normalized_candidate_set / emit_overflow_tripwire (#245) ==='
#
# DIRECT determinism coverage for the lifted PURE normalize core. build_normalized_candidate_set
# takes EXPLICIT parameters (no caller globals) and emits the SINGLE compact normalized candidate
# array on stdout; emit_overflow_tripwire reads the three connection totalCounts off the raw payload
# and fires the >50 OVERFLOW diagnostic on stderr. Ground-truth inputs/outputs reuse the entrypoint
# oracle's canned fixtures (tests/fix-history/, tests/fetch-normalize/) so these unit assertions
# agree with the behavioral suite. SELF_LOGIN is "selfuser" to match the reused fix-history fixtures.
# Canonicalization mirrors the behavioral suite's `canon` VERBATIM: `jq -S` recursive key-sort PLUS
# a stable array sort_by the same key tuple, so element ORDER never makes a comparison brittle.
fn_canon() { jq -S -c 'sort_by((.databaseId // -1), (.url // ""), (.thread_id // ""), (.name // ""), (.surface // ""), (.classification // ""), (.item_source // ""))' 2>/dev/null; }

# 10a: review-surface-only union — the case01 review payload (handled by self fix-reply marker)
# with NO ci payload folds to exactly the expected single review record (item_source: "review").
fn_review_out="$(build_normalized_candidate_set \
  "$(cat "$FN_REVIEW_HANDLED")" "" "selfuser" "all" "$CLASSIFY_FILTER" | fn_canon)"
fn_review_exp="$(fn_canon < "$FN_EXPECTED_REVIEW")"
assert_eq "fncore:review-only-union" "$fn_review_exp" "$fn_review_out" \
  "build_normalized_candidate_set: review-only payload → expected normalized review record"

# 10b: ci-only union — an empty graphql payload with the ci-checks fixture folds to exactly the two
# bucket==fail records (item_source: "ci-check-failure", id:null), the pass/pending checks dropped.
fn_ci_out="$(build_normalized_candidate_set \
  "" "$(cat "$FN_CI_CHECKS")" "selfuser" "all" "$CLASSIFY_FILTER" | fn_canon)"
fn_ci_exp="$(fn_canon < "$FN_EXPECTED_CI")"
assert_eq "fncore:ci-only-union" "$fn_ci_exp" "$fn_ci_out" \
  "build_normalized_candidate_set: ci-only payload → two bucket==fail records, id:null"

# 10c: review + ci union — both families present → the concatenation of the review record family and
# the ci-check-failure record family (review records first, then ci records). The expected union is
# the jq -s concatenation of the two expected fixtures, canonicalized identically.
fn_union_out="$(build_normalized_candidate_set \
  "$(cat "$FN_REVIEW_HANDLED")" "$(cat "$FN_CI_CHECKS")" "selfuser" "all" "$CLASSIFY_FILTER" | fn_canon)"
fn_union_exp="$(jq -s 'add' "$FN_EXPECTED_REVIEW" "$FN_EXPECTED_CI" | fn_canon)"
assert_eq "fncore:review-plus-ci-union" "$fn_union_exp" "$fn_union_out" \
  "build_normalized_candidate_set: review + ci → concatenated review-then-ci candidate set"

# 10c-bis: ORDER-SENSITIVE union contract. fn_canon (above) sort_by-canonicalizes, which by design
# erases element order so cross-family ordering noise never flakes the value comparison — but that
# also means 10c can NOT catch a regression that REVERSES the union (ci records emitted before review
# records). The behavior-preservation contract is explicit: review-surface records are emitted FIRST,
# then ci-check-failure records (the `printf '%s\n%s\n' "$review_records" "$ci_records"` order). Assert
# the RAW (un-sorted) item_source sequence to lock that order. This complements 10c, it does not
# replace it.
fn_union_order="$(build_normalized_candidate_set \
  "$(cat "$FN_REVIEW_HANDLED")" "$(cat "$FN_CI_CHECKS")" "selfuser" "all" "$CLASSIFY_FILTER" \
  | jq -c '[.[].item_source]')"
assert_eq "fncore:union-order-review-then-ci" '["review","ci-check-failure","ci-check-failure"]' "$fn_union_order" \
  "build_normalized_candidate_set: RAW union emits review record(s) BEFORE ci-check-failure records"

# 10d: fail-OPEN on a malformed injected graphql payload → [] (NOT an error). The normalize core
# never errors on a bad injected payload; the slurp canonicalizes the empty record streams to [].
fn_malformed_out="$(build_normalized_candidate_set \
  "$(cat "$FN_MALFORMED")" "" "selfuser" "all" "$CLASSIFY_FILTER")"
assert_eq "fncore:malformed-fail-open" "[]" "$fn_malformed_out" \
  "build_normalized_candidate_set: malformed graphql payload → [] fail-open"

# 10e: fail-OPEN on an empty graphql payload AND empty ci payload → [] (both families empty).
fn_empty_out="$(build_normalized_candidate_set "" "" "selfuser" "all" "$CLASSIFY_FILTER")"
assert_eq "fncore:empty-fail-open" "[]" "$fn_empty_out" \
  "build_normalized_candidate_set: empty graphql + empty ci → [] fail-open"

# 10f: emit_overflow_tripwire FIRES on a >50 connection totalCount. The overflow-threads fixture
# carries a reviewThreads.totalCount of 51, so the >50 OVERFLOW stderr diagnostic must appear.
fn_overflow_err="$(emit_overflow_tripwire "$(cat "$FN_OVERFLOW_THREADS")" 2>&1 1>/dev/null)"
if printf '%s' "$fn_overflow_err" | grep -qF "OVERFLOW"; then
  pass "fncore:overflow-fires" "emit_overflow_tripwire emits >50 OVERFLOW diagnostic past threshold"
else
  failed "fncore:overflow-fires" "expected >50 OVERFLOW diagnostic; got: $fn_overflow_err"
fi

# 10f-bis: FULL overflow diagnostic-TEXT contract. 10f only greps for the bare "OVERFLOW" needle, so a
# regression that dropped/garbled the three counter values (reviewThreads/comments/reviews) or weakened
# the diagnostic wording would still pass. The diagnostic IS the consumer's fail-open signal and its
# exact counter payload is a behavior-preservation requirement, so assert the full line. The
# overflow-threads fixture carries reviewThreads.totalCount=51 (comments=0 reviews=0). Exact-match the
# whole stderr line (printf-captured, no needle grep).
fn_overflow_exp='github-review-loop: OVERFLOW one or more connection totalCounts exceed 50 (reviewThreads=51 comments=0 reviews=0); in-page classification is untrustworthy on the overflowed axis — the consumer must fail open (DISPATCH) per its >50 tripwire.'
assert_eq "fncore:overflow-full-diagnostic" "$fn_overflow_exp" "$fn_overflow_err" \
  "emit_overflow_tripwire: full >50 diagnostic line incl. exact counter payload (reviewThreads=51 comments=0 reviews=0)"

# 10g: emit_overflow_tripwire STAYS SILENT below the threshold. The case01 review fixture has small
# connection counts (no axis exceeds 50), so NO OVERFLOW diagnostic must be emitted (control).
fn_nooverflow_err="$(emit_overflow_tripwire "$(cat "$FN_REVIEW_HANDLED")" 2>&1 1>/dev/null)"
if printf '%s' "$fn_nooverflow_err" | grep -qF "OVERFLOW"; then
  failed "fncore:overflow-silent" "emit_overflow_tripwire wrongly fired OVERFLOW below threshold: $fn_nooverflow_err"
else
  pass "fncore:overflow-silent" "emit_overflow_tripwire stays silent below the >50 threshold"
fi

# 10h: emit_overflow_tripwire on a malformed/empty payload behaves like a 0-node page (counts default
# to 0) → NO OVERFLOW diagnostic (the overflow read fails OPEN to 0, never erroring).
fn_overflow_malformed_err="$(emit_overflow_tripwire "" 2>&1 1>/dev/null)"
if printf '%s' "$fn_overflow_malformed_err" | grep -qF "OVERFLOW"; then
  failed "fncore:overflow-empty-silent" "emit_overflow_tripwire wrongly fired on an empty payload: $fn_overflow_malformed_err"
else
  pass "fncore:overflow-empty-silent" "emit_overflow_tripwire treats empty payload as 0-node page (no OVERFLOW)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────────
echo ''
echo '=== Summary ==='
echo "Shared-lib unit tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
