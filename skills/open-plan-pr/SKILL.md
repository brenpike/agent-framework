---
name: open-plan-pr
description: Open a pull request for a successfully completed approved plan after final verification.
disable-model-invocation: false
allowed-tools:
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git log *)
  - Bash(git diff *)
  - Bash(git rev-parse *)
  - Bash(git config --get *)
  - Bash(git push *)
  - Bash(gh pr create *)
  - Bash(gh pr view *)
shell: powershell
---

Open a pull request for the completed approved plan.

Follow `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` and `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`.

## Required Inputs

The orchestrator resolves and passes these per `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Resolution Order). The skill does not resolve them on its own.

- `base`: resolved trunk branch (PR target).
- `head`: working branch (current branch).
- `push_remote`: optional explicit remote name. Omit unless the user named one.

## Requirements

1. Confirm current branch matches `head` and is not `base`.
2. Confirm no unexpected unstaged changes.
3. Confirm required validation has passed.
4. Confirm required version/release metadata is included or not required.
5. Capture local HEAD SHA: `git rev-parse HEAD`.
6. Place the working branch on a remote that `gh pr create` can target:
   - if `push_remote` is provided: `git push -u <push_remote> <head>`. On failure, stop blocked.
   - else if upstream tracking is set: run `git push`.
     - on success: continue with that remote.
     - on **non-fast-forward** failure: retry once with a refspec-scoped force-with-lease against the tracked upstream ref. Read remote and upstream ref via git plumbing (string-splitting on `/` is unsafe — branch names like `feature/foo` and rare remote names with `/` make any single-slash split incorrect):
       - `<remote>` = `git config --get branch.<head>.remote`
       - `<upstream_ref>` = `git config --get branch.<head>.merge` (yields `refs/heads/<upstream_branch>`)
       - `<upstream_branch>` = `<upstream_ref>` with the `refs/heads/` prefix stripped
       Run `git push --force-with-lease <remote> HEAD:<upstream_branch>`. The explicit `HEAD:<upstream_branch>` refspec targets the actual tracked branch — not the same-named branch on the remote, which may differ when the local branch tracks a renamed upstream (`push.default=upstream` or explicit branch mapping). Force-with-lease without a value uses the remote-tracking ref as expected, so it succeeds only when the remote tip matches what the local clone last fetched, which covers intentional history rewrites (rebase, amend) without overwriting concurrent pushes.
       - on FWL success: continue.
       - on FWL failure: stop blocked. Remote has commits the local clone has not seen.
     - on **auth / read-only / protected branch / hook-policy** failure: record warning and continue. `gh pr create` may route to a fork or alternate remote. Treat as auth/read-only/protected/hook-policy when stderr contains any of: `Permission denied`, `remote: Permission`, `protected branch`, `403`, `401`, `[remote rejected]`, `remote rejected`, `pre-receive hook`, `update hook`, `push declined`. Treat as non-fast-forward only when stderr contains `non-fast-forward` OR `(fetch first)`. Bare `rejected` is not a non-fast-forward marker on its own (`[remote rejected]` is server-side and is not resolved by force-with-lease).
   - else (no upstream, no `push_remote`): defer to `gh pr create` in step 7. It prompts for push target and can fork the base repo.
7. Run `gh pr create --base <base> ...` with title, summary, validation notes, version/release notes, and unresolved issues. Do not pass `--head` — `--head` makes `gh` skip its push/fork fallback, which defeats step 6's fork-based and unpushed-branch handling. `gh pr create` uses the current branch as head by default; confirm step 1 already verified current branch matches the intended `head`.
8. Verify the PR head SHA matches local HEAD captured in step 5: `gh pr view <pr> --json headRefOid --jq .headRefOid`. If mismatch, stop blocked — the PR points at a stale or wrong commit.

## Do Not

- open PR for a partial plan unless one of: the user explicitly requested a draft PR, OR the planner's `Delivery: Shape` field equals `multi-plan`
- open PR if validation has not been run per the "Validation procedure" definition
- open PR if required version/release metadata is missing per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`
- continue past step 6 with an unverified push state
- invent missing validation
- include any of the strings forbidden by `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Pull Requests) generated-content list

## Output

```text
Status: complete | blocked
Base:
Head:
Local HEAD:
Pushed: yes (git push) | yes (via gh pr create) | no
Push remote:
PR head SHA:
Head verified: yes | no
PR title:
PR URL:
Warnings:
- [warning]
- None
```
