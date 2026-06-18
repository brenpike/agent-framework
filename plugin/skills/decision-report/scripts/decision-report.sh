#!/usr/bin/env bash
#
# decision-report — containment-checked persist engine for the hivemind:decision-report
# skill. The skill RENDERS the post-merge decision narrative (the deliverable, returned to
# chat); this engine performs ONLY the final persist-to-disk hop: it DERIVES the report path
# from identity, containment-guards the write-target LEAF, and writes the rendered narrative
# atomically. The skill body is a thin navigator that authors an inert inputs file and calls
# this script once. Mirrors the record-state-result.sh / init-run-ledger.sh committed-script
# precedent (shebang, P18 floor, blocker() helper, jq parsing into inert variables, structured
# stdout routing, exit codes).
#
# WHY THIS ENGINE EXISTS (F1 P0 — Inert Inputs-File Navigator transport-path invariant #1):
# the skill formerly wrote the report to <git-root>/.hivemind/runs/<run_id>/decision-report.md
# with the agent Write tool. <run_id> sits BELOW the fixed-literal .hivemind/runs/ level and is
# CALLER-DERIVED; a committed symlinked <run_id> dir OR a symlinked decision-report.md leaf
# redirects that Write OUTSIDE the checkout BEFORE any inline realpath check runs (the agent
# Write fires first — an inline check is UNSOUND). Per security-policy.md (Inert Inputs-File
# Navigator Pattern → Transport-path invariant #1), the agent Write is demoted to a
# fixed-literal inert inputs file (.hivemind/runs/.decision-report-inputs-<token>.json, no
# caller-derived component below the fixed level) and THIS committed engine derives the report
# path, runs the shared containment guard on the resolved write-target leaf, and writes — so
# the symlink-escape is rejected by a canonical-containment guard ahead of the write.
#
# PATH POSTURE — the engine NEVER accepts a report path as input. It DERIVES the report path
# from identity: repo_root="$(git rev-parse --show-toplevel)" then
# "$repo_root/.hivemind/runs/<run_id>/decision-report.md". <run_id> comes from the inputs file,
# SAFE_ID_RE-validated and ./.. -rejected. The ONLY path on the command line is $1, the
# inputs-file authored by the trusted skill via Write.
#
# INJECTION POSTURE: the untrusted field report_markdown (the rendered narrative — the agent
# produced it from the untrusted ledger journal) is read from the inputs file with jq into an
# inert shell variable and written to the report file via a TEMP FILE; it never enters the jq
# program SOURCE, the shell command source, or any path. The ONLY value passed on the command
# line is the trusted inputs-file path. report_markdown reaches disk solely as the body of a
# `printf '%s'`-piped temp write.
#
# INPUT (single positional argument):
#   $1  Absolute or repo-relative path to a JSON inputs file authored by the agent via the
#       Write tool. The agent writes structured data; this script parses it with jq into shell
#       VARIABLES. Untrusted bytes in the JSON are read into variables and referenced only as
#       "$var" — bash does not re-evaluate command substitution from variable contents, so the
#       command-substitution injection class is structurally absent. Mirrors record-state-result.sh.
#
#   Inputs JSON shape (authoritative schema in SKILL.md § Inputs JSON):
#     {
#       "run_id":          "<required> identity of the run; the report path is DERIVED from it
#                           as <git-root>/.hivemind/runs/<run_id>/decision-report.md. NO path
#                           is accepted.",
#       "report_markdown": "<required> the rendered narrative text the agent produced —
#                           UNTRUSTED, serialized only, written via a temp file, never
#                           interpolated into shell/jq source.",
#       "pr_state":        "<required> the resolved PR state, exactly MERGED or CLOSED — used
#                           only to validate the caller resolved a state (the narrative already
#                           carries the abandoned callout when CLOSED)."
#     }
#
# OUTPUT:
#   - On success: writes the report atomically and prints YAML routing lines:
#       run_id: <run_id>
#       report: <path>
#     Exits 0.
#   - On any failure / containment reject: prints `blocker: <reason>` to stderr, exits 1, no write.
#
# EXIT CONTRACT:
#   0  report written
#   1  validation failure / containment reject (no write)
#
# P18 FLOOR (ADR-0020): this engine carries the FULL `set -euo pipefail` floor — it has no
# key-presence jq probes and no blocker-routed non-zero-in-normal-flow checks that the floor
# would abort, so NO CHECK13 allowlist entry is needed. blocker() exits 1 explicitly; every
# guarded command routes its failure through blocker() before the floor could fire.

set -euo pipefail

blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# SAFE_ID charset for the run_id identity component (mirrors record-state-result.sh). The
# reserved components "." and ".." pass this class but must be rejected explicitly (traversal).
SAFE_ID_RE='^[A-Za-z0-9._-]+$'

# ── Script self-location (portable; independent of ${CLAUDE_PLUGIN_ROOT} and the caller) ──
# Resolve the plugin root from THIS script's own location, never from a caller value.
# `cd ... && pwd -P` is portable (no GNU-only readlink -f); BASH_SOURCE is set under
# `#!/usr/bin/env bash`. Layout: plugin/skills/decision-report/scripts/ => 3 dirs up is the
# plugin root (verified against the real tree).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$(cd "$script_dir/../../.." && pwd -P)"

# Source the shared containment helper by the self-located absolute path. It provides
# hivemind_assert_file_contained (the write-target LEAF guard used before the report write).
# SOURCE-OR-DIE: a missing or unparseable shared library fails closed BEFORE any consumer
# logic — the containment guard lives in this lib, so proceeding without it would silently
# disarm the guard.
[ -f "$plugin_root/skills/_shared/containment.sh" ] || blocker "required shared library missing: skills/_shared/containment.sh; refusing to proceed"
. "$plugin_root/skills/_shared/containment.sh" || blocker "failed to source skills/_shared/containment.sh (unparseable); refusing to proceed"

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to read the decision-report inputs file but is not installed"

# ── Inputs file ───────────────────────────────────────────────────────────────
# Single positional argument: the path to a JSON inputs file the agent authored via the Write
# tool. The path is the ONLY value passed on the command line; every field (including the
# untrusted report_markdown) is read with jq into inert variables below — never interpolated
# into bash source, the jq program SOURCE, or any path.
INPUTS_FILE="${1:-}"
[ -n "$INPUTS_FILE" ] || blocker "missing required argument: path to decision-report inputs JSON file (\$1)"
[ -f "$INPUTS_FILE" ] || blocker "decision-report inputs file $INPUTS_FILE does not exist"

# Defense-in-depth inputs READ-guard: refuse to READ the inputs file when its canonical path
# escapes the checkout (e.g. via a symlinked ancestor or leaf). This runs BEFORE the `jq -e`
# validity probe — `jq -e` opening an attacker path is itself a JSON-validity read oracle. The
# helper never exits; its STDERR is left UNCAPTURED so its detail line flows to fd2 ABOVE the
# blocker line. Mirrors the three engines' read-guard call (the two-line stderr shape).
if ! hivemind_assert_inputs_contained "$(git rev-parse --show-toplevel 2>/dev/null)" "$INPUTS_FILE" >/dev/null; then
  blocker "refusing to read the inputs file: $INPUTS_FILE resolves outside the checkout (symlinked ancestor or leaf)"
fi

jq -e . "$INPUTS_FILE" >/dev/null 2>&1 || blocker "decision-report inputs file $INPUTS_FILE is not valid JSON"

# ── Parse fields into inert variables ─────────────────────────────────────────
run_id="$(jq -r '.run_id // ""' "$INPUTS_FILE")"
report_markdown="$(jq -r '.report_markdown // ""' "$INPUTS_FILE")"
pr_state="$(jq -r '.pr_state // ""' "$INPUTS_FILE")"

# ── Required-input validation ─────────────────────────────────────────────────
[ -n "$run_id" ]          || blocker "inputs file is missing required run_id"
[ -n "$report_markdown" ] || blocker "inputs file is missing required report_markdown"
[ -n "$pr_state" ]        || blocker "inputs file is missing required pr_state"

# pr_state must be exactly MERGED or CLOSED (the caller resolves PR state before invoking).
case "$pr_state" in
  MERGED|CLOSED) : ;;
  *) blocker "pr_state must be MERGED or CLOSED, got: $pr_state" ;;
esac

# run_id must be a single safe path component (SAFE_ID_RE + reserved-component reject). This is
# the ONLY identity the caller supplies; the report path below is derived from it.
printf '%s' "$run_id" | grep -Eq "$SAFE_ID_RE" \
  || blocker "run_id is not a safe path component: $run_id"
case "$run_id" in
  .|..) blocker "run_id is a reserved path component: $run_id" ;;
esac

# ── DERIVE the report path from git-root + run_id (NO caller path) ─────────────
# repo_root anchors the report to the checkout root, mirroring record-state-result.sh. Empty =
# not inside a git checkout = blocker.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo_root" ] || blocker "not inside a git repository"

# ── Write-target LEAF containment guard (shared helper) — BEFORE any write ─────
# The report write-target leaf is <run_id>/decision-report.md, where <run_id> is caller-derived
# and sits BELOW the fixed-literal .hivemind/runs/ level. A committed symlinked <run_id> dir OR
# a symlinked decision-report.md leaf would redirect the write OUTSIDE the checkout. The shared
# hivemind_assert_file_contained guard walks EVERY ancestor component of the chain (rejecting any
# symlinked ancestor, e.g. the <run_id> dir) AND [ -L ]-rejects a symlinked leaf, then echoes the
# CANONICAL checkout root. We derive the write paths from that canonical root so the temp-write +
# atomic mv operate on the verified-contained path. The helper never exits; a non-zero return or
# empty canon_root maps to our blocker (its own detail line flows to fd2 ABOVE the blocker line).
report_chain=".hivemind/runs/$run_id/decision-report.md"
canon_repo_root="$(hivemind_assert_file_contained "$repo_root" "$report_chain")" \
  || blocker "refusing to write the decision report: ${canon_repo_root:-$repo_root}/$report_chain resolves outside the checkout (symlinked ancestor or leaf)"
[ -n "$canon_repo_root" ] || blocker "failed to canonicalize repo root $repo_root"

# Derive the run dir + report path from the CANONICAL root (not the raw $repo_root) so the
# subsequent mkdir -p / mktemp / mv all operate on the verified-contained canonical path.
run_dir="$canon_repo_root/.hivemind/runs/$run_id"
report_path="$run_dir/decision-report.md"

# The run dir is expected to exist (the run ledger lives there); create it -p defensively so a
# fresh report write does not fail if only the runs/ ancestor exists. The containment guard
# above proved every existing component of the chain is symlink-free and in-checkout.
mkdir -p "$run_dir" || blocker "failed to create run dir $run_dir"

# ── Atomic write: temp file in the run dir, then mv into place ─────────────────
# Temp file lives in the same directory as the target so the rename is on the same filesystem
# (atomic). report_markdown is written via `printf '%s'` into the temp file — it never enters
# any command/program source. On a failure the temp file is removed and no partial report
# leaks.
tmp_report="$(mktemp "$run_dir/.decision-report.md.XXXXXX")" \
  || blocker "failed to create temp report file under $run_dir"

printf '%s' "$report_markdown" > "$tmp_report" \
  || { rm -f "$tmp_report"; blocker "failed to write the rendered narrative to the temp report file; no report written"; }

mv -f "$tmp_report" "$report_path" \
  || { rm -f "$tmp_report"; blocker "failed to atomically install the decision report at $report_path; no report written"; }

# ── Success routing ───────────────────────────────────────────────────────────
printf 'run_id: %s\n' "$run_id"
printf 'report: %s\n' "$report_path"
exit 0
