---
name: push-branch
description: Push the current working branch to its remote. No PR creation — push only, for resuming a review loop after remediation commits.
allowed-tools:
  - Bash(git status *)
  - Bash(git branch *)
  - Bash(git rev-parse *)
  - Bash(git config --get *)
  - Bash(git push *)
  - Bash(printf *)
  - Read
shell: bash
---

## Quick Reference

Rules: `GIT-01` (no trunk commits/push)

Before:
- [ ] Current branch matches `head` and is not `base`
- [ ] Git state not unsafe per `${CLAUDE_PLUGIN_ROOT}/governance/definitions.md` (Unsafe Git State)

After:
- [ ] Working branch is on its remote — push SUCCEEDED, or the skill returned `blocked` (exit 1)
- [ ] Final action is a Bash tool call (exit 0 = pushed/routing emitted, exit 1 = blocked)

Push the current working branch to its remote. This skill does NOT create a pull request — its sole job is to place remediation commits on the remote so an in-flight review loop can resume against the updated branch.

Contract: **the push succeeds or the skill returns `blocked`.** There is no warn-and-continue path. In the post-PR `push_remediation` flow a failed push means the review loop would resume against the UNCHANGED remote and could repeat the same finding forever (no `gh pr create` fallback exists here, unlike `hivemind:open-plan-pr`). Any push failure — auth, read-only, protected branch, hook policy, `[remote rejected]`, or a non-fast-forward that force-with-lease cannot resolve — is therefore a terminal `blocked` (exit 1), never a warning.

Follow `${CLAUDE_PLUGIN_ROOT}/governance/workflow.md`.

## Required Inputs

The orchestrator resolves and passes these. The skill does not resolve them on its own.

- `base`: resolved trunk branch — used only as a guard (current branch must not equal it).
- `head`: working branch (current branch).
- `push_remote`: optional explicit remote name. Omit unless the user named one.

## Requirements

1. Confirm current branch matches `head` and is not `base` (GIT-01 — never push trunk). On mismatch or trunk match, exit 1 with blocker.
2. Confirm git state is not unsafe per `${CLAUDE_PLUGIN_ROOT}/governance/definitions.md` (Unsafe Git State). On unsafe state, exit 1 with blocker.
3. Capture local HEAD SHA: `git rev-parse HEAD`.
4. Place the working branch on its remote:
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
     - on **any other** failure (auth, read-only, protected branch, hook policy, `[remote rejected]`): exit 1 with blocker. Do NOT warn and continue — a failed push leaves the remote unchanged, so the post-PR review loop would resume against stale commits and could repeat the same finding indefinitely (there is no PR-creation fallback in this skill). Classify the failure for the blocker message: treat as auth/read-only/protected/hook-policy when stderr contains any of `Permission denied`, `remote: Permission`, `protected branch`, `403`, `401`, `[remote rejected]`, `remote rejected`, `pre-receive hook`, `update hook`, `push declined`; treat as non-fast-forward (eligible for the force-with-lease retry above) only when stderr contains `non-fast-forward` OR `(fetch first)`. Bare `rejected` is not a non-fast-forward marker on its own (`[remote rejected]` is server-side and is not resolved by force-with-lease). Whichever class it is, the result is `blocked`.
   - else (no upstream, no `push_remote`): exit 1 with blocker. There is no remote to push to and none was supplied; the orchestrator must resolve a remote before the review loop can resume.
5. **Final Bash tool call.** Emit YAML routing data to stdout. Derive the branch name and SHA OUT-OF-BAND inside this same Bash call via command substitution captured into shell vars, then reference them only as `"$h"` / `"$c"` — never paste the captured ref bytes as model-authored literal text (untrusted ref bytes in command source allow `$(...)`/backtick command substitution even inside double quotes; bash does NOT re-evaluate command substitution from variable contents — the ADR-0017 out-of-band technique):

   ```bash
   h="$(git rev-parse --abbrev-ref HEAD)"; c="$(git rev-parse HEAD)"; printf 'branch: %s\ncommit: %s\n' "$h" "$c"
   ```

   On success, `branch` + `commit` are the routing data. On any blocking failure above, exit 1 with `blocker: <reason>` on stderr.

## Silence Discipline

This is a pipeline skill:

- Produce zero text output at any point during execution. Your only outputs are tool calls.
- Your final action must be a Bash tool call.
- Exit 0 = orchestrator proceeds. Routing data (`branch` + `commit`) is in stdout.
- Exit 1 = blocked. Emit reason: `printf 'blocker: <reason>' >&2; exit 1`
- Never include a `status:` field in any output.

## Do Not

- create a pull request — this skill pushes only; PR creation belongs to `hivemind:open-plan-pr`.
- push the trunk branch (`base`) under any circumstance.
- continue past step 4 with an unverified push state when the failure is non-fast-forward or no-remote.
- include any of the following strings (any case) in commit messages or output: `Co-Authored-By:`, `Generated with`, `Created with Claude`, `🤖 Generated`, any `Authored-by:` line naming a bot/AI/agent, or any line attributing generated-content authorship.
