# shellcheck shell=bash
#
# allowlist.sh — shared safe-token allowlist gate for manifest/ledger-derived values.
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/allowlist.sh"`).
# It defines one function; it runs no top-level statements, changes no caller state
# beyond defining the function, and never exits. `bash -n` validates it as a sourced
# fragment.
#
# SINGLE RESPONSIBILITY: validate ONE manifest-derived value against the same safe-token
# allowlist spawn-brood.sh inlines for branch/base refs (charset ^[A-Za-z0-9._/-]+$,
# non-empty, no leading '-', no '..'). The brood-status read side derives this rule into
# one named function so the read and write sides share an identical token contract.
#
# WHY ALLOWLIST BEFORE QUOTING (the security boundary): command substitution `$(...)`
# and backticks are EXPANDED by the shell even inside double quotes during the parsing
# of a command word. A value that ever reaches a context where the shell re-parses it
# (eval, an unquoted expansion, a generated command word) would execute its embedded
# `$(...)`/backtick — quoting is NOT the boundary. The brood-status engine therefore
# gates every manifest-derived value through this allowlist BEFORE the value is used in
# any path derivation or shell context; only allowlist-clean tokens proceed. A '..'
# component is rejected to close path traversal; a leading '-' is rejected to close
# argument injection into any downstream command the token might reach.

# hivemind_assert_safe_token <value>
# Returns 0 iff <value> is non-empty AND matches ^[A-Za-z0-9._/-]+$ AND does not start
# with '-' AND does not contain '..'. Returns non-zero otherwise. Emits nothing on
# success and nothing on failure (the caller decides how to render a rejected token —
# this function never echoes raw attacker bytes). Pure: no side effects, no exit.
hivemind_assert_safe_token() {
  local value="$1"
  # Empty is never a safe token.
  if [ -z "$value" ]; then
    return 1
  fi
  case "$value" in
    # Leading dash: argument-injection guard (a value reaching a command word as `-x`).
    -*) return 1 ;;
    # '..': path-traversal guard.
    *..*) return 1 ;;
  esac
  case "$value" in
    # Any byte outside the safe charset rejects the whole token.
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

# hivemind_assert_safe_path <value>
# A PATH-SPECIFIC confinement rule, distinct from hivemind_assert_safe_token. A filesystem
# path (e.g. a brood worktree_path) is legitimately allowed to contain SPACES — a repository
# checkout at "/home/me/hivemind review/wt" is a valid root that spawn-brood.sh itself supports
# by consistently quoting. The strict identifier allowlist (token charset [A-Za-z0-9._/-])
# rejects such paths, so a space-bearing worktree falsely renders MALFORMED and suppresses all
# ledger projection (Codex #172 P1). This relaxed rule permits the printable path characters a
# real checkout root may carry (notably space) while STILL closing the shell-injection and
# path-traversal classes the token allowlist closes:
#
#   - Returns 0 iff <value> is non-empty AND does not start with '-' (argument-injection guard)
#     AND does not contain '..' (path-traversal guard) AND contains NONE of the dangerous bytes
#     below.
#   - REJECTED bytes (the boundary): command-substitution / shell-metacharacter bytes
#     `$` ` `` ` `;` `&` `|` `<` `>` `(` `)` `{` `}` `*` `?` `[` `]` `\` `!` `#` `~` `=`, single
#     and double quotes, AND the whitespace bytes TAB / newline / carriage-return. TAB and
#     newline are rejected because the engine emits this value into a TAB-delimited,
#     newline-terminated output grammar; allowing either would let a crafted path break the
#     per-strain line framing the navigator parses. A literal SPACE is the ONLY whitespace
#     permitted.
#
# WHY THIS IS STILL SOUND under the allowlist-before-quoting boundary (allowlist.sh header):
# the only contexts a path validated here reaches are (1) cd/pwd -P canonicalization inside
# containment.sh (never shell-re-parsed — `cd "$dir"` is quoted and a space is just a path
# byte), (2) quoted textual prefix construction + `case` matching in the engine (no
# re-evaluation), and (3) the TAB-delimited output field (space-safe, tab/newline rejected
# here). It is NEVER used as an identifier, a shell probe token, or a command word — those keep
# the strict hivemind_assert_safe_token. By rejecting `$` and backtick this rule still forbids
# command substitution, so a path can never smuggle `$(...)`/`` `...` `` even though it may
# carry spaces. Pure: no side effects, no exit, echoes nothing.
hivemind_assert_safe_path() {
  local value="$1"
  # Empty is never a safe path.
  if [ -z "$value" ]; then
    return 1
  fi
  case "$value" in
    # Leading dash: argument-injection guard.
    -*) return 1 ;;
    # '..': path-traversal guard.
    *..*) return 1 ;;
  esac
  # Reject framing-breaking whitespace: TAB (delimiter), newline, and CR. A literal SPACE is
  # intentionally permitted (it is the ONLY whitespace allowed). These are matched against
  # ANSI-C bytes so the case-glob compares real control bytes, not the two-char escapes.
  local tab=$'\t' nl=$'\n' cr=$'\r'
  case "$value" in
    *"$tab"*|*"$nl"*|*"$cr"*) return 1 ;;
  esac
  # Reject every dangerous shell-metacharacter / command-substitution byte. SPACE is NOT in this
  # set. The bracket expression lists each forbidden byte literally; `]` is placed first (the
  # only position where `]` is a literal member of a bracket expression) and `\` is included to
  # forbid backslash escapes.
  case "$value" in
    *[]\$\`\;\&\|\<\>\(\)\{\}\*\?\[\\\!\#\~\=\'\"]*) return 1 ;;
  esac
  return 0
}
