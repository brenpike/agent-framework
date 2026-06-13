#!/usr/bin/env bash
#
# record-state-result — deterministic transition engine for the
# hivemind:record-state-result skill.
#
# Records the outcome of the current workflow state into the run ledger and advances
# state.current to the legal next state, reading the allowed-result set DIRECTLY from
# the workflow definition (the model NEVER supplies it). This script OWNS the
# deterministic read -> validate -> mutate -> atomic-write; the skill body is a thin
# navigator. Mirrors the spawn-brood.sh committed-script precedent (shebang, set -u,
# blocker() helper, jq parsing into inert variables, structured stdout routing, exit
# codes).
#
# DETERMINISM CONTRACT (per ADR-0018 + plan §C/§I):
#   1. ledger.state.current MUST equal --state, else blocker + exit 1, ledger UNCHANGED.
#   2. BINDING GUARD: definition.id MUST equal ledger.run.workflow AND definition.version
#      MUST equal ledger.run.workflow_version, else blocker + exit 1, ledger UNCHANGED. The
#      engine HARD-REJECTS a non-binding id/version mismatch and exposes NO rebind. The §I
#      resume gate offers only TWO doors (start fresh / proceed intent-driven); there is NO
#      deterministic-resume door. This guard is a hard-reject — it never reconciles skew.
#   3. --state MUST exist in definition.states (a renamed/removed state never guesses —
#      this is state-existence, NOT version-skew), else blocker + exit 1, UNCHANGED.
#   5. The allowed-result set is read DIRECTLY from definition.states[<state>].transitions
#      (keys). --result MUST be one of those keys, else blocker + exit 1, UNCHANGED.
#   6. next_state = transitions[result].
#   7. Append an event {at,state,result,next_state,summary,outputs}.
#   8. Update state.previous=state, state.current=next_state, state.status.
#   9. Update run.updated_at.
#  10. If next_state is a declared terminal, set run.status + state.status to the
#      matching terminal status (complete->complete, blocked->blocked,
#      cancelled->cancelled). The human-intervention terminals
#      (user_input_required, review_rejected, review_exhausted) are "stopped, needs
#      attention" outcomes — they map to blocked (NOT complete) so a stalled run is
#      never masked as success. Genuine done-terminals (e.g. hatchery_monitor) ->
#      complete-equivalent per the schema doc, which constrains run.status to
#      running|complete|blocked|cancelled.
#  11. Write via temp file + atomic mv so a concurrent hatchery reader never sees a
#      torn file.
#
# CRITICAL ATOMICITY: every write is temp-write + atomic rename. On ANY validation
# failure the on-disk ledger is byte-unchanged — no partial write ever occurs (all
# validation runs BEFORE the temp file is created).
#
# INJECTION POSTURE: the untrusted fields summary, outputs, plan_steps, and plan_path are
# read from the inputs file with jq into inert shell variables and serialized via jq
# --arg / --argjson ONLY; they never enter the jq program or any shell command source.
# plan_steps reaches jq solely as an --argjson binding; plan_path solely as an --arg
# binding. The ONLY value passed on the command line is the trusted inputs-file path.
#
# PATH POSTURE — the engine NEVER accepts a path as input. It DERIVES every path from
# identity, dissolving two trust-boundary P0s (a caller-supplied ledger path enabled an
# arbitrary-file overwrite; a caller-supplied workflow-definition path enabled a forged
# definition that bypassed the transition gate AND the plan-write authorization). The ONLY
# path on the command line is $1, the inputs-file authored by the trusted skill via Write.
#   - The ledger is DERIVED: repo_root="$(git rev-parse --show-toplevel)" then
#     "$repo_root/.hivemind/runs/<run_id>/state.json". <run_id> comes from the inputs file,
#     SAFE_ID_RE-validated and ./.. -rejected.
#   - A COHERENCE CHECK requires the on-disk ledger.run.id to equal the passed run_id.
#   - The workflow DEFINITION is DERIVED from the (trusted) ledger's run.workflow against the
#     script's OWN packaged workflows dir (self-located via BASH_SOURCE + pwd -P, independent
#     of ${CLAUDE_PLUGIN_ROOT} and of any caller value). The caller NEVER supplies this path,
#     so a forged definition can no longer be injected; the binding guard now compares the
#     trusted ledger against the self-derived PACKAGED definition.
#
# INPUT (single positional argument):
#   $1  Absolute or repo-relative path to a JSON inputs file authored by the agent via the
#       Write tool. The agent writes structured data; this script parses it with jq into
#       shell VARIABLES. Untrusted bytes in the JSON are read into variables and referenced
#       only as "$var" — bash does not re-evaluate command substitution from variable
#       contents, so the command-substitution injection class is structurally absent (the
#       values never enter generated command SOURCE). Mirrors spawn-brood.sh and
#       init-run-ledger.sh; rationale: docs/adr/0017-brood-spawn-mechanism.md amendment.
#
#   Inputs JSON shape (authoritative schema in SKILL.md § Inputs JSON):
#     {
#       "run_id":     "<required> identity of the run; the ledger path is DERIVED from it as
#                      <git-root>/.hivemind/runs/<run_id>/state.json. NO path is accepted.",
#       "state":      "<required> state the run is currently in (must match ledger)",
#       "result":     "<required> named outcome to record (must be a legal transition)",
#       "summary":    "<required> human-readable summary — UNTRUSTED, serialized only",
#       "outputs":    { ... },   // optional JSON object of named outputs — UNTRUSTED,
#                                // serialized only. KEY-PRESENCE semantics: a MISSING key OR
#                                // a present-but-null value is ABSENT (-> defaults to {}); a
#                                // present non-null value is SUPPLIED.
#       "plan_steps": [ ... ],   // optional cerebrate plan steps as a JSON array. This is the
#                                // PRIMARY, live writer of ledger.plan.steps: the overlord
#                                // supplies it when recording the `plan` state result (after
#                                // cerebrate returns). KEY-PRESENCE semantics: MISSING key OR
#                                // null value is ABSENT (-> .plan.* left UNTOUCHED, never
#                                // clobbered to []); a present non-null value is SUPPLIED ->
#                                // .plan.steps = the array. UNTRUSTED step text — enters jq
#                                // ONLY via --argjson (pre-validated JSON).
#       "plan_path":  "<optional> path to the cerebrate directive. KEY-PRESENCE semantics: a
#                      MISSING key OR null value is ABSENT (-> .plan.path UNTOUCHED); a present
#                      non-null value is SUPPLIED -> .plan.path = the (nullable) text.
#                      UNTRUSTED — enters jq ONLY via --arg."
#     }
#
# OUTPUT:
#   - On success: writes the mutated ledger atomically and prints YAML routing lines:
#       previous_state: <state>
#       result: <result>
#       current_state: <next_state>
#       ledger: <path>
#     Exits 0.
#   - On any failure / illegal transition: prints `blocker: <reason>` to stderr, exits 1,
#     ledger byte-unchanged.
#
# EXIT CONTRACT:
#   0  transition recorded + ledger advanced
#   1  validation failure / illegal transition (ledger UNCHANGED)
#
# set -u: an unset variable is a programming error (every value is parsed from the inputs
# file). No `set -e`: failures route through blocker() with a verbose reason.
#
# P18 FLOOR EXCEPTION (ADR-0020 / CHECK13 allowlisted): `set -u` only — `set -e`/`pipefail`
# are DELIBERATELY omitted. The full floor would change behavior: `jq -e has(...)`
# key-presence probes legitimately return non-zero in the normal absent-key flow, and
# transition/binding validation feeds blocker() (ledger left byte-unchanged) — `set -e`
# would abort mid-validation.

set -u

blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# SAFE_ID charset for identity components (mirrors init-run-ledger.sh). The reserved
# components "." and ".." pass this class but must be rejected explicitly (path traversal).
SAFE_ID_RE='^[A-Za-z0-9._-]+$'

# ── Script self-location (portable; independent of ${CLAUDE_PLUGIN_ROOT} and the caller) ──
# Resolve the packaged workflows dir from THIS script's own location, never from a caller
# value. `cd ... && pwd -P` is portable (no GNU-only readlink -f); BASH_SOURCE is set under
# `#!/usr/bin/env bash`. Layout: plugin/skills/record-state-result/scripts/ => 3 dirs up is
# the plugin root (verified against the real tree).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$(cd "$script_dir/../../.." && pwd -P)"
workflows_dir="$plugin_root/workflows"

# Source the shared containment helper ONCE, early — it provides both the inputs-file
# READ-guard (hivemind_assert_inputs_contained, used right after the inputs validity
# checks) and the write-chain guard (hivemind_assert_contained, used before the ledger
# temp-write). Sourcing once here keeps a single load point for both call sites below.
. "$plugin_root/skills/_shared/containment.sh"

# Source the shared ledger engine-IO helper by the SAME self-located absolute path. It
# provides hivemind_read_inputs_file (the inputs-file bootstrap) and hivemind_open_ledger
# (the depth-complete ledger-read/containment/coherence/post-existence chain). Both functions
# ORCHESTRATE the containment.sh helpers sourced above, so this MUST follow that source.
. "$plugin_root/skills/_shared/ledger-engine-io.sh"

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to read and write the run ledger but is not installed"

# ── Inputs file ───────────────────────────────────────────────────────────────
# Single positional argument: the path to a JSON inputs file the agent authored via the
# Write tool. The path is the ONLY value passed on the command line; every field (including
# the untrusted summary/outputs/plan_steps/plan_path) is read with jq into inert variables
# below — never interpolated into bash source or the jq program SOURCE.
INPUTS_FILE="${1:-}"

# ── Inputs-file bootstrap (shared helper) ──────────────────────────────────────
# hivemind_read_inputs_file performs, IN ORDER: the non-empty-arg check, the `[ -f ]`
# existence check, the hivemind_assert_inputs_contained defense-in-depth read-guard (run
# BEFORE the jq validity probe — `jq -e` on an attacker path is itself a JSON-validity read
# oracle), and the `jq -e .` JSON-validity probe. The "record-state-result" label reproduces
# this engine's EXACT current blocker strings. The helper never exits: it prints the reason
# to stderr (no `blocker: ` prefix) and returns non-zero. We capture that reason and re-emit
# it through blocker() so the on-screen bytes (the `blocker: ` prefix + exit 1) are identical
# to the prior inline checks.
inputs_err="$(hivemind_read_inputs_file "$INPUTS_FILE" "record-state-result" 2>&1)" \
  || blocker "$inputs_err"

# ── Parse fields into inert variables ─────────────────────────────────────────
# Required strings via `jq -r '.field // ""'`. The presence bools derive from KEY-PRESENCE on
# the inputs object: a MISSING key OR a present-but-null value is ABSENT; a present non-null
# value is SUPPLIED. This preserves EXACTLY the prior flag semantics — absent outputs defaults
# to {}, absent plan_steps/plan_path leaves .plan.* UNTOUCHED (never clobbered to []).
run_id="$(jq -r '.run_id // ""' "$INPUTS_FILE")"
state="$(jq -r '.state // ""' "$INPUTS_FILE")"
result="$(jq -r '.result // ""' "$INPUTS_FILE")"
summary="$(jq -r '.summary // ""' "$INPUTS_FILE")"

# have_outputs: outputs key present AND non-null. When supplied, read the raw JSON value
# (preserving its type for the up-front object check and the --argjson serialization).
if jq -e 'has("outputs") and .outputs != null' "$INPUTS_FILE" >/dev/null 2>&1; then
  have_outputs=true
  outputs="$(jq -c '.outputs' "$INPUTS_FILE")"
else
  have_outputs=false
  outputs=""
fi

# have_plan_steps: plan_steps key present AND non-null (-> .plan.steps written). Absent ->
# .plan.* left untouched. UNTRUSTED step text reaches jq ONLY via --argjson below.
if jq -e 'has("plan_steps") and .plan_steps != null' "$INPUTS_FILE" >/dev/null 2>&1; then
  have_plan_steps=true
  plan_steps="$(jq -c '.plan_steps' "$INPUTS_FILE")"
else
  have_plan_steps=false
  plan_steps=""
fi

# have_plan_path: plan_path key present AND non-null (-> .plan.path written). Absent ->
# .plan.path left untouched. UNTRUSTED — reaches jq ONLY via --arg below.
if jq -e 'has("plan_path") and .plan_path != null' "$INPUTS_FILE" >/dev/null 2>&1; then
  have_plan_path=true
  plan_path="$(jq -r '.plan_path' "$INPUTS_FILE")"
else
  have_plan_path=false
  plan_path=""
fi

# ── Required-input validation ─────────────────────────────────────────────────
[ -n "$run_id" ]  || blocker "inputs file is missing required run_id"
[ -n "$state" ]   || blocker "inputs file is missing required state"
[ -n "$result" ]  || blocker "inputs file is missing required result"
[ -n "$summary" ] || blocker "inputs file is missing required summary"

# run_id must be a single safe path component (SAFE_ID_RE + reserved-component reject). This
# is the ONLY identity the caller supplies; every path below is derived from it.
printf '%s' "$run_id" | grep -Eq "$SAFE_ID_RE" \
  || blocker "run_id is not a safe path component: $run_id"
case "$run_id" in
  .|..) blocker "run_id is a reserved path component: $run_id" ;;
esac

# ── DERIVE the ledger path from git-root + run_id (NO caller path) ─────────────
# repo_root anchors the ledger to the checkout root, mirroring init-run-ledger.sh. Empty =
# not inside a git checkout = blocker. The caller never supplies a ledger path, so an
# arbitrary-file overwrite via a caller path is structurally impossible.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo_root" ] || blocker "not inside a git repository"
# Raw textual ledger path (matches the prior inline derivation). The reads below
# (workflow-derive, coherence already done by the helper, state.current / binding-guard
# validation) all reference this raw path; the containment guards inside hivemind_open_ledger
# proved that the raw path and its canonical form resolve to the same in-checkout file. The
# atomic-write block below re-points $ledger at the CANONICAL path before any mktemp/mv.
ledger="$repo_root/.hivemind/runs/$run_id/state.json"

# ── Ledger-open machinery (shared helper) — BEFORE any ledger read ─────────────
# hivemind_open_ledger performs, IN THIS EXACT ORDER (a reordering silently breaks engine
# determinism): ledger-path derivation, the hivemind_assert_contained ancestor guard, the
# canonical-runs-dir canonicalization + trailing-slash prefix case-guard, the
# hivemind_assert_ledger_contained leaf guard (rejects a symlinked state.json LEAF), the
# `[ -f ]` existence + `jq -e .` validity reads, the coherence check (`.run.id == run_id`),
# and the post-existence canonical ledger-dir confirmation (canon dir + state.json/run_id
# basename asserts). On SUCCESS it echoes TWO stdout lines — line 1 = $canon_ledger,
# line 2 = $canon_ledger_dir — which we read back below. The helper never exits: on failure it
# prints the reason to stderr (no `blocker: ` prefix) and returns non-zero. We route stderr to
# a temp file and re-emit any reason through blocker() so the on-screen bytes (the `blocker: `
# prefix + exit 1) are identical to the prior inline guards. (containment.sh + the helper were
# sourced once early, just after plugin_root is computed.)
ledger_open_err="$(mktemp)" \
  || blocker "failed to create temp file for ledger-open diagnostics"
if ledger_open_out="$(hivemind_open_ledger "$repo_root" "$run_id" 2>"$ledger_open_err")"; then
  rm -f "$ledger_open_err"
else
  ledger_open_reason="$(cat "$ledger_open_err")"
  rm -f "$ledger_open_err"
  blocker "$ledger_open_reason"
fi

# Read the helper's two stdout lines: line 1 = canonical ledger path, line 2 = canonical
# ledger dir. Both are pwd -P paths under the checkout (no embedded newlines), so the
# two-line protocol is byte-safe. These feed the atomic-write block below.
{ IFS= read -r canon_ledger; IFS= read -r canon_ledger_dir; } <<EOF
$ledger_open_out
EOF

# ── DERIVE the workflow definition from the (trusted) ledger's run.workflow ────
# The definition is resolved against the self-located PACKAGED workflows dir, never a caller
# path — so a forged definition cannot bypass the transition gate or the plan-write auth.
# Defense in depth: SAFE_ID_RE + ./.. reject on run.workflow even though the ledger is trusted.
run_workflow="$(jq -r '.run.workflow // ""' "$ledger")"
[ -n "$run_workflow" ] || blocker "ledger run.workflow is empty; cannot derive workflow definition"
printf '%s' "$run_workflow" | grep -Eq "$SAFE_ID_RE" \
  || blocker "ledger run.workflow is not a safe path component: $run_workflow"
case "$run_workflow" in
  .|..) blocker "ledger run.workflow is a reserved path component: $run_workflow" ;;
esac
workflow="$workflows_dir/$run_workflow.json"
[ -f "$workflow" ] || blocker "packaged workflow definition does not exist: $workflow"
jq -e . "$workflow" >/dev/null 2>&1 || blocker "workflow definition is not valid JSON: $workflow"

# If --outputs was supplied, it must be a valid JSON object (--argjson rejects
# non-JSON, but validate up front for a clear blocker rather than a jq parse error).
if [ "$have_outputs" = true ]; then
  printf '%s' "$outputs" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || blocker "--outputs must be a JSON object"
else
  outputs='{}'
fi

# If --plan-steps was supplied, it must be a valid JSON array (validated up front for a
# clear blocker — same posture as --outputs). UNTRUSTED step text never enters the jq
# program SOURCE; it flows ONLY through the --argjson binding in the mutate program below.
# When ABSENT, .plan.steps is left untouched (never clobbered to []).
if [ "$have_plan_steps" = true ]; then
  printf '%s' "$plan_steps" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || blocker "--plan-steps must be a JSON array"
fi

# ── Deterministic validation (ALL before any write) ───────────────────────────
# (1) ledger.state.current must equal --state.
ledger_current="$(jq -r '.state.current // ""' "$ledger")"
[ "$ledger_current" = "$state" ] \
  || blocker "ledger state.current '$ledger_current' does not match --state '$state'; ledger unchanged"

# Workflow id for clear error messages and the definition<->ledger binding guard.
workflow_id="$(jq -r '.id // ""' "$workflow")"

# (2) BINDING GUARD: the supplied definition MUST bind to this ledger. The engine
# HARD-REJECTS a non-binding definition (exit 1, ledger byte-unchanged); it does NOT
# attempt to reconcile. Version-skew reconciliation is owned by the overlord resume-on-start
# gate's two doors (start fresh / proceed intent-driven), NOT here. There is NO
# deterministic-resume door — the engine exposes no rebind surface.
# These checks run BEFORE the state-existence check and BEFORE any temp-file creation, so a
# binding failure never mutates a byte of the on-disk ledger.
#   (2a) definition.id == ledger.run.workflow.
ledger_workflow="$(jq -r '.run.workflow // ""' "$ledger")"
[ "$workflow_id" = "$ledger_workflow" ] \
  || blocker "workflow definition id '$workflow_id' does not match ledger run.workflow '$ledger_workflow'; ledger unchanged"
#   (2b) definition.version == ledger.run.workflow_version (engine hard-reject half of the
#   §I policy; the overlord resume gate owns the two version-skew doors).
ledger_wf_version="$(jq -r '.run.workflow_version // empty' "$ledger")"
def_version="$(jq -r '.version // empty' "$workflow")"
[ "$def_version" = "$ledger_wf_version" ] \
  || blocker "workflow definition version '$def_version' does not match ledger run.workflow_version '$ledger_wf_version'; ledger unchanged (resume gate owns version-skew doors)"

# (3) --state must exist in definition.states (named state must exist in the definition;
# a renamed/removed state is never guessed). This is state-existence, NOT version-skew.
state_exists="$(jq --arg s "$state" '.states | has($s)' "$workflow")"
[ "$state_exists" = "true" ] \
  || blocker "state '$state' not found in workflow '$workflow_id'"

# (4) read the allowed-set DIRECTLY from definition.states[state].transitions; --result
# must be a key. The model never supplies this set.
result_valid="$(jq --arg s "$state" --arg r "$result" \
  '(.states[$s].transitions // {}) | has($r)' "$workflow")"
[ "$result_valid" = "true" ] \
  || blocker "result '$result' not valid from state '$state'"

# (5) resolve next_state.
next_state="$(jq -r --arg s "$state" --arg r "$result" \
  '.states[$s].transitions[$r]' "$workflow")"
[ -n "$next_state" ] && [ "$next_state" != "null" ] \
  || blocker "transition '$result' from state '$state' resolves to an empty target"

# (6) PLAN-WRITE AUTHORIZATION: --plan-steps / --plan-path may ONLY be honored when the
# state being recorded is a cerebrate planning state (definition.states[<state>].agent ==
# "hivemind:cerebrate"). This authorizes exactly the cerebrate agent states (plan /
# review_remediation_plan / brood_plan) and forbids every other state from mutating the
# plan — flag PRESENCE alone is NOT sufficient. This guard runs BEFORE mktemp and the
# temp-write, so a rejection leaves the on-disk ledger byte-unchanged. The untrusted plan
# values still reach jq solely via --arg/--argjson; here only the engine-validated $state
# (an existing definition key) is interpolated into the message.
if [ "$have_plan_steps" = true ] || [ "$have_plan_path" = true ]; then
  state_agent="$(jq -r --arg s "$state" '.states[$s].agent // ""' "$workflow")"
  [ "$state_agent" = "hivemind:cerebrate" ] \
    || blocker "plan steps may only be written from a cerebrate planning state; state '$state' (agent '$state_agent') is not authorized; ledger unchanged"
fi

# (10 pre-compute) determine whether next_state is a declared terminal and map its
# run/state status. The schema constrains run.status to running|complete|blocked|
# cancelled. The human-intervention terminals (user_input_required, review_rejected,
# review_exhausted) are "stopped, needs attention" outcomes and map to blocked — NOT
# complete — so a stalled run is never masked as success. Only genuine done-terminals
# (e.g. complete, hatchery_monitor) are complete-equivalent.
is_terminal="$(jq --arg n "$next_state" '(.terminal // []) | index($n) != null' "$workflow")"
if [ "$is_terminal" = "true" ]; then
  case "$next_state" in
    blocked)   terminal_status="blocked" ;;
    cancelled) terminal_status="cancelled" ;;
    user_input_required|review_rejected|review_exhausted) terminal_status="blocked" ;;
    *)         terminal_status="complete" ;;
  esac
  run_status="$terminal_status"
  state_status="$terminal_status"
else
  run_status="running"
  state_status="running"
fi

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Atomic write: temp file beside the ledger, then mv into place ──────────────
# Use the CANONICAL (verified-contained) dir for the temp-write + atomic rename so both
# operate on the path that passed containment, not the raw textual one.
ledger_dir="$canon_ledger_dir"
ledger="$canon_ledger"
tmp_ledger="$(mktemp "$ledger_dir/.state.json.XXXXXX")" \
  || blocker "failed to create temp ledger file under $ledger_dir"

# Mutate via a single jq program. Untrusted --summary / --outputs / --plan-steps /
# --plan-path enter ONLY as --arg / --argjson bindings; the structural values (state,
# result, next_state, statuses, timestamp) are engine-validated. The plan.* clauses are
# appended to the program ONLY when their flags are present — flag PRESENCE (an inert
# bool), never the untrusted VALUE, decides which clauses run; the values themselves still
# arrive solely through --argjson/--arg. When a flag is absent the corresponding plan.*
# field is left untouched (NOT clobbered). INVARIANT: the input ledger is the file itself;
# on a jq failure the temp file is removed and the on-disk ledger is untouched.
plan_program=""
if [ "$have_plan_steps" = true ]; then
  plan_program="$plan_program
  | .plan.steps = \$plan_steps"
fi
if [ "$have_plan_path" = true ]; then
  plan_program="$plan_program
  | .plan.path = (if \$plan_path == \"\" then null else \$plan_path end)"
fi

jq \
  --arg at "$now_ts" \
  --arg state "$state" \
  --arg result "$result" \
  --arg next_state "$next_state" \
  --arg summary "$summary" \
  --argjson outputs "$outputs" \
  --arg run_status "$run_status" \
  --arg state_status "$state_status" \
  --argjson plan_steps "${plan_steps:-[]}" \
  --arg plan_path "$plan_path" \
  '
  .events += [{
    at: $at,
    state: $state,
    result: $result,
    next_state: $next_state,
    summary: $summary,
    outputs: $outputs
  }]
  | .state.previous = $state
  | .state.current = $next_state
  | .state.status = $state_status
  | .run.status = $run_status
  | .run.updated_at = $at'"$plan_program"'
  ' "$ledger" > "$tmp_ledger" \
  || { rm -f "$tmp_ledger"; blocker "failed to serialize the mutated ledger with jq; on-disk ledger unchanged"; }

mv -f "$tmp_ledger" "$ledger" \
  || { rm -f "$tmp_ledger"; blocker "failed to atomically install the mutated ledger at $ledger; on-disk ledger unchanged"; }

# ── Success routing ───────────────────────────────────────────────────────────
printf 'previous_state: %s\n' "$state"
printf 'result: %s\n' "$result"
printf 'current_state: %s\n' "$next_state"
printf 'ledger: %s\n' "$ledger"
exit 0
