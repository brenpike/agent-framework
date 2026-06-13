# shellcheck shell=bash
#
# ledger-reconstruct-fold.sh — shared PURE fold/gate/wrap stage for the
# ledger-reconstruct entrypoint (github-review-loop). Defines normalized_to_findings
# (fold the fetch-normalize array into fix-ledger findings), normalized_live_parse_gate
# (LIVE FAIL-CLOSED fence for the normalized channel), and reconstruct_ledger (wrap the
# two finding families into the top-level fix-ledger object).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: the ledger-reconstruct entrypoint
# sources it by absolute path derived from its OWN script_dir
# (`. "$plugin_root/skills/_shared/ledger-reconstruct-fold.sh"`). It defines functions
# only; it runs no top-level statements and changes no caller state beyond defining the
# functions below. `bash -n` validates it as a sourced fragment.
#
# P18 FLOOR EXCEPTION (ADR-0020): as a SOURCED library this file deliberately
# OMITS the P18 shell-safety floor `set -e` / `set -o pipefail` and any EXIT trap. A sourced
# file mutates the SOURCING shell's option state, so installing those here would corrupt
# the entrypoint's shell; the floor is therefore the documented exception, not the full
# `set -euo pipefail`. This file carries no top-level `set` at all (pure function
# definitions); the ENTRYPOINT owns its own `set -u`, EXIT trap, and error routing.
# Allowlisted under CHECK13 as a P18 documented exception.
#
# VARIABLE CONTRACT: these functions run in the SOURCING (entrypoint) shell, so
# reconstruct_ledger reads the caller-shell global `BASE` (the base ref) the entrypoint
# defines BEFORE sourcing — it is NOT a function parameter; the exact reference pattern
# (`--arg base "$BASE"`) is preserved verbatim from the monolith. normalized_live_parse_gate
# emits the stable `LEDGERRECON_ERROR=normalized-parse-failed` marker literal inline (the
# entrypoint owns the ledgerrecon_fail()/exit routing; this gate only echoes + returns
# non-zero, mirroring the monolith).

# normalized_to_findings <normalized-payload>: PURE CORE (offline). Fold the
# fetch-normalize.sh output array (thread/finding state) into fix-ledger findings.
# Only REVIEW records (item_source=="review") carry thread identity; CI-check
# records are not prior fixes and are skipped. No git/network here.
#
# INJECTED FAIL-OPEN coercion: a non-array (or unparseable) payload yields `[]`
# (`type=="array" else []`). This fail-open is correct ONLY for the INJECTED
# (trusted fixture) path; the LIVE path is fenced by normalized_live_parse_gate
# (below), which fails CLOSED on a non-empty/non-array live payload BEFORE this core
# ever runs. So when control reaches here on a live run the payload is already a
# validated array and the coercion is a no-op; on an injected run the coercion is
# the intended fail-open. Mirrors the git-log live-parse-failed gate + injected
# fail-open split.
normalized_to_findings() {
  printf '%s' "$1" | jq -c '
    if type == "array" then . else [] end
    | [ .[]
        | select(.item_source == "review")
        | {
            id: (.id // .thread_id),
            severity: null,
            title: (.classification // null),
            body: null,
            recommendation: null,
            file: null,
            line_start: null,
            line_end: null,
            status: (
              if (.surface == "thread")
              then (if (.thread_resolved == true) then "fixed" else "open" end)
              else (if (.classification == "handled") then "fixed" else "open" end)
              end
            ),
            introduced_iteration: 1,
            fixed_iteration: null,
            fix_commit: null,
            fix_framing: null,
            root_class: null,
            thread_resolved: (.thread_resolved // null)
          }
      ]
  ' 2>/dev/null
}

# normalized_live_parse_gate <normalized-payload>: LIVE FAIL-CLOSED fence for the
# normalized channel (mirrors the git-log live-parse-failed gate). Applied ONLY on
# the LIVE path (INJECTED != 1). RETURNS:
#   0 — payload is a legitimately-EMPTY live normalized payload (zero bytes), a real
#       "no thread findings" state -> valid empty exit 0 downstream.
#   0 — payload is a NON-EMPTY, parseable JSON ARRAY (valid live thread findings).
#   non-zero (emits LEDGERRECON_ERROR=normalized-parse-failed) — payload is NON-EMPTY
#       but fails JSON parse OR is not a JSON array. Fail CLOSED rather than coerce to
#       `[]` and mask a real error as "no thread findings".
# INVARIANT: runs in the live branch BEFORE normalized_to_findings, so the pure core
# only ever sees a validated array on the live path. The injected path bypasses this
# gate entirely (trusted fixture, fail-open).
normalized_live_parse_gate() {
  local payload="$1"
  # LEGITIMATELY EMPTY live payload (zero bytes) -> valid empty, exit 0.
  [ -n "$payload" ] || return 0
  # NON-EMPTY: must parse AND be a JSON array, else fail CLOSED.
  if ! printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "LEDGERRECON_ERROR=normalized-parse-failed" >&2
    return 1
  fi
  return 0
}

# reconstruct_ledger <git-findings-json> <thread-findings-json>: PURE CORE. Wrap
# the two finding families into the top-level fix-ledger object. The branch is
# best-effort (null off a detached/non-repo state — non-fatal). Always emits one
# valid fix-ledger object; empty families -> empty findings (the fail-open shape).
reconstruct_ledger() {
  local git_findings="$1" thread_findings="$2" branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$branch" in ''|HEAD) branch="" ;; esac
  jq -n -c \
    --argjson git_findings "$git_findings" \
    --argjson thread_findings "$thread_findings" \
    --arg base "$BASE" \
    --arg branch "$branch" '
    ($git_findings + $thread_findings) as $findings
    | {
        branch: (if ($branch | length) > 0 then $branch else null end),
        base:   (if ($base | length) > 0 then $base else null end),
        max_iterations: 10,
        iterations: [
          {
            iteration: 1,
            findings: $findings,
            verdict: "needs-attention",
            exit_reason: null,
            review_base_ref: (if ($base | length) > 0 then $base else null end)
          }
        ],
        exit_reason: null,
        exit_iteration: null
      }
  '
}
