#!/usr/bin/env bash
#
# exit-precedence.sh
#
# 1. PURPOSE
# ----------
# Single source of truth for the exit_reason PRECEDENCE LADDER shared by both
# the github-review-loop skill and the github-reviewer / local-reviewer agents.
# Before this script, the "outranks" / "does NOT override" / "pre-empted by" /
# "higher-priority returns have already won" ordering was prose-only, scattered
# across three consumer files that could drift independently. This script is the
# ONE place the ladder is encoded — callers reduce a set of fired tokens to the
# single highest-precedence winner here rather than re-implementing the ladder in
# each consumer.
#
# 2. INPUT CONTRACT
# -----------------
# The set of fired exit_reason tokens, supplied via:
#   (a) positional arguments:  exit-precedence.sh token1 token2 ...
#   (b) stdin (whitespace/newline-delimited):  echo "token1 token2" | exit-precedence.sh
#   (c) both at once — tokens from both sources are unioned.
# Empty input (no positional args AND stdin is empty or whitespace-only) → outputs
# "clean" (the documented precedence floor: nothing fired = clean). This is a
# RESOLVED decision; the caller need not special-case the empty set.
#
# 3. OUTPUT
# ---------
# The single highest-precedence winning token on stdout (one line, no trailing
# newline beyond what printf adds). Exit 0 on success.
#
# Unknown / garbage token → stderr diagnostic + exit 1 (REJECT LOUDLY).
# This is a RESOLVED decision: silent fallthrough would mask a caller bug where a
# new token was introduced without updating this ladder.
#
# 4. ENCODED PRECEDENCE LADDER (highest-wins-first)
# --------------------------------------------------
# The order below is the behavior-preserving union across:
#   - plugin/agents/github-reviewer.md  (step 7 + step 13 escalation priority prose)
#   - plugin/agents/local-reviewer.md   (steps 3 / 6 / 9 priority prose)
#   - plugin/skills/github-review-loop/SKILL.md  (Reviewer-return handling)
#
#   1  injection-suspect
#   2  high-severity-rejection
#   3  user-input-required
#   4  planner-escalation
#   5  break-fix-break          ← local-reviewer token
#   6  blocked                  ← github-reviewer surfaces mutation-decay as
#                                  blocked(blocker_reason=mutation-decay); both
#                                  occupy rank 5/6 (the same mandatory-stop tier).
#                                  Generic blocked (validation fail, destructive-fix
#                                  gate) sits here too — all hard-stops at this tier.
#   7  root-cluster-suspected
#   8  diminishing-returns       ← local-reviewer only; pre-empts merge-advised
#   9  merge-advised
#  10  max-iterations-reached    ← local-reviewer ceiling token
#  11  max-cycles-reached        ← github-review-loop WATCH_TIMEOUT token
#  12  clean                     ← floor: nothing fired
#
# ALIAS NOTE: local-reviewer emits `break-fix-break` for the Mutation Decay
# mandatory stop; github-reviewer surfaces the same condition as `blocked` with
# `blocker_reason: mutation-decay`. Both map to the SAME rank tier (5/6). This
# script treats each as a distinct valid token at adjacent ranks so that a caller
# holding both simultaneously yields `break-fix-break` (slightly higher), which is
# consistent with local-reviewer's own step-6 priority prose
# ("break-fix > root-cluster"). A caller holding only `blocked` still wins at
# rank 6, well above `root-cluster-suspected`.
#
# 5. INVARIANTS
# -------------
# INVARIANT: pure function — no /tmp writes, no network calls, no .hivemind writes,
# no side effects beyond stdout/stderr and exit code.
# INVARIANT: unknown token → exit 1 + stderr; never silently ignored.
# INVARIANT: empty input → "clean" on stdout + exit 0.

set -euo pipefail

# ---------------------------------------------------------------------------
# Ladder: token → integer rank (lower number = higher precedence).
# ---------------------------------------------------------------------------
token_rank() {
  local token="$1"
  case "$token" in
    injection-suspect)        echo 1  ;;
    high-severity-rejection)  echo 2  ;;
    user-input-required)      echo 3  ;;
    planner-escalation)       echo 4  ;;
    break-fix-break)          echo 5  ;;
    blocked)                  echo 6  ;;
    root-cluster-suspected)   echo 7  ;;
    diminishing-returns)      echo 8  ;;
    merge-advised)            echo 9  ;;
    max-iterations-reached)   echo 10 ;;
    max-cycles-reached)       echo 11 ;;
    clean)                    echo 12 ;;
    *)
      printf 'exit-precedence: unknown exit_reason token: %s\n' "$token" >&2
      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Collect tokens from positional args + stdin.
# ---------------------------------------------------------------------------
all_tokens=()

# Positional args
for arg in "$@"; do
  all_tokens+=($arg)
done

# Stdin — read only when stdin is not a terminal (pipe or redirect).
if [ ! -t 0 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    for word in $line; do
      all_tokens+=("$word")
    done
  done
fi

# ---------------------------------------------------------------------------
# Empty input → floor token.
# ---------------------------------------------------------------------------
if [ "${#all_tokens[@]}" -eq 0 ]; then
  printf 'clean\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Walk tokens, validate each, track lowest rank (= highest precedence).
# ---------------------------------------------------------------------------
best_rank=999
best_token=""

for token in "${all_tokens[@]}"; do
  rank="$(token_rank "$token")"
  if [ "$rank" -lt "$best_rank" ]; then
    best_rank="$rank"
    best_token="$token"
  fi
done

printf '%s\n' "$best_token"
exit 0
