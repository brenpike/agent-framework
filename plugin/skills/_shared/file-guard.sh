# shellcheck shell=bash
#
# file-guard.sh — shared append-if-absent file-guard kernel + documented variants (seed-hive).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/file-guard.sh"`).
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
# SINGLE RESPONSIBILITY: the append-if-absent file-guard family that seed-hive applies to
# PLAIN TEXT project files (seed-hive SKILL.md steps 8, 9, 10, and the step-14 `## Validation`
# CLAUDE.md guard). This is DISTINCT from settings-merge.sh (which merges the JSON
# `.claude/settings.json` object) and claude-mem-path.sh (which provisions claude-mem's OWN
# JSON config): those operate on JSON via jq; THIS lib operates on line-oriented TEXT files
# with pure bash. No jq, no eval, no source — the entry text is never interpreted as code.
#
# THE SHARED KERNEL (P22 — one home for genuinely shared knowledge):
#   `hivemind_append_if_absent` is the ONE kernel the `.gitignore` guard (SKILL.md step 8) uses,
#   called once per entry (`.hivemind/`, `.claude/worktrees/`). The kernel's idempotency
#   predicate is "<entry> already appears as a STANDALONE ACTIVE line (trimmed) in <file>". The
#   trailing-newline-before-append guard (SKILL.md step 8b: "prepend a blank line if the file
#   does not end with a newline at the time of that append") lives in the kernel so every guard
#   that appends a line inherits it identically.
#
# DOCUMENTED VARIANTS (NOT copy-paste forks — each is the SAME kernel with one documented knob):
#   - `hivemind_append_env_if_absent` (.envrc, SKILL.md step 9): the kernel with a
#     COMMENT-AWARE + QUOTE-TOLERANT presence predicate. The difference from the bare kernel is
#     precisely two documented knobs — (a) a line beginning with `#` after trimming is NOT
#     active, so a `# export CAVEMAN_DEFAULT_MODE=ultra` commented line does NOT count as present
#     and the entry is STILL appended; (b) the value's surrounding quotes are tolerated, so
#     `export CAVEMAN_DEFAULT_MODE="ultra"` and `...=ultra` and `...='ultra'` all count as
#     present. It delegates the actual append (including the trailing-newline guard) to the
#     kernel; only the PRESENCE predicate differs. This is a genuine variant (a different
#     predicate), expressed by parameterizing the kernel's matcher — NOT a near-duplicate body.
#   - `hivemind_guard_validation_section` (CLAUDE.md `## Validation`, SKILL.md step 14c/d/e):
#     a SECTION-aware append — the unit appended is a whole `## Validation` markdown section, and
#     the presence predicate is "a `## Validation` heading already exists" rather than a single
#     standalone line. Same append-if-absent SHAPE as the kernel (test presence, else append a
#     trailing-newline-guarded block, report added/already), with the section-scoped predicate.
#
# THE HOOK SCAFFOLD IS NOT A LINE GUARD (different op, lives here for cohesion):
#   `hivemind_scaffold_hook_file` is a CREATE-IF-ABSENT file scaffold for the caveman
#   SubagentStart hook (SKILL.md step 10a-c): create the hook file with the EXACT fixed content
#   if absent + set the executable bit (report `created`); if it exists, report `already present`
#   and leave content untouched. It does NOT wire the hook into `.claude/settings.json` —
#   step 10d's `hooks.SubagentStart` settings wiring is OWNED BY settings-merge.sh (which already
#   emits that key in its OUTPUT CONTRACT). This lib creates the FILE + chmod ONLY; duplicating
#   the settings wiring here would fork the rule settings-merge.sh already owns (P1 violation).
#
# DATA-BOUNDARY: the entry / section / hook content is plain TEXT written verbatim. It is never
# interpolated into eval, source, or a jq program; the presence tests are pure-bash string
# comparisons on trimmed lines, so a hostile entry value cannot execute. Files are read with
# `read`/`printf` only.
#
# OUTPUT CONTRACT (consumed by the seed-hive entrypoint, future step): each function emits ONE
# status word on stdout and returns 0. The status is signalled IN-BAND on stdout (consistent
# with settings-merge.sh / claude-mem-path.sh), NOT via exit code, so the caller branches on the
# word. The status words are exactly the SKILL.md report tokens for each guard:
#   - hivemind_append_if_absent / hivemind_append_env_if_absent → `added` | `already present`
#   - hivemind_scaffold_hook_file                               → `created` | `already present`
#   - hivemind_guard_validation_section                         → `added` | `already documented`
#
# DEPENDENCY: pure bash + coreutils (no jq, no sed/awk required). Inert.

# _hivemind_trim <line>
# Emit <line> with leading and trailing whitespace removed. Pure helper for the line-presence
# predicates (a "standalone line (trimmed)" per SKILL.md step 8b / "after trimming" per step 9b).
_hivemind_trim() {
  local s="$1"
  # Strip leading then trailing horizontal whitespace (spaces + tabs).
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _hivemind_file_has_trailing_newline <file>
# Return 0 when <file> is non-empty AND its last byte is a newline; return 1 otherwise (empty
# file, absent file, or a file whose last byte is not a newline). Drives the SKILL.md step 8b
# "prepend a blank line if the file does not end with a newline at the time of that append"
# guard so an appended entry always lands on its OWN line.
_hivemind_file_has_trailing_newline() {
  local file="$1"
  [ -s "$file" ] || return 1
  local last
  last="$(tail -c 1 "$file" 2>/dev/null)"
  # Command substitution strips a trailing newline → an empty capture means the last byte WAS a
  # newline; a non-empty capture means it was some other byte.
  [ -z "$last" ]
}

# _hivemind_append_line <file> <entry>
# Append <entry> on its own line to <file>, creating the file if absent and inserting the
# SKILL.md step 8b trailing-newline guard first (when the file is non-empty and lacks a trailing
# newline). This is the ONE append primitive the kernel and the .envrc variant both delegate to,
# so the newline guard is single-sourced (P22). Pure text write; the entry is never interpreted.
_hivemind_append_line() {
  local file="$1" entry="$2"
  if [ ! -e "$file" ]; then
    printf '%s\n' "$entry" > "$file"
    return 0
  fi
  # File exists and is non-empty but lacks a trailing newline → add one first so the entry is a
  # standalone line, never glued onto the file's last (unterminated) line.
  if [ -s "$file" ] && ! _hivemind_file_has_trailing_newline "$file"; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$entry" >> "$file"
}

# hivemind_append_if_absent <file> <entry>
# THE SHARED KERNEL (SKILL.md step 8b). If <entry> already appears as a STANDALONE ACTIVE line
# in <file> (compared after trimming leading/trailing whitespace), this is a no-op and reports
# `already present`. Otherwise <entry> is appended on its own line (with the trailing-newline
# guard) and reports `added`. The file is created if absent (the entry becomes its first line).
# Idempotent: a second call with the same entry reports `already present` and never duplicates.
#
# ARGUMENTS
#   <file>   absolute path to the target text file (e.g. `<root>/.gitignore`). Created if absent.
#   <entry>  the exact line to guarantee present (e.g. `.hivemind/`). Compared trimmed; written
#            verbatim. Called ONCE PER ENTRY by the .gitignore guard (`.hivemind/`, then
#            `.claude/worktrees/`), each entry independent.
hivemind_append_if_absent() {
  local file="$1" entry="$2"
  local want
  want="$(_hivemind_trim "$entry")"

  if [ -f "$file" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$(_hivemind_trim "$line")" = "$want" ]; then
        printf '%s\n' "already present"
        return 0
      fi
    done < "$file"
  fi

  _hivemind_append_line "$file" "$entry"
  printf '%s\n' "added"
}

# hivemind_append_env_if_absent <file> <entry>
# The kernel's COMMENT-AWARE + QUOTE-TOLERANT variant for `.envrc` (SKILL.md step 9b/c). Presence
# is decided ONLY over ACTIVE lines: a line whose trimmed form begins with `#` is a comment and
# does NOT count, so a `# export CAVEMAN_DEFAULT_MODE=ultra` commented line is treated as ABSENT
# and the entry is still appended. Quote tolerance: an active line counts as present when, after
# trimming, it equals <entry> OR equals <entry> with the VALUE wrapped in matching single or
# double quotes (SKILL.md step 9b: "with or without quotes around `ultra`"). On absence the
# append (and its trailing-newline guard) is delegated to the kernel's append primitive, so the
# only thing that differs from the bare kernel is the PRESENCE predicate — not the write.
#
# ARGUMENTS
#   <file>   absolute path to `<root>/.envrc`. Created if absent (entry becomes its first line).
#   <entry>  the active assignment to guarantee present, e.g. `export CAVEMAN_DEFAULT_MODE=ultra`.
#            <entry> is expected in unquoted `<lhs>=<value>` form; the quote-tolerant match
#            accepts an existing active line that quotes the value.
hivemind_append_env_if_absent() {
  local file="$1" entry="$2"
  local want
  want="$(_hivemind_trim "$entry")"

  # Build the quote-tolerant accepted forms: the bare entry, plus the entry with its value (the
  # substring after the FIRST `=`) wrapped in single or double quotes. When the entry has no `=`
  # the quoted variants collapse to the bare form (harmless).
  local lhs value want_dq want_sq
  if [[ "$want" == *=* ]]; then
    lhs="${want%%=*}"
    value="${want#*=}"
    want_dq="${lhs}=\"${value}\""
    want_sq="${lhs}='${value}'"
  else
    want_dq="$want"
    want_sq="$want"
  fi

  if [ -f "$file" ]; then
    local line trimmed
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed="$(_hivemind_trim "$line")"
      # Skip comment lines: a `#`-leading line is NOT active (SKILL.md step 9b).
      case "$trimmed" in
        '#'*) continue ;;
      esac
      if [ "$trimmed" = "$want" ] || [ "$trimmed" = "$want_dq" ] || [ "$trimmed" = "$want_sq" ]; then
        printf '%s\n' "already present"
        return 0
      fi
    done < "$file"
  fi

  _hivemind_append_line "$file" "$entry"
  printf '%s\n' "added"
}

# hivemind_caveman_hook_content
# Emit the EXACT fixed content of the caveman SubagentStart hook script (SKILL.md step 10b), as
# the SINGLE DATA source for that content (P1). The scaffold function writes this verbatim; any
# caller that needs to display or test the content reads it through this function. Pure: no side
# effects, no exit, reads no input.
#
# INVARIANT: this content is byte-for-byte the hook body in seed-hive/SKILL.md step 10b. The hook
# itself prints a SubagentStart hook JSON payload on stdout; do not edit either side without
# updating the other in the same change.
hivemind_caveman_hook_content() {
  cat <<'HOOK'
#!/usr/bin/env bash

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": "Caveman mode requirement for this project: operate in caveman ultra mode for this entire subagent conversation. Do not silently fall back to full, lite, or normal verbosity unless the user explicitly requests it."
  }
}
EOF
HOOK
}

# hivemind_scaffold_hook_file <hook_file>
# CREATE-IF-ABSENT scaffold for the caveman SubagentStart hook script (SKILL.md step 10a-c). When
# <hook_file> does NOT exist: write the EXACT fixed content (from hivemind_caveman_hook_content),
# set the executable bit (`chmod +x`), and report `created`. When it ALREADY exists: report
# `already present` and leave its content UNTOUCHED (SKILL.md step 10c). The parent directory is
# created if needed (mirroring SKILL.md step 10a's `mkdir -p .claude/hooks/`).
#
# This function does NOT wire `hooks.SubagentStart` into `.claude/settings.json`; that settings
# wiring (SKILL.md step 10d) is OWNED BY settings-merge.sh. This lib owns the FILE + chmod only.
#
# ARGUMENTS
#   <hook_file>  absolute path to the hook script (the entrypoint passes
#                `<root>/.claude/hooks/caveman-ultra-subagent.sh`).
hivemind_scaffold_hook_file() {
  local hook_file="$1"
  if [ -e "$hook_file" ]; then
    printf '%s\n' "already present"
    return 0
  fi
  local hook_dir
  hook_dir="$(dirname "$hook_file")"
  mkdir -p "$hook_dir"
  hivemind_caveman_hook_content > "$hook_file"
  chmod +x "$hook_file"
  printf '%s\n' "created"
}

# hivemind_guard_validation_section <claude_md_file> <section_body>
# SECTION-aware append-if-absent for the repo-root CLAUDE.md `## Validation` section (SKILL.md
# step 14c/d/e). If <claude_md_file> ALREADY contains a `## Validation` heading, this is a no-op
# and reports `already documented` — the existing prose is left byte-untouched (SKILL.md step
# 14c: "record NOTHING, leave the existing prose untouched"). Otherwise <section_body> is
# appended as a whole section (with the kernel's trailing-newline guard so the heading starts on
# its own line) and reports `added`. The file is created with <section_body> if absent (SKILL.md
# step 14e). This is the kernel's append-if-absent SHAPE with a SECTION-scoped presence predicate
# (a `## Validation` heading) instead of a single-line predicate; STEP-004's test-detector calls
# this once it has assembled the section body.
#
# ARGUMENTS
#   <claude_md_file>  absolute path to repo-root CLAUDE.md. Created if absent.
#   <section_body>    the full `## Validation` section text to append (heading + fenced command
#                     block(s)), assembled by the caller. Written verbatim; never interpreted.
#                     MUST begin with the `## Validation` heading line so the presence predicate
#                     and the appended content agree.
hivemind_guard_validation_section() {
  local file="$1" section_body="$2"

  # Presence predicate: a `## Validation` heading already exists (ATX heading, allowing trailing
  # whitespace after the word). Comment/heading match is line-oriented over the existing file.
  if [ -f "$file" ]; then
    local line trimmed
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed="$(_hivemind_trim "$line")"
      case "$trimmed" in
        '## Validation'|'## Validation '*)
          printf '%s\n' "already documented"
          return 0
          ;;
      esac
    done < "$file"
  fi

  if [ ! -e "$file" ]; then
    printf '%s\n' "$section_body" > "$file"
    printf '%s\n' "added"
    return 0
  fi

  # Append the section after a trailing-newline guard so the heading is never glued onto the
  # file's last unterminated line. Reuse the kernel's newline-guard test for single-sourcing.
  if [ -s "$file" ] && ! _hivemind_file_has_trailing_newline "$file"; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$section_body" >> "$file"
  printf '%s\n' "added"
}
