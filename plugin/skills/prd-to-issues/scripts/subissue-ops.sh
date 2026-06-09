#!/usr/bin/env bash
#
# subissue-ops.sh — deterministic MECHANISM substrate for the hivemind
# `prd-to-issues` skill (judgment/mechanism split; engineering-principles P5 +
# P11). Path: ${CLAUDE_PLUGIN_ROOT}/skills/prd-to-issues/scripts/subissue-ops.sh
#
# 1. PURPOSE
# ----------
# This script owns ONLY the lossless, deterministic mechanism of wiring GitHub
# NATIVE sub-issue relationships (the GA 2025 issue hierarchy), so the
# prd-to-issues skill can model a PRD as a PARENT (epic) issue with its sliced
# issues attached as NATIVE SUB-ISSUES — replacing the old `initiative:<slug>`
# label-grouping convention with a first-class GitHub parent/child link.
# NO slicing / judgment logic lives here — deciding WHAT the epic is, how the PRD
# decomposes into slices, or which slice blocks which is holistic LLM work (P11)
# and stays in the SKILL prose. The script is the reproducible hands:
#   - idempotently ensure (create-or-find) the PRD-level epic PARENT issue,
#     returning its issue number + GraphQL NODE ID,
#   - attach a sliced (child) issue to the parent as a NATIVE sub-issue via the
#     GraphQL `addSubIssue` mutation,
#   - read the parent's `subIssues` connection (paginated to completeness),
#   - surface a GitHub rejection of an attach (child already parented, cycle) as a
#     STRUCTURED recoverable warning record instead of crashing.
# The split mirrors triage-ops.sh: a thin live `gh`/network shell wrapping a pure,
# offline-exercisable transform core.
#
# 2. INPUT CONTRACT — per subcommand
# ----------------------------------
#   ensure-parent --title <str> --body <str>|--body-file <path|-> [--repo <owner/repo>]
#                 [--existing-number <int>] [--response-file <path|->]
#     Idempotently CREATE-OR-FIND the PRD-level epic (parent) issue.
#     Idempotency key: if --existing-number is supplied the parent is RESOLVED (its
#     node id read by number) instead of created — the skill anchors the epic to a
#     known issue across re-runs. Otherwise a NEW issue is created.
#     online (create path): `gh issue create --title --body[-file]` (untrusted title
#              /body flow ONLY through gh flags, never into shell/GraphQL source),
#              then resolve its node id by number via GraphQL. --repo, when given,
#              is passed to gh as `-R`.
#     online (resolve path, --existing-number): GraphQL repository.issue(number) read
#              of { number id }, routed through the SHARED kernel (see §4).
#     offline: with --response-file -> normalizes the injected raw GraphQL
#              repository.issue response (number+id) through the shared kernel and
#              emits the parent record. Title/body/create are NOT exercised offline
#              (no deterministic transform — creation is pure live side effect).
#     --response-file is a TEST SEAM honored ONLY when SUBISSUE_OPS_OFFLINE is set;
#     a live invocation supplying it is REJECTED fail-closed via the shared guard
#     (see §5) BEFORE any gh call.
#
#   attach-subissue --parent-id <NODE_ID> --child-id <NODE_ID> [--response-file <path|->]
#     Run the GraphQL `addSubIssue` mutation. CRITICAL FIELD MAPPING: the input
#     fields are `issueId` (the PARENT) and `subIssueId` (the CHILD). This is
#     DELIBERATELY DIFFERENT from the dependency API's `blockingIssueId` — do NOT
#     conflate the two. Operates on GraphQL NODE IDs (ensure-parent's id + the
#     child issue's id), so no number->id round-trip is needed.
#     online:  addSubIssue mutation, raw response routed through surface_attach_response.
#     offline: with --response-file -> surfaces that injected response (exercises the
#              attached / already-parented / cycle / error / transport records); else
#              -> emits the constructed GraphQL variables payload (exercises payload
#              build).
#     --response-file is a TEST SEAM honored ONLY when SUBISSUE_OPS_OFFLINE is set;
#     a live invocation supplying it is REJECTED fail-closed via the shared guard
#     (see §5) BEFORE any gh call.
#
#   list-children --parent-id <NODE_ID> [--response-file <path|->]
#     Read the parent's `subIssues` connection. PAGINATES TO COMPLETENESS in the
#     live path (first:100 per page, following endCursor while hasNextPage) so the
#     full child set is always returned — this script LEARNS the triage-ops single-
#     page lesson (issue #228): a partial read that drops children past page 1 would
#     let the skill re-attach an already-attached slice or miss a child entirely.
#     online:  one node(id:) subIssues page per cursor; each page's raw response is
#              routed through the SHARED kernel (see §4) BEFORE accumulation — a
#              malformed/error page FAILS CLOSED mid-pagination, never emitting a
#              partial set as if complete.
#     offline: with --response-file -> normalizes the injected raw single-page
#              GraphQL response through the shared kernel. The injected fixture is
#              treated as the COMPLETE connection (its pageInfo.hasNextPage MUST be
#              false; a true value FAILS CLOSED — the offline seam exercises the
#              same completeness gate the live loop enforces).
#     --response-file is a TEST SEAM honored ONLY when SUBISSUE_OPS_OFFLINE is set;
#     a live invocation supplying it is REJECTED fail-closed via the shared guard
#     (see §5) BEFORE any gh call.
#
# 3. OUTPUT SCHEMA — JSON on stdout (compact)
# -------------------------------------------
#   ensure-parent:
#     { "number": <int>, "id": <node-id>, "status": "created"|"resolved" }
#
#   attach-subissue payload (offline, no --response-file):
#     { "issueId": <parent-node-id>, "subIssueId": <child-node-id> }
#   attach-subissue surfaced response (online, or offline with --response-file):
#     attached: { "status": "attached", "parent": <int>, "child": <int> }
#     warning:  { "status": "warning",
#                 "kind": "already-parented"|"cycle-rejected"|"error"|"transport-error",
#                 "message": <str> }
#
#   list-children normalized:
#     { "parent_id": <node-id|null>,
#       "children": [ { "number": <int>, "id": <node-id>, "title": <str> }, ... ] }
#
# 4. INVARIANTS
# -------------
#   - SINGLE SHARED RESPONSE-SHAPE KERNEL: EVERY live gh/GraphQL read that informs a
#     decision or that is emitted as a result routes through validate_response_shape
#     before any processing. No per-site hand-parsing of response shape is permitted.
#     A non-clean response — transport error (empty/non-JSON), a non-empty `.errors`
#     envelope, null/missing entity at the expected root path, non-array collection,
#     or a null/wrong-typed field on any element — FAILS CLOSED (nonzero, structured
#     kind record to stderr) before any decision or emission. Covered reads:
#     ensure-parent's repository.issue resolve/normalize, list-children's per-page
#     subIssues response (before accumulation). No subcommand bypasses this kernel.
#   - NATIVE SUB-ISSUES, NOT LABELS. This script wires the first-class GitHub
#     parent/child hierarchy; it NEVER reads, writes, or grooms any `initiative:*`
#     (or any other) label. Grouping is the native relationship, full stop.
#   - addSubIssue FIELD MAPPING IS LOAD-BEARING: input `issueId` = the PARENT node,
#     `subIssueId` = the CHILD node. This is NOT the dependency API's
#     `blockingIssueId`. build_attach_payload and the mutation source are the SINGLE
#     SOURCE of this mapping so the two can never diverge.
#   - GraphQL-Features HEADER ON EVERY SUB-ISSUE CALL. Sub-issues are GA (2025) but
#     the GraphQL surface is gated behind `-H "GraphQL-Features: sub_issues"`. EVERY
#     live `gh api graphql` call in this script sends it via the single $GQL_HEADER
#     constant (one source, no per-site divergence). Absent it the API may 404/reject;
#     the script ALWAYS sends it and, if the API STILL rejects, FAILS CLOSED with a
#     clear error — it NEVER silently succeeds or no-ops.
#   - ADD-ONLY. attach-subissue never detaches an existing sub-issue; reparenting /
#     removal is a human decision outside this script.
#   - A GitHub rejection of an attach that is EXPECTED and non-fatal — the child
#     already has a parent, or the link would form a cycle — is surfaced as a warning
#     record (kind already-parented / cycle-rejected) with exit 0, so a batch attach
#     keeps going (slices are independent). EVERY other failure FAILS CLOSED.
#   - PAGINATE TO COMPLETENESS (issue #228 lesson). list-children follows the
#     subIssues connection across ALL pages; a partial read is never emitted as if
#     complete (live: loop on hasNextPage; offline: an injected page asserting
#     hasNextPage==true FAILS CLOSED).
#   - Untrusted issue body/title is DATA: it flows ONLY through `gh issue create`
#     flags (--title / --body / --body-file) and `gh api graphql -f/-F` / jq
#     --arg/--argjson; it is NEVER interpolated into shell source or into GraphQL
#     query source. Node IDs are validated non-empty before use. GraphQL variables
#     are passed via -f/-F, never string-concatenated.
#   - FAIL-CLOSED on malformed injected input to a pure transform (bad --response-file,
#     unreadable injection file, a continued offline page) — a malformed fixture is a
#     usage bug, not noise.
#
# 5. OFFLINE TEST SEAM (STEP-002 depends on this)
# -----------------------------------------------
# Set env SUBISSUE_OPS_OFFLINE to any non-empty value to make EVERY subcommand skip
# ALL gh/network calls and instead drive its pure transform over INJECTED input,
# emitting the deterministic artifact (parent record / attach payload / surfaced
# record / normalized children) to stdout. Input that would normally come from gh is
# injected via --response-file (ensure-parent, attach-subissue, list-children). The
# fixture flag is honored ONLY when SUBISSUE_OPS_OFFLINE is set; a live invocation
# supplying it is REJECTED fail-closed (exit 2) BEFORE any gh call via the single
# shared guard reject_fixture_flags_in_live_mode (one mechanism, no per-subcommand
# divergence) — it is a test seam, not a live caller payload, and would otherwise let
# a fixture spoof a created/attached/child state for a mutation that never ran. Use
# `-` for stdin on any *-file flag. The pure transforms are factored as functions
# reading from injected input (build_attach_payload, surface_attach_response,
# normalize_parent_resolve, normalize_children) so the test can drive each directly
# via the offline CLI with only jq + bash, no `gh`. Mirrors triage-ops.sh's
# --response-file injection.

set -euo pipefail

PROG="subissue-ops"

# SINGLE SOURCE of the sub-issues GraphQL feature header. EVERY live `gh api graphql`
# call in this script passes `-H "$GQL_HEADER"`; the GA sub-issue surface is gated
# behind it (see INVARIANT §4). Splice via the array idiom `"${GQL_HEADER_ARGS[@]}"`.
GQL_HEADER="GraphQL-Features: sub_issues"
GQL_HEADER_ARGS=(-H "$GQL_HEADER")

die() {
  # Structured, nonzero failure to stderr — propagate, never swallow.
  echo "$PROG: $1" >&2
  exit "${2:-1}"
}

require_gh() {
  command -v gh >/dev/null 2>&1 \
    || die "the '$1' subcommand requires the 'gh' CLI on PATH (offline mode: set SUBISSUE_OPS_OFFLINE)" 1
}

is_offline() {
  [ -n "${SUBISSUE_OPS_OFFLINE:-}" ]
}

# reject_fixture_flags_in_live_mode <subcommand> <flag-name>=<value> [<flag-name>=<value> ...]
# UNIFIED offline-test-seam gate (mirrors triage-ops). Fixture/injection flags
# (--response-file) are honored ONLY when SUBISSUE_OPS_OFFLINE is set; supplying one
# on a LIVE invocation could spoof a created/attached/child state for a mutation that
# never ran. So: when NOT offline, any passed flag whose value is non-empty fails
# CLOSED with exit 2 BEFORE any require_gh/gh/graphql call (so STEP-002's live-reject
# tests run with no gh on PATH). Receives the ALREADY-PARSED flag value(s) as
# arguments — it does NOT re-parse argv (P9). Each arg is "<flag-name>=<value>"; only
# the value is tested, the name is used solely for the diagnostic message.
reject_fixture_flags_in_live_mode() {
  local subcmd="$1"; shift
  is_offline && return 0
  local pair flag value
  for pair in "$@"; do
    flag="${pair%%=*}"
    value="${pair#*=}"
    [ -z "$value" ] \
      || die "$subcmd: $flag is valid only with SUBISSUE_OPS_OFFLINE set" 2
  done
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

# validate_response_shape <resp> <root_path> <root_pred> <coll_path> <elem_pred> <projection>:
# the SINGLE SOURCE fail-closed GraphQL/response-shape validator+normalizer (P1).
# Byte-for-byte the same contract as triage-ops.sh's kernel (one shape mechanism
# across the plugin's GraphQL scripts). Pure jq+bash, no gh — offline-exercisable.
# Given a RAW response string and a PROJECTION SPEC (author-static jq fragments
# passed as the 2nd..6th args), it REJECTS fail-closed (nonzero, structured kind
# record to stderr) any of:
#   - empty / non-JSON transport body            => kind transport-error
#   - a non-empty `.errors` array                => kind graphql-error
#   - null/missing entity at <root_path>, or a
#     non-array collection at <coll_path>, or the
#     <root_pred>/<elem_pred> field-completeness
#     predicates failing on any element           => kind malformed-read
# On a clean response it runs <projection> and emits the projected value (exit 0).
#
# PROJECTION SPEC (all jq program fragments — AUTHOR-STATIC, never caller/untrusted
# text; the untrusted RESPONSE is the only value flowing through as DATA, piped on
# stdin and never interpolated, satisfying the §4 no-interpolation invariant):
#   <root_path>   jq path to the entity that holds the collection (e.g.
#                 `.data.node`); fail-closed when it is null/missing.
#   <root_pred>   jq boolean over that entity bound as `.` (field-completeness on
#                 the root).
#   <coll_path>   jq path FROM the root entity to the node collection (e.g.
#                 `.subIssues.nodes`); fail-closed when not an array.
#   <elem_pred>   jq boolean over each element bound as `.` (per-element field
#                 completeness); must hold for EVERY element.
#   <projection>  jq program over the FULL response that yields the clean value.
# Exit codes: 0 = projected; 1 = fail-closed.
validate_response_shape() {
  local resp="$1" root_path="$2" root_pred="$3" coll_path="$4" elem_pred="$5" projection="$6"
  # Empty / non-JSON => transport error. Fail closed (cannot be checked in-jq).
  if ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    jq -c -n '{ status:"error", kind:"transport-error",
                message:"empty or non-JSON response" }' >&2
    return 1
  fi
  # Any GraphQL `.errors` (no recoverable variant for a read) => fail closed.
  if printf '%s' "$resp" | jq -e '((.errors // []) | length) > 0' >/dev/null 2>&1; then
    printf '%s' "$resp" | jq -c \
      '{ status:"error", kind:"graphql-error",
         message: ((.errors[0].message) // "response rejected") }' >&2
    return 1
  fi
  # Shape + field-completeness gate (root non-null, collection is an array, the root
  # and EVERY element satisfy their completeness predicate). The fragments are
  # spliced into the jq PROGRAM (author-static), never into the DATA.
  if ! printf '%s' "$resp" | jq -e "
        ($root_path) as \$root
        | \$root != null
          and (((\$root | $coll_path) | type) == \"array\")
          and (\$root | ($root_pred))
          and ((\$root | $coll_path) | all($elem_pred))" \
        >/dev/null 2>&1; then
    jq -c -n '{ status:"error", kind:"malformed-read",
                message:"response missing root entity, collection array, or required fields" }' >&2
    return 1
  fi
  printf '%s' "$resp" | jq -c "$projection"
}

# normalize_parent_resolve <response-json>: project a raw repository.issue GraphQL
# response (used by ensure-parent's resolve path and its post-create node-id read)
# into the parent identity { number, id }. FAIL-CLOSED via the shared kernel: a
# transport error, `.errors` envelope, null/missing issue node, or a null/wrong-typed
# number/id field exits nonzero — never emit a parent record built from an
# unverifiable read. The issue node carries no collection of interest, so the kernel's
# collection slot is `[]` (a trivially-valid empty array) and there is no element
# predicate. <status> is spliced as DATA via --arg to tag the record created/resolved.
# Exit codes: 0 = normalized; 1 = fail-closed.
normalize_parent_resolve() {
  local resp="$1" status="$2"
  validate_response_shape "$resp" \
    '.data.repository.issue' \
    '(.number | type == "number")
     and (.id | type == "string" and length > 0)' \
    '[]' \
    'true' \
    "{ number: .data.repository.issue.number,
       id: .data.repository.issue.id,
       status: \"$status\" }"
}

# normalize_children <response-json>: project a raw node(id:) subIssues GraphQL page
# into the stable list-children schema (§3) — FAIL-CLOSED via the shared kernel. A
# subIssues read carries NO recoverable failure: EVERY failure exits nonzero so the
# caller never makes attach decisions from a corrupted-into-"no children" state.
# Fail-closed on: empty/non-JSON transport, any `.errors`, missing/null `.data.node`,
# missing/non-array `subIssues.nodes`, any null/wrong-typed child identifier
# (number/id/title), AND — mirroring deps-read's #228 lesson — a CONTINUED connection
# (`subIssues.pageInfo.hasNextPage == true`): the offline seam injects a SINGLE page
# and treats it as COMPLETE, so a continued page would normalize as if the unfetched
# children do not exist; that partial read is failed closed rather than emitted. (The
# LIVE path follows endCursor across all pages, so live completeness is enforced by
# the loop, not this normalizer — see cmd_list_children.) The parent_id is captured
# from .data.node.id. Exit codes: 0 = normalized; 1 = fail-closed.
normalize_children() {
  local resp="$1"
  validate_response_shape "$resp" \
    '.data.node' \
    '(.id | type == "string" and length > 0)
     and ((.subIssues.pageInfo.hasNextPage // false) == false)' \
    '.subIssues.nodes' \
    '(.number | type == "number")
     and (.id | type == "string" and length > 0)
     and (.title | type == "string" and length > 0)' \
    '.data.node as $n
     | { parent_id: ($n.id // null),
         children: [ ($n.subIssues.nodes)[] | { number, id, title } ] }'
}

# build_attach_payload <parent-id> <child-id>: the GraphQL variables for the
# addSubIssue mutation. Pure jq construction — node ids pass through as DATA.
# CRITICAL: issueId = the PARENT, subIssueId = the CHILD (NOT blockingIssueId — see
# INVARIANT §4). This function and DEPS-style mutation source are the single source
# of the field mapping.
build_attach_payload() {
  jq -c -n --arg issueId "$1" --arg subIssueId "$2" \
    '{ issueId: $issueId, subIssueId: $subIssueId }'
}

# surface_attach_response <response-json>: classify a raw addSubIssue GraphQL response
# into a structured record AND signal recoverability via exit code (mirrors triage-ops'
# surface_dep_response). A GraphQL `.errors` array becomes an exit-0 warning ONLY when
# EVERY error names an EXPECTED, non-fatal sub-issue rejection — the child already has
# a parent (already-parented) or the link would form a cycle (cycle-rejected). A MIXED
# array (an expected rejection alongside ANY other error — auth, rate-limit, schema, a
# missing sub_issues feature header) is FAIL-CLOSED: the non-recoverable sibling marks
# a genuine write failure that a first-error-only check would mask. EVERY other failure
# is FAIL-CLOSED and exits nonzero so the caller never proceeds as if a sub-issue were
# attached when none was: empty/non-JSON transport errors, a success body missing the
# expected addSubIssue issue numbers, and any array containing a non-recoverable error.
# The record is still emitted on stdout (recoverable) or stderr (fail-closed) for
# diagnostics; the EXIT CODE is the gate. See INVARIANT §4.
# Exit codes: 0 = attached | already-parented | cycle-rejected; 1 = fail-closed.
surface_attach_response() {
  local resp="$1"
  # Empty / non-JSON => transport error. Fail closed: record to stderr, exit 1.
  if ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    jq -c -n '{ status:"warning", kind:"transport-error",
                message:"empty or non-JSON response from addSubIssue" }' >&2
    return 1
  fi
  # Single classification pass (always exits 0): emit the structured record. The
  # record's `kind` is the gate the caller honors — `attached`, `already-parented`,
  # and `cycle-rejected` are recoverable (exit 0); every other kind is fail-closed
  # (exit 1). Recoverable ONLY when EVERY error matches a known non-fatal pattern; a
  # single other sibling fails the whole array closed (a first-error-only check would
  # mask a real write failure, e.g. a missing sub_issues feature-header rejection).
  local record kind
  record="$(printf '%s' "$resp" | jq -c '
        if ((.errors // []) | length) > 0
        then
          (.errors | map(.message // "")) as $msgs
          | if   ($msgs | all(test("already (has|been added)|parent"; "i")))
            then { status: "warning", kind: "already-parented",
                   message: ($msgs[0] // "child already has a parent") }
            elif ($msgs | all(test("cycl|circular"; "i")))
            then { status: "warning", kind: "cycle-rejected",
                   message: ($msgs[0] // "addSubIssue rejected: cycle") }
            else { status: "warning", kind: "error",
                   message: ($msgs | map(select(test("already (has|been added)|parent|cycl|circular"; "i") | not)))[0] } end
        elif (.data.addSubIssue.issue.number != null
              and .data.addSubIssue.subIssue.number != null)
        then { status: "attached",
               parent: (.data.addSubIssue.issue.number),
               child:  (.data.addSubIssue.subIssue.number) }
        else { status: "warning", kind: "error",
               message: "addSubIssue response missing expected issue numbers" }
        end')"
  kind="$(printf '%s' "$record" | jq -r '.kind // "attached"')"
  case "$kind" in
    attached|already-parented|cycle-rejected)  # recoverable: stdout, caller continues.
      printf '%s\n' "$record"; return 0 ;;
    *)  # error (and any unknown): fail closed.
      printf '%s\n' "$record" >&2; return 1 ;;
  esac
}

# --- Baked GraphQL operations (live path only) -------------------------------
# Native GitHub sub-issues (issue hierarchy), GA 2025. Spec citation:
# https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues
# and the GraphQL mutation `addSubIssue(input: AddSubIssueInput!)` — input fields
# `issueId` (the PARENT) + `subIssueId` (the CHILD); the Issue.subIssues connection
# reads the child set. The GraphQL surface is feature-gated: every call sends
# `-H "$GQL_HEADER"` (GraphQL-Features: sub_issues). Variables are passed via -f/-F
# (never interpolated); external issue text is never read into source.
PARENT_RESOLVE_QUERY='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      number
      id
    }
  }
}'

SUBISSUES_QUERY='
query($id: ID!, $after: String) {
  node(id: $id) {
    ... on Issue {
      id
      subIssues(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id number title }
      }
    }
  }
}'

ADD_SUBISSUE_MUTATION='
mutation($issueId: ID!, $subIssueId: ID!) {
  addSubIssue(input: { issueId: $issueId, subIssueId: $subIssueId }) {
    issue { id number }
    subIssue { id number }
  }
}'

# --- Subcommand implementations ----------------------------------------------

cmd_ensure_parent() {
  local title="" body="" body_file="" repo="" existing_number="" response_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) [ "$#" -ge 2 ] || die "missing value for --title" 2
               title="$2"; shift 2 ;;
      --body) [ "$#" -ge 2 ] || die "missing value for --body" 2
               body="$2"; shift 2 ;;
      --body-file) [ "$#" -ge 2 ] || die "missing value for --body-file" 2
               body_file="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || die "missing value for --repo" 2
               repo="$2"; shift 2 ;;
      --existing-number) [ "$#" -ge 2 ] || die "missing value for --existing-number" 2
               existing_number="$2"; shift 2 ;;
      --response-file) [ "$#" -ge 2 ] || die "missing value for --response-file" 2
               response_file="$2"; shift 2 ;;
      *) die "ensure-parent: unexpected argument '$1'" 2 ;;
    esac
  done
  if [ -n "$existing_number" ]; then
    case "$existing_number" in ''|*[!0-9]*) die "ensure-parent: --existing-number must be an integer (got '$existing_number')" 2 ;; esac
  fi

  if is_offline; then
    # Offline exercises ONLY the resolve/normalize transform (creation is a pure live
    # side effect with no deterministic transform). The injected response is treated
    # as a repository.issue read; status tag is resolved when --existing-number was
    # given, else created (the create path's post-create node-id read).
    [ -n "$response_file" ] || die "offline ensure-parent requires --response-file" 2
    local status="created"
    [ -n "$existing_number" ] && status="resolved"
    normalize_parent_resolve "$(read_injected "$response_file")" "$status"
    return
  fi

  reject_fixture_flags_in_live_mode "ensure-parent" "--response-file=$response_file"
  require_gh "ensure-parent"

  # Resolve owner/repo: explicit --repo wins, else the current checkout.
  local owner_repo owner repo_name
  if [ -n "$repo" ]; then
    owner_repo="$repo"
  else
    owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
      || die "ensure-parent: failed to resolve owner/repo (pass --repo)" 1
  fi
  case "$owner_repo" in */*) ;; *) die "ensure-parent: --repo must be owner/repo (got '$owner_repo')" 2 ;; esac
  owner="${owner_repo%%/*}"; repo_name="${owner_repo#*/}"

  local number resp
  if [ -n "$existing_number" ]; then
    # RESOLVE path (idempotency key supplied): read the known epic's node id. Routed
    # through the shared kernel — a missing/malformed read FAILS CLOSED.
    number="$existing_number"
    resp="$(gh api graphql "${GQL_HEADER_ARGS[@]}" -f query="$PARENT_RESOLVE_QUERY" \
              -f owner="$owner" -f repo="$repo_name" -F number="$number" 2>/dev/null)" \
      || die "ensure-parent: GraphQL resolve failed for issue #$number" 1
    normalize_parent_resolve "$resp" "resolved"
    return
  fi

  # CREATE path: untrusted title/body flow ONLY through gh flags (never shell/GraphQL
  # source). Prefer --body-file when given (large/multiline PRD epic bodies).
  [ -n "$title" ] || die "ensure-parent: --title is required to create a parent (or pass --existing-number)" 2
  local -a create_args=(issue create --title "$title")
  [ -n "$repo" ] && create_args=(issue create -R "$owner_repo" --title "$title")
  if [ -n "$body_file" ]; then
    [ -z "$body" ] || die "ensure-parent: pass --body OR --body-file, not both" 2
    if [ "$body_file" = "-" ]; then
      # Materialize stdin to a temp file so gh reads the untrusted body as DATA.
      local tmp_body; tmp_body="$(mktemp)"
      cat > "$tmp_body"
      create_args+=(--body-file "$tmp_body")
      local created_url
      created_url="$(gh "${create_args[@]}")" || { rm -f "$tmp_body"; die "ensure-parent: gh issue create failed" 1; }
      rm -f "$tmp_body"
      number="${created_url##*/}"
    else
      create_args+=(--body-file "$body_file")
      local created_url
      created_url="$(gh "${create_args[@]}")" || die "ensure-parent: gh issue create failed" 1
      number="${created_url##*/}"
    fi
  else
    [ -n "$body" ] || die "ensure-parent: --body or --body-file is required to create a parent" 2
    create_args+=(--body "$body")
    local created_url
    created_url="$(gh "${create_args[@]}")" || die "ensure-parent: gh issue create failed" 1
    # `gh issue create` prints the new issue URL; the trailing path segment is the number.
    number="${created_url##*/}"
  fi
  case "$number" in ''|*[!0-9]*) die "ensure-parent: could not parse new issue number from gh output" 1 ;; esac

  # Resolve the just-created issue's node id (the skill needs the id to attach
  # children). Routed through the shared kernel — a malformed read FAILS CLOSED.
  resp="$(gh api graphql "${GQL_HEADER_ARGS[@]}" -f query="$PARENT_RESOLVE_QUERY" \
            -f owner="$owner" -f repo="$repo_name" -F number="$number" 2>/dev/null)" \
    || die "ensure-parent: GraphQL node-id resolve failed for created issue #$number" 1
  normalize_parent_resolve "$resp" "created"
}

cmd_attach_subissue() {
  local parent_id="" child_id="" response_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --parent-id) [ "$#" -ge 2 ] || die "missing value for --parent-id" 2
               parent_id="$2"; shift 2 ;;
      --child-id) [ "$#" -ge 2 ] || die "missing value for --child-id" 2
               child_id="$2"; shift 2 ;;
      --response-file) [ "$#" -ge 2 ] || die "missing value for --response-file" 2
               response_file="$2"; shift 2 ;;
      *) die "attach-subissue: unexpected argument '$1'" 2 ;;
    esac
  done

  if is_offline; then
    if [ -n "$response_file" ]; then
      # Propagate surface_attach_response's exit code — a fail-closed (non-recoverable)
      # error must surface as nonzero on the offline seam too, not be masked.
      surface_attach_response "$(read_injected "$response_file")"
      return "$?"
    fi
    [ -n "$parent_id" ] && [ -n "$child_id" ] \
      || die "offline attach-subissue requires --parent-id and --child-id (or --response-file)" 2
    build_attach_payload "$parent_id" "$child_id"
    return 0
  fi

  reject_fixture_flags_in_live_mode "attach-subissue" "--response-file=$response_file"
  [ -n "$parent_id" ] && [ -n "$child_id" ] \
    || die "attach-subissue requires --parent-id and --child-id" 2
  require_gh "attach-subissue"
  # Capture stdout regardless of gh's exit status: a GraphQL rejection (already-
  # parented / cycle) returns the error BODY (which surface_attach_response classifies)
  # yet gh exits nonzero. The surfacing function is the single decision point — never
  # crash. issueId = PARENT, subIssueId = CHILD (NOT blockingIssueId — INVARIANT §4).
  local resp
  resp="$(gh api graphql "${GQL_HEADER_ARGS[@]}" -f query="$ADD_SUBISSUE_MUTATION" \
            -f issueId="$parent_id" -f subIssueId="$child_id" 2>/dev/null)" || true
  surface_attach_response "$resp"
}

cmd_list_children() {
  local parent_id="" response_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --parent-id) [ "$#" -ge 2 ] || die "missing value for --parent-id" 2
               parent_id="$2"; shift 2 ;;
      --response-file) [ "$#" -ge 2 ] || die "missing value for --response-file" 2
               response_file="$2"; shift 2 ;;
      *) die "list-children: unexpected argument '$1'" 2 ;;
    esac
  done

  if is_offline; then
    # Offline injects a SINGLE page treated as the COMPLETE connection — its
    # pageInfo.hasNextPage MUST be false (normalize_children FAILS CLOSED otherwise),
    # exercising the same completeness gate the live loop enforces.
    [ -n "$response_file" ] || die "offline list-children requires --response-file" 2
    normalize_children "$(read_injected "$response_file")"
    return
  fi

  reject_fixture_flags_in_live_mode "list-children" "--response-file=$response_file"
  [ -n "$parent_id" ] || die "list-children requires --parent-id" 2
  require_gh "list-children"

  # PAGINATE TO COMPLETENESS (issue #228 lesson): follow endCursor while hasNextPage.
  # Each raw page is routed through the SHARED kernel BEFORE accumulation, so a
  # malformed/error page FAILS CLOSED mid-loop rather than emitting a partial set. The
  # per-page projection keeps the page's own pageInfo (so this loop can read
  # hasNextPage/endCursor) AND the cleaned child nodes; children accumulate across
  # pages, then the final record drops pageInfo. `$after` (the cursor) is GitHub-issued
  # DATA passed via -F, never interpolated into source.
  local after="" page projected accumulated="[]" has_next end_cursor
  while :; do
    if [ -z "$after" ]; then
      page="$(gh api graphql "${GQL_HEADER_ARGS[@]}" -f query="$SUBISSUES_QUERY" \
                -f id="$parent_id" 2>/dev/null)" \
        || die "list-children: GraphQL subIssues query failed for parent id '$parent_id'" 1
    else
      page="$(gh api graphql "${GQL_HEADER_ARGS[@]}" -f query="$SUBISSUES_QUERY" \
                -f id="$parent_id" -F after="$after" 2>/dev/null)" \
        || die "list-children: GraphQL subIssues query failed for parent id '$parent_id'" 1
    fi
    # Validate the raw page shape WITHOUT the hasNextPage==false gate (mid-pagination a
    # continued page is legitimate); the loop itself drives completeness. Project to
    # this page's clean child nodes + its pageInfo for cursor advance.
    projected="$(validate_response_shape "$page" \
      '.data.node' \
      '(.id | type == "string" and length > 0)' \
      '.subIssues.nodes' \
      '(.number | type == "number")
       and (.id | type == "string" and length > 0)
       and (.title | type == "string" and length > 0)' \
      '{ children: [ (.data.node.subIssues.nodes)[] | { number, id, title } ],
         hasNextPage: (.data.node.subIssues.pageInfo.hasNextPage // false),
         endCursor: (.data.node.subIssues.pageInfo.endCursor // null) }')" \
      || die "list-children: malformed subIssues page for parent id '$parent_id'" 1
    accumulated="$(jq -c -n --argjson acc "$accumulated" --argjson page "$projected" \
      '$acc + $page.children')"
    has_next="$(printf '%s' "$projected" | jq -r '.hasNextPage')"
    end_cursor="$(printf '%s' "$projected" | jq -r '.endCursor // ""')"
    [ "$has_next" = "true" ] || break
    [ -n "$end_cursor" ] \
      || die "list-children: connection reports hasNextPage but no endCursor for parent id '$parent_id'" 1
    after="$end_cursor"
  done
  jq -c -n --arg pid "$parent_id" --argjson children "$accumulated" \
    '{ parent_id: $pid, children: $children }'
}

# --- Dispatch ----------------------------------------------------------------

usage() {
  cat >&2 <<EOF
$PROG — deterministic mechanism for the hivemind prd-to-issues skill (native sub-issues).
usage: $PROG <subcommand> [args]
subcommands:
  ensure-parent   --title <str> --body <str>|--body-file <path|-> [--repo <owner/repo>] [--existing-number <int>] [--response-file <path|->]
  attach-subissue --parent-id <ID> --child-id <ID> [--response-file <path|->]
  list-children   --parent-id <ID> [--response-file <path|->]
Set SUBISSUE_OPS_OFFLINE to drive the pure transforms over injected input (no gh).
EOF
}

[ "$#" -ge 1 ] || { usage; exit 2; }
subcmd="$1"; shift
case "$subcmd" in
  ensure-parent)   cmd_ensure_parent "$@" ;;
  attach-subissue) cmd_attach_subissue "$@" ;;
  list-children)   cmd_list_children "$@" ;;
  -h|--help)       usage; exit 0 ;;
  *)               die "unknown subcommand '$subcmd' (try --help)" 2 ;;
esac
