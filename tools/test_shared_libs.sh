#!/usr/bin/env bash
#
# Shared-library unit runner for the brood-status read-side projection (issue #161).
#
# PURE UNIT TESTS — CI-runnable with ONLY jq present (NO tmux / claude / gh). Exercises the
# three sourced libraries the brood-status-project.sh entrypoint composes:
#   - plugin/skills/_shared/allowlist.sh      (hivemind_assert_safe_token)
#   - plugin/skills/_shared/manifest.sh       (hivemind_manifest_strain_names / _field)
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
MANIFEST_V1="$FIX_DIR/manifest-v1-old.yaml"
MANIFEST_V2="$FIX_DIR/manifest-v2-new.yaml"
LEDGER_PRESENT="$FIX_DIR/child-ledger-present.json"

for required in "$MANIFEST_V1" "$MANIFEST_V2" "$LEDGER_PRESENT" \
                "$SHARED_DIR/allowlist.sh" "$SHARED_DIR/manifest.sh" "$SHARED_DIR/ledger-project.sh"; do
  [ -f "$required" ] || { echo "FAIL: required fixture/lib missing: $required" >&2; exit 2; }
done

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this suite" >&2; exit 2; }

# Source the libs under test.
# shellcheck source=/dev/null
. "$SHARED_DIR/allowlist.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/manifest.sh"
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

# ── Section 1: allowlist.sh ─────────────────────────────────────────────────────
echo '=== allowlist.sh: hivemind_assert_safe_token ==='

# Accept cases.
for v in "feat/x" "brood-auth" "/abs/path-1.json" "a.b_c" "2026-05-30T22-10-00Z--api"; do
  if hivemind_assert_safe_token "$v"; then
    pass "allow:accept" "accepted safe token '$v'"
  else
    failed "allow:accept" "rejected a token that should be safe: '$v'"
  fi
done

# Reject cases. The metacharacter cases ALSO must not produce a side-effect file.
PWN_MARKER="$WORKDIR/pwn-marker"
rm -f "$PWN_MARKER"
# Build the metacharacter payloads referencing PWN_MARKER so an accidental eval would touch it.
declare -a reject_cases=(
  ""
  "-rf"
  "a..b"
  "x\$(touch $PWN_MARKER)"
  "\`touch $PWN_MARKER\`"
  "a b"
  "a;b"
)
for v in "${reject_cases[@]}"; do
  if hivemind_assert_safe_token "$v"; then
    failed "allow:reject" "accepted a token that should be rejected: '$v'"
  else
    pass "allow:reject" "rejected unsafe token '$v'"
  fi
done
# No metacharacter case may have created the marker (proves no command substitution ran).
if [ -e "$PWN_MARKER" ]; then
  failed "allow:no-side-effect" "a metacharacter case created the side-effect marker $PWN_MARKER"
else
  pass "allow:no-side-effect" "no metacharacter case created a side-effect file"
fi

# ── Section 2: manifest.sh ──────────────────────────────────────────────────────
echo ''
echo '=== manifest.sh: hivemind_manifest_strain_names / hivemind_manifest_field ==='

# v2: strain names.
names_v2="$(hivemind_manifest_strain_names "$MANIFEST_V2")"
assert_eq "manifest:v2-names" "api" "$names_v2" "v2 strain names"

# v2: each static field + block-scalar parity.
assert_eq "manifest:v2-worktree" "/repo/.claude/worktrees/api" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "worktree_path")" "v2 worktree_path (|- block scalar)"
assert_eq "manifest:v2-branch" "feature/api-slice" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "branch")" "v2 branch (|- block scalar)"
assert_eq "manifest:v2-tmux" "brood-api" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "tmux_session")" "v2 tmux_session (inline quoted)"
assert_eq "manifest:v2-status" "running" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "status")" "v2 status (inline bare)"
assert_eq "manifest:v2-suggested-id" "2026-05-30T22-10-00Z--api" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "run.suggested_id")" "v2 run.suggested_id (nested |-)"
assert_eq "manifest:v2-suggested-ledger" "TESTS_BROOD_DIR/child-ledger-present.json" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "run.suggested_ledger")" "v2 run.suggested_ledger (nested |-)"
assert_eq "manifest:v2-workflow-hint" "standard-delivery" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "workflow_hint")" "v2 workflow_hint (nested |-)"

# run.* prefix-stripping parity: passing the bare field name yields the same value.
assert_eq "manifest:v2-suggested-ledger-bare" "TESTS_BROOD_DIR/child-ledger-present.json" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "api" "suggested_ledger")" "v2 suggested_ledger (bare name)"

# v1: names + static fields still extract; run.* fields are empty (no run: block).
assert_eq "manifest:v1-names" "api" \
  "$(hivemind_manifest_strain_names "$MANIFEST_V1")" "v1 strain names"
assert_eq "manifest:v1-branch" "feature/api-slice" \
  "$(hivemind_manifest_field "$MANIFEST_V1" "api" "branch")" "v1 branch (|- block scalar)"
assert_eq "manifest:v1-tmux" "brood-api" \
  "$(hivemind_manifest_field "$MANIFEST_V1" "api" "tmux_session")" "v1 tmux_session (inline quoted)"
assert_eq "manifest:v1-suggested-ledger-empty" "" \
  "$(hivemind_manifest_field "$MANIFEST_V1" "api" "run.suggested_ledger")" "v1 has no run: block"

# Absent strain → empty.
assert_eq "manifest:absent-strain" "" \
  "$(hivemind_manifest_field "$MANIFEST_V2" "nope" "branch")" "absent strain yields empty"

# ── Hostile-description containment (#161 P1) ────────────────────────────────────
# A strain `description: |` block carries untrusted issue-sourced free text. The fixture's
# description body embeds counterfeit `status:`, `worktree_path:`, `branch:`, `tmux_session:`,
# nested `run.suggested_ledger:`, and an injected `- name:` strain entry. The extractor MUST
# treat all of it as inert block-scalar BODY — never as strain structure — and return the
# GENUINE field values that follow the description block.
MANIFEST_HOSTILE="$FIX_DIR/manifest-v2-hostile-desc.yaml"
[ -f "$MANIFEST_HOSTILE" ] || { echo "FAIL: missing fixture $MANIFEST_HOSTILE" >&2; exit 2; }

# Only the genuine "api" strain is discovered; the description-embedded "- name: injected-strain"
# must NOT surface as a second strain.
assert_eq "manifest:hostile-names" "api" \
  "$(hivemind_manifest_strain_names "$MANIFEST_HOSTILE")" "injected '- name:' in description body is not a strain"

# Genuine status wins over the counterfeit "status: failed" inside the description body.
assert_eq "manifest:hostile-status" "running" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "status")" "counterfeit status in description body is ignored"

# Genuine worktree_path wins over the counterfeit "/attacker/escape".
assert_eq "manifest:hostile-worktree" "/repo/.claude/worktrees/api" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "worktree_path")" "counterfeit worktree_path in description body is ignored"

# Genuine branch wins over the counterfeit "attacker-branch".
assert_eq "manifest:hostile-branch" "feature/api-slice" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "branch")" "counterfeit branch in description body is ignored"

# Genuine tmux_session wins over the counterfeit "brood-attacker".
assert_eq "manifest:hostile-tmux" "brood-api" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "tmux_session")" "counterfeit tmux_session in description body is ignored"

# Genuine run.suggested_ledger wins over the counterfeit nested "/attacker/escape/...".
assert_eq "manifest:hostile-ledger" "/repo/.claude/worktrees/api/.hivemind/runs/2026-05-30T22-10-00Z--api/state.json" \
  "$(hivemind_manifest_field "$MANIFEST_HOSTILE" "api" "run.suggested_ledger")" "counterfeit nested run.suggested_ledger in description body is ignored"

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
