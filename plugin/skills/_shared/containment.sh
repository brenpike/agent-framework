# shellcheck shell=bash
#
# containment.sh — shared symlink-write-escape containment idiom for the three
# committed hivemind run-ledger / brood writers (init-run-ledger, record-state-result,
# spawn-brood).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/containment.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
#
# WHY ONE SHARED HELPER: the three writers each DERIVE a write path textually from the git
# checkout root (e.g. "$repo_root/.hivemind/runs/<run_id>"). Textual derivation does NOT
# confine the write when an ANCESTOR component of the chain is a SYMLINK pointing outside
# the checkout — a repo that commits .hivemind, .hivemind/runs, or a deeper component as a
# symlink to an external dir makes the derived path resolve OUTSIDE the checkout, so a
# subsequent mkdir/mktemp/mv/worktree-add writes EXTERNALLY. Previously each writer guarded
# only a hand-enumerated set of ancestor names (.hivemind, .hivemind/runs), which left the
# `<run_id>` leaf (and any future component) unguarded — the finding-1 escape vector. This
# helper closes the class DEPTH-COMPLETELY (every component of the chain, generically, not
# by name) in ONE place so the three writers cannot diverge again.
#
# CONTRACT
#   hivemind_assert_contained <raw_repo_root> <relative_chain>
#     <raw_repo_root>  the git checkout root (e.g. `git rev-parse --show-toplevel`).
#     <relative_chain> a checkout-relative path whose write target lives at its leaf,
#                      e.g. ".hivemind/runs/<run_id>" or ".claude/worktrees".
#     On success: echoes the CANONICAL checkout root (cd && pwd -P) to stdout and returns 0.
#                 Callers MUST derive their write paths from this canonical root.
#     On reject:  prints a human-readable reason to stderr and returns non-zero. The caller
#                 maps the non-zero return to its OWN blocker() (this helper never exits).
#
# DEPTH-COMPLETE: every component of <relative_chain> that ALREADY EXISTS is checked for
#   being a symlink ([ -L ]); the deepest existing prefix is canonicalized and required to
#   stay under "<canon_root>/<expected-sub-prefix>/". Non-existent leaf components are fine
#   (init/spawn-brood CREATE them) — only existing components are checked. This covers
#   .hivemind, .hivemind/runs, .hivemind/runs/<run_id>, .claude, .claude/worktrees, and any
#   deeper/future component generically, NOT by enumerated name.
#
# PORTABLE: canonicalization is `cd "$dir" && pwd -P` (pwd -P resolves EVERY symlink
#   component) — NEVER realpath / readlink -f, which BSD/macOS lack or spell differently.
#   Symlink detection is POSIX `[ -L path ]` (fires regardless of whether the target
#   exists). Prefix-containment appends a trailing slash to BOTH operands so a sibling like
#   .hivemind-evil cannot prefix-match .hivemind.
#
# SET -U SAFETY: callers run under `set -u` (no `set -e`). A failed `cd` in a command
#   substitution yields an EMPTY string; every canonicalization below is empty-tested and
#   rejected rather than allowed to proceed with an empty path.
#
# DEPENDENCY-FREE: pure bash / POSIX test builtins (cd, pwd, [ -L ], case). No jq, no
#   realpath, no external canonicalizer.

# hivemind_canon_root <raw_repo_root>
# Echo the canonical checkout root (cd && pwd -P), or echo nothing and return 1 on failure.
# Canonicalizing the root handles a repo_root that itself sits under a symlinked path (e.g.
# macOS /tmp -> /private/tmp) so an equal-but-symlinked root does not false-reject later.
hivemind_canon_root() {
  local raw_root="$1"
  local canon_root
  canon_root="$(cd "$raw_root" 2>/dev/null && pwd -P)"
  if [ -z "$canon_root" ]; then
    return 1
  fi
  printf '%s' "$canon_root"
  return 0
}

# hivemind_assert_contained <raw_repo_root> <relative_chain>
# Depth-complete symlink-containment check over every existing component of the chain.
# Echoes the canonical root on success (return 0); prints a reason to stderr and returns
# non-zero on reject. Never exits — the caller maps non-zero to its own blocker.
hivemind_assert_contained() {
  local raw_root="$1"
  local rel_chain="$2"

  local canon_root
  canon_root="$(hivemind_canon_root "$raw_root")"
  if [ -z "$canon_root" ]; then
    printf 'failed to canonicalize repo root %s\n' "$raw_root" >&2
    return 1
  fi

  # Walk every component of the relative chain from the root down. `partial` accumulates the
  # checkout-relative prefix; `deepest_existing` tracks the deepest prefix that exists on
  # disk (canonicalized and prefix-checked after the walk). IFS='/' splits the chain into
  # components without invoking a subshell or external tool.
  local partial=""
  local deepest_existing=""
  local component
  local old_ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  set -- $rel_chain
  IFS="$old_ifs"
  for component in "$@"; do
    # Skip empty components (leading/duplicate slashes) defensively.
    [ -n "$component" ] || continue
    if [ -n "$partial" ]; then
      partial="$partial/$component"
    else
      partial="$component"
    fi
    local abs="$canon_root/$partial"
    if [ -L "$abs" ]; then
      printf 'refusing symlinked component %s under %s\n' "$partial" "$canon_root" >&2
      return 1
    fi
    if [ -e "$abs" ]; then
      deepest_existing="$partial"
    fi
  done

  # Canonicalize the deepest EXISTING prefix and require it stay under the canonical root
  # (and, transitively, under the expected sub-prefix the chain names — the canonical prefix
  # text starts with "$canon_root/<chain-prefix>"). A non-existent leaf is fine; only the
  # existing prefix is verified. Trailing-slash-guarded so a sibling like .hivemind-evil
  # cannot prefix-match .hivemind.
  if [ -n "$deepest_existing" ]; then
    local canon_prefix
    canon_prefix="$(cd "$canon_root/$deepest_existing" 2>/dev/null && pwd -P)"
    if [ -z "$canon_prefix" ]; then
      printf 'failed to canonicalize %s/%s\n' "$canon_root" "$deepest_existing" >&2
      return 1
    fi
    case "$canon_prefix/" in
      "$canon_root/$deepest_existing/") : ;;
      *)
        printf 'component %s resolves outside the checkout: %s\n' "$deepest_existing" "$canon_prefix" >&2
        return 1
        ;;
    esac
  fi

  printf '%s' "$canon_root"
  return 0
}

# hivemind_assert_inputs_contained <raw_repo_root> <inputs_file_path>
#
# Defense-in-depth READ-guard for the three inputs-file navigators (init-run-ledger,
# record-state-result, spawn-brood). The model authors an inputs JSON file via the Write
# tool BEFORE the committed engine runs. This function lets each engine REFUSE TO READ an
# inputs file whose canonical path escapes the checkout (e.g. via a symlinked ancestor),
# converting a silent external-write-and-consume into a hard, loud blocker.
#
# HONEST SCOPE NOTE: this does NOT prevent the external Write itself — the model's Write tool
# runs before any committed code executes, so a path escaped via symlink is already written
# by the time this guard runs. What this guard does is REFUSE TO READ such a file, making
# the violation loud (hard non-zero return) rather than silent. The PRIMARY fix for the
# write-through-symlink class is the navigator transport-path correction (record's
# fixed-literal-sibling path + token transport), not this guard. This guard is a
# defense-in-depth backstop only.
#
# PRECONDITION: the caller must verify the file exists ([ -f "$inputs_file" ]) before
# calling this function. Behavior on a missing file is unspecified.
#
# On success: echoes the canonical repo root and returns 0.
# On reject:  prints a concise reason to stderr and returns non-zero. Never exits.
hivemind_assert_inputs_contained() {
  local raw_root="$1"
  local inputs_file_path="$2"

  local canon_root
  canon_root="$(hivemind_canon_root "$raw_root")"
  if [ -z "$canon_root" ]; then
    printf 'failed to canonicalize repo root %s\n' "$raw_root" >&2
    return 1
  fi

  # Canonicalize the inputs file path using the same cd && pwd -P idiom as the rest of this
  # file. We cd into dirname (which must already exist — the file exists per precondition)
  # and re-append the basename. This resolves every symlink component in the directory path.
  local inputs_dir inputs_base canon_inputs
  inputs_dir="$(dirname "$inputs_file_path")"
  inputs_base="$(basename "$inputs_file_path")"
  canon_inputs="$(cd "$inputs_dir" 2>/dev/null && pwd -P)"
  if [ -z "$canon_inputs" ]; then
    printf 'failed to canonicalize inputs file directory %s\n' "$inputs_dir" >&2
    return 1
  fi
  canon_inputs="$canon_inputs/$inputs_base"

  # Trailing-slash-guarded prefix match — mirrors hivemind_assert_contained's case pattern
  # exactly so a sibling path like /repo-evil cannot prefix-match /repo.
  case "$canon_inputs/" in
    "$canon_root/"*)
      ;;
    *)
      printf 'inputs file %s resolves outside the checkout: %s\n' "$inputs_file_path" "$canon_inputs" >&2
      return 1
      ;;
  esac

  printf '%s' "$canon_root"
  return 0
}
