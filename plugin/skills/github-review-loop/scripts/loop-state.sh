#!/usr/bin/env bash
#
# loop-state.sh
#
# 1. PURPOSE
# ----------
# Single source of truth for the github-review-loop's OWN deterministic loop
# bookkeeping. Before this script, the cycle-increment / cycle-ceiling /
# terminal-vs-cycle / same-finding-repeat / guard-token-mapping decisions lived
# only as prose scattered through SKILL.md sections 4/5/6 + the Termination guard
# set. This script encodes ONLY those deterministic mechanics so the skill body
# can describe intent without re-deriving the arithmetic in prose.
#
# This is NOT a generic state machine. It is watch-loop-scoped bookkeeping for the
# github-review-loop alone. It does NOT read, classify, or interpret feedback
# content (that is the reviewer's job) and it does NOT encode the cross-consumer
# precedence ladder (that is exit-precedence.sh — see subcommand `cycle-decision`'s
# multi-token delegation below).
#
# 2. INPUT CONTRACT
# -----------------
# Subcommand dispatch on $1. Each subcommand takes a fixed positional arg list.
# Every argv is consumed as exactly ONE field — no word-splitting, no glob
# expansion (guards against the malformed-argv class fixed in exit-precedence.sh).
#
#   loop-state.sh cycle-decision <current_count> <max_cycles> <findings_resolved> <reviewer_exit_reason>
#     current_count        non-negative integer — remediation cycles completed SO FAR.
#                          PASSED IN by the caller; never persisted by this script.
#                          GitHub is the only ledger (no persisted loop ledger).
#     max_cycles           positive integer — max_remediation_cycles ceiling.
#     findings_resolved    non-negative integer — findings the reviewer resolved THIS return.
#     reviewer_exit_reason one reviewer fix-mode exit_reason token (see token set below),
#                          or the literal `same-finding-repeat` for the oscillation guard.
#
#   loop-state.sh token-map <signal>
#     signal one deterministic loop-input signal the loop itself observes:
#       STATE=MERGED   -> pr-merged
#       STATE=CLOSED   -> pr-closed
#       WATCH_TIMEOUT  -> max-cycles-reached
#       POLL_ERROR     -> blocked
#
#   loop-state.sh resolve-precedence <token> [token ...]
#     When the caller holds MORE THAN ONE fired exit_reason at once (e.g. a reviewer
#     terminal AND a poll guard token from token-map in the same wake), forward them
#     to the sibling exit-precedence.sh, which is the single source of truth for the
#     14-rank ladder. This script does NOT re-encode that ladder (reuse / P9); it
#     only delegates. The tokens pass through UNMODIFIED (one argv = one token).
#
# Any unknown subcommand, wrong arg count, non-integer numeric field, or unknown
# token / signal → stderr diagnostic + exit 1 (REJECT LOUDLY). Silent fallthrough
# would mask a caller bug where a new signal/token was introduced without updating
# this script.
#
# 3. OUTPUT
# ---------
# cycle-decision → two lines on stdout, exit 0:
#     NEXT_COUNT=<int>      the cycle count AFTER this return (caller carries it
#                           forward; the script does not persist it).
#     EXIT_REASON=<token>   the terminal exit_reason if the loop must stop now, or
#                           the literal `none` if the loop should keep watching.
# token-map → one line on stdout, exit 0:
#     EXIT_REASON=<token>
#
# 4. ENCODED DECISIONS (SKILL.md sections 4/5/6 + Termination guard set)
# ---------------------------------------------------------------------
#   (a) cycle-increment: increment IFF findings_resolved >= 1 (section 6).
#   (b) cycle-ceiling: when the resulting count reaches max_cycles, emit
#       `max-cycles-reached` (section 6).
#   (c) terminal-vs-cycle: `root-cluster-suspected` and `merge-advised` are
#       TERMINALS, never cycle increments — do NOT increment on them (section 5).
#       The other reviewer escalation terminals (planner-escalation, blocked,
#       injection-suspect, high-severity-rejection, user-input-required) likewise
#       hard-stop without incrementing.
#   (d) same-finding-repeat: oscillation guard maps to `max-cycles-reached`
#       (Termination guard set), no increment.
#   (e) `clean`: the keep-watching case — increment per (a)/(b), emit `none`
#       unless the ceiling is hit.
#
# 5. PRECEDENCE DELEGATION
# ------------------------
# cycle-decision and token-map each yield at most one candidate exit_reason. When
# more than one fired exit_reason is held simultaneously (e.g. a reviewer terminal
# AND a poll guard token in the same wake), the `resolve-precedence` subcommand
# DELEGATES ordering to the sibling exit-precedence.sh — this script does NOT
# re-encode the 14-rank ladder (reuse constraint / P9). The sibling is resolved
# relative to ${SCRIPT_DIR}:
#   ${SCRIPT_DIR}/exit-precedence.sh
#
# 6. INVARIANTS
# -------------
# INVARIANT: pure function — no /tmp, no stop-file, no persisted state, no network,
# no gh, no git, no Monitor; side effects are stdout/stderr + exit code only.
# INVARIANT: the cycle counter is an INPUT, never persisted here — GitHub is the
# only ledger; there is NO persisted loop ledger.
# INVARIANT: unknown subcommand / token / signal / malformed numeric → exit 1 +
# stderr; never silently ignored.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die() {
  printf 'loop-state: %s\n' "$1" >&2
  exit 1
}

# INVARIANT: a field must be a non-negative integer (no sign, no whitespace, no
# glob). Reject anything else loudly rather than letting bash arithmetic coerce it.
require_uint() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) die "$name must be a non-negative integer: '$value'" ;;
  esac
}

# Reviewer fix-mode exit_reason tokens that HARD-STOP without a cycle increment.
# root-cluster-suspected and merge-advised are propagated reviewer terminals;
# the rest are reviewer escalations. (SKILL.md section 5 + Termination guard set.)
is_terminal_no_increment() {
  case "$1" in
    planner-escalation|blocked|injection-suspect|high-severity-rejection|\
user-input-required|root-cluster-suspected|merge-advised) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_cycle_decision() {
  [ "$#" -eq 4 ] || die "cycle-decision expects 4 args: <current_count> <max_cycles> <findings_resolved> <reviewer_exit_reason>"
  local current_count="$1" max_cycles="$2" findings_resolved="$3" reviewer_exit_reason="$4"

  require_uint "current_count" "$current_count"
  require_uint "max_cycles" "$max_cycles"
  require_uint "findings_resolved" "$findings_resolved"
  [ "$max_cycles" -ge 1 ] || die "max_cycles must be >= 1: '$max_cycles'"

  # same-finding-repeat oscillation guard → max-cycles-reached, no increment.
  if [ "$reviewer_exit_reason" = "same-finding-repeat" ]; then
    printf 'NEXT_COUNT=%s\n' "$current_count"
    printf 'EXIT_REASON=max-cycles-reached\n'
    return 0
  fi

  # Terminal reviewer returns hard-stop WITHOUT incrementing the cycle count.
  if is_terminal_no_increment "$reviewer_exit_reason"; then
    printf 'NEXT_COUNT=%s\n' "$current_count"
    printf 'EXIT_REASON=%s\n' "$reviewer_exit_reason"
    return 0
  fi

  # Only `clean` remains as a valid keep-watching return. Any other token is a
  # caller bug (unknown reviewer exit_reason reached the loop bookkeeper).
  [ "$reviewer_exit_reason" = "clean" ] || die "unknown reviewer_exit_reason: '$reviewer_exit_reason'"

  # cycle-increment: increment IFF the reviewer resolved >= 1 finding.
  local next_count="$current_count"
  if [ "$findings_resolved" -ge 1 ]; then
    next_count=$((current_count + 1))
  fi

  # cycle-ceiling: reaching max_cycles is terminal max-cycles-reached.
  if [ "$next_count" -ge "$max_cycles" ]; then
    printf 'NEXT_COUNT=%s\n' "$next_count"
    printf 'EXIT_REASON=max-cycles-reached\n'
    return 0
  fi

  printf 'NEXT_COUNT=%s\n' "$next_count"
  printf 'EXIT_REASON=none\n'
}

cmd_token_map() {
  [ "$#" -eq 1 ] || die "token-map expects 1 arg: <signal>"
  local signal="$1"
  case "$signal" in
    STATE=MERGED)  printf 'EXIT_REASON=pr-merged\n' ;;
    STATE=CLOSED)  printf 'EXIT_REASON=pr-closed\n' ;;
    WATCH_TIMEOUT) printf 'EXIT_REASON=max-cycles-reached\n' ;;
    POLL_ERROR)    printf 'EXIT_REASON=blocked\n' ;;
    *) die "unknown loop signal: '$signal'" ;;
  esac
}

cmd_resolve_precedence() {
  [ "$#" -ge 1 ] || die "resolve-precedence expects >= 1 token arg"
  local sibling="$SCRIPT_DIR/exit-precedence.sh"
  [ -f "$sibling" ] || die "sibling precedence kernel missing: $sibling"
  # Forward each token UNMODIFIED (one argv = one token). exit-precedence.sh owns
  # validation, the 14-rank ladder, and loud rejection of unknown tokens.
  bash "$sibling" "$@"
}

[ "$#" -ge 1 ] || die "usage: loop-state.sh <cycle-decision|token-map|resolve-precedence> ..."
subcommand="$1"
shift

case "$subcommand" in
  cycle-decision)     cmd_cycle_decision "$@" ;;
  token-map)          cmd_token_map "$@" ;;
  resolve-precedence) cmd_resolve_precedence "$@" ;;
  *) die "unknown subcommand: '$subcommand' (expected cycle-decision | token-map | resolve-precedence)" ;;
esac

exit 0
