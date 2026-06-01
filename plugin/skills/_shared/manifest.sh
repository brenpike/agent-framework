# shellcheck shell=bash
#
# manifest.sh — shared brood-manifest field extractor (read side of spawn-brood.sh).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/manifest.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
#
# SINGLE RESPONSIBILITY: extract scalar fields from the YAML brood manifest via sed/awk
# (no yq — ADR-0017 rejected yq/python as a hard dep; only jq is permitted, and the
# manifest is YAML not JSON). This file is PURE EXTRACTION only: it does NOT validate the
# extracted bytes (that is allowlist.sh's job). Every value emitted here is UNTRUSTED and
# must be re-gated by the caller through hivemind_assert_safe_token before use.
#
# MANIFEST SHAPE (mirrors spawn-brood.sh's emitter; see brood-ledger-model.md): exact-value
# fields are emitted as `key: |-` block scalars whose single value line sits at the content
# indent below the key; `tmux_session` and `status` are emitted INLINE (the producer writes
# `tmux_session: "<value>"` double-quoted and `status: <value>` bare). Per strain the layout is:
#
#   strains:
#     - name: |-
#         <name>
#       description: |
#         <free text>
#       worktree_path: |-
#         <path>
#       branch: |-
#         <branch>
#       tmux_session: "<session>"
#       status: <status>
#       ...
#       run:
#         suggested_id: |-
#           <id>
#         suggested_ledger: |-
#           <path>
#         workflow_hint: |-
#           <hint>
#
# A v1 manifest has no `run:` block, so run.* fields extract as empty (exit 0, no output) —
# the caller treats an empty suggested_ledger as "no ledger pointer present".
#
# PARSE DISCIPLINE: extraction is strain-scoped. hivemind_manifest_field isolates the YAML
# region belonging to the named strain (from its `- name:` block start up to the next
# strain's `- name:` block start, or merge_order/EOF) with awk, then pulls the requested
# field from that region. The tmux_session/status inline forms and the `key: |-` block-scalar
# form (value on the following content line) are both handled, matching the producer exactly.
# DEPENDENCY-FREE beyond sed/awk (both POSIX); no jq, no yq.

# hivemind_manifest_strain_names <manifest_path>
# Emit one strain name per line, in manifest order. A strain block begins with a
# `- name: |-` (or `- name: "..."` / `- name: value`) entry under the top-level `strains:`
# key; the name value is the block-scalar content line that follows (for the |- form) or the
# inline value. Mirrors the producer, which always emits `- name: |-` with the value on the
# next content line. Emits nothing (exit 0) when there are no strains.
hivemind_manifest_strain_names() {
  local manifest_path="$1"
  [ -f "$manifest_path" ] || return 0
  awk '
    # Enter the strains: region at the top-level (column-0) strains: key.
    /^strains:[[:space:]]*$/ { in_strains = 1; next }
    # Any other top-level (column-0) key ends the strains region.
    /^[^[:space:]]/ { if (in_strains) in_strains = 0 }
    in_strains {
      # Block-scalar name entry: "  - name: |-" — value is on the next content line.
      if ($0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*\|-?[[:space:]]*$/) {
        grab = 1
        next
      }
      # Inline name entry: "  - name: api" or "  - name: \"api\"".
      if (match($0, /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/)) {
        val = substr($0, RLENGTH + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        gsub(/^"|"$/, "", val)
        if (val != "") { print val }
        next
      }
      if (grab) {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        grab = 0
      }
    }
  ' "$manifest_path"
}

# hivemind_manifest_field <manifest_path> <strain_name> <field>
# Emit the scalar value of <field> for the strain whose name equals <strain_name>. Supported
# fields: worktree_path, branch, tmux_session, status, run.suggested_ledger, run.suggested_id,
# workflow_hint (the run.* fields may be passed with or without the `run.` prefix). Handles the
# `key: |-` block-scalar form (value on the following content line) and the inline form
# (`tmux_session: "x"`, `status: x`). Emits empty (exit 0) when the strain or field is absent.
hivemind_manifest_field() {
  local manifest_path="$1"
  local strain_name="$2"
  local field="$3"
  [ -f "$manifest_path" ] || return 0

  # Normalize run.* field names: callers may pass `run.suggested_ledger` or `suggested_ledger`.
  case "$field" in
    run.*) field="${field#run.}" ;;
  esac

  awk -v want="$strain_name" -v field="$field" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function unquote(s) { gsub(/^"|"$/, "", s); return s }

    # Track the strains: region (top-level strains: key down to the next column-0 key).
    /^strains:[[:space:]]*$/ { in_strains = 1; next }
    /^[^[:space:]]/ { if (in_strains) in_strains = 0; in_target = 0 }
    !in_strains { next }

    # A new strain block begins at "  - name:". Decide whether it is the target strain.
    /^[[:space:]]*-[[:space:]]*name:/ {
      pending_name_block = 0
      cur_is_target = 0
      # Inline name?
      if (match($0, /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/)) {
        rest = substr($0, RLENGTH + 1)
        rest = trim(rest)
        if (rest ~ /^\|-?[[:space:]]*$/) {
          # Block-scalar name: the value is on the next content line.
          pending_name_block = 1
        } else {
          nm = unquote(rest)
          cur_is_target = (nm == want)
          in_target = cur_is_target
        }
      }
      grab_field = 0
      next
    }

    # Resolve a pending block-scalar name value (the line after "- name: |-").
    pending_name_block {
      nm = trim($0)
      cur_is_target = (nm == want)
      in_target = cur_is_target
      pending_name_block = 0
      next
    }

    # Once a field block scalar was opened for the target strain, the very next content
    # line carries the value.
    grab_field {
      print trim($0)
      grab_field = 0
      found = 1
      exit
    }

    in_target {
      # Match "<indent><field>:" possibly with an inline value or a block-scalar indicator.
      # The field token must be the exact key (anchored with a trailing colon).
      pat = "^[[:space:]]*" field ":"
      if ($0 ~ pat) {
        # Extract everything after the first colon following the field name.
        idx = index($0, ":")
        rest = trim(substr($0, idx + 1))
        if (rest ~ /^\|-?[[:space:]]*$/) {
          # Block scalar: value is on the next content line.
          grab_field = 1
          next
        }
        # Inline value (handles tmux_session: "x" and status: x).
        print unquote(rest)
        found = 1
        exit
      }
    }
  ' "$manifest_path"
}
