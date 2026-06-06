# tests/ledger-reconstruct

Offline behavioral fixtures for `tools/test_ledger_reconstruct.sh` (STEP-003, issue #222).

## Layout

```
tests/ledger-reconstruct/
  git-log-one-commit.txt           git-log payload: 1 remediation commit, 2 files, 2 hunks
  git-log-oscillation.txt          git-log payload: 2 remediation commits touching the same surface + 1 unique surface
  git-log-empty.txt                git-log payload: empty (no commits); also reused as empty normalized payload
  git-log-malformed.txt            git-log payload: malformed text (no valid headers/hunks); also reused as garbage normalized payload
  git-log-feature-churn.txt        git-log payload: 2 non-remediation commits (feat + test) sharing a surface
  git-log-mixed-feature-and-fix.txt git-log payload: 1 feat (excluded) + 1 review-loop fix (qualifies) + 1 ordinary dev fix (excluded)
  normalized-threads.json          fetch-normalize output: review(resolved) + review(unresolved) + ci-check-failure
  expected/
    one-commit-git-only.json      commit findings, no thread records
    one-commit-with-threads.json  commit findings + thread records (ci record skipped)
    oscillation.json              multi-commit same-surface: all findings "fixed" (no cycling label — cycling is agent judgment)
    thread-state-merge.json       thread-only: resolved=fixed, unresolved=open, ci skipped
    empty-findings.json           canonical empty findings shape (reused for empty + malformed cases)
    feature-churn-empty.json      empty findings: non-remediation commits excluded by qualification gate
    mixed-feature-and-fix.json    1 finding: feat AND ordinary dev fix(parser) excluded; only the review-loop "address review feedback" commit qualifies
```

## Git-log byte format

Fixtures mirror the LIVE format the script emits and parses:
`git log <base>..HEAD --no-color --unified=0 -z --raw -p --find-renames --format=$'\x1eCOMMIT\x1f%H\x1f%s'`.

Per-commit byte layout (NUL = `\0`, US = `\x1e`, RS = `\x1f`):

```
\x1eCOMMIT\x1f<sha>\x1f<subject>\0      format record; -z appends a NUL terminator
\n:<m> <m> <b> <b> <STATUS>\0           one --raw entry per changed file
<path1>\0[<path2>\0]                    R/C status emits two paths (old,new); else one
\0                                      empty token: raw-block terminator
<patch>                                 the -p unified-diff body
```

PATHS come from the `--raw` machine channel (NUL-delimited, never quoted, space-/rename-safe);
the destination (new-file) path is the LAST path of each entry. The `-p` hunks are correlated to
files BY ORDER (Nth `diff --git` = Nth raw entry); the diff line's path text is ignored. Only the
hunk arithmetic is read from `-p`: `@@ -a,b +c,d @@` maps to `line_start=c`, `line_end=c+d-1`
(d defaults to 1; d==0 → end=start).

Because the fixtures carry NUL delimiters, they are generated/edited as raw bytes (not plain text)
and the script streams them straight into the tokenizer — never through a shell-variable capture
(bash strips NUL). `git-log-empty.txt` is zero bytes (a legitimate "no commits" log);
`git-log-malformed.txt` is non-empty text with no `\x1eCOMMIT\x1f` record marker (injected fail-open
→ empty findings, exit 0).

## De-scoped skeleton: factual status only, no cycling

The script is a DETERMINISTIC SKELETON. All judgment — cycling/oscillation interpretation,
iteration grouping, N-2 recurrence, diminishing-returns trend, and the `fix_framing` cluster key
— is owned by the github-reviewer agent, NOT by this script. The script emits only facts
mechanically derivable from ground truth.

**Status:** every git-log fix-surface finding carries `status: "fixed"` (the surface was touched
by a qualifying remediation commit). The script NEVER emits `status: "cycling"`. When two commits
touch the same surface (as in `git-log-oscillation.txt`), both findings carry `"fixed"` — the
agent observes the repeated surface from the per-finding `file`/`line_start`/`fix_commit` facts
and applies cycling interpretation itself (P7 judgment). `oscillation.json` reflects this: all
three findings carry `"fixed"`.

**Iteration grouping:** `iterations[0]` is a SCHEMA-CONFORMANCE CONTAINER only — it is NOT an
iteration boundary. `introduced_iteration` is a constant `1` placeholder. Iteration boundaries
are not reconstructable from git history and are not asserted anywhere in the expected fixtures.

## Prior-fix qualification gate

Not every commit in `<base>..HEAD` becomes a git-log finding. The script admits a commit ONLY
when its subject passes a POSITIVE ALLOWLIST (closed-by-construction):

- literal phrase: `address review feedback` (fixed-substring match) — the DETERMINISTIC subject
  both reviewers emit (github-reviewer step 7: `fix(<scope>): address review feedback`;
  local-reviewer molt remediation checkpoints carry the same phrase).

The bare conventional `fix:`/`hotfix:` type alone is NOT sufficient: an ordinary bug-fix an
engineer makes BEFORE the review loop runs (e.g. `fix(parser): correct off-by-one`) is normal
development, not review remediation, and admitting it would let ordinary commits drive false
mutation-decay/cluster signals (PR #223 P1). So ordinary `feat/test/refactor` AND ordinary
`fix/hotfix` dev commits on a multi-commit feature branch contribute ZERO findings.
`git-log-feature-churn.txt` and `git-log-mixed-feature-and-fix.txt` lock this boundary.

## Fail-closed / fail-open gates

Two live-vs-injected discriminators keep the script safe in production while remaining testable
offline. The INJECTED flag is set iff `--git-log-file` is present (trusted fixture path, used
only by the test harness). The LIVE path is what the agent uses at runtime.

**Git-log channel:**
- Live non-empty payload with no `\x1eCOMMIT\x1f` record marker → `LEDGERRECON_ERROR=live-parse-failed` + exit 1.
- Injected malformed payload → fail-open: empty findings, exit 0.
- Empty live log (zero bytes) → valid empty-findings exit 0 (legitimate "no prior fixes yet").

Seam: `LEDGERRECON_TEST_LIVE_PAYLOAD_FILE=<file>` replaces `git log` on the live path (mirrors
`FETCHNORM_LIVE_*` pattern). Setting it to `git-log-empty.txt` suppresses live git entirely.

**Normalized channel (fetch-normalize output):**
- Live non-empty payload that is not a JSON array → `LEDGERRECON_ERROR=normalized-parse-failed` + exit 1.
- Injected (INJECTED=1) garbage normalized payload → fail-open: coerced to `[]`, exit 0.
- Empty live normalized payload (zero bytes) → valid empty thread-findings exit 0.

The normalized live gate runs only when `INJECTED != 1`. The test suite drives this via
`LEDGERRECON_TEST_LIVE_PAYLOAD_FILE=git-log-empty.txt` (suppresses git log) plus
`--normalized-file git-log-malformed.txt` (non-JSON garbage) without `--git-log-file`, keeping
INJECTED=0 so the gate fires.

## Canonicalization

Expected fixtures store the ledger with `branch: null` (live git state) and findings sorted by `id`.
The test runner applies the same transform to actual output before comparison.
