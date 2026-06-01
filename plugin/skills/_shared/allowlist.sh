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
