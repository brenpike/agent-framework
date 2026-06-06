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
# The git-log payload (live OR injected) is a MACHINE-DELIMITED stream produced by
#   git log <base>..HEAD --no-color --unified=0 -z --raw -p --find-renames \
#           --format=$'\x1eCOMMIT\x1f%H\x1f%s'
# Per-commit byte layout (empirically verified against real git output in this
# repo; the tokenizer parses to THIS actual layout):
#   \x1eCOMMIT\x1f<sha>\x1f<subject>\0      format record; -z appends a NUL
#   \n:<m> <m> <b> <b> <STATUS>\0           one --raw entry per changed file
#   <path1>\0[<path2>\0]                    R/C status -> two paths (old,new); else one
#   \0                                      empty token: raw-block terminator
#   <patch>                                 the -p unified-diff text (next commit's
#                                           \x1eCOMMIT record may be glued to its tail)
# (US=0x1e record start, RS=0x1f field sep.)
#
# PATHS COME FROM GIT'S MACHINE CHANNEL, never an in-band ` b/` substring split.
# The --raw entries carry NUL-delimited, NEVER-quoted, space-/rename-safe paths;
# the destination (new-file) path is the LAST path of each entry. The -p hunks are
# correlated to files BY ORDER: the Nth `diff --git` in a commit's patch is the
# Nth --raw entry. We read ONLY the hunk `@@ -a,b +c,d @@` arithmetic from -p
# (NEW-file range: start=c, count=d, d defaulting to 1, d==0 -> end=start) — the
# diff line's path text is IGNORED. This yields one fix surface per (commit,file,hunk).
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
# JSON-STRING EMISSION IS OWNED ENTIRELY BY jq. The awk stage is a pure TOKENIZER:
# it emits NUL-FREE, 0x1f-field-delimited RAW records (sha, subject, path,
# line_start, line_end) and NO JSON. jq assembles every finding object and escapes
# every string (it correctly escapes U+0000–U+001F C0 control bytes as well as
# quotes/backslashes), so a C0 byte (e.g. backspace 0x08) in a subject or path is
# INERT data jq escapes into valid JSON — it can never break the JSON or collapse
# the output to []. This dissolves the former in-awk hand-rolled escaper by
# construction.
#
# 4. BEHAVIOR-PRESERVING INVARIANTS
# ---------------------------------
#   - LIVE FAIL-CLOSED: on the LIVE path (--git-log-file NOT set) a `git log`
#     failure (bad base, not-a-repo) emits a stable LEDGERRECON_ERROR marker on
#     stderr and exits non-zero, so the caller returns `blocked`. ADDITIONALLY, if
#     a NON-EMPTY live payload cannot be parsed into the expected record structure
#     (no recognizable \x1eCOMMIT\x1f record marker present), the script emits
#     LEDGERRECON_ERROR=live-parse-failed + exit non-zero rather than degrading to
#     a silent empty "no prior fixes" ledger (which would mask a real error as
#     "nothing to cluster"). A LEGITIMATELY EMPTY live log (no commits in
#     <base>..HEAD, i.e. zero bytes) stays a valid empty-findings exit 0 — it is a
#     real "no prior fixes yet" state, NOT a parse failure.
#   - INJECTED FAIL-OPEN: a malformed / empty INJECTED fixture (--git-log-file /
#     --normalized-file) yields a valid fix-ledger shape with empty findings and
#     exit 0 (trusted fixture, mirrors fetch-normalize's --payload-file). The
#     live-parse-failed gate above is NOT applied to injected input.
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
#     (missing base, git failure, unreadable input file, live-parse-failed) —
#     never on a merely-empty or malformed INJECTED payload.
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
# The \x1eCOMMIT\x1f record marker (used by both the tokenizer and the live
# parse-failed gate). A live payload with commits ALWAYS contains it.
RECORD_MARKER="${US}COMMIT${RS}"

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

# live_git_log_preflight: validate the LIVE path BEFORE streaming (BASE present,
# inside a work tree). RETURNS non-zero with a stable LEDGERRECON_ERROR marker so
# a real failure never degrades to an empty ledger (LIVE FAIL-CLOSED). Separated
# from the byte stream because the git-log payload carries NUL delimiters and so
# MUST NOT round-trip through a `$(...)` capture (bash strips NUL from variables) —
# it streams straight into awk instead.
live_git_log_preflight() {
  [ -n "$BASE" ] || { echo "LEDGERRECON_ERROR=missing-base" >&2; return 1; }
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "LEDGERRECON_ERROR=not-a-repo" >&2
    return 1
  fi
  return 0
}

# stream_git_log: write the raw git-log bytes to stdout (NUL-delimited), streamed
# directly so NULs survive (no variable round-trip). -z --raw gives rename-safe,
# quote-safe, space-safe PATHS on git's machine channel; -p --unified=0 gives hunk
# headers with exact NEW-file line ranges; --find-renames classifies renames
# (R-status emits old+new paths); --no-color keeps the payload machine-parseable.
# RETURNS git's own exit status. All diff/path text is DATA.
stream_git_log() {
  git log --no-color --unified=0 -z --raw -p --find-renames \
    --format="$GIT_LOG_FORMAT" "${BASE}..HEAD" 2>/dev/null
}

# git_log_to_findings: PURE CORE (offline). Read a git-log payload on STDIN (live
# OR injected — identical bytes, streamed so NUL delimiters survive) and emit a
# JSON array of git-log fix-surface findings on stdout. One finding per
# (commit, file, hunk). The OSCILLATION rule (a surface in >=2 commits -> cycling)
# is applied in a second jq pass. A malformed / empty payload yields `[]`
# (INJECTED FAIL-OPEN). No git/network here.
#
# Stage 1 = awk TOKENIZER: parses the -z --raw -p stream and emits NUL-FREE,
# 0x1f-field-delimited RAW records (sha, subject, path, line_start, line_end). It
# emits NO JSON — every string stays raw bytes. Stage 2 = jq: builds each finding
# object and escapes ALL strings (C0 control bytes included), so a C0 byte in a
# subject/path is inert data jq escapes (no collapse, F1 closed by construction).
git_log_to_findings() {
  awk -v US="$US" -v RS_FIELD="$RS" '
    # RS=US: each record begins at a \x1e boundary. $0 (US stripped by RS) is
    # "COMMIT\x1f<sha>\x1f<subj>\0\n<raw block>\0<patch>" for a commit record, or
    # empty/garbage for the leading preamble.
    BEGIN { RS = US }
    {
      rec = $0
      if (substr(rec, 1, 7) != "COMMIT" RS_FIELD) next   # not a commit record
      body = substr(rec, 8)                              # "<sha>\x1f<subj>\0\n<raw>\0\0<patch>"

      # Header ends at the first NUL (the -z format terminator).
      nul = index(body, "\x00")
      if (nul == 0) next                                 # malformed: no -z terminator
      header = substr(body, 1, nul - 1)                  # "<sha>\x1f<subj>"
      remainder = substr(body, nul + 1)                  # "\n<raw block>\0\0<patch>"

      hn = split(header, hf, RS_FIELD)
      sha = (hn >= 1 ? hf[1] : "")
      subject = (hn >= 2 ? hf[2] : "")
      if (sha == "") next

      # Drop the single leading "\n" the format adds before the raw block.
      if (substr(remainder, 1, 1) == "\n") remainder = substr(remainder, 2)

      # The raw block and the patch are separated by an EMPTY NUL field, i.e. a
      # literal "\0\0". Before it = raw block (NUL-delimited status/path tokens);
      # after it = the -p patch text.
      sep = index(remainder, "\x00\x00")
      if (sep > 0) {
        rawblock = substr(remainder, 1, sep - 1)
        patch = substr(remainder, sep + 2)
      } else {
        rawblock = ""
        patch = remainder
        if (substr(patch, 1, 1) == "\x00") patch = substr(patch, 2)
      }

      # Parse the raw block into an ORDERED destination-path list (one per file).
      # Tokens NUL-delimited: STATUS line, then 1 path (M/A/D/T) or 2 paths (R/C).
      # Keep the NEW-file path = the LAST path of the entry (rename-safe).
      n_paths = 0
      delete paths
      if (rawblock != "") {
        tn = split(rawblock, toks, "\x00")
        i = 1
        while (i <= tn) {
          stat_line = toks[i]
          if (stat_line == "") { i++; continue }
          sc = split(stat_line, sf, " ")          # STATUS = last space field
          status = sf[sc]
          i++
          first_char = substr(status, 1, 1)
          if (first_char == "R" || first_char == "C") {
            i++                                    # skip old path
            new_p = (i <= tn ? toks[i] : ""); i++
          } else {
            new_p = (i <= tn ? toks[i] : ""); i++
          }
          n_paths++; paths[n_paths] = new_p
        }
      }

      # Walk the -p patch; correlate hunks to files BY ORDER. The Nth `diff --git`
      # selects the Nth raw path (from the machine channel — the diff line text is
      # IGNORED). @@ headers under it supply the NEW-file range.
      file_idx = 0
      cur_path = ""
      pn = split(patch, plines, "\n")
      for (p = 1; p <= pn; p++) {
        pline = plines[p]
        if (substr(pline, 1, 11) == "diff --git ") {
          file_idx++
          cur_path = (file_idx <= n_paths ? paths[file_idx] : "")
          continue
        }
        if (substr(pline, 1, 3) == "@@ " && cur_path != "") {
          # @@ -a,b +c,d @@ -> new-side is the +c,d token.
          plus = ""
          m = split(pline, hk, " ")
          for (j = 1; j <= m; j++) {
            if (substr(hk[j], 1, 1) == "+") { plus = substr(hk[j], 2); break }
          }
          if (plus != "") {
            c = plus; d = ""
            ci = index(plus, ",")
            if (ci > 0) { c = substr(plus, 1, ci - 1); d = substr(plus, ci + 1) }
            if (d == "") d = 1
            if (d + 0 == 0) { end = c + 0 } else { end = c + d - 1 }
            # NUL-FREE, 0x1f-field, newline-terminated RAW record. NO JSON.
            printf "%s%s%s%s%s%s%d%s%d\n", \
              sha, RS_FIELD, subject, RS_FIELD, cur_path, RS_FIELD, c + 0, RS_FIELD, end
          }
        }
      }
    }
  ' 2>/dev/null \
  | jq -R -c --arg sep "$RS" '
      # Stage 2a: each line is a 0x1f-delimited RAW record. split($sep) -> fields;
      # jq escapes every string (C0 control bytes + quotes/backslashes) -> valid JSON.
      split($sep)
      | select(length >= 5)
      | { sha: .[0], subject: .[1], file: .[2],
          line_start: (.[3] | tonumber), line_end: (.[4] | tonumber) }
    ' 2>/dev/null \
  | jq -c -s '
      # Stage 2b: dedupe per (sha,file,line_start,line_end), then apply the
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

# --- Resolve the git-log findings (live fetch OR injected fixture) -----------
# The git-log payload carries NUL delimiters, so it is STREAMED straight into the
# tokenizer — never captured into a shell variable (bash strips NUL). Only the
# resulting JSON (NUL-free) is captured. INJECTED FAIL-OPEN: a malformed/empty
# payload degrades to `[]`.
INJECTED=0
if [ -n "$GIT_LOG_FILE" ]; then
  INJECTED=1
  if [ "$GIT_LOG_FILE" = "-" ]; then
    git_findings="$(git_log_to_findings)"          # stdin streams into the tokenizer
  else
    if [ ! -f "$GIT_LOG_FILE" ]; then
      ledgerrecon_fail "input-file-not-found"
    fi
    git_findings="$(git_log_to_findings < "$GIT_LOG_FILE")"
  fi
else
  # LIVE FAIL-CLOSED preflight: bad base / not-a-repo fails closed BEFORE the walk.
  if ! live_git_log_preflight; then
    exit 1
  fi
  # LIVE FAIL-CLOSED parse gate (§4): a NON-EMPTY git output that carries no
  # \x1eCOMMIT\x1f record marker is structurally-broken git output, NOT a real
  # empty log — fail closed rather than mask it as "no prior fixes". An EMPTY
  # output (no commits in <base>..HEAD) is a legitimate "no prior fixes yet" state
  # and stays exit 0. The marker probe streams git once (NUL-safe, no capture);
  # the findings stream git a second time. The injected path is exempt (trusted
  # fixture, fail-open). git's own failure on either stream fails closed.
  # grep -a: the -z stream carries NUL, so force text matching; -F: the marker's
  # \x1e/\x1f bytes are a literal fixed string, never a regex.
  if ! stream_git_log | grep -aqF "$RECORD_MARKER" 2>/dev/null; then
    probe_status="${PIPESTATUS[0]}"
    # grep exit 1 = marker absent. Distinguish empty-log (exit 0, no bytes) from a
    # non-empty unparseable payload: re-probe for ANY byte.
    if [ "$probe_status" -ne 0 ]; then
      ledgerrecon_fail "git-log-failed"
    fi
    if stream_git_log | read -r -n 1 _ 2>/dev/null; then
      ledgerrecon_fail "live-parse-failed"
    fi
  fi
  git_findings="$(stream_git_log | git_log_to_findings)"
fi
case "$git_findings" in '') git_findings='[]' ;; esac

# --- Resolve the normalized payload (injected fixture; optional) -------------
# The normalized payload is JSON (NUL-free), so a variable capture is safe here.
normalized_payload=""
if [ -n "$NORMALIZED_FILE" ]; then
  if ! normalized_payload="$(read_source "$NORMALIZED_FILE")"; then
    exit 1
  fi
fi

thread_findings="$(normalized_to_findings "$normalized_payload")"
case "$thread_findings" in '') thread_findings='[]' ;; esac

reconstruct_ledger "$git_findings" "$thread_findings"

exit 0
