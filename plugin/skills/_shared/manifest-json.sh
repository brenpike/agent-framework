# shellcheck shell=bash
#
# manifest-json.sh — shared brood-manifest field extractor (read side of spawn-brood.sh).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/manifest-json.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
#
# SINGLE RESPONSIBILITY: extract scalar fields from the JSON brood manifest with jq. The
# manifest is the same JSON spawn-brood.sh writes (manifest_version 3). This file is PURE
# EXTRACTION only: it does NOT validate the extracted bytes (that is allowlist.sh's job).
# Every value emitted here is UNTRUSTED and must be re-gated by the caller through the
# matching allowlist value-class validator (identifier / path / presentation) before use.
#
# READ-SIDE INJECTION CLASS IS DEAD BY CONSTRUCTION: the prior YAML read side (sed/awk)
# could not separate YAML STRUCTURE from attacker CONTENT — a hostile `description` block
# scalar carrying counterfeit `status:`/`worktree_path:`/nested `run:` keys or an injected
# `- name:` entry had to be defended against with hand-rolled block-scalar-aware,
# indent-anchored awk. With the manifest as JSON parsed by jq, jq CANNOT confuse content for
# structure: a string field's bytes are just a string, never re-parsed as sibling keys. The
# ENTIRE block-scalar / nested-mapping / multiline-injection class the YAML reader fought is
# gone by construction. The remaining boundary is purely VALUE-shape (allowlist), applied by
# the caller, not structural.
#
# DATA-BOUNDARY: every untrusted value (the strain name the caller searches by) enters jq as
# a --arg binding, NEVER interpolated into the jq program string. An unparseable / torn
# manifest yields no output (jq error swallowed) — the caller treats absent fields as empty.
#
# SINGLE-SNAPSHOT READ (read-side projection path): the projection engine
# (brood-status-project.sh) reads the manifest file EXACTLY ONCE into an in-memory shell
# variable (`content="$(cat -- "$path")"`) and then runs every projection against THAT snapshot
# via jq stdin (`printf '%s' "$content" | jq ...`) — it never re-opens the file. This closes the read-side
# SNAPSHOT-SKEW class: a concurrent write mid-read can no longer make the probe and the per-field
# projections observe different instants. Bytes held in a shell variable and passed only to jq
# stdin are inert — bash does not re-evaluate them as command source. The content-snapshot
# helpers below (suffix `_snapshot` / `_at`) take the CONTENT, not the path; the legacy
# path-based pair (hivemind_manifest_strain_names / hivemind_manifest_field) is retained for the
# unit-test callers that pass a fixture path directly.
#
# MANIFEST SHAPE (mirrors spawn-brood.sh's jq emitter): a top-level object with a `strains`
# array; each strain is an object with `name`, `worktree_path`, `branch`, `tmux_session`,
# `status`, and a nested `run` object carrying `suggested_id` / `suggested_ledger` /
# `workflow_hint`. A v1 manifest (no `run` block) yields empty for the run.* fields.
#
# DEPENDENCY: jq only (POSIX + jq). No yq, no sed/awk YAML parsing.

# hivemind_manifest_strain_names <manifest_path>
# Emit one strain name per line, in manifest order. Emits nothing (exit 0) when the file is
# absent, unparseable, or has no strains. jq `// empty` drops a null/absent name.
hivemind_manifest_strain_names() {
  local manifest_path="$1"
  [ -f "$manifest_path" ] || return 0
  jq -r '.strains[]?.name // empty' "$manifest_path" 2>/dev/null
  return 0
}

# hivemind_manifest_field <manifest_path> <strain_name> <field>
# Emit the scalar value of <field> for the strain whose name equals <strain_name>. Supported
# fields: worktree_path, branch, tmux_session, status, run.suggested_ledger,
# run.suggested_id, workflow_hint. The run.* fields may be passed with or WITHOUT the `run.`
# prefix (workflow_hint/suggested_id/suggested_ledger normalize under `run`). Emits empty
# (exit 0) when the strain or field is absent (a v1 manifest with no `run` block yields empty
# for run.* fields), when the file is absent, or when the manifest is unparseable.
#
# The strain name enters jq as `--arg want`, NEVER interpolated into the program. The field
# is resolved as a dot-path: direct fields read `.<field>`; run.* fields read `.run.<field>`.
# The field name itself is a fixed, caller-supplied selector (not attacker content); it is
# still mapped through a closed case so an unexpected field selects nothing rather than
# building an arbitrary jq path.
hivemind_manifest_field() {
  local manifest_path="$1"
  local strain_name="$2"
  local field="$3"
  [ -f "$manifest_path" ] || return 0

  # Normalize the field selector to a fixed jq path under the matched strain. run.* fields
  # (with or without the `run.` prefix) resolve under `.run`; direct fields at the top of the
  # strain object. An unrecognized field maps to nothing (empty output).
  local jq_path
  case "$field" in
    worktree_path|branch|tmux_session|status)
      jq_path=".${field}" ;;
    run.suggested_id|suggested_id)
      jq_path=".run.suggested_id" ;;
    run.suggested_ledger|suggested_ledger)
      jq_path=".run.suggested_ledger" ;;
    run.workflow_hint|workflow_hint)
      jq_path=".run.workflow_hint" ;;
    *)
      return 0 ;;
  esac

  # Select the strain by name (--arg want), then resolve the fixed field path. `// empty`
  # drops a null/absent field so the caller sees empty output (exit 0). The jq_path is one of
  # the fixed literals above — never attacker content — composed into the program after the
  # `select`. `first(...)` guards against a (malformed) manifest with duplicate names.
  jq -r --arg want "$strain_name" \
    "first(.strains[]? | select(.name == \$want)) | $jq_path // empty" \
    "$manifest_path" 2>/dev/null
  return 0
}

# ── Single-snapshot content helpers (read-side projection path) ──────────────────
# These operate on an in-memory CONTENT snapshot the caller read ONCE from the manifest file,
# never re-opening it. The content enters jq ONLY via pipe (`printf '%s' "$content" | jq ...`), never spliced into
# the program; an index enters as --argjson. This is what lets the projection engine open the
# manifest exactly once and run all projections + shape validation against one consistent view.

# hivemind_manifest_validate_shape <content>
# Returns 0 iff <content> is valid JSON AND `.strains` EXISTS and is an ARRAY AND every element
# of `.strains` is an OBJECT. Returns non-zero otherwise (invalid JSON, missing/null/non-array
# `.strains`, or any non-object element). This FOLDS the old `jq empty` syntax-only probe into a
# single shape-validating read: invalid JSON fails `jq -e` here just as it failed `jq empty`, and
# a valid-JSON-but-wrong-shape manifest ({}, {"strains":null}, {"strains":"x"}, {"strains":[1]})
# now ALSO fails — joining the wrong-shape class to the syntactically-invalid class so the caller
# treats both as UNREADABLE rather than silently projecting zero strains. A valid `{"strains":[]}`
# passes (all() over an empty array is true): a legitimate EMPTY brood, NOT unreadable. An element
# that IS an object but lacks `name` still passes shape validation — per-strain field degradation
# (MALFORMED/MISSING tokens) is the existing per-strain contract, not a whole-manifest verdict.
# Emits nothing; pure (no side effects, no exit).
# SINGLE-DOCUMENT REQUIREMENT (root, Codex #172): jq accepts a STREAM of concatenated JSON
# documents, so a non-slurped `jq -e '(.strains|type=="array") ...'` runs the predicate ONCE PER
# document and a file holding TWO valid manifest objects would pass shape validation. The downstream
# count would then emit one length per document (`1\n1`), the loop's `[ "$idx" -lt "$count" ]`
# integer test would error on the multiline value, and the engine would exit 0 with no STRAIN lines
# — live children rendered as an empty brood. We SLURP with `jq -s` and require the slurped array
# length == 1 (exactly one top-level document) AND that the single element is an object with
# `.strains` an array of objects. A multi-document file → length>1 → fails → caller treats it as
# UNREADABLE. The count/field projectors below slurp the same way and index `.[0]`, so the whole
# read operates on one consistent single document.
hivemind_manifest_validate_shape() {
  local content="$1"
  printf '%s' "$content" \
    | jq -e -s 'length == 1
        and (.[0] | type == "object")
        and (.[0].strains | type == "array")
        and (all(.[0].strains[]; type == "object"))' \
      >/dev/null 2>&1
}

# hivemind_manifest_strain_count_snapshot <content>
# Emit the number of strains (length of the `.strains` array) for the in-memory snapshot. Assumes
# the snapshot already passed hivemind_manifest_validate_shape (so `.strains` is an array). Emits
# `0` on any jq error. The caller drives an INDEX-based loop off this count rather than splitting
# a newline-delimited name stream — so an untrusted field value containing a newline (already
# rejected by the value-class floor, but only AFTER extraction) can never split the loop or forge
# an extra iteration before validation. Pure (no side effects, no exit).
hivemind_manifest_strain_count_snapshot() {
  local content="$1"
  # SLURP + index .[0] (root, Codex #172): match hivemind_manifest_validate_shape's single-document
  # discipline so this can never emit one length per document for a multi-document file (which would
  # break the engine's integer loop test). validate_shape has already required exactly one document
  # before this is reached; slurping here keeps the count projection on that same single document.
  printf '%s' "$content" | jq -r -s '.[0].strains | length' 2>/dev/null || printf '0'
}

# hivemind_manifest_field_at <content> <index> <field>
# Emit the scalar value of <field> for the strain at array position <index> (0-based) in the
# in-memory snapshot. Same supported fields and the same fixed-jq-path closed-case mapping as
# hivemind_manifest_field; the strain is selected by INDEX (--argjson i), never by a name that
# could collide or carry a delimiter. `// empty` drops a null/absent field. The field selector is
# a fixed literal from the closed case below — never attacker content. An unrecognized field
# selects nothing. Pure (no side effects, no exit).
hivemind_manifest_field_at() {
  local content="$1"
  local index="$2"
  local field="$3"

  local jq_path
  case "$field" in
    worktree_path|branch|tmux_session|status)
      jq_path=".${field}" ;;
    run.suggested_id|suggested_id)
      jq_path=".run.suggested_id" ;;
    run.suggested_ledger|suggested_ledger)
      jq_path=".run.suggested_ledger" ;;
    run.workflow_hint|workflow_hint)
      jq_path=".run.workflow_hint" ;;
    *)
      return 0 ;;
  esac

  # CONTROL-BYTE REJECTION INSIDE jq (root, Codex #172): the extracted value is consumed by the
  # caller via `$(...)` command substitution, which SILENTLY STRIPS NUL bytes — so a value the
  # caller validates AFTER the `$(...)` round-trip differs from what jq produced. A JSON ` `
  # escape is VALID JSON; `jq -r` decodes it to a real NUL that `$(...)` would erase, turning a
  # value like `feature/api -slice` into the trusted-looking `feature/api-slice` before the
  # allowlist ever sees it. We make jq the integrity point: jq sees the decoded bytes intact, so
  # if the resolved value contains ANY C0 control byte ( - ) we emit NOTHING (empty), exactly
  # as for an absent field. The caller never receives a control-bearing value to strip, and an
  # empty value is rendered MALFORMED by its value-class gate. (` ` is `\u0000`; `` is the
  # last C0 control byte. jq's regex engine matches the decoded codepoints, not the escapes.)
  # SLURP + index .[0] (root, Codex #172): same single-document discipline as
  # hivemind_manifest_validate_shape / _strain_count_snapshot — select the strain at $index from the
  # ONE top-level document, never from a concatenated stream.
  printf '%s' "$content" \
    | jq -r -s --argjson i "$index" \
        ".[0].strains[\$i] | ($jq_path // empty) | select((tostring | test(\"[\\u0000-\\u001f]\")) | not)" \
        2>/dev/null
  return 0
}
