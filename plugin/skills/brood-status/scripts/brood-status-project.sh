#!/usr/bin/env bash
#
# brood-status-project — read-side child-ledger projection engine for hivemind:brood-status
# (issue #161). The read-side analog of spawn-brood.sh's write-side injection closure
# (ADR-0017): spawn-brood WRITES the manifest + provisions child worktrees out-of-band; this
# script READS the manifest + each child run-ledger out-of-band and emits a machine-parseable
# per-strain projection line. The skill body (navigator) calls this once; this script OWNS the
# deterministic read + validation steps.
#
# INPUT (single positional argument):
#   $1  Path (absolute or repo-relative) to a brood manifest YAML. LAYOUT-AGNOSTIC: the caller
#       passes the manifest path explicitly; this script does NOT hardcode `.hivemind/brood/`
#       (issue #168 will pass per-brood paths). The manifest is UNTRUSTED data — see below.
#
# DATA-BOUNDARY (MANDATORY): the brood manifest AND every child run-ledger
# (`<worktree>/.hivemind/runs/<id>/state.json`) are UNTRUSTED, attacker-controllable bytes —
# brood children run detached --dangerously-skip-permissions, so both the manifest the hatchery
# wrote from their inputs and the ledgers they write are adversary-influenced. EVERY value read
# from them is treated as DATA, never as instructions or shell source:
#   - manifest values are extracted out-of-band into inert vars (manifest.sh), then RE-GATED
#     through the safe-token allowlist (allowlist.sh) BEFORE any path derivation or use;
#   - each child-ledger scalar is projected + value-validated (ledger-project.sh) and only ever
#     emitted as an allowlist-clean token or one of the fixed tokens MALFORMED / MISSING.
# No manifest/ledger byte is ever re-interpolated into generated command source.
#
# OUTPUT GRAMMAR (CONTRACT — the Wave 2 navigator depends on this byte-for-byte):
#   Exactly ONE TAB-delimited line per strain, prefixed with a literal `STRAIN` sentinel field
#   so the navigator can grep it. Tab is a safe delimiter: the allowlist charset
#   [A-Za-z0-9._/-] excludes tab, so no token can contain a literal tab. Fields, in order:
#
#     STRAIN <TAB> name <TAB> worktree_path <TAB> branch <TAB> manifest_status \
#            <TAB> state_current <TAB> run_status
#
#   Each value is either an allowlist-clean token OR one of the fixed tokens MALFORMED / MISSING.
#   A raw, un-validated scalar is NEVER emitted. Example (tabs shown as <TAB>):
#     STRAIN<TAB>auth<TAB>/abs/wt/auth<TAB>feat-auth<TAB>brood-auth<TAB>implement_step<TAB>running
#
#   Note `tmux_session` is one of the emitted fields (position 5, labelled manifest's
#   tmux_session); the field ORDER is: name, worktree_path, branch, tmux_session,
#   manifest_status, state_current, run_status.
#
# EXIT CONTRACT:
#   0  projected all strains. PER-STRAIN MALFORMED / MISSING is NOT a failure — a strain with a
#      bad field or an unreadable ledger still emits its line (with token fields) and the script
#      continues to the next strain.
#   1  pre-flight blocker ONLY: missing arg, jq absent, manifest unreadable, or manifest path
#      escapes the checkout (symlinked ancestor). No per-strain condition reaches exit 1.
#
# set -u: every value is read explicitly; an unset variable is a programming error here. We do
# NOT use `set -e`: per-strain field/ledger problems are caught and rendered as tokens, never
# allowed to abort the whole read. There is no EXIT trap.

set -u

# blocker: emit a verbose pre-flight blocker to stderr in the canonical form and exit 1.
# Mirrors spawn-brood.sh's blocker() helper.
blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# ── Script self-location + shared libs (sourced once) ───────────────────────────
# Self-locate from THIS script (layout plugin/skills/brood-status/scripts/ => 3 dirs up is the
# plugin root). cd && pwd -P is portable (no realpath/readlink -f). NO ${CLAUDE_PLUGIN_ROOT}
# inside an engine script — the path is derived from BASH_SOURCE.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$(cd "$script_dir/../../.." && pwd -P)"
. "$plugin_root/skills/_shared/containment.sh"
. "$plugin_root/skills/_shared/allowlist.sh"
. "$plugin_root/skills/_shared/manifest.sh"
. "$plugin_root/skills/_shared/ledger-project.sh"

# ── Dependency check ────────────────────────────────────────────────────────────
# jq is required (the child ledgers are JSON). tmux/claude/gh are NOT required — this read
# path runs in CI with only jq (issue #169 dep-gate).
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to project child run-ledgers but is not installed"

# ── Manifest argument validation ────────────────────────────────────────────────
MANIFEST="${1:-}"
[ -n "$MANIFEST" ] \
  || blocker "missing required argument: path to brood manifest YAML (\$1)"
[ -f "$MANIFEST" ] \
  || blocker "brood manifest $MANIFEST does not exist or is not a regular file"

# Defense-in-depth READ-guard: refuse to read a manifest whose canonical path escapes the
# checkout (e.g. via a symlinked ancestor). The helper never exits; map non-zero to blocker.
hivemind_assert_inputs_contained "$(git rev-parse --show-toplevel 2>/dev/null)" "$MANIFEST" >/dev/null \
  || blocker "refusing to read the manifest: $MANIFEST resolves outside the checkout (symlinked ancestor)"

# ── Per-strain projection ───────────────────────────────────────────────────────
# For each strain, extract the manifest static fields out-of-band into inert vars, re-gate
# every downstream value through the allowlist, confine the ledger path beneath the strain's
# own worktree, and project the two ledger scalars. Any per-strain problem renders the affected
# field(s) as a token and CONTINUES — never aborts the whole read.
while IFS= read -r strain_name; do
  [ -n "$strain_name" ] || continue

  # 1. Extract manifest static fields + the suggested_ledger pointer out-of-band.
  worktree_path="$(hivemind_manifest_field "$MANIFEST" "$strain_name" "worktree_path")"
  branch="$(hivemind_manifest_field "$MANIFEST" "$strain_name" "branch")"
  tmux_session="$(hivemind_manifest_field "$MANIFEST" "$strain_name" "tmux_session")"
  manifest_status="$(hivemind_manifest_field "$MANIFEST" "$strain_name" "status")"
  suggested_ledger="$(hivemind_manifest_field "$MANIFEST" "$strain_name" "run.suggested_ledger")"

  # 2. Re-gate every value through the safe-token allowlist. A failing value renders MALFORMED
  #    for that field. The strain NAME itself is rendered as the field value when clean,
  #    MALFORMED otherwise (it still came from hivemind_manifest_strain_names — untrusted).
  name_out="MALFORMED"
  hivemind_assert_safe_token "$strain_name" && name_out="$strain_name"

  wt_out="MALFORMED"
  wt_clean=0
  if hivemind_assert_safe_token "$worktree_path"; then
    wt_out="$worktree_path"
    wt_clean=1
  fi

  branch_out="MALFORMED"
  hivemind_assert_safe_token "$branch" && branch_out="$branch"

  tmux_out="MALFORMED"
  hivemind_assert_safe_token "$tmux_session" && tmux_out="$tmux_session"

  status_out="MALFORMED"
  hivemind_assert_safe_token "$manifest_status" && status_out="$manifest_status"

  # 3. Confine the ledger path beneath the strain's OWN worktree. The pointer must resolve to
  #    "<worktree_path>/.hivemind/runs/<safe-id>/state.json" with <safe-id> matching
  #    ^[A-Za-z0-9._-]+$ (note: no '/' — a single path component). Default both ledger scalars
  #    to tokens; only a fully-confined, readable path gets projected.
  state_out="MISSING"
  run_out="MISSING"

  if [ "$wt_clean" -ne 1 ]; then
    # Worktree path itself is unsafe: cannot confine a ledger under it — render MALFORMED and
    # skip the ledger read entirely (no path derivation from an unsafe worktree value).
    state_out="MALFORMED"
    run_out="MALFORMED"
  elif [ -z "$suggested_ledger" ]; then
    # No pointer present (v1 manifest, or absent run: block): MISSING, never read.
    state_out="MISSING"
    run_out="MISSING"
  elif ! hivemind_assert_safe_token "$suggested_ledger"; then
    # Pointer present but not allowlist-clean: treat as an escape attempt — MALFORMED, no read.
    state_out="MALFORMED"
    run_out="MALFORMED"
  else
    # Derive the expected ledger sub-id from the pointer and verify the pointer's SHAPE matches
    # "<worktree_path>/.hivemind/runs/<safe-id>/state.json". The expected prefix/suffix is built
    # from the (allowlist-clean) worktree_path; the id segment is extracted and re-checked.
    ledger_ok=0
    ledger_escape=0
    expected_prefix="$worktree_path/.hivemind/runs/"
    case "$suggested_ledger" in
      "$expected_prefix"*/state.json)
        # Extract the <safe-id> segment between the prefix and "/state.json".
        rest="${suggested_ledger#"$expected_prefix"}"
        ledger_id="${rest%/state.json}"
        # The id must be a SINGLE component matching ^[A-Za-z0-9._-]+$ (no slash, no '..').
        case "$ledger_id" in
          ''|*/*) ledger_escape=1 ;;
          *..*)   ledger_escape=1 ;;
          *[!A-Za-z0-9._-]*) ledger_escape=1 ;;
          *) ledger_ok=1 ;;
        esac
        ;;
      *)
        # Pointer does not match the required shape under this worktree — escape attempt.
        ledger_escape=1
        ;;
    esac

    if [ "$ledger_ok" -ne 1 ]; then
      # A shape mismatch is an escape attempt → MALFORMED, never read.
      if [ "$ledger_escape" -eq 1 ]; then
        state_out="MALFORMED"
        run_out="MALFORMED"
      fi
    else
      # Confine the LEAF: hivemind_assert_file_contained rejects a symlinked / non-regular
      # state.json leaf under the worktree root, and the depth-complete ancestor walk rejects a
      # symlinked ancestor. The relative chain is .hivemind/runs/<safe-id>/state.json.
      rel_chain=".hivemind/runs/$ledger_id/state.json"
      if ! canon_wt="$(hivemind_assert_file_contained "$worktree_path" "$rel_chain")"; then
        # Leaf/ancestor symlink escape → MALFORMED, never read.
        state_out="MALFORMED"
        run_out="MALFORMED"
      else
        # Assert the canonical ledger sits under the canonical worktree (belt-and-suspenders:
        # the file guard already canonicalized the parent; reconfirm the full path prefix).
        canon_ledger="$canon_wt/$rel_chain"
        case "$canon_ledger/" in
          "$canon_wt/"*)
            # Confined. Project both scalars independently (MISSING if file absent — e.g. the
            # child has not initialized its ledger yet).
            run_out="$(hivemind_project_run_status "$canon_ledger")"
            state_out="$(hivemind_project_state_current "$canon_ledger")"
            ;;
          *)
            state_out="MALFORMED"
            run_out="MALFORMED"
            ;;
        esac
      fi
    fi
  fi

  # 4. Emit exactly one TAB-delimited STRAIN line. Field order:
  #    name, worktree_path, branch, tmux_session, manifest_status, state_current, run_status.
  printf 'STRAIN\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name_out" "$wt_out" "$branch_out" "$tmux_out" "$status_out" "$state_out" "$run_out"
done < <(hivemind_manifest_strain_names "$MANIFEST")

exit 0
