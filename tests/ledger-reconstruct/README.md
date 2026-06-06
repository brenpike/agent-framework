# tests/ledger-reconstruct

Offline behavioral fixtures for `tools/test_ledger_reconstruct.sh` (STEP-003, issue #222).

## Layout

```
tests/ledger-reconstruct/
  git-log-one-commit.txt      git-log payload: 1 commit, 2 files, 2 hunks (commit-finding mapping)
  git-log-oscillation.txt     git-log payload: 2 commits, same surface cycling + unique fixed
  git-log-empty.txt           git-log payload: empty (no commits)
  git-log-malformed.txt       git-log payload: malformed text (no valid headers/hunks)
  normalized-threads.json     fetch-normalize output: review(resolved) + review(unresolved) + ci-check-failure
  expected/
    one-commit-git-only.json      commit findings, no thread records
    one-commit-with-threads.json  commit findings + thread records (ci record skipped)
    oscillation.json              cycling surfaces + fixed surface
    thread-state-merge.json       thread-only: resolved=fixed, unresolved=open, ci skipped
    empty-findings.json           canonical empty findings shape (reused for empty + malformed cases)
```

## Git-log byte format

Commit header: `\x1eCOMMIT\x1f<sha>\x1f<subject>` followed by `git log --unified=0 -p` diff body.
Hunk `@@ -a,b +c,d @@` maps to `line_start=c`, `line_end=c+d-1` (d defaults to 1; d==0 → end=start).

## Canonicalization

Expected fixtures store the ledger with `branch: null` (live git state) and findings sorted by `id`.
The test runner applies the same transform to actual output before comparison.
