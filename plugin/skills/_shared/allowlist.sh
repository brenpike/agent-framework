# shellcheck shell=bash
#
# allowlist.sh — shared value-class validators for manifest/ledger-derived values.
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/allowlist.sh"`).
# It defines functions only; it runs no top-level statements, changes no caller state
# beyond defining the functions, and never exits. `bash -n` validates it as a sourced
# fragment.
#
# SINGLE RESPONSIBILITY: gate ONE manifest/ledger-derived value against the value CLASS
# its field belongs to. This file implements the INPUT half of a FLOOR-AT-INPUT /
# ENCODE-AT-OUTPUT model: every value is gated against the shared security floor at the
# moment it enters the engine, and any context-specific safety (Markdown-cell escaping,
# C0-control stripping) is the responsibility of OUTPUT-ENCODING at the render boundary —
# NOT of these validators. The brood-status read side gates every value it emits through
# the class matching that field, so a value never reaches a path derivation, a shell
# context, or the TAB-delimited output grammar un-vetted.
#
# THE SHARED SECURITY FLOOR (the boundary — NEVER relaxed by any class):
#   1. command-substitution bytes — `$` and backtick `` ` ``. These are EXPANDED by the
#      shell even inside double quotes when a value reaches a re-parsed command word, so
#      they are forbidden in EVERY class regardless of how "display-only" the field is.
#   2. `..` traversal — closes path traversal in any class.
#   3. leading `-` — closes argument injection (a value reaching a command word as `-x`).
#   4. framing bytes — TAB, newline (LF), carriage-return (CR). The engine emits values
#      into a TAB-delimited, newline-terminated per-strain output grammar; any of these
#      would let a crafted value forge or split the framing the navigator parses.
#   5. empty — never a valid value in any class.
# Every validator below applies this floor FIRST.
#
# THE THREE CLASSES, with the fields that map to each:
#   hivemind_assert_identifier   FLOOR + strict charset ^[A-Za-z0-9._/-]+$ (strictest).
#       FIELDS: branch, tmux_session, manifest status, ledger id-segment. Values used as
#       shell-probe tokens / command arguments — no space, no shell-metachar, ever. This
#       class is deliberately strict and is NOT loosened by the floor-at-input model.
#   hivemind_assert_path         FLOOR-ONLY (no charset enumeration).
#       FIELDS: worktree_path, suggested_ledger. Paths are used ONLY as quoted data
#       (`cd "$dir"`, jq `--arg`, `pwd -P` canonicalization) and are never re-parsed, so the
#       floor IS the full security boundary. Arbitrary filesystem-path bytes that pass the
#       floor — including spaces, `+ @ , %`, etc. — are ACCEPTED as quoted data. A per-byte
#       charset enumeration here was the source of a recurring false-reject treadmill
#       (#177 whack-a-mole doctrine); do NOT re-add per-byte charset rules to this class.
#   hivemind_assert_presentation FLOOR + positive display allowlist.
#       FIELDS: strain `name` (display-only — emitted into the output field and used only as
#       the quoted jq/awk `--arg`/`-v` lookup key, NEVER a shell-probe token). Markdown-cell
#       safety (escaping `|`, stripping C0 controls) has MOVED to output-encoding at the
#       render boundary; this class no longer carries that responsibility and keeps only a
#       positive allowlist over the floor for its remaining display-label role.

# ── Shared security floor ────────────────────────────────────────────────────────
# hivemind__assert_floor <value>
# Returns 0 iff <value> is non-empty AND does not start with '-' AND contains neither '..'
# nor any command-substitution byte ($ or backtick) nor any framing byte (TAB/LF/CR).
# INTERNAL: the three public validators call this first; not intended as a caller entry
# point (double-underscore marks it private). Pure: no side effects, no exit, echoes nothing.
hivemind__assert_floor() {
  local value="$1"
  # Empty is never valid in any class.
  if [ -z "$value" ]; then
    return 1
  fi
  case "$value" in
    # Leading dash: argument-injection guard.
    -*) return 1 ;;
    # '..': path-traversal guard.
    *..*) return 1 ;;
  esac
  # Command-substitution bytes: `$` and backtick. Forbidden in EVERY class — these expand
  # even inside double quotes when a value reaches a re-parsed command word.
  case "$value" in
    *'$'*|*'`'*) return 1 ;;
  esac
  # Framing bytes: TAB (output delimiter), newline, CR. Matched against ANSI-C bytes so the
  # case-glob compares real control bytes, not two-char escapes.
  local tab=$'\t' nl=$'\n' cr=$'\r'
  case "$value" in
    *"$tab"*|*"$nl"*|*"$cr"*) return 1 ;;
  esac
  return 0
}

# ── Class 1: identifier (strictest) ──────────────────────────────────────────────
# hivemind_assert_identifier <value>
# Returns 0 iff <value> passes the shared floor AND matches ^[A-Za-z0-9._/-]+$. This is the
# strictest class: no space, no shell-metacharacter, ever. FIELDS: branch, tmux_session,
# manifest status, ledger id-segment — all used as shell-probe tokens / command arguments.
# Emits nothing; never echoes raw attacker bytes (the caller decides how to render a reject).
# Pure: no side effects, no exit.
hivemind_assert_identifier() {
  local value="$1"
  hivemind__assert_floor "$value" || return 1
  case "$value" in
    # Any byte outside the strict identifier charset rejects the whole token.
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

# ── Class 2: path (FLOOR-ONLY) ────────────────────────────────────────────────────
# hivemind_assert_path <value>
# Returns 0 iff <value> passes the shared security floor. THERE IS NO CHARSET ENUMERATION:
# any byte that survives the floor is accepted as quoted path data, including spaces and
# inert filesystem bytes such as `+ @ , %`.
# FIELDS: worktree_path, suggested_ledger. Paths are used ONLY as quoted data — `cd "$dir"`,
# jq `--arg`, `pwd -P` canonicalization — and are NEVER re-parsed into a command word, so the
# floor (which already forbids `$`/backtick command substitution, `..` traversal, leading
# `-`, TAB/LF/CR framing, and empty) IS the complete security boundary for this class.
# A per-byte charset enumeration here was the source of a recurring false-reject treadmill
# (#177 whack-a-mole doctrine): every legitimate path byte the enumeration omitted produced a
# spurious MALFORMED that suppressed ledger projection. Do NOT re-add per-byte charset rules.
# Pure: no side effects, no exit.
hivemind_assert_path() {
  local value="$1"
  hivemind__assert_floor "$value" || return 1
  return 0
}

# ── Class 3: presentation (broadest) — POSITIVE ALLOWLIST closed by construction ──
# hivemind_assert_presentation <value>
# Returns 0 iff <value> passes the shared floor AND every byte is in the explicit permitted
# display set below. This is a POSITIVE ALLOWLIST: an unlisted byte is rejected by default,
# closing the reject-enumeration treadmill (control bytes, non-ASCII bidi/homoglyph, and
# markdown-structural bytes are all rejected without naming them one at a time).
#
# PERMITTED SET — bounded, justified for issue-title/slug-derived strain display labels:
#   A-Z a-z         letters
#   0-9             digits
#   (space)         "api worker", "web frontend" — real multi-word display names
#   . _ - /         slug separators and path components
#   ( )             "feature (2)", "auth (legacy)"
#   :               "api: v2"
#   ,               "search, index"
#   +               "auth+session"
#   @               "@org/pkg"-style names
#   # = ~ !         issue refs and label-style display (matches the path-class inert set)
#
# REJECTED BY CONSTRUCTION (not in the allowlist — no per-byte enumeration needed):
#   ALL C0/C1 control bytes incl. NUL, BEL, ESC \033, VT \v, FF \f, DEL \177 — multibyte
#     values ≥0x80 (Unicode bidi-override U+202E, homoglyphs, RTL marks) — because the
#     bracket uses explicit ASCII ranges A-Za-z0-9 only, not locale-sensitive [:print:] or
#     [:alnum:], so no locale widening can admit non-ASCII.
#   ` ; & < > [ ] { } \ ^ " ' * ? | — shell-structural / glob bytes not needed for display.
#   $ and backtick — already rejected by the shared floor (command-substitution guard).
#
# MARKDOWN SAFETY LIVES AT THE RENDER BOUNDARY, NOT HERE. Under the floor-at-input /
# encode-at-output model, escaping the Markdown table-cell delimiter `|` and stripping any
# residual control bytes is the job of OUTPUT-ENCODING when the navigator renders a name into
# a Markdown table row. This validator no longer owns an ad-hoc `|` carve-out; with a positive
# allowlist `|` simply isn't in the permitted set, but the authoritative Markdown-cell defense
# is the render-boundary encoder.
#
# FIELD: strain `name` — display-only, emitted into the output field and used only as the
# quoted jq/awk `--arg`/`-v` lookup key, NEVER a shell-probe token or command word.
# Pure: no side effects, no exit.
hivemind_assert_presentation() {
  local value="$1"
  hivemind__assert_floor "$value" || return 1
  # INVARIANT: the bracket below is a POSITIVE allowlist — any byte NOT explicitly listed
  # rejects the entire value. The bracket uses explicit ASCII ranges (A-Za-z0-9) and literal
  # punctuation, NOT locale-sensitive classes like [:print:] or [:alnum:], so the LOCALE
  # cannot widen the set to admit non-ASCII bytes. `-` is placed last in the bracket so it is
  # a literal character, not a range operator.
  case "$value" in
    *[!A-Za-z0-9._/=~#!\ \(\):,+@-]*) return 1 ;;
  esac
  return 0
}
