# shellcheck shell=bash
#
# ledger-project.sh — shared child run-ledger scalar projector (read side).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/ledger-project.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
#
# P18 FLOOR EXCEPTION (ADR-0020): as a SOURCED library this file deliberately
# OMITS the P18 shell-safety floor `set -e` / `set -o pipefail` and any EXIT trap. A sourced
# file mutates the SOURCING shell's option state, so installing those here would corrupt
# every caller's shell; the floor is therefore the documented exception, not the full
# `set -euo pipefail`. This file carries no top-level `set` at all (pure function
# definitions); each caller owns its own `set -u` and error routing. Allowlisted under
# CHECK13 as a P18 documented exception.
#
# SINGLE RESPONSIBILITY: project + validate the two workflow-state scalars (run.status and
# state.current) from a CONFINED child run-ledger path. The ledger is JSON, parsed READ-ONLY
# with jq. This file sources nothing and writes nothing — pure projection.
#
# DATA-BOUNDARY (MANDATORY): a child run-ledger (`<worktree>/.hivemind/runs/<id>/state.json`)
# is UNTRUSTED, attacker-controllable bytes — a brood child runs detached
# --dangerously-skip-permissions, so its ledger contents are adversary-influenced. These
# functions NEVER echo raw ledger bytes: they emit ONLY a value that passed strict validation,
# or one of the fixed tokens MISSING / MALFORMED. The caller is expected to have already
# CONFINED the ledger path (containment + allowlist) before calling; these functions add the
# value-shape validation layer.
#
# PER-SCALAR INDEPENDENCE: the two projectors are independent. A bad run.status never blanks
# state.current and vice versa — the caller reads both and renders each on its own merit.
#
# TOKEN SEMANTICS:
#   MISSING   — the ledger file/dir is absent, OR the field is absent/empty in a parseable file
#               (`// empty` yielded nothing). "Nothing to report", not an attack.
#   MALFORMED — the file exists but jq could not parse it (torn/partial/invalid JSON), OR the
#               field is present but fails its value contract (out-of-enum status, or a
#               state.current that violates the identifier shape / length cap). "Present but
#               invalid" — never echoed raw.

# SINGLE-SNAPSHOT READ (read-side projection path): the projection engine
# (brood-status-project.sh) reads the ledger file EXACTLY ONCE into an in-memory shell variable
# and projects BOTH scalars from THAT snapshot via jq stdin (`printf '%s' "$content" | jq ...`),
# never re-opening the file. This mirrors the manifest single-snapshot pattern (manifest-json.sh)
# and collapses the prior per-scalar reopen window: the OLD path-based projectors each independently
# re-stat + re-open the leaf via jq (which FOLLOWS symlinks), so a hostile child could swap the
# regular-file leaf to a symlink in the post-check window and the per-scalar reopens would follow it.
# The content-snapshot projectors below (suffix `_content`) take the CONTENT, not the path; the
# legacy path-based pair (hivemind_project_run_status / hivemind_project_state_current) is retained
# as a thin read-once wrapper for the unit-test callers that pass a fixture path directly.

# hivemind_path_has_nul <file>
# Returns 0 (true) iff <file> contains at least one literal NUL byte. JSON never legitimately
# contains a literal NUL, so its presence marks the file UNREADABLE/MALFORMED.
#
# WHY THIS EXISTS: bash command substitution `$(...)` SILENTLY STRIPS NUL bytes from its
# captured output. A file read with `content="$(cat -- "$f")"` therefore yields a value that
# DIFFERS from the on-disk bytes whenever a NUL is present — e.g. an on-disk
# `{"strains":<NUL>[]}` becomes the valid-looking `{"strains":[]}` and passes shape validation.
# We must therefore reject a NUL-bearing file at the FILE level, BEFORE any `$(...)` read can
# erase the NUL. `grep`/bash-string approaches cannot carry a NUL in the pattern (the NUL is
# itself stripped from the pattern), so detection is done byte-accurately via `tr`: strip every
# NUL and compare the byte length to the original — any difference means a NUL was present.
# LC_ALL=C keeps `tr`/`wc` byte-oriented (no locale multibyte interpretation).
hivemind_path_has_nul() {
  local file="$1"
  [ -f "$file" ] || return 1
  local orig stripped
  orig="$(LC_ALL=C wc -c < "$file" 2>/dev/null)" || return 1
  stripped="$(LC_ALL=C tr -d '\000' < "$file" 2>/dev/null | LC_ALL=C wc -c)"
  [ "$orig" != "$stripped" ]
}

# hivemind_project_run_status_content <content>
# Emit the validated run.status from an in-memory ledger CONTENT snapshot, or MISSING
# (empty content / absent-or-empty field) or MALFORMED (unparseable JSON / value outside the
# fixed enum running|complete|blocked|cancelled). The content is UNTRUSTED bytes; it enters jq
# ONLY via stdin pipe, never spliced into the program, never eval'd.
#
# IN-JQ VALIDATION (framing-preserving): the type gate, empty/absent classification, AND the
# enum membership test ALL run INSIDE jq, so the verdict is computed while the bytes are still
# intact. jq emits ONLY a fixed token (MISSING / MALFORMED) or a value that is byte-for-byte
# one of the four enum literals. This closes two distinct gaps that a post-extraction bash
# `case` left open:
#   1. NUL/control-byte stripping: bash command substitution SILENTLY DROPS NUL
#      bytes, so a hostile `"run\u0000ning"` would, after extraction, become `running` and pass
#      a bash enum check. Comparing inside jq (where the NUL is intact) rejects it as MALFORMED,
#      and a value that DOES pass `IN(...)` is exactly an enum literal — it can carry no NUL.
#   2. Falsy non-string values: the prior `.run.status // empty` treated JSON
#      `false` as absent (`//` is alternative-on-falsy), projecting a tamper value as MISSING.
#      The explicit `type` gate reports a PRESENT non-string as MALFORMED; only an absent/null
#      field or an explicit empty string is MISSING.
#
# SINGLE-DOCUMENT DISCIPLINE: jq accepts a STREAM of concatenated JSON documents, so a
# non-slurped `jq -r` runs the program ONCE PER document and a child state.json holding TWO valid
# objects would emit TWO output lines — the embedded newline corrupts the one-line STRAIN frame the
# caller builds. We SLURP with `-s` and require `length==1` (exactly one top-level document); 0 or
# >1 documents → MALFORMED. The scalar is projected from `.[0]` of the slurped array. This mirrors
# the single-document discipline in manifest-json.sh (hivemind_manifest_validate_shape et al).
hivemind_project_run_status_content() {
  local content="$1"
  if [ -z "$content" ]; then
    printf 'MISSING\n'
    return 0
  fi
  local verdict
  if ! verdict="$(printf '%s' "$content" | jq -r -s '
      if (length != 1) then "MALFORMED"
      elif (.[0]|type)!="object" then "MALFORMED"
      elif (.[0]|has("run")|not) or (.[0].run|type)!="object" or (.[0].run.status==null) then "MISSING"
      elif (.[0].run.status|type)!="string" then "MALFORMED"
      elif (.[0].run.status=="") then "MISSING"
      elif (.[0].run.status|IN("running","complete","blocked","cancelled")) then .[0].run.status
      else "MALFORMED" end' 2>/dev/null)"; then
    # jq failed: unparseable / torn JSON.
    printf 'MALFORMED\n'
    return 0
  fi
  printf '%s\n' "$verdict"
  return 0
}

# hivemind_project_state_current_content <content>
# Emit the validated state.current from an in-memory ledger CONTENT snapshot, or MISSING (empty
# content / absent-or-empty field) or MALFORMED (unparseable JSON / value failing ^[a-z0-9_]+$ /
# value longer than 64 chars). The content enters jq ONLY via stdin pipe, never spliced/eval'd.
#
# IN-JQ VALIDATION (framing-preserving): the JSON-type gate, length cap, AND the charset test
# ALL run INSIDE jq, so the verdict is computed while the bytes are still intact, and jq emits
# ONLY a fixed token (MISSING / MALFORMED) or a value that has already satisfied ^[a-z0-9_]+$.
# This closes two gaps a post-extraction bash check left open:
#   1. NUL/control-byte stripping: bash command substitution SILENTLY DROPS NUL
#      bytes, so a hostile `"imp lement"` would, after extraction, become `implement` and pass
#      a bash charset `case`. Testing inside jq (NUL intact) rejects it as MALFORMED, and a value
#      that DOES pass `test("^[a-z0-9_]+$")` contains only [a-z0-9_] — it can carry no NUL.
#   2. Non-string scalars (the pre-existing type gate): jq -r stringifies a JSON true to "true"
#      etc.; a PRESENT non-string is a tamper indicator → MALFORMED. An ABSENT/null field or an
#      explicit empty string is the intended "nothing to report" case → MISSING.
#
# SINGLE-DOCUMENT DISCIPLINE: same rationale as hivemind_project_run_status_content — a
# non-slurped `jq -r` over a child state.json holding TWO concatenated valid objects would emit TWO
# lines, and the embedded newline corrupts the one-line STRAIN frame. We SLURP with `-s` and require
# `length==1`; 0 or >1 documents → MALFORMED. The scalar is projected from `.[0]`.
hivemind_project_state_current_content() {
  local content="$1"
  if [ -z "$content" ]; then
    printf 'MISSING\n'
    return 0
  fi
  local verdict
  if ! verdict="$(printf '%s' "$content" | jq -r -s '
      if (length != 1) then "MALFORMED"
      elif (.[0]|type)!="object" then "MALFORMED"
      elif (.[0]|has("state")|not) or (.[0].state|type)!="object" or (.[0].state.current==null) then "MISSING"
      elif (.[0].state.current|type)!="string" then "MALFORMED"
      elif (.[0].state.current=="") then "MISSING"
      elif (.[0].state.current|length>64) then "MALFORMED"
      elif (.[0].state.current|test("^[a-z0-9_]+$")) then .[0].state.current
      else "MALFORMED" end' 2>/dev/null)"; then
    # jq failed: unparseable / torn JSON.
    printf 'MALFORMED\n'
    return 0
  fi
  printf '%s\n' "$verdict"
  return 0
}

# hivemind_project_run_status <ledger_path>
# Legacy path-based wrapper retained for unit-test callers that pass a fixture path. Reads the
# ledger ONCE and delegates to hivemind_project_run_status_content. Emit the validated run.status,
# or MISSING (absent file / absent-or-empty field) or MALFORMED (unparseable JSON / value outside
# the fixed enum). An absent file is MISSING (the wrapper short-circuits before any read).
hivemind_project_run_status() {
  local ledger_path="$1"
  if [ ! -f "$ledger_path" ]; then
    printf 'MISSING\n'
    return 0
  fi
  # FILE-LEVEL NUL REJECTION: the `cat` below captures via `$(...)`, which
  # SILENTLY STRIPS NUL bytes, so a NUL-bearing ledger would parse as a different document than
  # what is on disk. JSON never legitimately contains a literal NUL → "present but invalid" →
  # MALFORMED, checked at the FILE level before the `$(...)` read can erase the NUL.
  if hivemind_path_has_nul "$ledger_path"; then
    printf 'MALFORMED\n'
    return 0
  fi
  local content
  # READ FAILURE on a PRESENT file (unreadable perms, I/O error) is "present but cannot be
  # read" → MALFORMED, never MISSING. `cat` returns empty AND non-zero on failure; the
  # `2>/dev/null` silences stderr only, not the exit status the `if !` tests. Mirrors the
  # pre-single-snapshot jq-open-failure semantics and the content-snapshot read site. The
  # re-test `[ -e ]` keeps a file that VANISHED after the `[ -f ]` guard above as MISSING
  # (genuine absence), reporting MALFORMED only for a present-but-unreadable file.
  if ! content="$(cat -- "$ledger_path" 2>/dev/null)"; then
    if [ -e "$ledger_path" ]; then
      printf 'MALFORMED\n'
    else
      printf 'MISSING\n'
    fi
    return 0
  fi
  hivemind_project_run_status_content "$content"
  return 0
}

# hivemind_project_state_current <ledger_path>
# Legacy path-based wrapper retained for unit-test callers that pass a fixture path. Reads the
# ledger ONCE and delegates to hivemind_project_state_current_content. Emit the validated
# state.current, or MISSING (absent file / absent-or-empty field) or MALFORMED (unparseable JSON /
# value failing ^[a-z0-9_]+$ / value longer than 64 chars).
hivemind_project_state_current() {
  local ledger_path="$1"
  if [ ! -f "$ledger_path" ]; then
    printf 'MISSING\n'
    return 0
  fi
  # FILE-LEVEL NUL REJECTION: see hivemind_project_run_status — a literal NUL in
  # the ledger would be silently stripped by the `$(...)` read; a NUL-bearing ledger is MALFORMED.
  if hivemind_path_has_nul "$ledger_path"; then
    printf 'MALFORMED\n'
    return 0
  fi
  local content
  # READ FAILURE on a PRESENT file (unreadable perms, I/O error) is "present but cannot be
  # read" → MALFORMED, never MISSING. `cat` returns empty AND non-zero on failure; the
  # `2>/dev/null` silences stderr only, not the exit status the `if !` tests. Mirrors the
  # pre-single-snapshot jq-open-failure semantics and the content-snapshot read site. The
  # re-test `[ -e ]` keeps a file that VANISHED after the `[ -f ]` guard above as MISSING
  # (genuine absence), reporting MALFORMED only for a present-but-unreadable file.
  if ! content="$(cat -- "$ledger_path" 2>/dev/null)"; then
    if [ -e "$ledger_path" ]; then
      printf 'MALFORMED\n'
    else
      printf 'MISSING\n'
    fi
    return 0
  fi
  hivemind_project_state_current_content "$content"
  return 0
}
