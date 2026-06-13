# shellcheck shell=bash
#
# ledger-reconstruct-parse.sh — shared PURE git-log parse stage for the
# ledger-reconstruct entrypoint (github-review-loop). Defines git_log_to_findings:
# the awk git-log TOKENIZER + the jq fix-surface assembly stages, INCLUDING the
# positive-allowlist `address review feedback` prior-fix qualification gate.
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: the ledger-reconstruct entrypoint
# sources it by absolute path derived from its OWN script_dir
# (`. "$plugin_root/skills/_shared/ledger-reconstruct-parse.sh"`). It defines functions
# only; it runs no top-level statements and changes no caller state beyond defining the
# function below. `bash -n` validates it as a sourced fragment.
#
# P18 FLOOR EXCEPTION (ADR-0020): as a SOURCED library this file deliberately
# OMITS the P18 shell-safety floor `set -e` / `set -o pipefail` and any EXIT trap. A sourced
# file mutates the SOURCING shell's option state, so installing those here would corrupt
# the entrypoint's shell; the floor is therefore the documented exception, not the full
# `set -euo pipefail`. This file carries no top-level `set` at all (pure function
# definitions); the ENTRYPOINT owns its own `set -u`, EXIT trap, and error routing.
# Allowlisted under CHECK13 as a P18 documented exception.
#
# VARIABLE CONTRACT: git_log_to_findings runs in the SOURCING (entrypoint) shell, so it
# reads the caller-shell globals the entrypoint defines BEFORE sourcing — `US` (0x1e
# record start) and `RS` (0x1f field sep). They are NOT function parameters; the exact
# reference pattern (`awk -v US="$US" -v RS_FIELD="$RS"` / `--arg sep "$RS"`) is preserved
# verbatim from the monolith.

# git_log_to_findings: PURE CORE (offline). Read a git-log payload on STDIN (live
# OR injected — identical bytes, streamed so NUL delimiters survive) and emit a
# JSON array of git-log fix-surface findings on stdout. One finding per
# (commit, file, hunk), each with FACTUAL status `fixed` (no cycling/oscillation
# interpretation — that is agent judgment, P7). A malformed / empty payload yields
# `[]` (INJECTED FAIL-OPEN). No git/network here.
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

      # PRIOR-FIX QUALIFICATION GATE (positive allowlist, closed-by-construction).
      # Only a REMEDIATION commit may become a git-log prior-fix finding. The
      # reviewers emit a DETERMINISTIC remediation subject (github-reviewer step 7:
      # "fix(<scope>): address review feedback"; local-reviewer molt remediation
      # checkpoints carry the same phrase), so this allowlist keys EXACTLY on that
      # reviewer-owned phrase. An ordinary conventional `fix:`/`hotfix:` bug-fix an
      # engineer makes BEFORE the review loop runs (e.g. "fix(parser): correct
      # off-by-one") is NOT review remediation and must NOT enter the reconstructed
      # ledger as a prior-fix/cycling surface — admitting the bare conventional type
      # would let ordinary development drive false mutation-decay / root-cluster
      # signals. So the gate keys ONLY on the literal review-loop phrase, never on
      # the conventional commit type. Evaluated on the parsed subject; non-qualifying
      # commits emit zero findings.
      #   - the literal phrase "address review feedback" (fixed-substring index()
      #     test — NO regex metachar handling), the deterministic subject both
      #     reviewers emit. By construction an ordinary fix/hotfix dev commit cannot
      #     qualify.
      is_remediation = (index(subject, "address review feedback") > 0)
      if (!is_remediation) next

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
      # Stage 2b: build one finding per git-log fix surface. Status is FACTUAL
      # `fixed` (the surface was touched by a qualifying remediation commit). NO
      # cycling/oscillation interpretation — surface re-appearance is observable to
      # the agent from the per-finding file/line/fix_commit facts (P7 judgment).
      [ .[]
        | {
            id: ("fix:\(.sha):\(.file):\(.line_start)"),
            severity: null,
            title: .subject,
            body: null,
            recommendation: null,
            file: .file,
            line_start: .line_start,
            line_end: .line_end,
            status: "fixed",
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
