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
#
# BLOCK-SCALAR BODY DISCIPLINE (untrusted-content containment, #161 P1): the `description: |`
# field carries UNTRUSTED, issue-sourced free text reproduced verbatim at the block-scalar
# content indent. A hostile description such as
#       status: failed
#       worktree_path: |-
#         /attacker/path
# would otherwise be re-interpreted as strain STRUCTURE by a naive `^[[:space:]]*key:` match,
# letting description text override genuine strain fields (falsify the dashboard, redirect the
# ledger projector). To prevent this, BOTH functions are block-scalar-aware: when a `key: |` /
# `key: |-` line opens a block scalar, every following line MORE-INDENTED than that key is the
# scalar's BODY and is skipped for field/structure matching. Field keys are matched ONLY at the
# strain's direct field indent (the indent of the `- name:`/sibling keys), never inside a body.
# This is the schema-faithful read of the producer's emission (fields at the strain indent,
# block-scalar bodies strictly deeper) and contains description content as inert DATA.

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
    # indent_of(s): count leading spaces of a line (tabs are not emitted by the producer).
    function indent_of(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }

    # Enter the strains: region at the top-level (column-0) strains: key.
    /^strains:[[:space:]]*$/ { in_strains = 1; in_scalar = 0; next }
    # Any other top-level (column-0) key ends the strains region.
    /^[^[:space:]]/ { if (in_strains) in_strains = 0; in_scalar = 0 }
    !in_strains { next }

    # BLOCK-SCALAR BODY SKIP: while inside a block-scalar body, every line deeper than the
    # opening key is untrusted content (e.g. the description body) — never structure. The body
    # ends at the first line whose indent is <= the key indent (or a blank line is tolerated as
    # interior content and skipped too). This MUST run before any `- name:` match so an injected
    # "- name:" inside a description body cannot be mistaken for a strain entry.
    in_scalar {
      if ($0 ~ /^[[:space:]]*$/) { next }           # blank interior line: still body
      if (indent_of($0) > scalar_indent) { next }   # deeper than key: body content, skip
      in_scalar = 0                                  # dedented to/under the key: body ended
      # fall through to evaluate this line as structure
    }

    {
      # A pending block-scalar NAME value (line after "  - name: |-") is consumed first: the
      # genuine name is ONLY its first content line. Any FURTHER lines more-indented than the
      # name key are injected block-scalar BODY (e.g. a multiline name carrying "status: failed"
      # on line 2) and must be skipped as content, never parsed as structure. So after printing
      # the first line, enter the block-scalar body-skip keyed off the name content indent (the
      # same containment applied to description/other-scalar bodies). (Codex #172 P1.)
      if (grab) {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        grab = 0
        # Treat the rest of the name block-scalar as body to skip. The body comprises lines at
        # the name CONTENT indent (this first content line indent) or deeper; a sibling field
        # such as "    description:" sits at a SHALLOWER indent and correctly ends the body.
        # Using content_indent - 1 as the threshold means the in_scalar rule skips body lines
        # (indent > threshold) while a dedent to the sibling-field indent ends the skip.
        scalar_indent = indent_of($0) - 1
        in_scalar = 1
        next
      }
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
      # Any OTHER "key: |" / "key: |-" opens a block scalar whose body must be skipped (e.g.
      # description). Record the key indent so the in_scalar rule above can skip the body.
      if ($0 ~ /^[[:space:]]*[^:[:space:]][^:]*:[[:space:]]*\|-?[[:space:]]*$/) {
        scalar_indent = indent_of($0)
        in_scalar = 1
        next
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
    function indent_of(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }

    # Track the strains: region (top-level strains: key down to the next column-0 key).
    /^strains:[[:space:]]*$/ { in_strains = 1; in_scalar = 0; next }
    /^[^[:space:]]/ { if (in_strains) in_strains = 0; in_target = 0; in_scalar = 0 }
    !in_strains { next }

    # Resolve a pending block-scalar NAME value (the line after "- name: |-"). This first content
    # line is the genuine name value, consumed BEFORE the body-skip rule (it sits one level deeper
    # than the "- name:" key but is the value we actually want, not skippable body). Any FURTHER
    # lines of a multiline name are injected block-scalar BODY (e.g. line 2 "status: failed") and
    # MUST be skipped as content, never matched as fields — so after capturing the value we enter
    # the body-skip with the name content indent (content_indent - 1 threshold, so a shallower
    # sibling field ends the skip). (Codex #172 P1; pairs with the producer newline rejection.)
    pending_name_block {
      nm = trim($0)
      cur_is_target = (nm == want)
      in_target = cur_is_target
      pending_name_block = 0
      scalar_indent = indent_of($0) - 1
      in_scalar = 1
      next
    }

    # Once a FIELD block scalar was opened for the TARGET strain, the very next content line
    # carries the value. Consumed before the body-skip rule for the same reason as the name.
    grab_field {
      print trim($0)
      grab_field = 0
      found = 1
      exit
    }

    # BLOCK-SCALAR BODY SKIP (untrusted-content containment): while inside a block-scalar body
    # we are NOT capturing (description, overlap_details, or any non-target scalar), every line
    # deeper than the opening key is content — NEVER structure. An injected "status: failed" or
    # "worktree_path: |-" inside a description body therefore can never be matched as a field.
    # The body ends at the first non-blank line whose indent is <= the key indent. This rule
    # runs BEFORE the field/name matchers so injected keys never reach them.
    in_scalar {
      if ($0 ~ /^[[:space:]]*$/) { next }
      if (indent_of($0) > scalar_indent) { next }
      in_scalar = 0
      # fall through to evaluate this line as structure
    }

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

    in_target {
      # Match "<indent><field>:" with the field token anchored as the exact key (trailing
      # colon). The field must be a DIRECT key, not a key buried in a deeper block-scalar body —
      # the in_scalar rule above already discarded body lines, so any "key: |" line reaching
      # here is a genuine strain (or nested run.) field.
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
      # A NON-target block-scalar key (e.g. description, or a run.* scalar we were not asked for)
      # opens a body that must be skipped so its untrusted content is never matched as a field.
      if ($0 ~ /^[[:space:]]*[^:[:space:]][^:]*:[[:space:]]*\|-?[[:space:]]*$/) {
        scalar_indent = indent_of($0)
        in_scalar = 1
        next
      }
    }
  ' "$manifest_path"
}
