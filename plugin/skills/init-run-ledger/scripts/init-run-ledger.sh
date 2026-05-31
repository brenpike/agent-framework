#!/usr/bin/env bash
#
# init-run-ledger — deterministic run-ledger initializer for the
# hivemind:init-run-ledger skill.
#
# Creates the per-run state directory and writes the initial run ledger
# (<checkout-root>/.hivemind/runs/<run-id>/state.json) per
# ${CLAUDE_PLUGIN_ROOT}/references/run-ledger-schema.md. The run dir is anchored to the
# git checkout ROOT (git rev-parse --show-toplevel), NOT $(pwd): a CWD-relative dir placed
# the ledger under whatever subdir the script ran from, so resume-on-start (which looks at
# the checkout-root location) could not find it and spawned a DUPLICATE run. In a LINKED
# worktree --show-toplevel resolves to the worktree root (correct — a brood child's ledger
# lives in the child worktree, matching spawn-brood's per-strain suggested ledger path).
# Init now REQUIRES being inside a git checkout (the overlord only inits inside one).
# This script OWNS the deterministic create-and-write; the skill body is a thin
# navigator that gathers inputs and calls this script once. Mirrors the
# spawn-brood.sh committed-script precedent (shebang, set -u, blocker() helper, jq
# parsing into inert variables, structured stdout routing, exit codes).
#
# INJECTION POSTURE: every ledger field is serialized with `jq -n` using --arg
# (strings) / --argjson (pre-validated JSON), NEVER string-interpolated into the jq
# program or any shell command source. The untrusted fields request.raw,
# request.normalized, and every parent-block text value enter the jq program only as
# named --arg bindings, so untrusted bytes never become program/command SOURCE.
# The ledger is written to a temp file and atomically renamed into place so a
# concurrent reader (the hatchery reading a child ledger) never sees a torn file.
#
# FLAG INTERFACE:
#   --workflow <id>            (required) selected workflow id; matches plugin/workflows/<id>.json
#   --workflow-version <int>   (required) the definition version at init time
#   --start-state <state>      (required) the workflow's start state (state.current at init)
#   --user-request <text>      (required) raw user request — UNTRUSTED data, serialized only
#   --normalized <text>        (required) overlord's normalized summary of the request
#   --parent-kind <kind>       (optional) none|brood ; default none
#   --parent-run-id <id>       (required when --parent-kind=brood) parent run id
#   --parent-brood-id <id>     (required when --parent-kind=brood) brood id
#   --parent-strain-id <id>    (required when --parent-kind=brood) strain id
#   --parent-manifest <path>   (required when --parent-kind=brood) manifest path
#   --suggested-run-id <id>    (optional) caller-suggested run id; used verbatim only if
#                              it matches ^[A-Za-z0-9._-]+$, else a derived id is used.
#   --plan-steps <json-array>  (optional) cerebrate's plan steps reformatted to a JSON
#                              array — the child/resume SEED path for plan.steps (NOT the
#                              primary live writer; record-state-result --plan-steps at the
#                              `plan` state is primary). UNTRUSTED step text — enters jq ONLY
#                              via --argjson (pre-validated JSON). Default [].
#   --plan-path <text>         (optional) path to the cerebrate directive — child/resume seed
#                              for plan.path. Default null.
#
# RUN-ID DERIVATION:
#   - --parent-kind=brood: child form <brood-id>--<strain-id> (both required, both must
#     match the safe charset).
#   - else if --suggested-run-id is safe (^[A-Za-z0-9._-]+$): use it verbatim.
#   - else derived: <utc-timestamp>-<workflow-id> (timestamp colons mapped to dashes so
#     the id is a safe directory name).
#
# OUTPUT:
#   - On success: creates <checkout-root>/.hivemind/runs/<run-id>/ and its evidence/ subdir,
#     writes state.json, prints YAML routing lines to stdout and exits 0:
#       run_id: <id>
#       ledger: <checkout-root>/.hivemind/runs/<id>/state.json
#   - On any failure: prints `blocker: <reason>` to stderr, exits 1, writes no ledger.
#
# EXIT CONTRACT:
#   0  ledger initialized
#   1  pre-flight blocker (missing/invalid inputs, unsafe ids, fs failure)
#
# set -u: an unset variable is a programming error here (every value is parsed
# explicitly from flags). We do NOT use `set -e`: failures are routed through the
# blocker() helper with a verbose reason rather than a bubbled raw tool error.

set -u

blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# SAFE_ID charset for run-id components and suggested run ids.
SAFE_ID_RE='^[A-Za-z0-9._-]+$'

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to write the run ledger but is not installed"

# ── Flag parse into inert variables ───────────────────────────────────────────
workflow=""
workflow_version=""
start_state=""
user_request=""
normalized=""
parent_kind="none"
parent_run_id=""
parent_brood_id=""
parent_strain_id=""
parent_manifest=""
suggested_run_id=""
plan_steps="[]"
plan_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workflow)          workflow="${2:-}"; shift 2 ;;
    --workflow-version)  workflow_version="${2:-}"; shift 2 ;;
    --start-state)       start_state="${2:-}"; shift 2 ;;
    --user-request)      user_request="${2:-}"; shift 2 ;;
    --normalized)        normalized="${2:-}"; shift 2 ;;
    --parent-kind)       parent_kind="${2:-}"; shift 2 ;;
    --parent-run-id)     parent_run_id="${2:-}"; shift 2 ;;
    --parent-brood-id)   parent_brood_id="${2:-}"; shift 2 ;;
    --parent-strain-id)  parent_strain_id="${2:-}"; shift 2 ;;
    --parent-manifest)   parent_manifest="${2:-}"; shift 2 ;;
    --suggested-run-id)  suggested_run_id="${2:-}"; shift 2 ;;
    --plan-steps)        plan_steps="${2:-}"; shift 2 ;;
    --plan-path)         plan_path="${2:-}"; shift 2 ;;
    *) blocker "unknown argument: $1" ;;
  esac
done

# ── Required-input validation ─────────────────────────────────────────────────
[ -n "$workflow" ]         || blocker "missing required --workflow"
[ -n "$workflow_version" ] || blocker "missing required --workflow-version"
[ -n "$start_state" ]      || blocker "missing required --start-state"
[ -n "$user_request" ]     || blocker "missing required --user-request"
[ -n "$normalized" ]       || blocker "missing required --normalized"

# workflow_version must be an integer (it becomes a JSON number via --argjson).
case "$workflow_version" in
  ''|*[!0-9]*) blocker "--workflow-version must be a non-negative integer, got: $workflow_version" ;;
esac

# parent_kind selects the parent variant.
case "$parent_kind" in
  none|brood) : ;;
  *) blocker "--parent-kind must be none|brood, got: $parent_kind" ;;
esac

# --plan-steps (default []) must be a JSON array. Validated up front for a clear blocker
# rather than a downstream --argjson parse error. UNTRUSTED step text never enters the jq
# program SOURCE — only as the named --argjson binding below.
printf '%s' "$plan_steps" | jq -e 'type=="array"' >/dev/null 2>&1 \
  || blocker "--plan-steps must be a JSON array"

# ── Run-id derivation ─────────────────────────────────────────────────────────
run_id=""
if [ "$parent_kind" = "brood" ]; then
  # Child form <brood-id>--<strain-id>; both components required and safe.
  [ -n "$parent_brood_id" ]  || blocker "--parent-kind=brood requires --parent-brood-id"
  [ -n "$parent_strain_id" ] || blocker "--parent-kind=brood requires --parent-strain-id"
  # parent_run_id and parent_manifest identify the hatchery relationship (run-ledger-schema
  # brood variant). A child that omits either while translating its injected metadata would
  # otherwise write a brood ledger with null ancestry fields, silently breaking the
  # reconciliation trail — so require both non-empty before creating the ledger.
  [ -n "$parent_run_id" ]    || blocker "--parent-kind=brood requires --parent-run-id"
  [ -n "$parent_manifest" ]  || blocker "--parent-kind=brood requires --parent-manifest"
  case "$parent_brood_id"  in *[!A-Za-z0-9._-]*) blocker "--parent-brood-id contains characters outside [A-Za-z0-9._-]: $parent_brood_id" ;; esac
  case "$parent_strain_id" in *[!A-Za-z0-9._-]*) blocker "--parent-strain-id contains characters outside [A-Za-z0-9._-]: $parent_strain_id" ;; esac
  run_id="${parent_brood_id}--${parent_strain_id}"
elif [ -n "$suggested_run_id" ] && printf '%s' "$suggested_run_id" | grep -Eq "$SAFE_ID_RE"; then
  run_id="$suggested_run_id"
else
  # Derived form <utc-timestamp>-<workflow-id>. Map colons to dashes for a safe dir name.
  utc_ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  # Reject a workflow id that would make an unsafe directory component.
  case "$workflow" in *[!A-Za-z0-9._-]*) blocker "--workflow contains characters outside [A-Za-z0-9._-]; cannot derive a safe run id: $workflow" ;; esac
  run_id="${utc_ts}-${workflow}"
fi

# Final defensive check: the resolved run_id must be a safe single path component.
printf '%s' "$run_id" | grep -Eq "$SAFE_ID_RE" \
  || blocker "resolved run id is not a safe path component: $run_id"
case "$run_id" in
  .|..) blocker "resolved run id is a reserved path component: $run_id" ;;
esac

# ── Directory creation ────────────────────────────────────────────────────────
# Anchor the run dir to the git checkout ROOT, not $(pwd). Started from a subdir a
# CWD-relative path misplaced the ledger, so resume-on-start (which reads the checkout-root
# location) could not find it and spawned a duplicate run. In a linked worktree
# --show-toplevel resolves to the worktree root (correct for brood children). Mirrors
# spawn-brood.sh's repo_root precedent. Empty result = not inside a git checkout = blocker.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo_root" ] || blocker "not inside a git repository"
run_dir="$repo_root/.hivemind/runs/$run_id"
ledger_path="$run_dir/state.json"

[ -e "$ledger_path" ] && blocker "a ledger already exists at $ledger_path; refusing to overwrite"

mkdir -p "$run_dir/evidence" \
  || blocker "failed to create run directory $run_dir/evidence"

# ── Parent block (argjson assembled from --arg bindings) ──────────────────────
# Build the parent object inside jq from named --arg bindings so untrusted parent
# text never enters the jq program SOURCE. null-out the brood-only fields when kind=none.
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Atomic write: temp file in the run dir, then mv into place ─────────────────
# Temp file lives in the same directory as the target so the rename is on the same
# filesystem (atomic). mktemp template keeps it adjacent to state.json.
tmp_ledger="$(mktemp "$run_dir/.state.json.XXXXXX")" \
  || blocker "failed to create temp ledger file under $run_dir"

# Every field flows through --arg/--argjson. Untrusted: user_request, normalized,
# and all parent-* text values. Pre-validated numbers via --argjson.
jq -n \
  --argjson schema_version 1 \
  --arg run_id "$run_id" \
  --arg workflow "$workflow" \
  --argjson workflow_version "$workflow_version" \
  --arg created_at "$now_ts" \
  --arg updated_at "$now_ts" \
  --arg parent_kind "$parent_kind" \
  --arg parent_run_id "$parent_run_id" \
  --arg parent_brood_id "$parent_brood_id" \
  --arg parent_strain_id "$parent_strain_id" \
  --arg parent_manifest "$parent_manifest" \
  --arg request_raw "$user_request" \
  --arg request_normalized "$normalized" \
  --arg start_state "$start_state" \
  --argjson plan_steps "$plan_steps" \
  --arg plan_path "$plan_path" \
  '
  def nz(s): if s == "" then null else s end;
  {
    schema_version: $schema_version,
    run: {
      id: $run_id,
      workflow: $workflow,
      workflow_version: $workflow_version,
      status: "running",
      mode: "deterministic",
      created_at: $created_at,
      updated_at: $updated_at
    },
    parent: {
      kind: $parent_kind,
      run_id: nz($parent_run_id),
      brood_id: nz($parent_brood_id),
      strain_id: nz($parent_strain_id),
      manifest: nz($parent_manifest)
    },
    request: {
      raw: $request_raw,
      normalized: $request_normalized
    },
    state: {
      current: $start_state,
      previous: null,
      status: "running"
    },
    facts: {
      branch: null,
      base: null,
      pr: null
    },
    plan: {
      path: nz($plan_path),
      current_step: null,
      steps: $plan_steps
    },
    artifacts: {},
    events: [],
    blockers: []
  }
  ' > "$tmp_ledger" \
  || { rm -f "$tmp_ledger"; blocker "failed to serialize the run ledger with jq"; }

mv -f "$tmp_ledger" "$ledger_path" \
  || { rm -f "$tmp_ledger"; blocker "failed to atomically install the run ledger at $ledger_path"; }

# ── Success routing ───────────────────────────────────────────────────────────
printf 'run_id: %s\n' "$run_id"
printf 'ledger: %s\n' "$ledger_path"
exit 0
