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

for required in "$LEDGER_PRESENT" \
                "$SHARED_DIR/allowlist.sh" "$SHARED_DIR/manifest-json.sh" "$SHARED_DIR/ledger-project.sh"; do
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

# ── Summary ─────────────────────────────────────────────────────────────────────
echo ''
echo '=== Summary ==='
echo "Shared-lib unit tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
