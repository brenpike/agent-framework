#!/usr/bin/env bash
#
# triage-ops.sh — deterministic MECHANISM substrate for the hivemind
# `triage-backlog` skill (judgment/mechanism split; engineering-principles P5 +
# P11). Path: ${CLAUDE_PLUGIN_ROOT}/skills/triage-backlog/scripts/triage-ops.sh
#
# 1. PURPOSE
# ----------
# This script owns ONLY the lossless, deterministic mechanism of issue triage.
# NO rating / judgment logic lives here — choosing a readiness / type / effort /
# moscow / priority / risk / difficulty value for an issue is holistic LLM work
# (P11) and stays in the SKILL prose. The script is the reproducible hands:
#   - bake + idempotently ensure the fixed label palette (name->color->family),
#   - enumerate open issues with their current labels in one call,
#   - apply a rating as labels with PER-FAMILY MUTUAL EXCLUSION (clean reconcile),
#   - read + add NATIVE GitHub issue dependencies (blocked-by) via GraphQL,
#   - surface a GitHub-rejected dependency cycle as a STRUCTURED warning record
#     instead of crashing.
# The split mirrors fetch-normalize.sh: a thin live `gh`/network shell wrapping a
# pure, offline-exercisable transform core.
#
# 2. INPUT CONTRACT — per subcommand
# ----------------------------------
#   ensure-labels
#     args:    none
#     online:  create-or-update every palette label (gh label create --force;
#              idempotent + self-healing color). NEVER deletes any label
#              (foreign labels and triage:locked content are untouched).
#     offline: emits the baked palette JSON; performs no gh call.
#
#   list-issues [--limit N] [--response-file <path|->]
#     online:  gh issue list --state open --limit N
#                --json number,title,labels,body,id   (id = GraphQL node id)
#     offline: re-emits the injected --response-file verbatim (identity), no gh.
#     N defaults to 500. PRs are excluded by `gh issue list` default.
#
#   apply-labels <issue-number> --targets <json> | --targets-file <path>
#                                [--current-labels-file <path|->]
#     <json> is a family->value object, e.g. {"priority":"high","type":"bug"}.
#     Only the families PRESENT in the object are reconciled; absent families are
#     left untouched. Every "<family>:<value>" MUST be a managed palette label
#     (validated against the palette — an unknown family/value fails CLOSED).
#     online:  derives current labels UNCONDITIONALLY from `gh issue view` (ground
#              truth); if triage:locked is present it emits a skipped-locked record
#              and mutates NOTHING; otherwise applies the computed delta via one
#              `gh issue edit`. --current-labels-file is a TEST SEAM and is honored
#              ONLY when TRIAGE_OPS_OFFLINE is set — supplying it in the live path
#              is REJECTED fail-closed (it could spoof label state, incl. omitting
#              triage:locked to bypass the human-only lock).
#     offline: reads current labels from --current-labels-file (a JSON array of
#              label-name strings) and emits the computed delta JSON; no gh.
#
#   deps-read <issue-number> [--response-file <path|->]
#     online:  gh api graphql — repository.issue(number).blockedByIssues.
#     offline: normalizes the injected --response-file (a raw GraphQL response).
#
#   deps-add --issue-id <NODE_ID> --blocked-by-id <NODE_ID> [--response-file <path|->]
#     Operates on GraphQL NODE IDs (from list-issues' `id` field), not numbers —
#     no number->id resolution round-trip is needed because the skill already has
#     the ids. ADD-ONLY: never removes an existing dependency.
#     online:  runs the addBlockedBy mutation and surfaces the response.
#     offline: with --response-file -> surfaces that injected response (exercises
#              the cycle/error/success records); without it -> emits the
#              constructed GraphQL variables payload (exercises payload build).
#
# 3. OUTPUT SCHEMA — JSON on stdout (compact)
# -------------------------------------------
#   ensure-labels (offline) / palette:
#     [ { "name": <str>, "color": <hex6-no-#>, "family": <str>, "managed": bool }, ... ]
#
#   apply-labels delta (offline, and the applied set echoed online):
#     { "issue": <int>, "remove": [<label-name>...], "add": [<label-name>...] }
#   apply-labels online, additionally one of:
#     { "issue": <int>, "status": "applied",       "remove": [...], "add": [...] }
#     { "issue": <int>, "status": "skipped-locked" }   # triage:locked present
#
#   deps-read normalized:
#     { "issue": <int|null>, "id": <node-id|null>,
#       "blocked_by": [ { "number": <int>, "id": <node-id>, "title": <str> }, ... ] }
#
#   deps-add payload (offline, no --response-file):
#     { "issueId": <node-id>, "blockedByIssueId": <node-id> }
#   deps-add surfaced response (online, or offline with --response-file):
#     added:   { "status": "added",   "issue": <int>, "blocked_by": <int> }
#     warning: { "status": "warning", "kind": "cycle-rejected"|"error"|"transport-error",
#                "message": <str> }
#
# 4. INVARIANTS
# -------------
#   - PER-FAMILY MUTUAL EXCLUSION (clean reconcile): for each family in --targets,
#     the delta REMOVES every existing "<family>:*" label that is not the chosen
#     value and ADDS the chosen value if absent. End state: exactly the chosen
#     value in that family. This is minimal-churn (an already-correct value is not
#     removed-and-re-added) yet self-correcting for the conflicting-duplicate case
#     (e.g. a stray second priority:* is removed). Families NOT in --targets are
#     never touched.
#   - NEVER touches triage:locked. It is a human-only control label: the script
#     ensures it EXISTS (ensure-labels) but never adds or removes it, and refuses
#     to mutate any issue carrying it (skipped-locked). "triage" is never a target
#     family, so the mutex prefix match can never select triage:locked.
#   - NEVER deletes foreign labels. Reconcile only removes labels whose prefix is a
#     family PRESENT in --targets and whose value differs from the chosen one;
#     anything outside the seven managed families (incl. initiative:*, wontfix, …)
#     is invisible to the delta. ensure-labels uses create/update only — no delete.
#   - NEVER touches initiative:* (a special case of the foreign-label invariant —
#     this skill is grouping-agnostic).
#   - ADD-ONLY dependencies. deps-add never removes an existing dependency; removal
#     is a human decision outside this script.
#   - A GitHub-rejected dependency CYCLE is surfaced as a warning record (kind
#     cycle-rejected) with exit 0 — the script never crashes on it, so a batch
#     keeps going (issues are independent).
#   - Untrusted issue body/title is DATA: it flows only through `gh --json` output
#     and is never interpolated into shell or into GraphQL query source. GraphQL
#     variables are passed via `gh api graphql -f/-F`, never string-concatenated.
#   - FAIL-CLOSED on malformed injected input to a pure transform (bad --targets,
#     unknown family/value, unreadable injection file) — distinct from the review
#     loop's fail-open posture; here a malformed rating is a usage bug, not noise.
#
# 5. OFFLINE TEST SEAM (STEP-002 depends on this)
# -----------------------------------------------
# Set env TRIAGE_OPS_OFFLINE to any non-empty value to make EVERY subcommand skip
# ALL gh/network calls and instead drive its pure transform over INJECTED input,
# emitting the deterministic artifact (palette / delta / payload / surfaced
# record / normalized deps) to stdout. Input that would normally come from gh is
# injected via flags: --current-labels-file (apply-labels), --response-file
# (deps-read, deps-add, list-issues). --current-labels-file is honored ONLY when
# TRIAGE_OPS_OFFLINE is set; a live invocation supplying it is REJECTED fail-closed
# (it is a test seam, not a live caller payload). Use `-` for stdin on any *-file
# flag. The pure transforms are factored as functions reading from injected input
# (compute_mutex_delta, build_deps_add_payload, surface_dep_response,
# normalize_deps_read, triage_palette) so the test can drive each directly via
# the offline CLI with only jq + bash, no `gh`. Mirrors fetch-normalize.sh's
# --payload-file injection.

set -euo pipefail

PROG="triage-ops"

die() {
  # Structured, nonzero failure to stderr — propagate, never swallow.
  echo "$PROG: $1" >&2
  exit "${2:-1}"
}

require_gh() {
  command -v gh >/dev/null 2>&1 \
    || die "the '$1' subcommand requires the 'gh' CLI on PATH (offline mode: set TRIAGE_OPS_OFFLINE)" 1
}

is_offline() {
  [ -n "${TRIAGE_OPS_OFFLINE:-}" ]
}

# read_injected <path>: read an injected fixture from a file or stdin (`-`).
# Fails CLOSED (nonzero) when the file is unreadable — an explicitly-supplied
# injection path that cannot be read is a usage error, not empty input.
read_injected() {
  local src="$1"
  if [ "$src" = "-" ]; then
    cat
  elif [ -f "$src" ]; then
    cat "$src"
  else
    die "injection file not found: $src" 1
  fi
}

# --- Pure transform core (offline-exercisable; no gh) ------------------------

# triage_palette: the SINGLE SOURCE of the fixed label palette. Emits a compact
# JSON array of { name, color, family, managed }. Color constraints (plan
# "Label creation + color palette"): ordinal families are one hue shaded by
# ordinal; `type` values get distinct hues; triage:locked gets a distinct control
# color. Exact hexes are this build's concrete choice. `managed: false` marks the
# human-only control label, which mutex reconcile must never select.
triage_palette() {
  jq -c -n '
    [
      # readiness ladder — neutral grey progression (light=early -> dark=done);
      # off-ladder blocked/parked kept muted-neutral.
      {name:"readiness:ideation",       color:"ededed", family:"readiness", managed:true},
      {name:"readiness:needs-decision", color:"d4d4d4", family:"readiness", managed:true},
      {name:"readiness:interrogation",  color:"bdbdbd", family:"readiness", managed:true},
      {name:"readiness:planning",       color:"a3a3a3", family:"readiness", managed:true},
      {name:"readiness:ready",          color:"8a8a8a", family:"readiness", managed:true},
      {name:"readiness:implementation", color:"707070", family:"readiness", managed:true},
      {name:"readiness:done",           color:"565656", family:"readiness", managed:true},
      {name:"readiness:blocked",        color:"7a6a6a", family:"readiness", managed:true},
      {name:"readiness:parked",         color:"6a6a7a", family:"readiness", managed:true},

      # type — DISTINCT hue per value.
      {name:"type:bug",           color:"d73a4a", family:"type", managed:true},
      {name:"type:idea",          color:"fef2c0", family:"type", managed:true},
      {name:"type:feature",       color:"a2eeef", family:"type", managed:true},
      {name:"type:enhancement",   color:"84b6eb", family:"type", managed:true},
      {name:"type:chore",         color:"c2e0c6", family:"type", managed:true},
      {name:"type:refactor",      color:"5319e7", family:"type", managed:true},
      {name:"type:epic",          color:"3e4b9e", family:"type", managed:true},
      {name:"type:documentation", color:"0075ca", family:"type", managed:true},

      # effort — one hue (purple) light->dark by volume xs->xl.
      {name:"effort:xs", color:"f5f0ff", family:"effort", managed:true},
      {name:"effort:s",  color:"d9c7ff", family:"effort", managed:true},
      {name:"effort:m",  color:"b18cff", family:"effort", managed:true},
      {name:"effort:l",  color:"8a4fff", family:"effort", managed:true},
      {name:"effort:xl", color:"5a189a", family:"effort", managed:true},

      # moscow — commitment red(must) -> grey(wont).
      {name:"moscow:must",   color:"b60205", family:"moscow", managed:true},
      {name:"moscow:should", color:"d98880", family:"moscow", managed:true},
      {name:"moscow:could",  color:"bcaaaa", family:"moscow", managed:true},
      {name:"moscow:wont",   color:"cccccc", family:"moscow", managed:true},

      # priority — sequencing urgency red(high) -> amber -> green(low).
      {name:"priority:high",   color:"b60205", family:"priority", managed:true},
      {name:"priority:medium", color:"fbca04", family:"priority", managed:true},
      {name:"priority:low",    color:"0e8a16", family:"priority", managed:true},

      # risk — likelihood x blast radius red(high) -> amber -> green(low).
      {name:"risk:high",   color:"e11d21", family:"risk", managed:true},
      {name:"risk:medium", color:"fbca04", family:"risk", managed:true},
      {name:"risk:low",    color:"0e8a16", family:"risk", managed:true},

      # difficulty — intellectual hardness, one hue (brown/amber) shaded by ordinal.
      {name:"difficulty:high",   color:"8a3b00", family:"difficulty", managed:true},
      {name:"difficulty:medium", color:"c46210", family:"difficulty", managed:true},
      {name:"difficulty:low",    color:"f4c79e", family:"difficulty", managed:true},

      # control — human-only lock, DISTINCT control color, NOT a managed family.
      {name:"triage:locked", color:"0e1116", family:"control", managed:false}
    ]'
}

# compute_mutex_delta <issue-number> <targets-json> <current-labels-json>:
# pure per-family reconcile. Reads injected input directly (no gh) so the test
# drives it. Validates every target against the palette (single source); an
# unknown family/value fails CLOSED via jq error. See INVARIANTS §4.
compute_mutex_delta() {
  local issue="$1" targets_json="$2" current_json="$3"
  triage_palette | jq -c \
    --argjson issue "$issue" \
    --argjson targets "$targets_json" \
    --argjson current "$current_json" '
    . as $palette
    | ( [ $palette[] | select(.managed) | .name ] ) as $valid
    | ( [ $targets | to_entries[] ] ) as $fams
    | ( [ $fams[] | (.key + ":" + .value) ] ) as $wants
    | ( [ $wants[] as $w | select( ($valid | index($w)) | not ) | $w ] ) as $bad
    | if ($bad | length) > 0
      then error("unknown target label(s): " + ($bad | join(", ")))
      else
        {
          issue: $issue,
          remove: ( [ $fams[] as $f
                      | $current[] as $lbl
                      | $lbl
                      | select(startswith($f.key + ":"))
                      | select(. != ($f.key + ":" + $f.value))
                      # Bound the remove set to the FIXED managed palette: a
                      # foreign/human label sharing a family prefix (e.g.
                      # priority:customer) is invisible and MUST NOT be removed.
                      # NOTE: capture $lbl first — inside `$valid | index(.)` the
                      # `.` rebinds to $valid (the pipe input), so index(.) would
                      # search for the whole array and always match; test the
                      # captured element with `index($lbl)` instead.
                      | select( $valid | index($lbl) ) ] | unique ),
          add:    ( [ $fams[]
                      | (.key + ":" + .value) as $want
                      | select( ($current | index($want)) | not )
                      | $want ] | unique )
        }
      end'
}

# build_deps_add_payload <issue-id> <blocked-by-id>: the GraphQL variables for
# the addBlockedBy mutation. Pure jq construction — node ids pass through as DATA.
build_deps_add_payload() {
  jq -c -n --arg issueId "$1" --arg blockedById "$2" \
    '{ issueId: $issueId, blockedByIssueId: $blockedById }'
}

# surface_dep_response <response-json>: classify a raw addBlockedBy GraphQL
# response into a structured record AND signal recoverability via exit code.
# A GraphQL `.errors` array becomes an exit-0 `cycle-rejected` warning ONLY when
# EVERY error in the array names a cycle (the one expected, non-fatal GitHub
# rejection — a cycle is a legitimate "can't add this edge" answer, not a failed
# write). A MIXED array (a cycle error alongside ANY non-cycle error — auth,
# rate-limit, schema) is FAIL-CLOSED: the non-cycle sibling marks a genuine write
# failure that a first-error-only check would mask. EVERY other failure is
# FAIL-CLOSED and exits nonzero so the caller never proceeds as if an edge were
# written when none was: empty/non-JSON transport errors, a success body missing
# the expected addBlockedBy issue numbers, and any array containing a non-cycle
# GraphQL error (auth, rate-limit, 4xx, schema, malformed). The record is still
# emitted on stdout for diagnostics; the EXIT CODE is the gate.
# See INVARIANT §4. Exit codes: 0 = added | cycle-rejected; 1 = fail-closed.
surface_dep_response() {
  local resp="$1"
  # Empty / non-JSON => transport error. Fail closed: record to stderr, exit 1.
  if ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    jq -c -n '{ status:"error", kind:"transport-error",
                message:"empty or non-JSON response from addBlockedBy" }' >&2
    return 1
  fi
  # Single classification pass (always exits 0): emit the structured record. The
  # record's `kind` is the gate the caller honors — `cycle-rejected` and `added`
  # are recoverable (exit 0); every other kind is fail-closed (exit 1). A
  # non-cycle GraphQL error, or a success body missing the expected addBlockedBy
  # issue numbers, is classified `graphql-error` / `malformed-success`.
  local record kind
  record="$(printf '%s' "$resp" | jq -c '
        if ((.errors // []) | length) > 0
        then
          (.errors | map(.message // "")) as $msgs
          # Recoverable ONLY when EVERY error names a cycle. A single non-cycle
          # sibling (auth/rate-limit/schema) fails the whole array closed — a
          # first-error-only check would mask a real write failure.
          | if ($msgs | all(test("cycl|circular"; "i")))
            then { status: "warning", kind: "cycle-rejected",
                   message: ($msgs[0] // "addBlockedBy rejected") }
            else { status: "error", kind: "graphql-error",
                   message: ($msgs | map(select(test("cycl|circular"; "i") | not)))[0] } end
        elif (.data.addBlockedBy.issue.number != null
              and .data.addBlockedBy.blockedBy.number != null)
        then { status: "added",
               issue: (.data.addBlockedBy.issue.number),
               blocked_by: (.data.addBlockedBy.blockedBy.number) }
        else { status: "error", kind: "malformed-success",
               message: "addBlockedBy response missing expected issue numbers" }
        end')"
  kind="$(printf '%s' "$record" | jq -r '.kind // "added"')"
  case "$kind" in
    added|cycle-rejected)  # recoverable: emit on stdout, caller continues.
      printf '%s\n' "$record"; return 0 ;;
    *)  # graphql-error, malformed-success (and any unknown): fail closed.
      printf '%s\n' "$record" >&2; return 1 ;;
  esac
}

# normalize_deps_read <response-json>: project a raw blockedByIssues GraphQL
# response into the stable deps-read schema (§3) — FAIL-CLOSED, mirroring
# surface_dep_response. A blockedByIssues read carries NO recoverable failure
# (unlike deps-add's cycle rejection): EVERY failure exits nonzero so the caller
# never makes triage/dependency decisions from a corrupted-into-"no blockers"
# state. Fail-closed on: empty/non-JSON transport errors, any non-empty
# `.errors` (auth, rate-limit, 4xx, schema), a missing/null `.data.repository.issue`
# (issue absent or 200-with-error body), a missing/non-array
# `blockedByIssues.nodes`, and any null/wrong-typed identifier FIELD on the issue
# or a blocker node (null issue id/number, or a blocker missing its number/id/title).
# A 200 body satisfying the outer shape but carrying null identifiers would
# normalize into dependency records that cannot be safely matched for later
# deps-add/removal, so the field-completeness gate fails it closed too. Only a
# fully-formed issue node with fully-formed blocker nodes is normalized and emitted
# on stdout with exit 0. See INVARIANT §3/§4. Exit codes: 0 = normalized; 1 = fail-closed.
normalize_deps_read() {
  local resp="$1"
  # Empty / non-JSON => transport error. Fail closed.
  if ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    jq -c -n '{ status:"error", kind:"transport-error",
                message:"empty or non-JSON response from blockedByIssues read" }' >&2
    return 1
  fi
  # Any GraphQL `.errors` (no recoverable variant for a read) => fail closed.
  if printf '%s' "$resp" | jq -e '((.errors // []) | length) > 0' >/dev/null 2>&1; then
    printf '%s' "$resp" | jq -c \
      '{ status:"error", kind:"graphql-error",
         message: ((.errors[0].message) // "blockedByIssues read rejected") }' >&2
    return 1
  fi
  # Missing/null issue node, or a non-array nodes list => corrupted/unexpected
  # shape; fail closed rather than projecting an empty "no blockers" set.
  if ! printf '%s' "$resp" | jq -e \
        '(.data.repository.issue) != null
         and ((.data.repository.issue.blockedByIssues.nodes) | type == "array")' \
        >/dev/null 2>&1; then
    jq -c -n '{ status:"error", kind:"malformed-read",
                message:"blockedByIssues response missing issue or nodes array" }' >&2
    return 1
  fi
  # Field-completeness gate: the outer shape can be satisfied while a key
  # identifier is null/wrong-typed. Require a numeric issue number, a nonempty
  # string issue id, and — for EVERY blocker node — a numeric number plus nonempty
  # string id and title. A null id/number would normalize into a record that
  # cannot be matched for later deps-add/removal, so fail it closed here.
  if ! printf '%s' "$resp" | jq -e \
        '(.data.repository.issue) as $i
         | ($i.number | type == "number")
         and ($i.id | type == "string" and length > 0)
         and (($i.blockedByIssues.nodes) | all(
               (.number | type == "number")
               and (.id | type == "string" and length > 0)
               and (.title | type == "string" and length > 0)))' \
        >/dev/null 2>&1; then
    jq -c -n '{ status:"error", kind:"malformed-read",
                message:"blockedByIssues response has null/invalid issue or blocker identifier fields" }' >&2
    return 1
  fi
  printf '%s' "$resp" | jq -c '
    .data.repository.issue as $i
    | { issue: ($i.number // null),
        id: ($i.id // null),
        blocked_by: [ ($i.blockedByIssues.nodes)[] | { number, id, title } ] }'
}

# --- Baked GraphQL operations (live path only) -------------------------------
# Native GitHub issue dependencies (blocked-by), GA 2025-08-21. Spec citation:
# https://github.blog/changelog/2025-08-21-dependencies-on-issues/ — mutation
# `addBlockedBy(input: AddBlockedByInput!)` with issueId + blockedByIssueId; the
# Issue.blockedByIssues connection reads the blocked-by set. Variables are passed
# via -f/-F (never interpolated). External issue text is never read into source.
DEPS_READ_QUERY='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      id
      number
      blockedByIssues(first: 50) {
        nodes { id number title }
      }
    }
  }
}'

DEPS_ADD_MUTATION='
mutation($issueId: ID!, $blockedByIssueId: ID!) {
  addBlockedBy(input: { issueId: $issueId, blockedByIssueId: $blockedByIssueId }) {
    issue { id number }
    blockedBy { id number }
  }
}'

# --- Subcommand implementations ----------------------------------------------

cmd_ensure_labels() {
  [ "$#" -eq 0 ] || die "ensure-labels takes no arguments" 2
  if is_offline; then
    triage_palette
    return 0
  fi
  require_gh "ensure-labels"
  # Idempotent create-or-update: --force creates if missing and self-heals a
  # drifted color, and NEVER deletes. Each label is independent — a single
  # failure is reported but does not abort the rest (issues/labels independent).
  local failures=0
  while IFS=$'\t' read -r name color family; do
    local desc="triage ${family} rating"
    [ "$family" = "control" ] && desc="human-only triage lock (never set by the skill)"
    if ! gh label create "$name" --color "$color" --description "$desc" --force >/dev/null 2>&1; then
      echo "$PROG: WARNING failed to ensure label '$name'" >&2
      failures=$((failures + 1))
    fi
  done < <(triage_palette | jq -r '.[] | [.name, .color, .family] | @tsv')
  [ "$failures" -eq 0 ] || die "ensure-labels: $failures label(s) failed to apply" 1
}

cmd_list_issues() {
  local limit=500 response_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) [ "$#" -ge 2 ] || die "missing value for --limit" 2
               limit="$2"; shift 2 ;;
      --response-file) [ "$#" -ge 2 ] || die "missing value for --response-file" 2
               response_file="$2"; shift 2 ;;
      *) die "list-issues: unexpected argument '$1'" 2 ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) die "list-issues: --limit must be an integer" 2 ;; esac
  if is_offline; then
    [ -n "$response_file" ] || die "offline list-issues requires --response-file" 2
    read_injected "$response_file" | jq -c .
    return 0
  fi
  require_gh "list-issues"
  gh issue list --state open --limit "$limit" \
    --json number,title,labels,body,id
}

cmd_apply_labels() {
  local issue="" targets_json="" targets_file="" current_file=""
  [ "$#" -ge 1 ] || die "apply-labels requires an issue number" 2
  issue="$1"; shift
  case "$issue" in ''|*[!0-9]*) die "apply-labels: issue number must be an integer (got '$issue')" 2 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --targets) [ "$#" -ge 2 ] || die "missing value for --targets" 2
                 targets_json="$2"; shift 2 ;;
      --targets-file) [ "$#" -ge 2 ] || die "missing value for --targets-file" 2
                 targets_file="$2"; shift 2 ;;
      --current-labels-file) [ "$#" -ge 2 ] || die "missing value for --current-labels-file" 2
                 current_file="$2"; shift 2 ;;
      *) die "apply-labels: unexpected argument '$1'" 2 ;;
    esac
  done
  if [ -n "$targets_file" ]; then
    [ -z "$targets_json" ] || die "apply-labels: pass --targets OR --targets-file, not both" 2
    targets_json="$(read_injected "$targets_file")"
  fi
  [ -n "$targets_json" ] || die "apply-labels requires --targets or --targets-file" 2
  printf '%s' "$targets_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "apply-labels: --targets must be a JSON object (family->value)" 2

  local current_json
  if is_offline; then
    [ -n "$current_file" ] || die "offline apply-labels requires --current-labels-file" 2
    current_json="$(read_injected "$current_file")"
    printf '%s' "$current_json" | jq -e 'type == "array"' >/dev/null 2>&1 \
      || die "apply-labels: --current-labels-file must be a JSON array of label names" 2
    compute_mutex_delta "$issue" "$targets_json" "$current_json"
    return 0
  fi

  # --current-labels-file is a TEST SEAM (offline only). In the LIVE path it would
  # let a caller spoof the label set — including omitting triage:locked to bypass
  # the human-only lock. Reject it fail-closed BEFORE any gh call so the live path
  # derives ground truth UNCONDITIONALLY from `gh issue view`.
  [ -z "$current_file" ] \
    || die "apply-labels: --current-labels-file is valid only with TRIAGE_OPS_OFFLINE set" 2
  require_gh "apply-labels"
  current_json="$(gh issue view "$issue" --json labels --jq '[.labels[].name]')" \
    || die "apply-labels: failed to read current labels for issue #$issue" 1
  # Honor the human-only lock: a locked issue is reported and mutated NOT at all.
  if printf '%s' "$current_json" | jq -e 'index("triage:locked") != null' >/dev/null 2>&1; then
    jq -c -n --argjson issue "$issue" '{ issue: $issue, status: "skipped-locked" }'
    return 0
  fi

  local delta
  delta="$(compute_mutex_delta "$issue" "$targets_json" "$current_json")"

  # Build one `gh issue edit` invocation from the delta (atomic per issue).
  local -a edit_args=()
  while IFS= read -r lbl; do
    [ -n "$lbl" ] && edit_args+=(--remove-label "$lbl")
  done < <(printf '%s' "$delta" | jq -r '.remove[]')
  while IFS= read -r lbl; do
    [ -n "$lbl" ] && edit_args+=(--add-label "$lbl")
  done < <(printf '%s' "$delta" | jq -r '.add[]')

  if [ "${#edit_args[@]}" -gt 0 ]; then
    gh issue edit "$issue" "${edit_args[@]}" >/dev/null \
      || die "apply-labels: gh issue edit failed for issue #$issue" 1
  fi
  printf '%s' "$delta" | jq -c '. + { status: "applied" }'
}

cmd_deps_read() {
  local issue="" response_file=""
  [ "$#" -ge 1 ] || die "deps-read requires an issue number" 2
  issue="$1"; shift
  case "$issue" in ''|*[!0-9]*) die "deps-read: issue number must be an integer (got '$issue')" 2 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --response-file) [ "$#" -ge 2 ] || die "missing value for --response-file" 2
               response_file="$2"; shift 2 ;;
      *) die "deps-read: unexpected argument '$1'" 2 ;;
    esac
  done
  if is_offline; then
    [ -n "$response_file" ] || die "offline deps-read requires --response-file" 2
    # Propagate normalize_deps_read's fail-closed exit code — do NOT mask with
    # `return 0` (mirrors the cmd_deps_add fix): a GraphQL error / null-issue /
    # malformed read must surface as nonzero through the offline seam too.
    normalize_deps_read "$(read_injected "$response_file")"
    return
  fi
  require_gh "deps-read"
  local owner_repo owner repo resp
  owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
    || die "deps-read: failed to resolve owner/repo" 1
  owner="${owner_repo%%/*}"; repo="${owner_repo#*/}"
  resp="$(gh api graphql -f query="$DEPS_READ_QUERY" \
            -f owner="$owner" -f repo="$repo" -F number="$issue" 2>/dev/null)" \
    || die "deps-read: GraphQL query failed for issue #$issue" 1
  normalize_deps_read "$resp"
}

cmd_deps_add() {
  local issue_id="" blocked_by_id="" response_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --issue-id) [ "$#" -ge 2 ] || die "missing value for --issue-id" 2
               issue_id="$2"; shift 2 ;;
      --blocked-by-id) [ "$#" -ge 2 ] || die "missing value for --blocked-by-id" 2
               blocked_by_id="$2"; shift 2 ;;
      --response-file) [ "$#" -ge 2 ] || die "missing value for --response-file" 2
               response_file="$2"; shift 2 ;;
      *) die "deps-add: unexpected argument '$1'" 2 ;;
    esac
  done

  if is_offline; then
    if [ -n "$response_file" ]; then
      # Propagate surface_dep_response's exit code — a fail-closed (non-cycle)
      # error must surface as nonzero on the offline seam too, not be masked.
      surface_dep_response "$(read_injected "$response_file")"
      return "$?"
    fi
    [ -n "$issue_id" ] && [ -n "$blocked_by_id" ] \
      || die "offline deps-add requires --issue-id and --blocked-by-id (or --response-file)" 2
    build_deps_add_payload "$issue_id" "$blocked_by_id"
    return 0
  fi

  [ -n "$issue_id" ] && [ -n "$blocked_by_id" ] \
    || die "deps-add requires --issue-id and --blocked-by-id" 2
  require_gh "deps-add"
  # Capture stdout regardless of gh's exit status: a GraphQL cycle rejection
  # returns the error BODY (which surface_dep_response classifies) yet gh exits
  # nonzero. The surfacing function is the single decision point — never crash.
  local resp
  resp="$(gh api graphql -f query="$DEPS_ADD_MUTATION" \
            -f issueId="$issue_id" -f blockedByIssueId="$blocked_by_id" 2>/dev/null)" || true
  surface_dep_response "$resp"
}

# --- Dispatch ----------------------------------------------------------------

usage() {
  cat >&2 <<EOF
$PROG — deterministic mechanism for the hivemind triage-backlog skill.
usage: $PROG <subcommand> [args]
subcommands:
  ensure-labels
  list-issues   [--limit N] [--response-file <path|->]
  apply-labels  <issue> --targets <json>|--targets-file <path> [--current-labels-file <path|->]
  deps-read     <issue> [--response-file <path|->]
  deps-add      --issue-id <ID> --blocked-by-id <ID> [--response-file <path|->]
Set TRIAGE_OPS_OFFLINE to drive the pure transforms over injected input (no gh).
EOF
}

[ "$#" -ge 1 ] || { usage; exit 2; }
subcmd="$1"; shift
case "$subcmd" in
  ensure-labels) cmd_ensure_labels "$@" ;;
  list-issues)   cmd_list_issues "$@" ;;
  apply-labels)  cmd_apply_labels "$@" ;;
  deps-read)     cmd_deps_read "$@" ;;
  deps-add)      cmd_deps_add "$@" ;;
  -h|--help)     usage; exit 0 ;;
  *)             die "unknown subcommand '$subcmd' (try --help)" 2 ;;
esac
