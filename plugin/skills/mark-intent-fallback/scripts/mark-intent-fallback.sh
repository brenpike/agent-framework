#!/usr/bin/env bash
#
# mark-intent-fallback — sanctioned version-skew resume write-path for the
# hivemind:mark-intent-fallback skill (issue #160).
#
# Provides the resume door that record-state-result.sh DELIBERATELY refuses: it appends an
# intent-fallback event to the run ledger and (optionally) closes the run WITHOUT
# transition-validation and WITHOUT the version-binding guard — the EXACT two conditions
# record-state-result.sh hard-rejects. It is the sole sanctioned write-path for a run whose
# ledger no longer binds to a packaged workflow definition (version skew), so the overlord
# resume-on-start gate's "proceed intent-driven" door has a deterministic ledger writer
# instead of an unreachable rebind.
#
# WHAT IT DELIBERATELY SKIPS (this is the whole point — see issue #160):
#   - NO workflow-definition derivation/read. The skewed run may reference a definition
#     version no longer packaged; reading it is neither possible nor required here.
#   - NO binding guard (definition.id / version vs ledger). Skew is the precondition, not a
#     failure — record-state-result.sh owns the hard-reject half of the §I policy; this is
#     the intent-driven half.
#   - NO state-existence check (the recorded state is NOT validated against any definition).
#   - NO transition/result validation, NO next_state resolution, NO terminal mapping.
#   - NO binding/version precondition on the closeout path either — that guard stays
#     deliberately skipped. The ONLY closeout precondition is the narrow footgun guard below:
#     when close_status is supplied, the on-disk run.status MUST be exactly "running" (you
#     cannot close out an already-terminal run). The bare mode-flip path (no close_status)
#     stays fully permissive and may run on a non-running skew ledger.
#
# WHAT IT REUSES IDENTICALLY from record-state-result.sh (security posture is unchanged):
#   - Identity derivation: run_id is the ONLY identity the caller supplies; the ledger path
#     is DERIVED as <git-root>/.hivemind/runs/<run_id>/state.json. NO path is accepted.
#   - SAFE_ID_RE + ./.. reject on run_id; coherence check (ledger.run.id == run_id).
#   - Inputs-file READ-guard + depth-complete write-chain containment (shared helper).
#   - Atomicity: every write is temp-write + atomic mv on the CANONICAL contained path; on
#     ANY validation failure the on-disk ledger is byte-unchanged (all validation runs
#     BEFORE the temp file is created).
#
# INJECTION POSTURE: the untrusted fields state, summary, and outputs are read from the
# inputs file with jq into inert shell variables and serialized via jq --arg / --argjson
# ONLY; they never enter the jq program or any shell command source. The ONLY value passed on
# the command line is the trusted inputs-file path ($1).
#
# INPUT (single positional argument):
#   $1  Absolute or repo-relative path to a JSON inputs file authored by the navigator skill
#       via the Write tool.
#
#   Inputs JSON shape (authoritative schema in SKILL.md § Inputs JSON):
#     {
#       "run_id":       "<required> identity of the run; the ledger path is DERIVED from it.
#                        NO path is accepted.",
#       "state":        "<required> state string recorded verbatim in the appended event;
#                        NOT validated against any definition — UNTRUSTED, serialized only.",
#       "summary":      "<required> human-readable summary — UNTRUSTED, serialized only",
#       "outputs":      { ... },   // optional JSON object — UNTRUSTED, serialized only.
#                                  // KEY-PRESENCE semantics: a MISSING key OR a present-but-
#                                  // null value is ABSENT (-> defaults to {}); a present
#                                  // non-null value is SUPPLIED.
#       "close_status": "cancelled" | "complete"
#                                  // OPTIONAL. When present MUST be exactly "cancelled" or
#                                  // "complete" (anything else, notably "abandoned", is
#                                  // REJECTED). When absent, run.status is left untouched
#                                  // (the run stays running).
#     }
#
# OUTPUT:
#   - On success: writes the mutated ledger atomically and prints YAML routing lines:
#       run_id: <run_id>
#       mode: intent_fallback
#       status: <resulting run.status — close_status if supplied, else "running">
#       ledger: <canonical ledger path>
#     Exits 0.
#   - On any failure: prints `blocker: <reason>` to stderr, exits 1, ledger byte-unchanged.
#
# EXIT CONTRACT:
#   0  intent-fallback event recorded (and run optionally closed)
#   1  validation failure (ledger UNCHANGED)
#
# set -u: an unset variable is a programming error (every value is parsed from the inputs
# file). No `set -e`: failures route through blocker() with a verbose reason.

set -u

blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# SAFE_ID charset for identity components (mirrors record-state-result.sh). The reserved
# components "." and ".." pass this class but must be rejected explicitly (path traversal).
SAFE_ID_RE='^[A-Za-z0-9._-]+$'

# ── Script self-location (portable; independent of ${CLAUDE_PLUGIN_ROOT} and the caller) ──
# Resolve the plugin root from THIS script's own location, never from a caller value.
# `cd ... && pwd -P` is portable (no GNU-only readlink -f); BASH_SOURCE is set under
# `#!/usr/bin/env bash`. Layout: plugin/skills/mark-intent-fallback/scripts/ => 3 dirs up is
# the plugin root. This script reads NO workflow definition, so workflows_dir is not needed.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$(cd "$script_dir/../../.." && pwd -P)"

# Source the shared containment helper ONCE, early — it provides both the inputs-file
# READ-guard (hivemind_assert_inputs_contained) and the write-chain guard
# (hivemind_assert_contained, used before the ledger temp-write).
. "$plugin_root/skills/_shared/containment.sh"

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 \
  || blocker "jq is required to read and write the run ledger but is not installed"

# ── Inputs file ───────────────────────────────────────────────────────────────
# Single positional argument: the path to a JSON inputs file the agent authored via the
# Write tool. The path is the ONLY value passed on the command line; every field (including
# the untrusted state/summary/outputs) is read with jq into inert variables below — never
# interpolated into bash source or the jq program SOURCE.
INPUTS_FILE="${1:-}"
[ -n "$INPUTS_FILE" ] \
  || blocker "missing required argument: path to mark-intent-fallback inputs JSON file (\$1)"
[ -f "$INPUTS_FILE" ] \
  || blocker "mark-intent-fallback inputs file $INPUTS_FILE does not exist"

# ── Defense-in-depth inputs READ-guard (shared helper) ─────────────────────────
# Refuse to READ the inputs file when its canonical path escapes the checkout (e.g. via a
# symlinked ancestor) — converting a silent external-read into a hard blocker BEFORE the
# first jq read below (the JSON-validity probe AND every field read). Running this BEFORE the
# `jq -e` validity probe is REQUIRED: `jq -e` opening an attacker-supplied external path is
# itself an external-file JSON-validity read oracle, so the containment guard must gate it.
# The helper never exits; map non-zero to our blocker. The authoritative not-in-a-repo gate
# remains the repo_root check further below.
hivemind_assert_inputs_contained "$(git rev-parse --show-toplevel 2>/dev/null)" "$INPUTS_FILE" >/dev/null \
  || blocker "refusing to read the inputs file: $INPUTS_FILE resolves outside the checkout (symlinked ancestor)"

jq -e . "$INPUTS_FILE" >/dev/null 2>&1 \
  || blocker "mark-intent-fallback inputs file $INPUTS_FILE is not valid JSON"

# ── Parse fields into inert variables ─────────────────────────────────────────
# Required strings via `jq -r '.field // ""'`. The presence bools derive from KEY-PRESENCE on
# the inputs object: a MISSING key OR a present-but-null value is ABSENT; a present non-null
# value is SUPPLIED. Absent outputs defaults to {}; absent close_status leaves run.status
# untouched (run stays running).
run_id="$(jq -r '.run_id // ""' "$INPUTS_FILE")"
state="$(jq -r '.state // ""' "$INPUTS_FILE")"
summary="$(jq -r '.summary // ""' "$INPUTS_FILE")"

# have_outputs: outputs key present AND non-null. When supplied, read the raw JSON value
# (preserving its type for the up-front object check and the --argjson serialization).
if jq -e 'has("outputs") and .outputs != null' "$INPUTS_FILE" >/dev/null 2>&1; then
  have_outputs=true
  outputs="$(jq -c '.outputs' "$INPUTS_FILE")"
else
  have_outputs=false
  outputs=""
fi

# have_close_status: close_status key present AND non-null (-> run.status + state.status set
# to the validated value). Absent -> run.status left untouched (run stays running).
if jq -e 'has("close_status") and .close_status != null' "$INPUTS_FILE" >/dev/null 2>&1; then
  have_close_status=true
  close_status="$(jq -r '.close_status' "$INPUTS_FILE")"
else
  have_close_status=false
  close_status=""
fi

# ── Required-input validation ─────────────────────────────────────────────────
[ -n "$run_id" ]  || blocker "inputs file is missing required run_id"
[ -n "$state" ]   || blocker "inputs file is missing required state"
[ -n "$summary" ] || blocker "inputs file is missing required summary"

# run_id must be a single safe path component (SAFE_ID_RE + reserved-component reject). This
# is the ONLY identity the caller supplies; every path below is derived from it.
printf '%s' "$run_id" | grep -Eq "$SAFE_ID_RE" \
  || blocker "run_id is not a safe path component: $run_id"
case "$run_id" in
  .|..) blocker "run_id is a reserved path component: $run_id" ;;
esac

# ── DERIVE the ledger path from git-root + run_id (NO caller path) ─────────────
# repo_root anchors the ledger to the checkout root. Empty = not inside a git checkout =
# blocker. The caller never supplies a ledger path, so an arbitrary-file overwrite via a
# caller path is structurally impossible.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo_root" ] || blocker "not inside a git repository"
ledger="$repo_root/.hivemind/runs/$run_id/state.json"

# ── Depth-complete canonical-containment guard (shared helper) — BEFORE any ledger read ──
# Derive-from-ground-truth (repo_root) must be PAIRED with canonicalize-and-verify-
# containment, and that pairing MUST gate every ledger READ as well as the later write. The
# ledger path is derived TEXTUALLY as "$repo_root/.hivemind/runs/<run_id>/state.json"; that
# text does NOT confine access when ANY component of the chain is a SYMLINK pointing outside
# the checkout. Run this guard immediately after deriving repo_root/run_id and BEFORE the
# `[ -f "$ledger" ]` existence check, the `jq -e` JSON-validity probe, and the coherence read
# — otherwise an externally-resolved state.json would be opened by jq (a JSON-validity read
# oracle) and its `.run.id` could be echoed in the coherence blocker before rejection. The
# shared helper walks EVERY component of the FULL chain (INCLUDING the <run_id> leaf) and
# rejects any existing symlink component at ANY depth, then verifies the deepest existing
# prefix stays inside the checkout — BEFORE any read, mktemp, or mv. The state.json LEAF
# itself (a symlinked ledger file under a real run dir) is now [ -L ]-rejected by the
# dedicated hivemind_assert_ledger_contained guard below, before any [ -f ]/jq read,
# completing leaf-symmetry with the inputs-file and write-target leaves.
canon_repo_root="$(hivemind_assert_contained "$repo_root" ".hivemind/runs/$run_id")" \
  || blocker "refusing: ${canon_repo_root:-$repo_root}/.hivemind/runs/$run_id resolves outside the checkout (symlinked ancestor or leaf); ledger unchanged"
[ -n "$canon_repo_root" ] || blocker "failed to canonicalize repo root $repo_root; ledger unchanged"

# Canonicalize the contained runs dir, then require the ledger live at
# "$canon_runs/<run_id>/state.json". Trailing-slash-guarded prefix so a sibling like
# .hivemind/runs-evil cannot prefix-match. basename asserts confirm the leaf component is
# exactly <run_id> and the file is exactly state.json. The ledger's own dir is canonicalized
# only after its existence is confirmed below (cd into a not-yet-existing dir would fail), but
# the runs-dir containment proof above already gates the read path against a symlinked ancestor.
canon_runs="$(cd "$canon_repo_root/.hivemind/runs" && pwd -P)"
[ -n "$canon_runs" ] || blocker "failed to canonicalize $canon_repo_root/.hivemind/runs; ledger unchanged"
case "$canon_runs/$run_id/state.json/" in
  "$canon_runs/"*) : ;;
  *) blocker "ledger resolves outside the checkout runs dir; ledger unchanged" ;;
esac

# ── Ledger-read LEAF guard (shared helper) — rejects a symlinked state.json LEAF ──
# The ancestor/runs-dir guard above proves the chain DOWN TO the <run_id> run-dir but does
# NOT inspect the state.json leaf itself. When the run dir is real but state.json is a
# SYMLINK, the `[ -f "$ledger" ]`/`jq -e .`/`jq -r '.run.id'` reads below would FOLLOW it to
# an external target — a content/validity read oracle the ancestor guard never sees. This
# shared helper [ -L ]-rejects the leaf on the RAW path FIRST (firing even for a dangling
# target) before any [ -f ]/jq read, completing leaf-symmetry with the inputs-file and
# write-target leaves. A legitimate regular-file ledger is [ -L ]-false and passes through.
hivemind_assert_ledger_contained "$repo_root" "$ledger" >/dev/null \
  || blocker "refusing to read the ledger: $ledger resolves outside the checkout (symlinked ancestor or leaf); ledger unchanged"

[ -f "$ledger" ] || blocker "ledger file does not exist: $ledger"
jq -e . "$ledger" >/dev/null 2>&1 || blocker "ledger file is not valid JSON: $ledger"

# ── COHERENCE CHECK: the on-disk ledger must self-identify with the passed run_id ──
ledger_run_id="$(jq -r '.run.id // ""' "$ledger")"
[ "$ledger_run_id" = "$run_id" ] \
  || blocker "ledger run.id '$ledger_run_id' does not match run_id '$run_id'; ledger unchanged"

# ── Post-existence canonical ledger-dir confirmation ───────────────────────────
# Now that the ledger file is confirmed to exist, canonicalize its own dir and re-verify the
# leaf/dir basenames against the contained runs dir. This pairs the containment proof above
# (which gated the read) with a final byte-exact path identity before the mktemp/mv write.
canon_ledger_dir="$(cd "$(dirname "$ledger")" && pwd -P)"
[ -n "$canon_ledger_dir" ] || blocker "failed to canonicalize the ledger directory; ledger unchanged"
canon_ledger="$canon_ledger_dir/state.json"
case "$canon_ledger/" in
  "$canon_runs/"*) : ;;
  *) blocker "ledger resolves outside the checkout runs dir: $canon_ledger; ledger unchanged" ;;
esac
[ "$(basename "$canon_ledger")" = "state.json" ] \
  || blocker "canonical ledger leaf is not state.json: $canon_ledger; ledger unchanged"
[ "$(basename "$canon_ledger_dir")" = "$run_id" ] \
  || blocker "canonical ledger dir name does not match run_id '$run_id': $canon_ledger_dir; ledger unchanged"

# If outputs was supplied, it must be a valid JSON object (--argjson rejects non-JSON, but
# validate up front for a clear blocker rather than a jq parse error).
if [ "$have_outputs" = true ]; then
  printf '%s' "$outputs" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || blocker "outputs must be a JSON object"
else
  outputs='{}'
fi

# ── close_status validation (the ONLY permitted close values) ──────────────────
# When supplied, close_status MUST be exactly "cancelled" or "complete". This EXPLICITLY
# rejects "abandoned" (and anything else). When absent, run.status is left untouched.
if [ "$have_close_status" = true ]; then
  case "$close_status" in
    cancelled|complete) : ;;
    *) blocker "close_status must be cancelled or complete, got: $close_status; ledger unchanged" ;;
  esac

  # ── Closeout footgun guard (close_status path ONLY) ─────────────────────────
  # You cannot close out an already-terminal run. Read the on-disk run.status from the
  # validated ledger (identity/coherence/containment all proven above) and reject unless it is
  # exactly "running". Empty/missing status -> not running -> reject (correct). This runs
  # BEFORE any mktemp/temp-write, so a reject leaves the ledger byte-unchanged. The bare
  # mode-flip path (no close_status) is intentionally NOT gated and may run on a skew ledger.
  ledger_status="$(jq -r '.run.status // ""' "$ledger")"
  [ "$ledger_status" = "running" ] \
    || blocker "close_status closeout requires a running run; run.status is '$ledger_status'; ledger unchanged"
fi

# Resulting run.status reported on stdout: the validated close_status if supplied, else the
# run stays running (the ledger's run.status is left untouched by the mutation below).
if [ "$have_close_status" = true ]; then
  result_status="$close_status"
else
  result_status="running"
fi

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Atomic write: temp file beside the ledger, then mv into place ──────────────
# Use the CANONICAL (verified-contained) dir for the temp-write + atomic rename so both
# operate on the path that passed containment, not the raw textual one.
ledger_dir="$canon_ledger_dir"
ledger="$canon_ledger"
tmp_ledger="$(mktemp "$ledger_dir/.state.json.XXXXXX")" \
  || blocker "failed to create temp ledger file under $ledger_dir"

# Mutate via a single jq program. Untrusted --state / --summary / --outputs enter ONLY as
# --arg / --argjson bindings. The close clause is appended to the program ONLY when
# close_status is present — clause PRESENCE (an inert bool), never the untrusted VALUE,
# decides whether the clause runs; the value itself still arrives solely through --arg. When
# absent, run.status / state.status are left untouched. INVARIANT: the input ledger is the
# file itself; on a jq failure the temp file is removed and the on-disk ledger is untouched.
close_program=""
if [ "$have_close_status" = true ]; then
  close_program="
  | .run.status = \$close_status
  | .state.status = \$close_status"
fi

jq \
  --arg at "$now_ts" \
  --arg state "$state" \
  --arg summary "$summary" \
  --argjson outputs "$outputs" \
  --arg close_status "$close_status" \
  '
  .run.mode = "intent_fallback"
  | .events += [{
    at: $at,
    state: $state,
    result: "intent_fallback",
    next_state: null,
    summary: $summary,
    outputs: $outputs
  }]
  | .run.updated_at = $at'"$close_program"'
  ' "$ledger" > "$tmp_ledger" \
  || { rm -f "$tmp_ledger"; blocker "failed to serialize the mutated ledger with jq; on-disk ledger unchanged"; }

mv -f "$tmp_ledger" "$ledger" \
  || { rm -f "$tmp_ledger"; blocker "failed to atomically install the mutated ledger at $ledger; on-disk ledger unchanged"; }

# ── Success routing ───────────────────────────────────────────────────────────
printf 'run_id: %s\n' "$run_id"
printf 'mode: intent_fallback\n'
printf 'status: %s\n' "$result_status"
printf 'ledger: %s\n' "$ledger"
exit 0
