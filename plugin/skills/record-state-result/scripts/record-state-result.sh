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
# INJECTION POSTURE: the untrusted fields --summary, --outputs, --plan-steps, and
# --plan-path are serialized via jq --arg / --argjson ONLY; they never enter the jq
# program or any shell command source. --plan-steps reaches jq solely as an --argjson
# binding; --plan-path solely as an --arg binding.
#
# FLAG INTERFACE:
#   --ledger <path>      (required) path to the run ledger state.json
#   --workflow <path>    (required) path to the workflow definition JSON
#   --state <state>      (required) the state the run is currently in (must match ledger)
#   --result <outcome>   (required) the named outcome to record (must be a legal transition)
#   --summary <text>     (required) human-readable summary — UNTRUSTED, serialized only
#   --outputs <json>     (optional) JSON object of named outputs — UNTRUSTED, serialized only
#   --plan-steps <json>  (optional) cerebrate's plan steps reformatted to a JSON array. This
#                        is the PRIMARY, live writer of ledger.plan.steps: the overlord passes
#                        it when recording the `plan` state result (after cerebrate returns).
#                        When present, .plan.steps = the array. When ABSENT, .plan.* is left
#                        UNTOUCHED (never clobbered to []). UNTRUSTED step text — enters jq
#                        ONLY via --argjson (pre-validated JSON), never the program/shell SOURCE.
#   --plan-path <text>   (optional) path to the cerebrate directive. When present, .plan.path =
#                        this (nullable) text. UNTRUSTED — enters jq ONLY via --arg.
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
# set -u: an unset variable is a programming error (every value is parsed from flags).
# No `set -e`: failures route through blocker() with a verbose reason.

set -u

blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to read and write the run ledger but is not installed"

# ── Flag parse into inert variables ───────────────────────────────────────────
ledger=""
workflow=""
state=""
result=""
summary=""
outputs=""
have_outputs=false
plan_steps=""
have_plan_steps=false
plan_path=""
have_plan_path=false

# require_value: every valued flag must be followed by an argument. A trailing valued flag
# with no value would otherwise consume "" and `shift 2` would fail against a single remaining
# positional — silently mis-parsing under set -u (no set -e). Reject with a clear blocker.
require_value() { [ "$#" -ge 2 ] || blocker "flag $1 requires a value"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger)     require_value "$@"; ledger="$2"; shift 2 ;;
    --workflow)   require_value "$@"; workflow="$2"; shift 2 ;;
    --state)      require_value "$@"; state="$2"; shift 2 ;;
    --result)     require_value "$@"; result="$2"; shift 2 ;;
    --summary)    require_value "$@"; summary="$2"; shift 2 ;;
    --outputs)    require_value "$@"; outputs="$2"; have_outputs=true; shift 2 ;;
    --plan-steps) require_value "$@"; plan_steps="$2"; have_plan_steps=true; shift 2 ;;
    --plan-path)  require_value "$@"; plan_path="$2"; have_plan_path=true; shift 2 ;;
    *) blocker "unknown argument: $1" ;;
  esac
done

# ── Required-input validation ─────────────────────────────────────────────────
[ -n "$ledger" ]   || blocker "missing required --ledger"
[ -n "$workflow" ] || blocker "missing required --workflow"
[ -n "$state" ]    || blocker "missing required --state"
[ -n "$result" ]   || blocker "missing required --result"
[ -n "$summary" ]  || blocker "missing required --summary"

[ -f "$ledger" ]   || blocker "ledger file does not exist: $ledger"
[ -f "$workflow" ] || blocker "workflow definition file does not exist: $workflow"

jq -e . "$ledger"   >/dev/null 2>&1 || blocker "ledger file is not valid JSON: $ledger"
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
ledger_dir="$(dirname "$ledger")"
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
