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
# path STILL enforces the shared floor: command-sub, '..', leading '-', framing bytes reject.
# Plus VT (\v) and FF (\f): the path whitespace widening is a LITERAL space only — `[:space:]`
# would have admitted these C0 control bytes (Codex #172 P1), so they must reject here.
tab=$'\t'; nl=$'\n'; cr=$'\r'; vt=$'\v'; ff=$'\f'
for v in "" "-rf" "/a/../b" "x\$(touch $PWN_MARKER)" "\`touch $PWN_MARKER\`" "a${tab}b" "a${nl}b" "a${cr}b" "a${vt}b" "a${ff}b" "a;b" 'a|b' 'a>b'; do
  if hivemind_assert_path "$v"; then
    failed "path:reject" "accepted a value the path floor must reject: '$v'"
  else
    pass "path:reject" "rejected unsafe path '$v'"
  fi
done

# ── Class 3: presentation (broadest printable; display-only name). ──
# Space-bearing display name ACCEPTS — this is what lets `api worker` render not MALFORMED.
# NOTE: `|` is NOT in the accept set — the presentation value is rendered into a Markdown table
# cell by the brood-status navigator, so a `|` would inject extra cells (Codex #172 P1). It is
# asserted in the reject list below alongside the shared floor bytes.
for v in "api worker" "api" "a;b" "a#b" "a (worker)" "a/b-c.d_e"; do
  if hivemind_assert_presentation "$v"; then
    pass "pres:accept" "accepted presentation value '$v'"
  else
    failed "pres:accept" "rejected a presentation value that should render: '$v'"
  fi
done
# presentation STILL enforces the shared floor (command-sub, '..', leading '-', framing) AND
# rejects the Markdown table delimiter '|' (Codex #172 P1 — table-cell injection).
for v in "" "-x" "a..b" "x\$(touch $PWN_MARKER)" "\`touch $PWN_MARKER\`" "a${tab}b" "a${nl}b" "a${cr}b" 'a|b'; do
  if hivemind_assert_presentation "$v"; then
    failed "pres:reject" "accepted a value the presentation floor must reject: '$v'"
  else
    pass "pres:reject" "rejected floor-violating presentation value '$v'"
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

# ── Summary ─────────────────────────────────────────────────────────────────────
echo ''
echo '=== Summary ==='
echo "Shared-lib unit tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
