#!/usr/bin/env bash
#
# rc-brood — deterministic engine for the hivemind:enable-brood-remote skill.
#
# Fans the Claude Code slash command `/rc <strain-name>` (alias `/remote-control`) out to
# every LIVE strain session of one brood via tmux keystroke injection. Each strain's OWN live
# tmux session receives `/rc <its-own-strain-name>`, so each strain self-registers for remote
# control under its strain name. The user invokes this (through the skill) on an EXPLICIT
# natural-language request to enable RC for a brood — it is never an autonomous coordination step.
#
# ADR LINEAGE:
#   - ADR-0007 (fleet children unaware; coordinator is a read-only status dashboard): preserved.
#     Issuing the keystrokes on the user's EXPLICIT request is human-initiated addressing —
#     equivalent to the user attaching to each pane and typing the slash command themselves. It
#     does NOT make the coordinator an autonomous controller; the boundary holds.
#   - ADR-0027 (agent-invocable remote control via description scoping): the capability ships as a
#     normal agent-invocable skill scoped by its description; Claude Code has no in-band peer-drive
#     API (upstream anthropics/claude-code#34243), so external `tmux send-keys` is the only
#     delivery path — the same keystroke-injection mechanism spawn-brood already uses.
#
# INPUT (single positional argument):
#   $1  <broodId> — a brood-id of the EXACT shape spawn-brood generates (`brood-<uuidv4>`,
#       asserted ^brood-[0-9a-f-]+$). Validated as a strict safe single path component BEFORE any
#       use (reject empty / leading-dash / path-traversal / separators / command-substitution /
#       framing bytes). Used to locate the per-brood manifest under the checkout root.
#
# MANIFEST:
#   <checkout-root>/.hivemind/broods/<broodId>/manifest.json  (manifest_version 4, JSON). The
#   checkout root is `git rev-parse --show-toplevel` — the SAME anchor spawn-brood writes against,
#   so read side and write side agree by construction.
#
# OUTPUT (stdout):
#   Per-strain disposition lines (`applied|skipped|failed: <strain> ...`) and a final summary line
#   with applied/skipped/failed counts.
#
# EXIT CONTRACT:
#   0  the fan-out COMPLETED — even with some strains skipped (dead/missing session, unsanitizable
#      name) or failed (a per-strain tmux error). Zero strains / zero alive sessions also exit 0.
#   1  ONLY a pre-flight blocker: bad brood-id, missing/unreadable/invalid manifest, missing
#      dependency. No keystroke is delivered on a pre-flight blocker.
#
# SAFETY (injection invariant — the test asserts this):
#   The ONLY bytes ever sent into any session are the FIXED literal `/rc <sanitized-name>`, where
#   <sanitized-name> is the strain name reduced to a safe token ([A-Za-z0-9._-]). Untrusted
#   manifest strings (names, descriptions) are read as DATA via `jq -r` and are NEVER interpolated
#   into shell command SOURCE, into a buffer file, or into `send-keys` unsanitized. A strain name
#   that fails sanitization (or is empty) is SKIPPED — no malformed `/rc` is ever sent.
#
# CONVENTIONS (mirrors brood-status-collect.sh / spawn-brood.sh): `set -euo pipefail`, an EXIT
# trap ending in a guaranteed-zero `:`, self-location via `cd && pwd -P` (NO realpath/readlink, NO
# ${CLAUDE_PLUGIN_ROOT} inside an engine script).

set -euo pipefail
trap ':' EXIT

# blocker: emit a pre-flight blocker to stderr in the canonical form and exit 1 (no keystroke
# delivered). Mirrors the spawn-brood.sh / brood-status-collect.sh blocker pattern.
blocker() { printf 'blocker: %s\n' "$1" >&2; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────────
# tmux delivers the keystrokes; jq reads the manifest as DATA; git resolves the checkout root.
# All three are hard pre-flight deps — a missing one is a blocker, not a degraded run.
for dep in tmux jq git; do
  command -v "$dep" >/dev/null 2>&1 \
    || blocker "$dep is required but is not installed"
done

# ── Argument: brood-id (validate FAIL-CLOSED before any use) ──────────────────────
# Mirrors spawn-brood.sh's brood-id assertions: the value becomes a filesystem path component, so
# it must be a single safe component. Reject empty / leading-dash / traversal / separators /
# framing bytes BEFORE it is ever interpolated into a path.
brood_id="${1:-}"
[ -n "$brood_id" ] || blocker "missing required argument: <broodId>"
case "$brood_id" in
  -*)       blocker "brood-id must not start with '-': $brood_id" ;;
  *..*)     blocker "brood-id must not contain '..': $brood_id" ;;
  */*|*\\*) blocker "brood-id must not contain a path separator: $brood_id" ;;
esac
# Shape gate: exactly the form spawn-brood generates (brood-<uuidv4>, lowercase hex + dashes).
case "$brood_id" in
  brood-[0-9a-f]*) : ;;
  *) blocker "brood-id must match ^brood-[0-9a-f-]+\$: $brood_id" ;;
esac
case "$brood_id" in
  *[!a-z0-9-]*) blocker "brood-id contains a byte outside [a-z0-9-]: $brood_id" ;;
esac

# ── Checkout root + manifest path ─────────────────────────────────────────────────
# The SAME anchor spawn-brood.sh writes against (git rev-parse --show-toplevel), so the manifest
# this read locates is exactly the one the spawn wrote.
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] && [ -d "$root" ] \
  || blocker "not inside a git checkout (git rev-parse --show-toplevel failed)"

manifest="$root/.hivemind/broods/$brood_id/manifest.json"
[ -f "$manifest" ] && [ -r "$manifest" ] \
  || blocker "brood manifest not found or unreadable: $manifest"
# Validate it parses as JSON before any field read — a corrupt manifest is a pre-flight blocker.
jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 \
  || blocker "brood manifest is not valid JSON: $manifest"

# ── Enumerate strains (DATA reads — never command source) ─────────────────────────
# Read the name + tmux_session of each strain as TAB-separated DATA via a single jq pass. jq
# emits each value as a string; we strip C0 control bytes defensively at the read boundary (a
# control byte cannot survive into a session, and tab/newline would corrupt the field split). The
# values are consumed ONLY as inert "$var" args below; they never enter generated command source.
TAB="$(printf '\t')"

strain_names=()
strain_sessions=()
while IFS="$TAB" read -r s_name s_session; do
  strain_names+=("$s_name")
  strain_sessions+=("$s_session")
done < <(
  jq -r '
    (.strains // [])[]
    | [ (.name // "" | gsub("[[:cntrl:]]"; "")),
        (.tmux_session // "" | gsub("[[:cntrl:]]"; "")) ]
    | @tsv
  ' "$manifest"
)

# ── Fan-out ───────────────────────────────────────────────────────────────────────
# Per strain: sanitize the name to the slug, guard session liveness, then deliver the FIXED
# `/rc <slug>` literal. One dead session or one tmux error NEVER aborts the rest (FAIL-SOFT) — it
# is recorded and the loop continues.
applied=0
skipped=0
failed=0

strain_count="${#strain_names[@]}"
idx=0
while [ "$idx" -lt "$strain_count" ]; do
  name="${strain_names[$idx]}"
  session="${strain_sessions[$idx]}"
  idx=$((idx + 1))

  # Compute the slug: strip every byte outside the safe token charset [A-Za-z0-9._-]. An empty
  # result (name was empty or wholly unsafe) means there is no safe `/rc` argument to send —
  # SKIP rather than deliver a malformed command. The slug is the ONLY untrusted-derived byte ever
  # sent, and it is now a pure [A-Za-z0-9._-] token.
  slug="$(printf '%s' "$name" | tr -cd 'A-Za-z0-9._-')"
  if [ -z "$slug" ]; then
    printf 'skipped: strain %q (name does not sanitize to a safe /rc slug)\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi

  # A strain whose recorded session is empty or sentinel-shaped has no live target to address.
  if [ -z "$session" ]; then
    printf 'skipped: %s (no tmux session recorded)\n' "$slug"
    skipped=$((skipped + 1))
    continue
  fi

  # Liveness guard: a dead/missing session is SKIPPED, never failed — it simply is not a delivery
  # target. `has-session` against an absent session is a normal negative, not an error.
  if ! tmux has-session -t "$session" 2>/dev/null; then
    printf 'skipped: %s (session not alive: %s)\n' "$slug" "$session"
    skipped=$((skipped + 1))
    continue
  fi

  # Deliver the FIXED form. Two separate send-keys events:
  #   1. `-l --` types the literal text `/rc <slug>` verbatim (no key-name interpretation; the
  #      leading `/` and the slug are sent as characters). For a SHORT fixed one-line command,
  #      literal send-keys is sufficient — no bracketed-paste needed (per the delivery decision).
  #   2. a SEPARATE Enter key event submits the slash command.
  # The slug is a sanitized [A-Za-z0-9._-] token, so the literal payload cannot carry framing or
  # control bytes. Any tmux failure for THIS strain is recorded `failed` and the loop continues —
  # a per-strain error never aborts the fan-out.
  if ! tmux send-keys -t "$session" -l -- "/rc $slug" 2>/dev/null; then
    printf 'failed: %s (send-keys literal failed for session %s)\n' "$slug" "$session"
    failed=$((failed + 1))
    continue
  fi
  if ! tmux send-keys -t "$session" Enter 2>/dev/null; then
    printf 'failed: %s (send-keys Enter failed for session %s)\n' "$slug" "$session"
    failed=$((failed + 1))
    continue
  fi
  printf 'applied: %s (/rc %s -> %s)\n' "$slug" "$slug" "$session"
  applied=$((applied + 1))
done

# ── Summary ────────────────────────────────────────────────────────────────────────
# Exit 0 once the fan-out completed, regardless of per-strain skipped/failed counts. The only
# exit-1 paths are the pre-flight blockers above.
printf 'summary: brood %s — %d applied, %d skipped, %d failed (of %d strains)\n' \
  "$brood_id" "$applied" "$skipped" "$failed" "$strain_count"
exit 0
