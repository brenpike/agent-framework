# shellcheck shell=bash
#
# ledger-project.sh — shared child run-ledger scalar projector (read side, issue #161).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/ledger-project.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
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

# hivemind_project_run_status_content <content>
# Emit the validated run.status from an in-memory ledger CONTENT snapshot, or MISSING
# (empty content / absent-or-empty field) or MALFORMED (unparseable JSON / value outside the
# fixed enum running|complete|blocked|cancelled). The content is UNTRUSTED bytes; it enters jq
# ONLY via stdin pipe, never spliced into the program, never eval'd.
hivemind_project_run_status_content() {
  local content="$1"
  if [ -z "$content" ]; then
    printf 'MISSING\n'
    return 0
  fi
  local value
  if ! value="$(printf '%s' "$content" | jq -r '.run.status // empty' 2>/dev/null)"; then
    # jq failed: unparseable / torn JSON.
    printf 'MALFORMED\n'
    return 0
  fi
  if [ -z "$value" ]; then
    printf 'MISSING\n'
    return 0
  fi
  case "$value" in
    running|complete|blocked|cancelled) printf '%s\n' "$value" ;;
    *) printf 'MALFORMED\n' ;;
  esac
  return 0
}

# hivemind_project_state_current_content <content>
# Emit the validated state.current from an in-memory ledger CONTENT snapshot, or MISSING (empty
# content / absent-or-empty field) or MALFORMED (unparseable JSON / value failing ^[a-z0-9_]+$ /
# value longer than 64 chars). The content enters jq ONLY via stdin pipe, never spliced/eval'd.
hivemind_project_state_current_content() {
  local content="$1"
  if [ -z "$content" ]; then
    printf 'MISSING\n'
    return 0
  fi
  # JSON-TYPE GATE (must precede value extraction): jq -r stringifies non-string scalars
  # (a JSON true becomes the text "true", 123 becomes "123"), which would then pass the
  # identifier length/charset checks and project a forged-but-valid-looking workflow state.
  # Probe the JSON type FIRST: a PRESENT non-string .state.current is a tamper/corruption
  # indicator and is reported MALFORMED; only a genuine JSON string proceeds to the
  # length/charset contract below. An ABSENT field (jq type "null" for a missing key or an
  # explicit JSON null) is the intended "nothing to report" case and is reported MISSING.
  local jtype
  if ! jtype="$(printf '%s' "$content" | jq -r '.state.current | type' 2>/dev/null)"; then
    printf 'MALFORMED\n'
    return 0
  fi
  case "$jtype" in
    null) printf 'MISSING\n'; return 0 ;;
    string) : ;;
    *) printf 'MALFORMED\n'; return 0 ;;
  esac
  local value
  if ! value="$(printf '%s' "$content" | jq -r '.state.current // empty' 2>/dev/null)"; then
    printf 'MALFORMED\n'
    return 0
  fi
  if [ -z "$value" ]; then
    printf 'MISSING\n'
    return 0
  fi
  # Length cap (64) BEFORE charset, so an over-long value is rejected even if all-lowercase.
  if [ "${#value}" -gt 64 ]; then
    printf 'MALFORMED\n'
    return 0
  fi
  case "$value" in
    *[!a-z0-9_]*) printf 'MALFORMED\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
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
