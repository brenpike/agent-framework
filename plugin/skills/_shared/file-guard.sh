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
#     a SECTION-aware guard keyed on a 3-state VALUE-STATE NORMALIZATION of the `## Validation`
#     section (ABSENT / PRESENT-NO-COMMAND / PRESENT-WITH-COMMAND), NOT on the bare presence of the
#     heading. The predicate is BODY-presence: a `## Validation` section counts as fully documented
#     only when it carries a real COMMAND BODY (a fenced ```` ``` ```` command block under the
#     heading). The three states:
#       ABSENT               — no `## Validation` heading at all → append the full assembled section
#                              body (heading + fenced block); report `added`.
#       PRESENT-WITH-COMMAND — a `## Validation` heading WITH a fenced command block in its range →
#                              no-op; report `already documented`; byte-unchanged.
#       PRESENT-NO-COMMAND   — a `## Validation` heading present, NO fenced command block in its
#                              range (prose-only, blank-only, comment-only, or any mix) → KEEP every
#                              existing line of the section VERBATIM and INSERT the fenced command
#                              block(s) (the body BELOW the assembled heading line, NOT a second
#                              heading) at the END of the section's existing content, before the
#                              next sibling/parent heading or EOF; report `added`.
#     This closes the predicate gap where a heading-only stub was mis-reported `already documented`
#     and the detected command was silently dropped. file-guard NEVER drops existing prose: a
#     prose-bearing `## Validation` section is APPENDED-UNDER, never REPLACED, so existing user
#     content is preserved byte-for-byte. The result is always exactly ONE `## Validation` heading.
#
# THE HOOK SCAFFOLD IS NOT A LINE GUARD (different op, lives here for cohesion):
#   `hivemind_scaffold_hook_file` is a CREATE-IF-ABSENT file scaffold for the caveman
#   SubagentStart hook: create the hook file with the EXACT fixed content (from
#   `hivemind_caveman_hook_content`, the single source of that content) if absent + set the
#   executable bit (report `created`); if it exists, report `already present` and leave content
#   untouched. It does NOT wire the hook into `.claude/settings.json` — that `hooks.SubagentStart`
#   settings wiring is OWNED BY settings-merge.sh (which already emits that key in its OUTPUT
#   CONTRACT). This lib creates the FILE + chmod ONLY; duplicating the settings wiring here would
#   fork the rule settings-merge.sh already owns (P1 violation).
#
#   TWO-SIDED COUPLING: this lib owns the FILE at `.claude/hooks/caveman-ultra-subagent.sh`
#   (create + chmod). settings-merge.sh owns the COMMAND that invokes it — the EXEC-FORM entry
#   `command: ${CLAUDE_PROJECT_DIR}/.claude/hooks/caveman-ultra-subagent.sh` (unquoted; `args: []`)
#   written into `hooks.SubagentStart` in `.claude/settings.json`. Renaming or moving the hook path
#   on either side requires changing the other in the SAME change, or the wired command and the
#   scaffolded file diverge silently.
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
# Emit the EXACT fixed content of the caveman SubagentStart hook script, as the SINGLE DATA
# source for that content (P1). The scaffold function writes this verbatim; any caller that needs
# to display or test the content reads it through this function. Pure: no side effects, no exit,
# reads no input.
#
# INVARIANT: THIS function is the single source of the hook script's content — there is no
# SKILL.md copy to keep in sync; every caller (scaffold, tests, docs) reads the body through this
# function rather than re-deriving it. The hook itself prints a SubagentStart hook JSON payload on
# stdout.
#
# TWO-SIDED COUPLING: this lib (via `hivemind_scaffold_hook_file`) owns the FILE at
# `.claude/hooks/caveman-ultra-subagent.sh`. settings-merge.sh owns the COMMAND that invokes it —
# the EXEC-FORM entry `command: ${CLAUDE_PROJECT_DIR}/.claude/hooks/caveman-ultra-subagent.sh`
# (unquoted; `args: []`) for that SAME path. Renaming or moving the hook path on either side
# requires changing the other in the SAME change.
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
# CREATE-IF-ABSENT scaffold for the caveman SubagentStart hook script. When <hook_file> does NOT
# exist: write the EXACT fixed content (from hivemind_caveman_hook_content), set the executable
# bit (`chmod +x`), and report `created`. When it ALREADY exists: report `already present` and
# leave its content UNTOUCHED. The parent directory is created if needed (`mkdir -p
# .claude/hooks/`).
#
# This function does NOT wire `hooks.SubagentStart` into `.claude/settings.json`; that settings
# wiring is OWNED BY settings-merge.sh. This lib owns the FILE + chmod only.
#
# TWO-SIDED COUPLING: this lib owns the FILE at `.claude/hooks/caveman-ultra-subagent.sh`.
# settings-merge.sh owns the COMMAND, which is the EXEC-FORM entry
# `command: ${CLAUDE_PROJECT_DIR}/.claude/hooks/caveman-ultra-subagent.sh` (unquoted; `args: []`).
# Renaming or moving either requires changing the other in the SAME change.
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

# _hivemind_atx_heading <raw_line>
# THE ONE consolidated CommonMark-ATX heading reduction (P22 — one home for heading parsing). It is a
# CANONICAL-ANCHOR normalize-and-equate primitive, NOT a general ATX text-extraction parser: it reduces
# <raw_line> to its (LEVEL, normalized TEXT) canonical form so BOTH the section-bound matcher
# (`_hivemind_is_section_heading`, which needs the LEVEL only) and the exact-name matcher
# (`_hivemind_is_validation_heading`, which equates the reduced form against the skill's OWN canonical
# `## Validation` heading) route through a SINGLE reduction — no per-matcher heading rule can drift
# apart. The skill emits exactly ONE canonical heading (`## Validation`); the exact-name matcher decides
# membership by reducing the candidate line through THIS function and comparing its canonical form to the
# canonical form of that one target, rather than by re-deriving arbitrary heading text. There is no
# general "extract any heading's title" contract — only LEVEL extraction plus a normalized TEXT used for
# the canonical equate — which is why a new closing-hash/marker/indent §4.3 edge cannot reopen a
# per-edge text-extraction bug class: every candidate and the canonical target pass through the SAME
# reduction, so they always agree.
#
# CONTRACT
#   stdout (heading): two lines — line 1 = the numeric LEVEL (1-6); line 2 = the normalized TEXT.
#   return: 0 when <raw_line> IS an ATX heading; 1 otherwise (stdout is then empty).
#   The caller captures stdout and splits on the first newline (level = first line, text = the rest).
#   TEXT is always a single line (an ATX heading is one source line), so a single split is exact.
#
# IMPORTANT: this reduction takes the RAW line, NOT a trimmed line. CommonMark distinguishes 0-3 leading
# spaces (still a heading) from 4+ leading spaces (an indented code block, NOT a heading); trimming
# first would erase that distinction. Every caller therefore passes the original line.
#
# COMMONMARK ATX RULES IMPLEMENTED (no Setext, no other markdown — heading parsing only):
#   - CRLF: a trailing `\r` is stripped first, so a `## Validation\r` CRLF line is reduced identically
#     to its LF form.
#   - Leading indent: 0-3 leading SPACES are allowed (still a heading); 4-or-more leading spaces — or
#     ANY leading TAB (a tab advances to the 4-col tab stop) — mean an indented code block, NOT a
#     heading → return 1.
#   - Marker: after the 0-3 spaces, 1-6 `#`s. A 7th `#` (`#######`) is not an ATX heading → return 1.
#   - After-marker whitespace: the `#` run MUST be followed by AT LEAST ONE space or tab, OR by
#     end-of-line (an empty heading). A `##Text` no-space marker is NOT a heading → return 1.
#   - Normalized TEXT (§4.3): leading indent + marker + after-marker whitespace removed; then trailing
#     whitespace removed; a closing run of `#`s is then stripped ONLY WHEN it is preceded by whitespace
#     (a true §4.3 closing sequence). A `#` run glued to the text with NO preceding whitespace is part
#     of the text and is KEPT. So `   ##  Validation  ##  \r` → level 2, text `Validation`; but
#     `## Validation#` → level 2, text `Validation#` (closing hash glued to the text, not a match).
# Pure text, no eval; set -u safe.
_hivemind_atx_heading() {
  local rest="$1"
  rest="${rest%$'\r'}"                        # CRLF: drop a single trailing carriage return

  # Leading indent: 0-3 spaces allowed; 4+ spaces, or any leading tab, is an indented code block.
  local indent=0
  while [ "${rest# }" != "$rest" ]; do        # peel one leading space at a time, counting
    indent=$(( indent + 1 ))
    rest="${rest# }"
    if [ "$indent" -ge 4 ]; then              # 4+ leading spaces → not a heading
      return 1
    fi
  done
  case "$rest" in
    '	'*) return 1 ;;                         # a leading TAB (after 0-3 spaces) → indented, not a heading
  esac

  # Marker: 1-6 `#`s, then end-of-line OR a space/tab. Count the run and reject 0 or 7+.
  local level=0
  while [ "${rest#\#}" != "$rest" ]; do
    level=$(( level + 1 ))
    rest="${rest#\#}"
    if [ "$level" -ge 7 ]; then               # 7+ `#`s → not an ATX heading
      return 1
    fi
  done
  if [ "$level" -eq 0 ]; then                  # no `#` marker at all
    return 1
  fi
  # The `#` run must be followed by whitespace OR end-of-line (a no-space `##Text` is not a heading).
  case "$rest" in
    '') ;;                                      # empty heading (`##` alone) — text is empty
    ' '*|'	'*) ;;                              # followed by a space or a tab — a real heading
    *) return 1 ;;                              # `#` run glued to text (`##Text`) — not a heading
  esac

  rest="${rest#"${rest%%[![:space:]]*}"}"     # drop ALL after-marker leading whitespace (spaces+tabs)
  # §4.3 closing sequence (plain bash, no extglob): drop trailing whitespace, then strip a contiguous
  # run of closing `#`s ONLY WHEN that run is preceded by whitespace. A `#` run glued to the text with
  # no preceding whitespace is NOT a closing sequence — it is part of the text and is kept. So
  # `Validation ##  ` reduces to `Validation`, but `Validation#` stays `Validation#`.
  rest="${rest%"${rest##*[![:space:]]}"}"     # drop trailing whitespace
  local stripped="$rest"
  while [ "${stripped%'#'}" != "$stripped" ]; do  # peel a contiguous run of trailing `#` into a candidate
    stripped="${stripped%'#'}"
  done
  # Strip the closing-`#` run ONLY when it was preceded by whitespace (true §4.3 closing sequence).
  # `stripped` differs from `rest` iff there was a `#` run; the run is closing iff what precedes it is
  # empty or ends in whitespace.
  if [ "$stripped" != "$rest" ]; then
    case "$stripped" in
      '' | *[[:space:]]) rest="${stripped%"${stripped##*[![:space:]]}"}" ;;  # closing seq → drop run + exposed ws
      *) ;;                                    # `#`s glued to text (no preceding ws) → keep as text
    esac
  fi

  printf '%s\n%s' "$level" "$rest"
  return 0
}

# _hivemind_heading_level <raw_line>
# Print the ATX heading LEVEL (1-6) when <raw_line> is a CommonMark ATX heading, or `0` otherwise.
# Routes through the consolidated `_hivemind_atx_heading` parser, so it inherits leading-indent (0-3
# spaces allowed, 4+ / leading-tab rejected), tab-after-marker, no-space-marker, and CRLF handling.
# Used to bound the `## Validation` section by heading LEVEL so a deeper child (`###`+) does NOT
# close the section. Takes the RAW line (the indent distinction is lost by trimming).
_hivemind_heading_level() {
  local parsed
  if ! parsed="$(_hivemind_atx_heading "$1")"; then
    printf '0'
    return 0
  fi
  printf '%s' "${parsed%%$'\n'*}"             # the LEVEL is the first line of the parser's output
}

# _hivemind_is_section_heading <raw_line>
# Return 0 when <raw_line> is a SIBLING-OR-PARENT heading that bounds the `## Validation` section —
# an ATX heading of LEVEL <= 2 (`#` or `##`). A deeper child heading (`###`+, level >= 3) returns 1:
# it is PART OF the section, so a nested `### Subsection` does NOT close the `##` section. The section
# runs from its `## Validation` heading to the next level-<=2 heading or EOF. Inherits all ATX rules
# (indent/tab/CRLF) via `_hivemind_heading_level` → `_hivemind_atx_heading`. Takes the RAW line.
_hivemind_is_section_heading() {
  local level
  level="$(_hivemind_heading_level "$1")"
  if [ "$level" -ge 1 ] && [ "$level" -le 2 ]; then
    return 0
  fi
  return 1
}

# _hivemind_is_validation_heading <raw_line>
# Return 0 when <raw_line> reduces to the skill's OWN canonical `## Validation` heading. This is a
# CANONICAL-ANCHOR equate, not an arbitrary title extraction: <raw_line> is reduced through the
# consolidated `_hivemind_atx_heading` reduction and its (LEVEL, TEXT) canonical form is compared to
# the canonical form of the one heading the skill emits — LEVEL == 2 AND normalized TEXT ==
# `Validation`. Because the candidate and the canonical target pass through the SAME reduction that
# `_hivemind_is_section_heading` uses for the section bound, the exact-name match and the section-bound
# can never disagree on what counts as a heading, and both inherit the full CommonMark ATX rule set:
#   - leading indent 0-3 spaces allowed; 4+ spaces or a leading tab → not a heading (so an indented
#     `    ## Validation` is correctly NOT recognized);
#   - the `##` marker may be followed by ANY run of spaces/tabs, so `##   Validation` and
#     `##\tValidation` reduce identically;
#   - a §4.3 closing `#` run (`## Validation ##  `) and a trailing `\r` (CRLF `## Validation\r`) are
#     handled, but a closing `#` run GLUED to the text with no preceding whitespace (`## Validation#`,
#     `## Validation##`) is part of the TEXT — its canonical form is `Validation#`/`Validation##`, NOT
#     `Validation`, so it does NOT match and the ABSENT path creates the real `## Validation` section;
#   - a no-space `##Validation` and a level-1/level-3+ marker are rejected.
# A SIBLING whose text merely STARTS WITH `Validation` (`## Validation Details`, `## ValidationX`)
# reduces to a different canonical form, so the ABSENT path creates the real `## Validation` section.
# Takes the RAW line. Pure text, no eval.
_hivemind_is_validation_heading() {
  local parsed level text
  if ! parsed="$(_hivemind_atx_heading "$1")"; then
    return 1                                   # not an ATX heading at all
  fi
  level="${parsed%%$'\n'*}"                    # first line = level
  text="${parsed#*$'\n'}"                      # everything after the first newline = normalized text
  [ "$level" = "2" ] && [ "$text" = "Validation" ]
}

# hivemind_guard_validation_section <claude_md_file> <section_body>
# SECTION-aware guard for the repo-root CLAUDE.md `## Validation` section (SKILL.md step 14c/d/e),
# keyed on a 3-state VALUE-STATE NORMALIZATION of the section rather than bare heading presence:
#
#   ABSENT               — no `## Validation` heading at all. The full assembled section
#                          (<section_body>: heading + fenced block) is appended and the result
#                          reports `added`.
#   PRESENT-WITH-COMMAND — a `## Validation` heading WITH a real command body (a fenced ```` ``` ````
#                          block already present in its range). No-op: reports `already documented`,
#                          file left byte-untouched (SKILL.md step 14c: "leave the existing prose
#                          untouched").
#   PRESENT-NO-COMMAND   — a `## Validation` heading present, NO fenced command block in its range
#                          (the range running from the heading to the next sibling/parent
#                          `#`-heading or EOF). Prose-only, blank-only, comment-only, or any mix all
#                          fall here. EVERY existing line of the section is KEPT VERBATIM and the
#                          fenced command block(s) — the body of <section_body> BELOW its heading
#                          line, NOT a second heading — is INSERTED at the END of the section's
#                          existing content (immediately before the next sibling/parent heading or
#                          EOF). The result reports `added`.
#
# This replaces the prior HEADING-ONLY predicate ("a `## Validation` heading exists ⇒
# already documented"), which mis-classified a heading-only stub as handled and silently dropped
# the detected command. The predicate now keys on BODY-presence (a fenced command block).
#
# file-guard NEVER DROPS EXISTING PROSE. A PRESENT-NO-COMMAND section is APPENDED-UNDER (the fenced
# block is inserted after the section's existing lines), never REPLACED — so any user prose under
# `## Validation` is preserved byte-for-byte. There is NO branch that substitutes <section_body>
# for a range containing existing lines; the only place content is written is an append. A
# blank/comment-only stub goes through the SAME append-preserving path (there is simply no prose to
# preserve); its trailing blank/comment lines are kept, which is harmless and lossless. The result
# is always exactly ONE `## Validation` heading carrying the command body.
#
# ARGUMENTS
#   <claude_md_file>  absolute path to repo-root CLAUDE.md. Created if absent.
#   <section_body>    the full `## Validation` section text (heading + fenced command block(s)),
#                     assembled by the caller. Written verbatim; never interpreted. MUST begin with
#                     the `## Validation` heading line: ABSENT writes it whole, and PRESENT-NO-
#                     COMMAND inserts only the lines BELOW that first heading line so the result
#                     keeps a single heading.
hivemind_guard_validation_section() {
  local file="$1" section_body="$2"

  # Absent file → write the whole section (SKILL.md step 14e).
  if [ ! -e "$file" ]; then
    printf '%s\n' "$section_body" > "$file"
    printf '%s\n' "added"
    return 0
  fi

  # Read the file into a line array so the section's value-state can be classified and, in the
  # PRESENT-NO-COMMAND case, the command body inserted at the end of the existing section while
  # every existing line is kept verbatim. Read is pure text (no interpretation).
  local lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done < "$file"

  # Locate the `## Validation` heading and its section range [heading_idx, end_idx). end_idx is
  # the index of the next SIBLING-OR-PARENT heading (LEVEL <= 2) after the heading, or the array
  # length (EOF). A nested `### Subsection` (level >= 3) does NOT bound the section — it is part of
  # it. Within that full range, detect a command body: a fenced ``` block line.
  local n="${#lines[@]}"
  local heading_idx=-1 end_idx="$n" has_body="no"
  local i trimmed
  # The heading matchers take the RAW line: `_hivemind_atx_heading` must see the leading indent to
  # apply the 0-3-spaces-allowed / 4+-spaces-rejected CommonMark rule, which trimming would erase.
  # The fenced-block detection below still uses the TRIMMED line (a fence may be indented as content).
  for (( i = 0; i < n; i++ )); do
    if _hivemind_is_validation_heading "${lines[$i]}"; then
      heading_idx="$i"
      break
    fi
  done

  if [ "$heading_idx" -ge 0 ]; then
    # Scan from the line after the heading to the next level-<=2 heading or EOF. A nested `### `
    # child does not end the scan, so a fenced block under it still sets has_body.
    for (( i = heading_idx + 1; i < n; i++ )); do
      if _hivemind_is_section_heading "${lines[$i]}"; then
        end_idx="$i"
        break
      fi
      # A fenced code block under the heading is the canonical command body. Blank lines and
      # comment lines (`#`-leading but not a heading) do NOT count.
      trimmed="$(_hivemind_trim "${lines[$i]}")"
      case "$trimmed" in
        '```'*) has_body="yes" ;;
      esac
    done
  fi

  # PRESENT-WITH-COMMAND: heading with a real command body → no-op, byte-unchanged.
  if [ "$heading_idx" -ge 0 ] && [ "$has_body" = "yes" ]; then
    printf '%s\n' "already documented"
    return 0
  fi

  # PRESENT-NO-COMMAND: a `## Validation` heading exists but its range has no fenced command block
  # (prose-only, blank-only, comment-only, or any mix). KEEP every existing line verbatim and
  # INSERT the command body — the lines of <section_body> BELOW its own `## Validation` heading
  # line, never a second heading — at the END of the section (immediately before end_idx). This is
  # an APPEND-UNDER, never a replace: no existing line is dropped, so any user prose is preserved.
  if [ "$heading_idx" -ge 0 ]; then
    # Split <section_body> into lines; drop its leading `## Validation` heading line so only the
    # command-body lines (the fenced block(s)) are inserted under the existing heading. The caller
    # always assembles section_body with the heading as its first line (test-detect.sh
    # `_hivemind_validation_section_body`), so the heading is `body_lines[0]`.
    local body_lines=()
    local body_line
    while IFS= read -r body_line || [ -n "$body_line" ]; do
      body_lines+=("$body_line")
    done <<< "$section_body"

    local out=()
    # Existing content up to and including the last line of the section (everything before end_idx).
    for (( i = 0; i < end_idx; i++ )); do
      out+=("${lines[$i]}")
    done
    # Insert only the command-body lines (everything in section_body AFTER its heading line). The
    # fenced block already begins on its own line (the caller emits a blank line before each ```bash
    # fence), so it never merges with a preceding non-blank prose line.
    local b
    for (( b = 1; b < "${#body_lines[@]}"; b++ )); do
      out+=("${body_lines[$b]}")
    done
    # Sibling/parent sections after `## Validation` are carried over byte-for-byte.
    for (( i = end_idx; i < n; i++ )); do
      out+=("${lines[$i]}")
    done
    # Rewrite the file from the rebuilt line array (newline-terminated lines).
    : > "$file"
    for (( i = 0; i < "${#out[@]}"; i++ )); do
      printf '%s\n' "${out[$i]}" >> "$file"
    done
    printf '%s\n' "added"
    return 0
  fi

  # ABSENT with NO heading at all: append the whole section after a trailing-newline guard so the
  # heading is never glued onto the file's last unterminated line (kernel newline-guard reuse).
  if [ -s "$file" ] && ! _hivemind_file_has_trailing_newline "$file"; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$section_body" >> "$file"
  printf '%s\n' "added"
}
