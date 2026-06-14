# shellcheck shell=bash
#
# ledger-engine-io.sh — shared run-ledger READ + BOOTSTRAP machinery for the three
# committed hivemind ledger engines. Defines exactly two functions extracted VERBATIM
# (pure code-move, behavior byte-preserving) from the engine monoliths:
#   hivemind_read_inputs_file — the inputs-file arg/existence/read-guard/JSON-validity
#     bootstrap, shared by ALL THREE engines (init-run-ledger, record-state-result,
#     mark-intent-fallback).
#   hivemind_open_ledger — the repo-root → ledger-path derivation + depth-complete
#     containment + ledger-read + coherence + post-existence canonical confirmation,
#     shared by record-state-result + mark-intent-fallback (NOT init, which CREATES a
#     ledger rather than opening an existing one).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each engine sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/ledger-engine-io.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
#
# P18 FLOOR EXCEPTION (ADR-0020): as a SOURCED library this file deliberately
# OMITS the P18 shell-safety floor `set -e` / `set -o pipefail` and any EXIT trap. A sourced
# file mutates the SOURCING shell's option state, so installing those here would corrupt
# every engine's shell; the floor is therefore the documented exception, not the full
# `set -euo pipefail`. This file carries no top-level `set` at all (pure function
# definitions); each ENGINE owns its own `set -u`, EXIT trap, and error routing.
# Allowlisted under CHECK13 as a P18 documented exception.
#
# VARIABLE CONTRACT: both functions run in the SOURCING (engine) shell under `set -u`.
# Every variable they touch is `local` or a passed argument — they read NO caller-shell
# globals. Neither function calls `exit`; each returns non-zero with a message on stderr,
# and the engine maps that non-zero return to its OWN blocker()/exit contract (mirroring
# the never-exit contract of the containment.sh helpers these functions orchestrate).
#
# DEPENDENCY CONTRACT: these functions ORCHESTRATE the containment.sh helpers
# (hivemind_assert_inputs_contained, hivemind_assert_contained, hivemind_assert_ledger_contained)
# at CALL time — this library does NOT source containment.sh. The ENGINE MUST have sourced
# containment.sh BEFORE calling either function. These functions also require `jq` and `git`
# on PATH (the engine's own up-front `command -v jq` dependency check covers jq).

# hivemind_read_inputs_file <inputs_file_path> <label>
#
# VERBATIM inputs-file bootstrap shared by all three engines. <label> is the human-readable
# script noun each engine interpolates so its EXACT current blocker strings reproduce
# byte-for-byte (record-state-result → "record-state-result", mark-intent-fallback →
# "mark-intent-fallback", init-run-ledger → "run-ledger"). Encapsulates, IN ORDER:
#   1. the `INPUTS_FILE="${1:-}"`-style non-empty arg check,
#   2. the `[ -f ]` existence check,
#   3. the hivemind_assert_inputs_contained defense-in-depth read-guard (run BEFORE the
#      jq validity probe — `jq -e` on an attacker path is itself a JSON-validity read oracle),
#   4. the `jq -e .` JSON-validity probe.
#
# Lifted verbatim from:
#   record-state-result.sh   L154-173 (label "record-state-result")
#   mark-intent-fallback.sh  L115-130, L132-133 (label "mark-intent-fallback")
#   init-run-ledger.sh       L164-181, L183-184 (label "run-ledger")
# The three differed ONLY in the label noun interpolated into the blocker strings (and the
# inputs-guard blocker text was already byte-identical across all three).
#
# STDERR / RETURN-CODE CONTRACT (byte-preservation):
#   This function emits NO stderr of its own. The non-containment failure reasons (missing
#   arg, missing file, invalid JSON) were SINGLE-LINE `blocker:` lines pre-extraction with no
#   preceding detail line, so this function only signals WHICH failure occurred via a distinct
#   non-zero return code; the ENGINE owns the (label-interpolated) fixed `blocker:` text. The
#   containment failure was a TWO-LINE sequence pre-extraction: the inner
#   hivemind_assert_inputs_contained helper's own UNPREFIXED detail line on fd2, THEN the
#   engine's `blocker:` line. To preserve that byte-for-byte, the inner-helper stderr is
#   deliberately PASS-THROUGH (UNCAPTURED — only its STDOUT is `>/dev/null`'d) so its detail
#   line reaches fd2 as a distinct line ABOVE the engine's blocker line; this function adds no
#   line of its own for the containment reject. NEVER exits.
#   Return codes (the engine maps each to its exact current blocker text):
#     0 success
#     2 missing required argument
#     3 inputs file does not exist
#     4 containment reject (inner helper already emitted its detail line to fd2, uncaptured)
#     5 inputs file is not valid JSON
hivemind_read_inputs_file() {
  local inputs_file="$1"
  local label="$2"

  if [ -z "$inputs_file" ]; then
    return 2
  fi
  if [ ! -f "$inputs_file" ]; then
    return 3
  fi

  # Defense-in-depth inputs READ-guard (shared helper). Refuse to READ the inputs file when
  # its canonical path escapes the checkout (e.g. via a symlinked ancestor) — converting a
  # silent external-read into a hard return BEFORE the jq validity probe below. Running this
  # BEFORE the `jq -e` probe is REQUIRED: `jq -e` opening an attacker-supplied external path
  # is itself an external-file JSON-validity read oracle, so the containment guard must gate
  # it. The helper never exits. Its STDOUT (the canonical root) is discarded with `>/dev/null`;
  # its STDERR is left UNCAPTURED so the helper's own detail line flows to fd2 as the FIRST of
  # the two byte-preserved lines (the engine adds the second, `blocker:`-prefixed line).
  if ! hivemind_assert_inputs_contained "$(git rev-parse --show-toplevel 2>/dev/null)" "$inputs_file" >/dev/null; then
    return 4
  fi

  if ! jq -e . "$inputs_file" >/dev/null 2>&1; then
    return 5
  fi

  return 0
}

# hivemind_open_ledger <repo_root> <run_id>
#
# VERBATIM ledger-open machinery shared by record-state-result + mark-intent-fallback (NOT
# init, which CREATES a ledger). The caller passes the already-derived <repo_root>
# (git rev-parse --show-toplevel, already non-empty-checked by the engine) and the
# already-validated <run_id> (SAFE_ID_RE + reserved-component reject already applied by the
# engine). This function then performs, IN THIS EXACT ORDER (a reordering silently breaks
# engine determinism):
#   1. derive ledger = "$repo_root/.hivemind/runs/$run_id/state.json",
#   2. hivemind_assert_contained "$repo_root" ".hivemind/runs/$run_id" ancestor guard,
#   3. canonical-runs-dir canonicalization (cd && pwd -P) + trailing-slash prefix case-guard,
#   4. hivemind_assert_ledger_contained leaf guard (rejects a symlinked state.json LEAF),
#   5. `[ -f ]` existence + `jq -e .` JSON-validity ledger reads,
#   6. coherence check (`.run.id == run_id`),
#   7. post-existence canonical ledger-dir confirmation (canon dir + state.json/run_id
#      basename asserts).
#
# Lifted verbatim from:
#   record-state-result.sh   L229-311 (THE HOT PATH — strictest source of truth)
#   mark-intent-fallback.sh  L177-250 (byte-identical executable block; only comment prose differs)
# The two blocks (incl. every blocker string) were byte-identical, so no label parameter is
# needed — the blocker text below reproduces both engines' exact current strings.
#
# On SUCCESS: echoes TWO lines on stdout for the engine to read back —
#   line 1 = the canonical ledger path  ($canon_ledger)
#   line 2 = the canonical ledger dir   ($canon_ledger_dir)
# The engine reads them with `IFS= read -r canon_ledger; IFS= read -r canon_ledger_dir`.
# Two newline-separated lines are byte-safe here: both values are canonical filesystem paths
# under the checkout (no embedded newlines possible — pwd -P output, and run_id is SAFE_ID_RE).
# STDERR / RETURN-CODE CONTRACT (byte-preservation):
#   Two failure SHAPES, distinguished by return code:
#
#   SHAPE A — inner-helper containment rejects (return 2 = hivemind_assert_contained ancestor
#   guard; return 6 = hivemind_assert_ledger_contained leaf guard). Pre-extraction these were
#   TWO-LINE sequences: the inner helper's own UNPREFIXED detail line on fd2, THEN the engine's
#   `blocker:` line. To preserve that byte-for-byte the inner-helper STDERR is deliberately
#   PASS-THROUGH (UNCAPTURED — only its STDOUT is `>/dev/null`'d) so its detail line reaches fd2
#   as the line ABOVE the engine's blocker line; this function writes NOTHING (neither stdout
#   nor stderr) for these two rejects. The engine maps 2/6 to its OWN fixed `blocker:` text,
#   which interpolates only values the engine already holds ($run_id for 2, $ledger for 6).
#
#   SHAPE B — every OTHER failure (canon-root empty, runs-dir canon empty, the inline runs-dir
#   trailing-slash case-guard which has NO inner helper, `[ -f ]` missing, `jq -e` invalid JSON,
#   coherence `.run.id` mismatch, post-existence canon-dir / basename asserts). Pre-extraction
#   these were SINGLE-LINE `blocker:` lines with no preceding detail line. Some interpolate
#   values computed only INSIDE this function ($ledger_run_id, $canon_ledger, $canon_ledger_dir),
#   so this function PRINTS the exact reason text (UNPREFIXED, no `blocker: `) to STDOUT and
#   returns 1; the engine captures that stdout and re-emits it through blocker() (adding the
#   `blocker: ` prefix + exit 1). One printed line in, one `blocker:` line out — matching the
#   pre-extraction single-line shape exactly.
#
#   The SUCCESS path's two stdout lines are unchanged; success and SHAPE-B failure are mutually
#   exclusive by return, so the engine's single stdout capture serves both. No `2>&1` is used on
#   any read, so inner-helper / SHAPE-B stderr never leaks onto the success stdout. NEVER exits.
#   Return codes: 0 success (two stdout lines); 2 ancestor-guard reject (stdout empty);
#   6 leaf-guard reject (stdout empty); 1 any SHAPE-B failure (reason on stdout).
hivemind_open_ledger() {
  local repo_root="$1"
  local run_id="$2"

  # ── DERIVE the ledger path from git-root + run_id (NO caller path) ─────────────
  local ledger="$repo_root/.hivemind/runs/$run_id/state.json"

  # ── Depth-complete canonical-containment guard (shared helper) — BEFORE any ledger read ──
  # The shared helper walks EVERY component of the FULL chain (INCLUDING the <run_id> leaf)
  # and rejects any existing symlink component at ANY depth, then verifies the deepest existing
  # prefix stays inside the checkout — BEFORE any read, mktemp, or mv, so a rejection never
  # opens or creates a file and the on-disk ledger is byte-unchanged. Its STDOUT is captured
  # (the canonical root); its STDERR is left UNCAPTURED so the helper's own detail line flows
  # to fd2 as the FIRST of the two byte-preserved lines (the engine adds the second, `blocker:`
  # line). Capturing stdout alone (no `2>&1`) keeps that detail line on fd2.
  local canon_repo_root
  if ! canon_repo_root="$(hivemind_assert_contained "$repo_root" ".hivemind/runs/$run_id")"; then
    return 2
  fi
  if [ -z "$canon_repo_root" ]; then
    printf 'failed to canonicalize repo root %s; ledger unchanged\n' "$repo_root"
    return 1
  fi

  # Canonicalize the contained runs dir, then require the ledger live at
  # "$canon_runs/<run_id>/state.json". Trailing-slash-guarded prefix so a sibling like
  # .hivemind/runs-evil cannot prefix-match.
  local canon_runs
  canon_runs="$(cd "$canon_repo_root/.hivemind/runs" && pwd -P)"
  if [ -z "$canon_runs" ]; then
    printf 'failed to canonicalize %s/.hivemind/runs; ledger unchanged\n' "$canon_repo_root"
    return 1
  fi
  case "$canon_runs/$run_id/state.json/" in
    "$canon_runs/"*) : ;;
    *)
      printf 'ledger resolves outside the checkout runs dir; ledger unchanged\n'
      return 1
      ;;
  esac

  # ── Ledger-read LEAF guard (shared helper) — rejects a symlinked state.json LEAF ──
  # The ancestor/runs-dir guard above proves the chain DOWN TO the <run_id> run-dir but does
  # NOT inspect the state.json leaf itself. This shared helper [ -L ]-rejects the leaf on the
  # RAW path FIRST (firing even for a dangling target) before any [ -f ]/jq read. Its STDERR
  # is left UNCAPTURED (only STDOUT `>/dev/null`'d) so its detail line flows to fd2 as the
  # FIRST of the two byte-preserved lines for this reject.
  if ! hivemind_assert_ledger_contained "$repo_root" "$ledger" >/dev/null; then
    return 6
  fi

  if [ ! -f "$ledger" ]; then
    printf 'ledger file does not exist: %s\n' "$ledger"
    return 1
  fi
  if ! jq -e . "$ledger" >/dev/null 2>&1; then
    printf 'ledger file is not valid JSON: %s\n' "$ledger"
    return 1
  fi

  # ── COHERENCE CHECK: the on-disk ledger must self-identify with the passed run_id ──
  local ledger_run_id
  ledger_run_id="$(jq -r '.run.id // ""' "$ledger")"
  if [ "$ledger_run_id" != "$run_id" ]; then
    printf "ledger run.id '%s' does not match run_id '%s'; ledger unchanged\n" "$ledger_run_id" "$run_id"
    return 1
  fi

  # ── Post-existence canonical ledger-dir confirmation ───────────────────────────
  # Now that the ledger file is confirmed to exist, canonicalize its own dir and re-verify the
  # leaf/dir basenames against the contained runs dir.
  local canon_ledger_dir canon_ledger
  canon_ledger_dir="$(cd "$(dirname "$ledger")" && pwd -P)"
  if [ -z "$canon_ledger_dir" ]; then
    printf 'failed to canonicalize the ledger directory; ledger unchanged\n'
    return 1
  fi
  canon_ledger="$canon_ledger_dir/state.json"
  case "$canon_ledger/" in
    "$canon_runs/"*) : ;;
    *)
      printf 'ledger resolves outside the checkout runs dir: %s; ledger unchanged\n' "$canon_ledger"
      return 1
      ;;
  esac
  if [ "$(basename "$canon_ledger")" != "state.json" ]; then
    printf 'canonical ledger leaf is not state.json: %s; ledger unchanged\n' "$canon_ledger"
    return 1
  fi
  if [ "$(basename "$canon_ledger_dir")" != "$run_id" ]; then
    printf "canonical ledger dir name does not match run_id '%s': %s; ledger unchanged\n" "$run_id" "$canon_ledger_dir"
    return 1
  fi

  # SUCCESS: echo the canonical ledger path + canonical ledger dir as two stable lines.
  printf '%s\n%s\n' "$canon_ledger" "$canon_ledger_dir"
  return 0
}
