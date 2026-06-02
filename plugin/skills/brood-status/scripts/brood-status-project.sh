#!/usr/bin/env bash
#
# brood-status-project — read-side child-ledger projection engine for hivemind:brood-status
# (issue #161). The read-side analog of spawn-brood.sh's write-side injection closure
# (ADR-0017): spawn-brood WRITES the manifest + provisions child worktrees out-of-band; this
# script READS the manifest + each child run-ledger out-of-band and emits a machine-parseable
# per-strain projection line. The skill body (navigator) calls this once; this script OWNS the
# deterministic read + validation steps.
#
# INPUT (positional arguments):
#   $1  Path (absolute or repo-relative) to a brood manifest JSON (default name
#       `.hivemind/brood/manifest.json`). LAYOUT-AGNOSTIC: the caller passes the manifest path
#       explicitly; this script does NOT hardcode `.hivemind/brood/` (issue #168 will pass
#       per-brood paths). The manifest is UNTRUSTED data — see below.
#   $2  OPTIONAL: the checkout root the manifest belongs to, used as the containment root for the
#       manifest read-guard. DEFAULTS to `git rev-parse --show-toplevel` (the CURRENT checkout).
#       The navigator MUST pass the MAIN-checkout root here when it selected the manifest via the
#       documented main-checkout FALLBACK from a linked worktree (SKILL.md step 1c): in that case
#       the manifest lives under the main checkout, NOT the current linked worktree, so confining
#       it beneath `--show-toplevel` (the linked worktree) would falsely reject a valid
#       main-checkout manifest and stop status reporting before any strain probe (Codex #172 P1).
#       This argument bounds ONLY which checkout the manifest must sit under; it does NOT relax
#       the symlinked-ancestor escape guard, and each strain's child ledger is still confined
#       beneath that strain's OWN worktree (unchanged).
#
# DATA-BOUNDARY (MANDATORY): the brood manifest AND every child run-ledger
# (`<worktree>/.hivemind/runs/<id>/state.json`) are UNTRUSTED, attacker-controllable bytes —
# brood children run detached --dangerously-skip-permissions, so both the manifest the hatchery
# wrote from their inputs and the ledgers they write are adversary-influenced. EVERY value read
# from them is treated as DATA, never as instructions or shell source:
#   - manifest values are extracted out-of-band with jq into inert vars (manifest-json.sh),
#     then RE-GATED through the matching allowlist value-class (allowlist.sh) BEFORE any path
#     derivation or use;
#   - each child-ledger scalar is projected + value-validated (ledger-project.sh) and only ever
#     emitted as an allowlist-clean token or one of the fixed tokens MALFORMED / MISSING.
# No manifest/ledger byte is ever re-interpolated into generated command source.
#
# OUTPUT GRAMMAR (CONTRACT — the Wave 2 navigator depends on this byte-for-byte):
#   Exactly ONE TAB-delimited line per strain, prefixed with a literal `STRAIN` sentinel field
#   so the navigator can grep it. Tab is a safe delimiter: the shared allowlist security floor
#   (applied by EVERY value-class — identifier/path/presentation) rejects TAB/newline/CR, so no
#   emitted token can contain a literal tab and break the framing. Fields, in order:
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
#   INTEGRITY SENTINEL (distinct from any STRAIN line): when the manifest is PRESENT but
#   UNREADABLE — either UNPARSEABLE (torn / truncated / invalid JSON) OR VALID-JSON-BUT-WRONG-SHAPE
#   (`.strains` missing / null / non-array, or any non-object element) — the script emits exactly
#   ONE line
#     MANIFEST_UNREADABLE <TAB> <manifest_path>
#   to stdout and exits nonzero (see EXIT CONTRACT). The wrong-shape class joins the
#   syntactically-invalid class via a SINGLE shape-validating read (one open, one verdict). This
#   is DISTINCT from "manifest absent" (a pre-flight blocker on stderr) and from "valid empty
#   brood" (`{"strains":[]}` → exit 0, zero STRAIN lines, no sentinel). A present-but-unreadable
#   manifest must NEVER be silently projected as zero strains: corruption (or a wrong-shape
#   manifest) is otherwise indistinguishable from an empty brood and would hide live children from
#   the monitoring dashboard. (A strain object that is well-formed but lacks `name` is NOT a
#   structural failure — it projects with per-strain MALFORMED/MISSING tokens.)
#
# EXIT CONTRACT:
#   0  projected all strains (including zero strains for a VALID empty manifest). PER-STRAIN
#      MALFORMED / MISSING is NOT a failure — a strain with a bad field or an unreadable ledger
#      still emits its line (with token fields) and the script continues to the next strain.
#   1  pre-flight blocker ONLY: missing arg, jq absent, manifest path escapes the checkout
#      (symlinked ancestor). Reported via blocker() on stderr. No per-strain condition reaches
#      exit 1.
#   2  manifest PRESENT but UNREADABLE (unparseable OR valid-JSON-but-wrong-shape): emits the
#      MANIFEST_UNREADABLE sentinel line to stdout (above) and exits 2. A distinct nonzero code so
#      the navigator can tell a corruption/wrong-shape integrity-failure (live children may exist
#      but cannot be enumerated) apart from the absent-manifest stderr blocker.
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
. "$plugin_root/skills/_shared/manifest-json.sh"
. "$plugin_root/skills/_shared/ledger-project.sh"

# ── Dependency check ────────────────────────────────────────────────────────────
# jq is required (the child ledgers are JSON). tmux/claude/gh are NOT required — this read
# path runs in CI with only jq (issue #169 dep-gate).
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to project child run-ledgers but is not installed"

# ── Manifest argument validation ────────────────────────────────────────────────
MANIFEST="${1:-}"
[ -n "$MANIFEST" ] \
  || blocker "missing required argument: path to brood manifest JSON (\$1)"
# Reject a SYMLINKED manifest leaf BEFORE the [ -f ] regular-file test (which FOLLOWS
# symlinks and would pass a symlink-to-regular-file). hivemind_assert_inputs_contained below
# canonicalizes only the manifest's dirname and re-appends the basename textually, so a
# symlinked manifest LEAF pointing at an external file would otherwise resolve outside and be
# read as an attacker-controlled JSON manifest (Codex #172 P1). [ -L ] fires for a symlink leaf even when
# its target is missing; checking it first closes the leaf-symlink escape the dirname-only
# canonicalization leaves open. A symlinked ANCESTOR is still caught by the containment guard.
[ -L "$MANIFEST" ] \
  && blocker "refusing to read the manifest: $MANIFEST is a symlink leaf"
[ -f "$MANIFEST" ] \
  || blocker "brood manifest $MANIFEST does not exist or is not a regular file"

# Determine the containment root the manifest must sit beneath. DEFAULT: the current checkout
# (`git rev-parse --show-toplevel`). OVERRIDE: an explicit $2 supplied by the navigator when it
# selected the manifest via the main-checkout fallback from a linked worktree (see header / Codex
# #172 P1). The override must name an EXISTING DIRECTORY; an unreadable or non-directory override
# is a pre-flight blocker (we never silently fall back, which could hide a wrong root).
CHECKOUT_ROOT="${2:-}"
if [ -n "$CHECKOUT_ROOT" ]; then
  [ -d "$CHECKOUT_ROOT" ] \
    || blocker "supplied checkout root $CHECKOUT_ROOT does not exist or is not a directory"
else
  CHECKOUT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
fi

# Defense-in-depth READ-guard: refuse to read a manifest whose canonical path escapes the
# selected checkout root (e.g. via a symlinked ancestor). The helper never exits; map non-zero
# to blocker. With a fallback-supplied root this confines the manifest beneath the MAIN checkout
# (where the fallback manifest actually lives) instead of the current linked worktree.
hivemind_assert_inputs_contained "$CHECKOUT_ROOT" "$MANIFEST" >/dev/null \
  || blocker "refusing to read the manifest: $MANIFEST resolves outside the checkout root $CHECKOUT_ROOT (symlinked ancestor)"

# ── Single-snapshot read + shape validation (one open, one verdict) ───────────────
# The manifest passed every pre-flight (present, regular file, not a symlink leaf, contained).
# Open it EXACTLY ONCE into an in-memory snapshot; every projection below runs against THIS
# snapshot via jq stdin, never re-opening the file. This closes BOTH read-side issues at once:
#   1. SNAPSHOT SKEW — probe and per-field projections previously re-opened the manifest at
#      different instants, so a concurrent write mid-read could yield inconsistent reads. One
#      open means one consistent view.
#   2. SCHEMA GAP — the old `jq empty` probe was SYNTAX-only: a valid-JSON-but-wrong-shape
#      manifest ({}, {"strains":null}, {"strains":"x"}, {"strains":[1]}) passed it, then the
#      per-field projection yielded zero strains and was reported as a legitimate EMPTY brood,
#      hiding live children. The shape validation here requires `.strains` to EXIST as an ARRAY
#      with every element an OBJECT, folding the wrong-shape class into the UNREADABLE class.
# On shape failure (invalid JSON OR wrong shape) emit one MANIFEST_UNREADABLE sentinel to stdout
# and exit 2 (integrity failure). A VALID empty manifest (`{"strains":[]}`) PASSES shape (all()
# over an empty array is true) and falls through to the loop, exiting 0 with no STRAIN lines
# (legit empty brood). An element that IS an object but lacks `name` passes shape validation and
# projects with per-strain MALFORMED/MISSING tokens — per-strain degradation is the existing
# contract, distinct from a whole-manifest structural failure. This is the READ-side response
# only; the WRITE-side liveness guard in spawn-brood.sh deliberately keeps its
# fail-open-on-malformed behavior (a corrupt manifest must not wedge spawning).
# The manifest is UNTRUSTED bytes; held only in a shell var passed to jq stdin, never eval'd.
manifest_content="$(cat -- "$MANIFEST")"
if ! hivemind_manifest_validate_shape "$manifest_content"; then
  printf 'MANIFEST_UNREADABLE\t%s\n' "$MANIFEST"
  exit 2
fi

# Canonical containment anchor for the per-strain worktree-residency check below. The manifest
# is UNTRUSTED: a tampered `worktree_path` could point at an unrelated external dir (e.g.
# /tmp/...), and confining the ledger ONLY beneath that attacker-declared worktree (the path
# guard's anchor) would let a crafted manifest redirect the bounded ledger reader outside every
# brood worktree owned by this checkout and surface its scalars in the dashboard (Codex #172 P1).
# Canonicalize CHECKOUT_ROOT once here; each strain's worktree_path must canonically sit beneath
# it before it is trusted as the ledger-containment anchor.
canon_checkout="$(hivemind_canon_root "$CHECKOUT_ROOT")"
[ -n "$canon_checkout" ] \
  || blocker "failed to canonicalize checkout root $CHECKOUT_ROOT for worktree-residency check"

# ── Per-strain projection ───────────────────────────────────────────────────────
# For each strain, extract the manifest static fields out-of-band into inert vars, re-gate
# every downstream value through the allowlist, confine the ledger path beneath the strain's
# own worktree, and project the two ledger scalars. Any per-strain problem renders the affected
# field(s) as a token and CONTINUES — never aborts the whole read.
#
# DELIMITER-INJECTION AVOIDANCE: the loop is driven by INDEX off the strain COUNT, not by
# splitting a newline-delimited name stream. An untrusted strain name containing a newline is
# rejected by the presentation value-class floor — but that rejection happens AFTER extraction,
# so splitting a name stream on newline could forge an extra loop iteration BEFORE validation.
# Index-based extraction (hivemind_manifest_field_at, name read via `.strains[$i].name`) selects
# each strain by position against the in-memory snapshot, so no field value is ever parsed as a
# loop delimiter before it has passed its value class.
strain_count="$(hivemind_manifest_strain_count_snapshot "$manifest_content")"
idx=0
while [ "$idx" -lt "$strain_count" ]; do
  # 1. Extract the strain NAME + static fields + the suggested_ledger pointer out-of-band, all
  #    selected by INDEX against the single in-memory snapshot.
  strain_name="$(printf '%s' "$manifest_content" | jq -r --argjson i "$idx" '.strains[$i].name // empty' 2>/dev/null)"
  worktree_path="$(hivemind_manifest_field_at "$manifest_content" "$idx" "worktree_path")"
  branch="$(hivemind_manifest_field_at "$manifest_content" "$idx" "branch")"
  tmux_session="$(hivemind_manifest_field_at "$manifest_content" "$idx" "tmux_session")"
  manifest_status="$(hivemind_manifest_field_at "$manifest_content" "$idx" "status")"
  suggested_ledger="$(hivemind_manifest_field_at "$manifest_content" "$idx" "run.suggested_ledger")"

  # 2. Re-gate every value through the allowlist value-class matching its field. A failing
  #    value renders MALFORMED for that field. The strain NAME is DISPLAY-ONLY — it is emitted
  #    in the output field; it is NOT used to select the strain (selection is by INDEX against
  #    the in-memory snapshot), so it never reaches a shell probe token. spawn-brood accepts and safely
  #    derives names containing SPACES, so a valid `api worker` strain must not be rendered
  #    MALFORMED (which would make the navigator skip the strain's live probes and lose its
  #    status entirely — Codex #172 P1). Gate the name with the broadest PRESENTATION class
  #    (permits space + printable display bytes; still rejects the shared floor: '..', leading
  #    '-', command-substitution `$`/backtick, and the TAB/newline/CR that would break the
  #    TAB-delimited output grammar). IDs used in shell probes (branch/tmux/status/ledger_id)
  #    keep the strict IDENTIFIER class below.
  name_out="MALFORMED"
  hivemind_assert_presentation "$strain_name" && name_out="$strain_name"

  # worktree_path is a filesystem PATH, not an identifier: a valid checkout root may contain
  # SPACES (and inert bytes # = ~ !). Gate it with the PATH class (permits those; still rejects
  # the shared floor: '..', leading '-', command-substitution + framing bytes) — NOT the strict
  # IDENTIFIER class, which would falsely render a space-bearing worktree MALFORMED and suppress
  # all ledger projection (Codex #172 P1). Its only downstream uses (cd/pwd -P canonicalization,
  # quoted prefix construction, the TAB-delimited output field) are all space-safe.
  # wt_clean gates whether worktree_path may anchor a ledger READ. It requires BOTH (a) the path
  # value-class AND (b) canonical RESIDENCY beneath this checkout. The manifest is untrusted, so a
  # charset-clean but EXTERNAL worktree_path (e.g. /tmp/evil) must NOT anchor the ledger reader —
  # confining the ledger only beneath the attacker-declared worktree would let a tampered manifest
  # redirect the bounded reader outside every brood worktree owned by this checkout (Codex #172
  # P1). A non-resident worktree still DISPLAYS its (charset-clean) value, but its ledger is
  # rendered MALFORMED (no external read) via the wt_clean gate below.
  wt_out="MALFORMED"
  wt_clean=0
  if hivemind_assert_path "$worktree_path"; then
    wt_out="$worktree_path"
    # Residency check: the worktree must canonically sit beneath the owning checkout root. cd &&
    # pwd -P resolves every symlink component; a worktree that does not exist, or whose canonical
    # path escapes canon_checkout, fails residency and is denied as a ledger anchor (but is still
    # shown as a value). Trailing-slash-guarded so a sibling like <checkout>-evil cannot prefix-match.
    canon_wt_resident="$(cd "$worktree_path" 2>/dev/null && pwd -P)"
    if [ -n "$canon_wt_resident" ]; then
      case "$canon_wt_resident/" in
        "$canon_checkout/"*) wt_clean=1 ;;
        *) wt_clean=0 ;;
      esac
    fi
  fi

  branch_out="MALFORMED"
  hivemind_assert_identifier "$branch" && branch_out="$branch"

  tmux_out="MALFORMED"
  hivemind_assert_identifier "$tmux_session" && tmux_out="$tmux_session"

  status_out="MALFORMED"
  hivemind_assert_identifier "$manifest_status" && status_out="$manifest_status"

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
  elif ! hivemind_assert_path "$suggested_ledger"; then
    # Pointer present but not path-clean: treat as an escape attempt — MALFORMED, no read. The
    # pointer embeds the worktree_path prefix, so a valid pointer under a space-bearing checkout
    # legitimately contains spaces — gate with the PATH class (still rejects '..', command-sub,
    # framing bytes). The id SEGMENT below is separately re-checked against the strict
    # ^[A-Za-z0-9._-]+$ identifier charset (no slash, no space), so the relaxed path class here
    # never weakens the single-component id confinement.
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
            # Confined. Read the ledger EXACTLY ONCE into an in-memory snapshot, then project
            # BOTH scalars from that one snapshot (mirrors the manifest single-snapshot pattern).
            # The OLD code called the path-based projectors here, each of which independently
            # re-stat'd + re-opened the leaf via jq (which FOLLOWS symlinks); a hostile child
            # could swap the regular-file leaf to a symlink in the post-check window and the
            # per-scalar reopens would follow it. One read collapses that multi-reopen window to
            # a single open. (MISSING if file absent / empty — e.g. child has not initialized its
            # ledger yet.)
            #
            # RESIDUAL (bounded, REQUIRED): bash has no portable O_NOFOLLOW, so an irreducible
            # micro-TOCTOU remains between the [ -L ] re-check immediately below and the single
            # `cat`. It is BOUNDED to near-zero impact: only the validated run.status enum +
            # state.current charset ever surface — never raw bytes; projection is informational-
            # only and never overrides observable status. The STRUCTURAL closure (no cross-worktree
            # reads of hostile-child files) is per-brood isolation tracked in #168. Re-assert the
            # leaf is not a symlink as close to the read as possible to narrow (not fully close)
            # the window.
            if [ -L "$canon_ledger" ]; then
              state_out="MALFORMED"
              run_out="MALFORMED"
            elif ledger_content="$(cat -- "$canon_ledger" 2>/dev/null)"; then
              # READ SUCCEEDED. Attempt the read IMMEDIATELY after the [ -L ] re-check — NO
              # intervening filesystem stat — to keep the irreducible single-open micro-TOCTOU
              # window (documented above, #168-homed) as NARROW as possible. An earlier draft
              # inserted a `[ -e ]` existence probe BETWEEN the [ -L ] check and the read, which
              # added an extra syscall to that window; ordering the `cat` first removes it and
              # mirrors the safe ordering already used by the path-based wrappers in
              # ledger-project.sh.
              run_out="$(hivemind_project_run_status_content "$ledger_content")"
              state_out="$(hivemind_project_state_current_content "$ledger_content")"
            elif [ -e "$canon_ledger" ]; then
              # READ FAILED on a leaf that STILL EXISTS → present-but-unreadable (unreadable
              # perms, I/O error). "Present but cannot be read" → MALFORMED, never MISSING.
              # `cat` returns the empty string AND a non-zero status on failure (the `2>/dev/null`
              # silences only stderr, not the exit status the `if` tests). Collapsing this to
              # MISSING would make a corrupted / attacker-influenced unreadable ledger
              # indistinguishable from an uninitialized one; this restores the pre-single-snapshot
              # jq-open-failure semantics. The existence re-test runs ONLY on the failure path,
              # so it never enlarges the success-path read window above.
              state_out="MALFORMED"
              run_out="MALFORMED"
            else
              # READ FAILED and the leaf is ABSENT → genuine absence (the containment guard
              # intentionally PASSES a non-existent leaf; the child may not have initialized its
              # ledger yet, or it vanished). "Nothing to report" → MISSING, per the documented
              # TOKEN SEMANTICS — distinct from the present-but-unreadable case above.
              state_out="MISSING"
              run_out="MISSING"
            fi
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

  idx=$((idx + 1))
done

exit 0
