#!/usr/bin/env bash
#
# next-wave — READ-ONLY deterministic ready-wave engine for the hivemind:next-wave skill.
#
# Computes the READY SET and the next dispatchable WAVE of plan steps for the intra-run
# parallel-wave implement loop. This is the engine that lets the overlord fan out
# independent plan steps concurrently while preserving today's serial behavior when the
# plan graph forces it. It reads the run ledger and PRINTS a routing decision; it mutates
# NOTHING (no ledger write, no temp file, no atomic rename) — a pure read -> derive -> emit
# engine. It sits in the same committed-script engine-op family as record-state-result.sh /
# init-run-ledger.sh (shebang, blocker() helper, jq parsing into inert variables, structured
# YAML routing on stdout, exit codes) and REUSES their shared read/containment machinery.
#
# INPUT (single positional argument):
#   $1  run_id — the ONLY caller identity. A bare scalar positional (NOT an inputs-file path)
#       is used DELIBERATELY: the sole input is a charset-constrained identity token, so the
#       inert Write-tool inputs-file transport (which exists to carry UNTRUSTED free-form text
#       injection-safely, e.g. record-state-result's summary/outputs) buys nothing here. run_id
#       never enters generated shell/jq SOURCE — it is validated by SAFE_ID_RE + reserved-
#       component reject and referenced only as "$run_id". This keeps the caller surface minimal
#       while holding the family's containment posture: NO caller-supplied PATH is ever accepted.
#
# PATH POSTURE — DERIVE-ONLY, READ-ONLY:
#   The engine NEVER accepts a path. It DERIVES the ledger as
#   "<git-root>/.hivemind/runs/<run_id>/state.json" (repo_root = git rev-parse --show-toplevel;
#   empty = not inside a checkout = blocker). The ledger read is routed through the SHARED
#   ledger-open guard (hivemind_open_ledger): depth-complete ancestor containment, canonical
#   runs-dir prefix-match, symlinked-state.json-LEAF reject, existence + JSON-validity, and the
#   coherence check (.run.id == run_id) — ALL before any jq read of ledger content. A
#   caller-supplied ledger path (arbitrary-file read) is therefore structurally impossible.
#
# COMPUTATION (all derived from ledger content; NEVER from plan.steps[].status):
#   1. steps       = .plan.steps[]  (each: id, owner, files[], depends_on[], status).
#   2. DONE SET    = union of every .events[].outputs.completed_steps[] (a flat list of
#                    step-id strings), de-duplicated. Done-ness lives in EVENTS, never in
#                    plan.steps[].status (which stays planner-emitted `pending`); the engine
#                    must not depend on that status field.
#   3. READY       = steps NOT in done whose depends_on is a SUBSET of done.
#   4. WAVE        = greedy, PLAN-ORDER, maximal subset of READY that is pairwise FILE-DISJOINT.
#                    Disjointness = exact normalized-path textual match (normalize: collapse
#                    repeated slashes, strip leading `./`). Walk READY in plan order; add a step
#                    iff its normalized file set shares NO path with any file already claimed by
#                    an earlier wave member.
#   5. CONFLICTS-WITH-ALL guard (conservative): any step whose files[] contains a glob
#                    metacharacter (`*`, `?`, `[`), a trailing `/`, OR a path that is a
#                    directory-prefix of ANOTHER step's file entry is treated as conflicting
#                    with everything — it may ONLY run ALONE (a wave of exactly itself). This
#                    protects against planner-underdeclared/vague scopes forcing unsafe
#                    concurrency.
#
# VALIDATION (all fail-closed -> `blocker: <reason>` on stderr, exit 1, nothing on stdout):
#   - empty / absent plan.steps
#   - a step missing an id
#   - duplicate step ids
#   - a depends_on referencing an unknown step id
#   - a dependency cycle
#   - remaining > 0 but wave empty with no cycle (defensive; a cycle-free acyclic notdone
#     subgraph always has a ready minimal element, so this cannot occur without a cycle)
#   - ledger missing / not valid JSON / not inside a git checkout / containment rejection
#     (delegated to the shared hivemind_open_ledger guard)
#
# OUTPUT on success (exit 0), YAML routing lines on stdout (mirrors the sibling engines'
# YAML routing style):
#     all_done: true|false
#     wave: [STEP-00X, STEP-00Y]     # step ids to dispatch this iteration; [] when all_done
#     remaining: <N>                 # count of not-done steps
#   all_done is true IFF the done set covers every step (wave empty, remaining 0).
#
# EXIT CONTRACT:
#   0  wave computed; routing YAML on stdout
#   1  validation failure / containment rejection (nothing on stdout)
#
# SHELL FLOOR: full P18 `set -euo pipefail`. The one nonzero-returning helper this engine must
# INSPECT (hivemind_open_ledger returns 0/1/2/6) is called as an `if` condition, which suppresses
# errexit throughout the function body — so its documented return codes stay inspectable while the
# floor still guards this engine's own top-level statements.

set -euo pipefail

blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# SAFE_ID charset for the run_id identity component (mirrors the sibling engines). The reserved
# components "." and ".." pass this class but are rejected explicitly (path traversal).
SAFE_ID_RE='^[A-Za-z0-9._-]+$'

# ── Script self-location (portable; independent of ${CLAUDE_PLUGIN_ROOT} and the caller) ──
# Resolve the plugin root from THIS script's own location, never from a caller value.
# `cd ... && pwd -P` is portable (no GNU-only readlink -f); BASH_SOURCE is set under
# `#!/usr/bin/env bash`. Layout: plugin/skills/next-wave/scripts/ => 3 dirs up is the plugin root.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$(cd "$script_dir/../../.." && pwd -P)"

# Source the shared containment helper ONCE, early. hivemind_open_ledger (sourced next)
# ORCHESTRATES its guards (hivemind_assert_contained / hivemind_assert_ledger_contained), so
# containment.sh MUST be sourced first. SOURCE-OR-DIE: a missing/unparseable shared library
# fails closed BEFORE any consumer logic — the ledger-read containment guards live in these
# libs, so proceeding without them would silently disarm containment.
[ -f "$plugin_root/skills/_shared/containment.sh" ] || blocker "required shared library missing: skills/_shared/containment.sh; refusing to proceed"
. "$plugin_root/skills/_shared/containment.sh" || blocker "failed to source skills/_shared/containment.sh (unparseable); refusing to proceed"

# Source the shared ledger engine-IO helper by the SAME self-located absolute path. It provides
# hivemind_open_ledger (the depth-complete ledger-read/containment/coherence chain). This engine
# READS an existing ledger, so it uses hivemind_open_ledger (NOT hivemind_read_inputs_file, which
# is for the inputs-file navigators). The helper ORCHESTRATES the containment.sh helpers above,
# so this MUST follow that source.
[ -f "$plugin_root/skills/_shared/ledger-engine-io.sh" ] || blocker "required shared library missing: skills/_shared/ledger-engine-io.sh; refusing to proceed"
. "$plugin_root/skills/_shared/ledger-engine-io.sh" || blocker "failed to source skills/_shared/ledger-engine-io.sh (unparseable); refusing to proceed"

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to read the run ledger but is not installed"

# ── Input: run_id (the ONLY caller identity) ──────────────────────────────────
run_id="${1:-}"
[ -n "$run_id" ] || blocker "missing required argument: run_id (\$1)"

# run_id must be a single safe path component (SAFE_ID_RE + reserved-component reject). This is
# the ONLY identity the caller supplies; every path below is derived from it.
printf '%s' "$run_id" | grep -Eq "$SAFE_ID_RE" \
  || blocker "run_id is not a safe path component: $run_id"
case "$run_id" in
  .|..) blocker "run_id is a reserved path component: $run_id" ;;
esac

# ── DERIVE the ledger path from git-root + run_id (NO caller path) ─────────────
# repo_root anchors the ledger to the checkout root, mirroring the sibling engines. Empty =
# not inside a git checkout = blocker. Guarded with `|| repo_root=""` so a non-repo `git`
# exit (128) does not trip errexit before the emptiness check reports the friendly blocker.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
[ -n "$repo_root" ] || blocker "not inside a git repository"
ledger="$repo_root/.hivemind/runs/$run_id/state.json"

# ── Ledger-open machinery (shared helper) — BEFORE any ledger read ─────────────
# hivemind_open_ledger performs, IN EXACT ORDER: ledger-path derivation, ancestor containment,
# canonical runs-dir prefix guard, the symlinked-state.json-LEAF reject, `[ -f ]` existence +
# `jq -e .` validity, and the coherence check (.run.id == run_id). On SUCCESS it returns 0 with
# NO stdout; the consumer DERIVES the canonical ledger path locally. The helper never exits.
# Called as an `if` condition so its nonzero returns (2 ancestor reject, 6 leaf reject, 1 any
# other failure) stay inspectable under `set -e` (errexit is suppressed inside a function run
# as an `if` condition). Failure-shape parity with the sibling engines: for 2/6 the inner
# helper's own UNPREFIXED detail line already flowed to fd2 (uncaptured); for 1 the reason text
# is on the captured stdout and re-emitted through blocker().
if ledger_open_out="$(hivemind_open_ledger "$repo_root" "$run_id")"; then
  ledger_open_rc=0
else
  ledger_open_rc=$?
fi
case $ledger_open_rc in
  0)
    # Containment/coherence proven by return 0. DERIVE the canonical ledger path LOCALLY now,
    # ONLY in this arm, AFTER the helper validated the path. FAIL-CLOSED: guard the `cd` status
    # AND emptiness so a run dir that vanished mid-flight cannot leave an empty path.
    if ! canon_ledger_dir="$(cd "$(dirname "$ledger")" && pwd -P)" || [ -z "$canon_ledger_dir" ]; then
      blocker "failed to canonicalize the ledger directory; ledger unchanged"
    fi
    ledger="$canon_ledger_dir/state.json"
    ;;
  2) blocker "refusing: ${repo_root}/.hivemind/runs/$run_id resolves outside the checkout (symlinked ancestor or leaf)" ;;
  6) blocker "refusing to read the ledger: $ledger resolves outside the checkout (symlinked ancestor or leaf)" ;;
  *) blocker "$ledger_open_out" ;;
esac

# ── Validation (all before the wave computation) ──────────────────────────────
# (a) plan.steps present and non-empty.
steps_len="$(jq '(.plan.steps // []) | length' "$ledger")"
[ "$steps_len" -gt 0 ] || blocker "plan.steps is empty or absent; nothing to schedule"

# (b) every step carries a non-empty id.
missing_id="$(jq '[.plan.steps[] | select((.id // "") == "")] | length' "$ledger")"
[ "$missing_id" = "0" ] || blocker "a plan step is missing an id"

# (c) no duplicate step ids (report the first offender).
dup_id="$(jq -r '[.plan.steps[].id] | (group_by(.) | map(select(length > 1) | .[0]))[0] // empty' "$ledger")"
[ -z "$dup_id" ] || blocker "duplicate plan step id: $dup_id"

# (d) every depends_on references a known step id (report the first offender).
unknown_dep="$(jq -r '
  [.plan.steps[].id] as $ids
  | [ .plan.steps[] | (.depends_on // [])[] as $d | select(($ids | index($d)) == null) | $d ]
  | .[0] // empty' "$ledger")"
[ -z "$unknown_dep" ] || blocker "depends_on references unknown step id: $unknown_dep"

# (e) no dependency cycle. Kahn-style peel: each pass removes every node whose deps are all
# already removed; after N passes an acyclic graph is fully drained. Any residue is a cycle
# (self-dependency included — a node depending on itself never drains).
cycle_residue="$(jq '
  .plan.steps as $steps
  | ([$steps[] | {key: .id, value: (.depends_on // [])}] | from_entries) as $deps
  | reduce range(0; ($steps | length)) as $_ (
      [$steps[].id];
      . as $rem
      | ($rem | map(select(. as $id | ($deps[$id] // []) | any(. as $d | ($rem | index($d)) != null) | not))) as $ready
      | ($rem - $ready)
    )
  | length' "$ledger")"
[ "$cycle_residue" = "0" ] || blocker "dependency cycle detected among plan steps"

# ── Wave computation (single jq program; emits tab-separated routing facts) ────
# Emits: <remaining>\t<all_done>\t<wave_count>\t<wave_display>
#   norm_path       collapse repeated slashes, then strip leading `./` (exact-path
#                   normalization for disjointness — compares DECLARED paths, not filesystem
#                   existence, so two steps declaring the same NOT-YET-EXISTING path still clash).
#   $done           union of events[].outputs.completed_steps[] (done-ness lives in events).
#   .ca             conflicts-with-all: glob metachar, trailing slash, or a file that is a
#                   directory-prefix (f + "/") of ANOTHER step's file. Such a step runs ALONE.
#   greedy reduce   walk READY in plan order; the first step always joins (locking the wave to
#                   itself when it is conflicts-with-all); each subsequent non-conflicting step
#                   joins iff file-disjoint from the already-claimed set.
main="$(jq -r '
  def norm_path: gsub("/+"; "/") | gsub("^(\\./)+"; "");
  .plan.steps as $steps
  | ([.events[]?.outputs?.completed_steps[]?] | unique) as $done
  | ($steps | map(. + {nf: ((.files // []) | map(norm_path))})) as $S
  | ([$S[] | .id as $id | .nf[] | {id: $id, f: .}]) as $allfiles
  | ($S | map(
      .id as $id | .nf as $nf
      | . + {ca: (
          ($nf | any(test("[*?\\[]")))
          or ($nf | any(endswith("/")))
          or ($nf | any(. as $f | $allfiles | any((.id != $id) and (.f | startswith($f + "/")))))
        )}
    )) as $S2
  | ($S2 | map(select(.id as $id | ($done | index($id)) == null))) as $notdone
  | ($notdone | length) as $remaining
  | ($notdone | map(select((.depends_on // []) | all(. as $d | ($done | index($d)) != null)))) as $ready
  | (reduce $ready[] as $st (
        {wave: [], claimed: [], locked: false};
        . as $acc
        | if $acc.locked then $acc
          elif $st.ca then
            (if ($acc.wave | length) == 0 then {wave: [$st.id], claimed: $st.nf, locked: true} else $acc end)
          elif ($st.nf | any(. as $f | ($acc.claimed | index($f)) != null)) then $acc
          else {wave: ($acc.wave + [$st.id]), claimed: ($acc.claimed + $st.nf), locked: false}
          end
      ) | .wave) as $wave
  | [
      ($remaining | tostring),
      (($remaining == 0) | tostring),
      ($wave | length | tostring),
      (if ($wave | length) == 0 then "[]" else "[" + ($wave | join(", ")) + "]" end)
    ] | join("\t")
' "$ledger")"

IFS=$'\t' read -r remaining all_done wave_count wave_display <<< "$main"

# Defensive: a cycle-free notdone subgraph always exposes a ready minimal element, so a
# non-empty remainder with an empty wave is unreachable without a cycle (already rejected).
# Guard it anyway — fail closed rather than emit a stalled, actionless wave.
if [ "$remaining" -gt 0 ] && [ "$wave_count" -eq 0 ]; then
  blocker "remaining steps exist but no step is ready (unsatisfiable dependencies); ledger unchanged"
fi

# ── Success routing ───────────────────────────────────────────────────────────
printf 'all_done: %s\n' "$all_done"
printf 'wave: %s\n' "$wave_display"
printf 'remaining: %s\n' "$remaining"
exit 0
