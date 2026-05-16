---
name: open-plan-pr
description: Open a pull request for a successfully completed approved plan after final verification.
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
  - Bash(printf *)
shell: bash
---

## Quick Reference

Rules: `GIT-01` (no trunk commits), `VAL-01` (validation gate), `VAL-02` (PR only after validation)

Before:
- [ ] Current branch matches `head` and is not `base`
- [ ] Validation passed or "Not run (no validation commands defined)"
- [ ] Required version/release metadata included or not required
- [ ] No unexpected unstaged changes

After:
- [ ] PR head SHA matches local HEAD
- [ ] PR created with `--base` targeting resolved trunk
- [ ] Final action is a Bash tool call (exit 0 = succeeded, exit 1 = blocked)

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
3. Confirm validation outcome per `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions → Validation procedure) is one of: every declared command passed, OR `Not run (no validation commands defined)`. Exit 1 with blocker if the procedure returned the Worker Report — Blocked (`stage: validation`) or any declared command failed.
4. Confirm required version/release metadata is included or not required.
5. Capture local HEAD SHA: `git rev-parse HEAD`.
6. Place the working branch on a remote that `gh pr create` can target:
   - if `push_remote` is provided: `git push -u <push_remote> <head>`. On failure, exit 1 with blocker.
   - else if upstream tracking is set: run `git push`.
     - on success: continue with that remote.
     - on **non-fast-forward** failure: retry once with a refspec-scoped force-with-lease against the tracked upstream ref. Read remote and upstream ref via git plumbing (string-splitting on `/` is unsafe — branch names like `feature/foo` and rare remote names with `/` make any single-slash split incorrect):
       - `<remote>` = `git config --get branch.<head>.remote`
       - `<upstream_ref>` = `git config --get branch.<head>.merge` (yields `refs/heads/<upstream_branch>`)
       - `<upstream_branch>` = `<upstream_ref>` with the `refs/heads/` prefix stripped
       Run `git push --force-with-lease <remote> HEAD:<upstream_branch>`. The explicit `HEAD:<upstream_branch>` refspec targets the actual tracked branch — not the same-named branch on the remote, which may differ when the local branch tracks a renamed upstream (`push.default=upstream` or explicit branch mapping). Force-with-lease without a value uses the remote-tracking ref as expected, so it succeeds only when the remote tip matches what the local clone last fetched, which covers intentional history rewrites (rebase, amend) without overwriting concurrent pushes.
       - on FWL success: continue.
       - on FWL failure: exit 1 with blocker. Remote has commits the local clone has not seen.
     - on **auth / read-only / protected branch / hook-policy** failure: record warning and continue. `gh pr create` may route to a fork or alternate remote. Treat as auth/read-only/protected/hook-policy when stderr contains any of: `Permission denied`, `remote: Permission`, `protected branch`, `403`, `401`, `[remote rejected]`, `remote rejected`, `pre-receive hook`, `update hook`, `push declined`. Treat as non-fast-forward only when stderr contains `non-fast-forward` OR `(fetch first)`. Bare `rejected` is not a non-fast-forward marker on its own (`[remote rejected]` is server-side and is not resolved by force-with-lease).
   - else (no upstream, no `push_remote`): defer to `gh pr create` in step 7. It prompts for push target and can fork the base repo.
7. Run `gh pr create --base <base> ...` with title, summary, validation notes, version/release notes, and unresolved issues. Do not pass `--head` — `--head` makes `gh` skip its push/fork fallback, which defeats step 6's fork-based and unpushed-branch handling. `gh pr create` uses the current branch as head by default; confirm step 1 already verified current branch matches the intended `head`.
8. Final Bash tool call: `gh pr view <pr> --json url,headRefOid`. Verify headRefOid matches local HEAD from step 5. If mismatch, emit `printf 'blocker: PR head SHA mismatch — expected %s got %s' "$local_sha" "$pr_sha" >&2; exit 1`. On success, the JSON output (url + headRefOid) is the routing data.

## Silence Discipline

This is a pipeline skill. Per `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` (Skill Output Convention):

- Produce zero text output at any point during execution. Your only outputs are tool calls.
- Your final action must be a Bash tool call.
- Exit 0 = orchestrator proceeds. Routing data (if any) is in stdout.
- Exit 1 = blocked. Emit reason: `printf 'blocker: <reason>' >&2; exit 1`
- Never include a `status:` field in any output.

## Do Not

- open PR for a partial plan unless one of: the user explicitly requested a draft PR, OR the planner's `Delivery: Shape` field equals `multi-plan`
- open PR if the Validation procedure returned the Worker Report — Blocked (`stage: validation`) or any declared validation command failed. `Validated: Not run (no validation commands defined)` is a valid terminal state per `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions → Validation procedure) and does not block PR opening.
- open PR if required version/release metadata is missing per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`
- continue past step 6 with an unverified push state
- invent missing validation
- include any of the strings forbidden by `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Pull Requests) generated-content list
