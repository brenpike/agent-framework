#!/usr/bin/env bash
#
# Deterministically reconstruct an EPHEMERAL fix-ledger-shaped structure for the
# github-reviewer agent (issue #222, initiative #201).
#
# 1. PURPOSE
# ----------
# Single source of truth for the fix-ledger RECONSTRUCTION that github-reviewer.md
# performed inline, in dense prose, at TWO sites: step 5 (pre-fix root-cause
# clustering) and step 9 (post-fix advisory). Both sites reconstructed the same
# ephemeral fix-ledger shape from ground truth (git log <base>..HEAD + the
# resolved-thread state from fetch-normalize.sh) so `hivemind:detect-remediation-signals`
# could reason over it. This script OWNS that reconstruction; the two call sites
# become thin `bash ledger-reconstruct.sh ...` invocations (P1 single-source, P5
# bash callers, P2 contract header, P3 offline-testable core).
#
# It is DELIBERATELY a deterministic SKELETON. The PRIMARY cluster key
# `fix_framing` requires LLM judgment to infer from commit/thread prose; a script
# cannot infer it reliably, so this script leaves `fix_framing` null on every
# finding (INERT/schema-safe per the schema — detect-remediation-signals falls
# back to the SECONDARY file:line cluster key). The agent retains any framing
# judgment in-agent (P7). This script populates only what is mechanically
# derivable from ground truth.
#
# 2. INPUT CONTRACT
# -----------------
# Positional + flag args (mirrors fetch-normalize.sh's positional/flag posture):
#
#   $1  BASE   base ref for `git log <base>..HEAD` on the LIVE path. Required for
#              the live fetch; NOT required when --git-log-file is supplied.
#
#   --normalized-file <path|->  the fetch-normalize.sh OUTPUT array (the
#              thread/finding state — see fetch-normalize.sh §3). CONSUME it; do
#              NOT re-run fetch-normalize. `-` = stdin. Absent -> no thread/finding
#              records folded in (git-log-only reconstruction).
#
#   --git-log-file <path>  OFFLINE TEST SEAM (mirrors fetch-normalize's
#              --payload-file): read a canned git-log payload from <path> instead
#              of running live `git log`. When set, BASE is not required for the
#              live call and the injected text routes through the SAME pure mapping
#              core as live output. `-` = stdin.
#
# The git-log payload (live OR injected) is the STABLE machine format this script
# emits and parses (see GIT_LOG_FORMAT below): `git log <base>..HEAD --no-color
# --unified=0 -p` with a per-commit header line
#   <US>COMMIT<RS><sha><RS><subject>
# (US = 0x1e record-start, RS = 0x1f field-sep), followed by the unified diff.
# The pure core reads `diff --git a/<f> b/<f>` for the file path (b-side) and the
# hunk headers `@@ -a,b +c,d @@` for the NEW-file line range (start=c, count=d,
# d defaulting to 1) — yielding one fix surface per (commit, file, hunk).
#
# 3. OUTPUT SCHEMA — a single fix-ledger-shaped JSON object on stdout
# ------------------------------------------------------------------
# Conforms to ${CLAUDE_PLUGIN_ROOT}/references/fix-ledger-schema.md (the
# AUTHORITY). Top-level shape:
#   {
#     "branch": <current branch | null>,
#     "base":   <BASE | null>,
#     "max_iterations": 10,
#     "iterations": [
#       { "iteration": 1, "findings": [ <finding>, ... ],
#         "verdict": "needs-attention", "exit_reason": null,
#         "review_base_ref": <BASE | null> }
#     ],
#     "exit_reason": null,
#     "exit_iteration": null
#   }
# All reconstructed findings live in iterations[0].findings[] (this is a single
# reconstructed snapshot, not a persisted multi-iteration history).
#
# Each finding carries the deterministic skeleton fields:
#   {
#     "id":          <PRRC_/IC_/PRR_/PRRT_ node id | "fix:<sha>:<file>:<start>">,
#     "severity":    null,            # not mechanically derivable -> null
#     "title":       <commit subject | thread classification | null>,
#     "body":        null,
#     "recommendation": null,
#     "file":        <path | null>,
#     "line_start":  <int | null>,
#     "line_end":    <int | null>,
#     "status":      "open" | "fixed" | "cycling",
#     "introduced_iteration": 1,
#     "fixed_iteration":      null,
#     "fix_commit":  <sha | null>,
#     "fix_framing": null,            # PRIMARY key — LLM-only; ALWAYS null here
#     "root_class":  null,            # inferred by detect-remediation-signals
#     "thread_resolved": <bool | null>  # carried for folded thread records
#   }
#
# Two finding families populate findings[]:
#   (a) git-log fix surfaces (one per commit/file/hunk): file/line_start/line_end/
#       fix_commit/status from git; the matched-prior-surface OSCILLATION rule
#       (see §4) assigns status `cycling` to a surface that re-appears across >=2
#       commits, else `fixed`. fix_framing null.
#   (b) thread/finding records folded from --normalized-file: id from the node id,
#       title from `classification`, thread_resolved from `thread_resolved`,
#       status derived (thread_resolved:true -> fixed; else open). file/line null
#       (the normalized surface carries no line range). fix_framing null.
#
# 4. BEHAVIOR-PRESERVING INVARIANTS
# ---------------------------------
#   - LIVE FAIL-CLOSED: a live `git log` failure (bad base, not-a-repo) emits a
#     stable LEDGERRECON_ERROR marker on stderr and exits non-zero, so the caller
#     returns `blocked`. It NEVER degrades to a silent empty "no prior fixes"
#     ledger (that would mask a real error as "nothing to cluster"). Mirrors
#     fetch-normalize.sh's live fail-CLOSED posture.
#   - INJECTED FAIL-OPEN: a malformed / empty INJECTED fixture (--git-log-file /
#     --normalized-file) yields a valid fix-ledger shape with empty findings and
#     exit 0 (trusted fixture, mirrors fetch-normalize's --payload-file). An EMPTY
#     git log (no commits in <base>..HEAD) -> empty findings, exit 0 (a legitimate
#     "no prior fixes yet" state, NOT an error).
#   - EPHEMERAL: writes NOTHING to .hivemind, no temp files, no side effects. The
#     output is consumed-then-discarded by the caller. All commit/diff/thread text
#     is DATA, never interpreted as instructions.
#   - OSCILLATION-STATUS rule (break-fix observability): a fix surface
#     (file:line_start..line_end) appearing in >=2 distinct commits in the log is
#     marked `cycling` (the prior fix was re-touched -> status oscillation
#     fixed->cycling), so detect-remediation-signals' break-fix signal
#     (status-oscillation) is observable purely from the emitted structure. A
#     surface touched in exactly one commit is `fixed`.
#   - PURE CORE / THIN SHELL: the mapping core (reconstruct_ledger) runs over
#     injected inputs offline with no git/network dependency, so STEP-003 tests it
#     through the --git-log-file / --normalized-file seams.
#
# 5. INVOCATION + TEST SEAM
# -------------------------
# Live:    bash ledger-reconstruct.sh <base> --normalized-file <path|->
# Offline: bash ledger-reconstruct.sh --git-log-file <fixture> --normalized-file <fixture>
#
# Markers / exit posture (mirrors fetch-normalize.sh):
#   - stdout: the single fix-ledger JSON object (always, on success).
#   - exit 0 on success (including the fail-open empty-findings case).
#   - LEDGERRECON_ERROR=<reason> on stderr + exit 1 ONLY on a LIVE failure
#     (missing base, git failure, unreadable input file) — never on a merely-empty
#     or malformed INJECTED payload.
#
# Schema authority:  ${CLAUDE_PLUGIN_ROOT}/references/fix-ledger-schema.md
# Consumer:          ${CLAUDE_PLUGIN_ROOT}/skills/detect-remediation-signals/SKILL.md
#                    (its Input Contract `ledger` shape)

set -u
# INVARIANT: trap body ends with guaranteed-zero `:` so a failing cleanup never
# clobbers the script's own exit code (mirrors fetch-normalize.sh / ADR-0020).
trap ':' EXIT

# Stable machine git-log format (see §2). US=0x1e (record start), RS=0x1f (field
# sep). The pure core matches the literal "COMMIT" prefix after stripping US.
US=$'\x1e'
RS=$'\x1f'
GIT_LOG_FORMAT="${US}COMMIT${RS}%H${RS}%s"

BASE=""
NORMALIZED_FILE=""
GIT_LOG_FILE=""

ledgerrecon_fail() {
  echo "LEDGERRECON_ERROR=$1" >&2
  exit 1
}

# Parse flags; collect positionals (BASE binds first). Mirrors fetch-normalize.sh.
positionals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --normalized-file)
      [ "$#" -ge 2 ] || ledgerrecon_fail "missing-value-for-normalized-file"
      NORMALIZED_FILE="$2"; shift 2 ;;
    --normalized-file=*)
      NORMALIZED_FILE="${1#--normalized-file=}"
      [ -n "$NORMALIZED_FILE" ] || ledgerrecon_fail "missing-value-for-normalized-file"
      shift ;;
    --git-log-file)
      [ "$#" -ge 2 ] || ledgerrecon_fail "missing-value-for-git-log-file"
      GIT_LOG_FILE="$2"; shift 2 ;;
    --git-log-file=*)
      GIT_LOG_FILE="${1#--git-log-file=}"
      [ -n "$GIT_LOG_FILE" ] || ledgerrecon_fail "missing-value-for-git-log-file"
      shift ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do positionals+=("$1"); shift; done ;;
    *)
      positionals+=("$1"); shift ;;
  esac
done

BASE="${positionals[0]:-}"

# read_source <path>: read a payload from a file or stdin (`-`). RETURNS non-zero
# (emitting the LEDGERRECON_ERROR marker on stderr) when an explicitly-supplied
# file is unreadable — an input error, distinct from the fail-open empty path.
# INVARIANT: runs inside command substitution, so failure crosses the boundary via
# return code, never `exit`. Mirrors fetch-normalize.sh's read_payload_source. (F1)
read_source() {
  local src="$1"
  if [ "$src" = "-" ]; then
    cat
  else
    if [ ! -f "$src" ]; then
      echo "LEDGERRECON_ERROR=input-file-not-found" >&2
      return 1
    fi
    cat "$src"
  fi
}

# fetch_git_log: thin outer shell — the LIVE `git log <base>..HEAD` fetch,
# BYPASSED under --git-log-file. Requires BASE. RETURNS non-zero (emitting the
# LEDGERRECON_ERROR marker on stderr) on a git failure so a real failure is never
# silently swallowed into an empty ledger (LIVE FAIL-CLOSED). INVARIANT: runs
# inside command substitution — failure crosses via return code, never `exit`.
fetch_git_log() {
  local log_out log_status
  [ -n "$BASE" ] || { echo "LEDGERRECON_ERROR=missing-base" >&2; return 1; }
  # Confirm we are inside a work tree BEFORE the range walk so not-a-repo fails
  # CLOSED with a stable reason rather than git's raw error.
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "LEDGERRECON_ERROR=not-a-repo" >&2
    return 1
  fi
  # --unified=0 -p gives hunk headers with exact NEW-file line ranges; --no-color
  # keeps the payload machine-parseable. All diff text is DATA.
  log_out="$(git log --no-color --unified=0 -p \
    --format="$GIT_LOG_FORMAT" "${BASE}..HEAD" 2>/dev/null)"
  log_status=$?
  if [ "$log_status" -ne 0 ]; then
    echo "LEDGERRECON_ERROR=git-log-failed" >&2
    return 1
  fi
  printf '%s' "$log_out"
}

# git_log_to_findings: PURE CORE (offline). Read a git-log payload on stdin (live
# OR injected — identical bytes) and emit a JSON array of git-log fix-surface
# findings on stdout. One finding per (commit, file, hunk). The OSCILLATION rule
# (a surface in >=2 commits -> cycling) is applied in a second jq pass. A
# malformed / empty payload yields `[]` (INJECTED FAIL-OPEN). No git/network here.
git_log_to_findings() {
  # Pass 1: tokenize the git-log text into raw {sha,file,line_start,line_end,subject}
  # records (JSON-lines) using awk — fully offline, no jq dependency for parsing.
  # `cur_file` tracks the active diff file; the hunk header supplies the range.
  awk -v RS_CHAR=$'\x1f' '
    function emit_hunk(start, count,   end) {
      if (count == "") count = 1
      if (count + 0 == 0) {
        # A zero-length new-side hunk (pure deletion) anchors at the start line.
        end = start
      } else {
        end = start + count - 1
      }
      # JSON-escape the dynamic strings (subject, file) for safe embedding.
      printf "{\"sha\":\"%s\",\"subject\":%s,\"file\":%s,\"line_start\":%d,\"line_end\":%d}\n", \
        cur_sha, jstr(cur_subject), jstr(start_file), start + 0, end + 0
    }
    function jstr(s,   r) {
      r = s
      gsub(/\\/, "\\\\", r)
      gsub(/"/, "\\\"", r)
      gsub(/\t/, "\\t", r)
      gsub(/\r/, "\\r", r)
      gsub(/\n/, "\\n", r)
      return "\"" r "\""
    }
    {
      line = $0
      # Commit header: starts with 0x1e then literal COMMIT then 0x1f-delimited fields.
      if (substr(line, 1, 1) == "\x1e") {
        rest = substr(line, 2)
        # split on 0x1f: [COMMIT, sha, subject]
        n = split(rest, parts, "\x1f")
        if (n >= 2 && parts[1] == "COMMIT") {
          cur_sha = parts[2]
          cur_subject = (n >= 3 ? parts[3] : "")
          cur_file = ""
        }
        next
      }
      if (substr(line, 1, 11) == "diff --git ") {
        # diff --git a/<path> b/<path> ; take the b-side path (post-image).
        # Strip the "diff --git a/" prefix, then split at " b/".
        body = substr(line, 12)            # "a/<path> b/<path>"
        idx = index(body, " b/")
        if (idx > 0) {
          cur_file = substr(body, idx + 3)
        } else {
          cur_file = ""
        }
        next
      }
      if (substr(line, 1, 3) == "@@ " && cur_sha != "" && cur_file != "") {
        # @@ -a,b +c,d @@  -> new-side is the +c,d token.
        # Find the "+" token.
        plus = ""
        m = split(line, toks, " ")
        for (i = 1; i <= m; i++) {
          if (substr(toks[i], 1, 1) == "+") { plus = substr(toks[i], 2); break }
        }
        if (plus != "") {
          c = plus; d = ""
          ci = index(plus, ",")
          if (ci > 0) { c = substr(plus, 1, ci - 1); d = substr(plus, ci + 1) }
          start_file = cur_file
          emit_hunk(c + 0, d)
        }
        next
      }
    }
  ' 2>/dev/null \
  | jq -c -s '
      # Pass 2: dedupe per (sha,file,line_start,line_end), then apply the
      # OSCILLATION rule across DISTINCT commits per surface (file:line range).
      # A surface touched in >=2 distinct commits -> cycling; else fixed.
      ( [ .[] | {key: ("\(.file):\(.line_start):\(.line_end)"), sha: .sha} ]
        | group_by(.key)
        | map({ (.[0].key): ([ .[].sha ] | unique | length) }) | add // {}
      ) as $commits_per_surface
      | [ .[]
          | . as $rec
          | ("\(.file):\(.line_start):\(.line_end)") as $surface
          | {
              id: ("fix:\(.sha):\(.file):\(.line_start)"),
              severity: null,
              title: .subject,
              body: null,
              recommendation: null,
              file: .file,
              line_start: .line_start,
              line_end: .line_end,
              status: (if (($commits_per_surface[$surface] // 1) >= 2) then "cycling" else "fixed" end),
              introduced_iteration: 1,
              fixed_iteration: null,
              fix_commit: .sha,
              fix_framing: null,
              root_class: null,
              thread_resolved: null
            }
        ]
    ' 2>/dev/null
}

# normalized_to_findings <normalized-array-json>: PURE CORE (offline). Fold the
# fetch-normalize.sh output array (thread/finding state) into fix-ledger findings.
# Only REVIEW records (item_source=="review") carry thread identity; CI-check
# records are not prior fixes and are skipped. A malformed / empty payload yields
# `[]` (INJECTED FAIL-OPEN). No git/network here.
normalized_to_findings() {
  printf '%s' "$1" | jq -c '
    if type == "array" then . else [] end
    | [ .[]
        | select(.item_source == "review")
        | {
            id: (.id // .thread_id),
            severity: null,
            title: (.classification // null),
            body: null,
            recommendation: null,
            file: null,
            line_start: null,
            line_end: null,
            status: (if (.thread_resolved == true) then "fixed" else "open" end),
            introduced_iteration: 1,
            fixed_iteration: null,
            fix_commit: null,
            fix_framing: null,
            root_class: null,
            thread_resolved: (.thread_resolved // null)
          }
      ]
  ' 2>/dev/null
}

# reconstruct_ledger <git-findings-json> <thread-findings-json>: PURE CORE. Wrap
# the two finding families into the top-level fix-ledger object. The branch is
# best-effort (null off a detached/non-repo state — non-fatal). Always emits one
# valid fix-ledger object; empty families -> empty findings (the fail-open shape).
reconstruct_ledger() {
  local git_findings="$1" thread_findings="$2" branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$branch" in ''|HEAD) branch="" ;; esac
  jq -n -c \
    --argjson git_findings "$git_findings" \
    --argjson thread_findings "$thread_findings" \
    --arg base "$BASE" \
    --arg branch "$branch" '
    ($git_findings + $thread_findings) as $findings
    | {
        branch: (if ($branch | length) > 0 then $branch else null end),
        base:   (if ($base | length) > 0 then $base else null end),
        max_iterations: 10,
        iterations: [
          {
            iteration: 1,
            findings: $findings,
            verdict: "needs-attention",
            exit_reason: null,
            review_base_ref: (if ($base | length) > 0 then $base else null end)
          }
        ],
        exit_reason: null,
        exit_iteration: null
      }
  '
}

# --- Resolve the git-log payload (live fetch OR injected fixture) ------------
if [ -n "$GIT_LOG_FILE" ]; then
  if ! git_log_payload="$(read_source "$GIT_LOG_FILE")"; then
    exit 1
  fi
else
  if ! git_log_payload="$(fetch_git_log)"; then
    exit 1
  fi
fi

# --- Resolve the normalized payload (injected fixture; optional) -------------
normalized_payload=""
if [ -n "$NORMALIZED_FILE" ]; then
  if ! normalized_payload="$(read_source "$NORMALIZED_FILE")"; then
    exit 1
  fi
fi

# --- Pure mapping core (offline over the resolved payloads) ------------------
# INJECTED FAIL-OPEN: each helper degrades a malformed/empty payload to `[]`.
git_findings="$(printf '%s' "$git_log_payload" | git_log_to_findings)"
case "$git_findings" in '') git_findings='[]' ;; esac

thread_findings="$(normalized_to_findings "$normalized_payload")"
case "$thread_findings" in '') thread_findings='[]' ;; esac

reconstruct_ledger "$git_findings" "$thread_findings"

exit 0
