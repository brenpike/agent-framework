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
