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
#   2. --state MUST exist in definition.states (the §I version-skew engine guard:
#      a renamed/removed state never guesses), else blocker + exit 1, UNCHANGED.
#   3. The allowed-result set is read DIRECTLY from definition.states[<state>].transitions
#      (keys). --result MUST be one of those keys, else blocker + exit 1, UNCHANGED.
#   4. next_state = transitions[result].
#   5. Append an event {at,state,result,next_state,summary,outputs}.
#   6. Update state.previous=state, state.current=next_state, state.status.
#   7. Update run.updated_at.
#   8. If next_state is a declared terminal, set run.status + state.status to the
#      matching terminal status (complete->complete, blocked->blocked,
#      cancelled->cancelled; any other terminal e.g. hatchery_monitor -> complete-
#      equivalent per the schema doc, which constrains run.status to
#      running|complete|blocked|cancelled).
#   9. Write via temp file + atomic mv so a concurrent hatchery reader never sees a
#      torn file.
#
# CRITICAL ATOMICITY: every write is temp-write + atomic rename. On ANY validation
# failure the on-disk ledger is byte-unchanged — no partial write ever occurs (all
# validation runs BEFORE the temp file is created).
#
# INJECTION POSTURE: the untrusted fields --summary and --outputs are serialized into
# the event object via jq --arg / --argjson ONLY; they never enter the jq program or
# any shell command source.
#
# FLAG INTERFACE:
#   --ledger <path>      (required) path to the run ledger state.json
#   --workflow <path>    (required) path to the workflow definition JSON
#   --state <state>      (required) the state the run is currently in (must match ledger)
#   --result <outcome>   (required) the named outcome to record (must be a legal transition)
#   --summary <text>     (required) human-readable summary — UNTRUSTED, serialized only
#   --outputs <json>     (optional) JSON object of named outputs — UNTRUSTED, serialized only
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger)   ledger="${2:-}"; shift 2 ;;
    --workflow) workflow="${2:-}"; shift 2 ;;
    --state)    state="${2:-}"; shift 2 ;;
    --result)   result="${2:-}"; shift 2 ;;
    --summary)  summary="${2:-}"; shift 2 ;;
    --outputs)  outputs="${2:-}"; have_outputs=true; shift 2 ;;
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

# ── Deterministic validation (ALL before any write) ───────────────────────────
# (1) ledger.state.current must equal --state.
ledger_current="$(jq -r '.state.current // ""' "$ledger")"
[ "$ledger_current" = "$state" ] \
  || blocker "ledger state.current '$ledger_current' does not match --state '$state'; ledger unchanged"

# Workflow id for clear error messages.
workflow_id="$(jq -r '.id // ""' "$workflow")"

# (2) --state must exist in definition.states (§I version-skew engine guard).
state_exists="$(jq --arg s "$state" '.states | has($s)' "$workflow")"
[ "$state_exists" = "true" ] \
  || blocker "state '$state' not found in workflow '$workflow_id'"

# (3) read the allowed-set DIRECTLY from definition.states[state].transitions; --result
# must be a key. The model never supplies this set.
result_valid="$(jq --arg s "$state" --arg r "$result" \
  '(.states[$s].transitions // {}) | has($r)' "$workflow")"
[ "$result_valid" = "true" ] \
  || blocker "result '$result' not valid from state '$state'"

# (4) resolve next_state.
next_state="$(jq -r --arg s "$state" --arg r "$result" \
  '.states[$s].transitions[$r]' "$workflow")"
[ -n "$next_state" ] && [ "$next_state" != "null" ] \
  || blocker "transition '$result' from state '$state' resolves to an empty target"

# (8 pre-compute) determine whether next_state is a declared terminal and map its
# run/state status. The schema constrains run.status to running|complete|blocked|
# cancelled, so any terminal other than blocked/cancelled is complete-equivalent.
is_terminal="$(jq --arg n "$next_state" '(.terminal // []) | index($n) != null' "$workflow")"
if [ "$is_terminal" = "true" ]; then
  case "$next_state" in
    blocked)   terminal_status="blocked" ;;
    cancelled) terminal_status="cancelled" ;;
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

# Mutate via a single jq program. Untrusted --summary / --outputs enter ONLY as
# --arg / --argjson bindings; the structural values (state, result, next_state,
# statuses, timestamp) are engine-validated. INVARIANT: the input ledger is the file
# itself; on a jq failure the temp file is removed and the on-disk ledger is untouched.
jq \
  --arg at "$now_ts" \
  --arg state "$state" \
  --arg result "$result" \
  --arg next_state "$next_state" \
  --arg summary "$summary" \
  --argjson outputs "$outputs" \
  --arg run_status "$run_status" \
  --arg state_status "$state_status" \
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
  | .run.updated_at = $at
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
