# tests/ledger-reconstruct

Offline behavioral fixtures for `tools/test_ledger_reconstruct.sh` (STEP-003, issue #222).

## Layout

```
tests/ledger-reconstruct/
  git-log-one-commit.txt           git-log payload: 1 remediation commit, 2 files, 2 hunks
  git-log-oscillation.txt          git-log payload: 2 remediation commits, same surface cycling + unique fixed
  git-log-empty.txt                git-log payload: empty (no commits)
  git-log-malformed.txt            git-log payload: malformed text (no valid headers/hunks)
  git-log-feature-churn.txt        git-log payload: 2 non-remediation commits (feat + test) sharing a surface
  git-log-mixed-feature-and-fix.txt git-log payload: 1 feat (excluded) + 2 qualifying fix commits
  normalized-threads.json          fetch-normalize output: review(resolved) + review(unresolved) + ci-check-failure
  expected/
    one-commit-git-only.json      commit findings, no thread records
    one-commit-with-threads.json  commit findings + thread records (ci record skipped)
    oscillation.json              cycling surfaces + fixed surface
    thread-state-merge.json       thread-only: resolved=fixed, unresolved=open, ci skipped
    empty-findings.json           canonical empty findings shape (reused for empty + malformed cases)
    feature-churn-empty.json      empty findings: non-remediation commits excluded by qualification gate
    mixed-feature-and-fix.json    2 findings: feat commit absent, both allowlist arms fire independently
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

## Prior-fix qualification gate

Not every commit in `<base>..HEAD` becomes a git-log finding. The script admits a commit ONLY
when its subject passes a POSITIVE ALLOWLIST (closed-by-construction):

- anchored conventional remediation type: `^(fix|hotfix)(\([^)]*\))?!?:[[:space:]]` (case-sensitive), OR
- literal phrase: `address review feedback` (fixed-substring match)

Ordinary `feat/test/refactor` commits on a multi-commit feature branch contribute ZERO findings,
so they can never produce a false `cycling` or oscillation signal. The `git-log-feature-churn.txt`
and `git-log-mixed-feature-and-fix.txt` fixtures lock this boundary: the former produces empty
findings; the latter produces findings only for the two qualifying fix commits (both allowlist
arms exercised independently).

## Canonicalization

Expected fixtures store the ledger with `branch: null` (live git state) and findings sorted by `id`.
The test runner applies the same transform to actual output before comparison.
