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
# its field belongs to. Three classes share ONE security floor; each widens the floor by a
# disjoint, field-justified set of additional inert bytes. The brood-status read side gates
# every value it emits through the class matching that field, so a value never reaches a
# path derivation, a shell context, or the TAB-delimited output grammar un-vetted.
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
# Every validator below applies this floor FIRST, then its class-specific charset/byte set.
#
# THE THREE CLASSES (strictest → broadest), with the fields that map to each:
#   hivemind_assert_identifier   charset ^[A-Za-z0-9._/-]+$ (strictest).
#       FIELDS: branch, tmux_session, manifest status, ledger id-segment. Values used as
#       shell-probe tokens / command arguments — no space, no shell-metachar, ever.
#   hivemind_assert_path         identifier charset PLUS space and the inert filesystem
#       bytes `#` `=` `~` `!`.
#       FIELDS: worktree_path, suggested_ledger. A real checkout root may legitimately
#       contain spaces (`/home/me/hive review/wt`) and these inert bytes; the strict
#       identifier rule would falsely render such a path MALFORMED and suppress all ledger
#       projection. None of the widened bytes is shell-active in this class's only
#       downstream contexts (quoted `cd "$dir"` canonicalization, quoted prefix `case`
#       matching, the TAB-delimited output field).
#   hivemind_assert_presentation POSITIVE ALLOWLIST closed by construction (broadest).
#       FIELDS: strain `name` (display-only — emitted into the output field and used only as
#       the quoted jq/awk `--arg`/`-v` lookup key, NEVER a shell-probe token). All three
#       classes are now POSITIVE ALLOWLISTS over the shared floor — the floor is a
#       defense-in-depth denylist of universally-dangerous bytes, but each class is closed
#       by construction so an unlisted byte is rejected by default.

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

# ── Class 2: path ─────────────────────────────────────────────────────────────────
# hivemind_assert_path <value>
# Returns 0 iff <value> passes the shared floor AND every byte is in the identifier charset
# [A-Za-z0-9._/-] OR is one of the widened inert filesystem bytes: SPACE, `#`, `=`, `~`, `!`.
# FIELDS: worktree_path, suggested_ledger. A real checkout root may carry spaces and these
# bytes; the strict identifier rule would falsely reject it and suppress ledger projection.
# None of the widened bytes is shell-active in this class's only downstream contexts (quoted
# `cd "$dir"` canonicalization, quoted prefix `case` matching, the TAB-delimited output
# field): `#` is a comment introducer ONLY at an unquoted word start, `=` an assignment token
# ONLY as a bare word, `~` tilde-expands ONLY unquoted at a word start, `!` is history
# expansion (interactive-only). The floor still forbids `$`/backtick, so a path can never
# smuggle command substitution even though it may carry spaces. Pure: no side effects, no exit.
hivemind_assert_path() {
  local value="$1"
  hivemind__assert_floor "$value" || return 1
  # Reject any byte NOT in {identifier charset} ∪ {literal SPACE, #, =, ~, !}. The negated
  # bracket expression lists the full permitted set; any byte outside it rejects the whole
  # value. The whitespace widening is a LITERAL SPACE only — NOT `[:space:]`, which also admits
  # VT (\v) and FF (\f); the shared floor only rejects TAB/LF/CR, so a `[:space:]` widening
  # would let those C0 control bytes through and the engine would emit raw VT/FF into the
  # navigator stream (Codex #172 P1). A single literal space is the only whitespace a real
  # checkout root carries; admit exactly that.
  case "$value" in
    *[!A-Za-z0-9._/=~#!\ -]*) return 1 ;;
  esac
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
#   | — Markdown table-cell delimiter; the brood-status navigator renders names into a
#     Markdown table row; `|` would inject extra cells and visually falsify the dashboard.
#     With a positive allowlist the explicit carve-out is unnecessary — `|` simply isn't
#     in the set.
#   ` ; & < > [ ] { } \ ^ " ' * ? — shell-structural / glob bytes not needed for display.
#   $ and backtick — already rejected by the shared floor (command-substitution guard).
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
