# Branching and Pull Request Workflow

## Purpose

This document defines a generic trunk-based branching/PR workflow for projects using the agent framework.

The approved plan is the unit of branch ownership, execution, checkpoint-commit decisions, PR submission, and external review remediation.

This workflow is mandatory for all agent activity unless overridden by project policy or by an explicit user instruction for a specific task.

## Resolution Order for Branch / Merge / Review Policy

The orchestrator owns resolution. Workflow skills (`agent-framework:create-working-branch`, `agent-framework:checkpoint-commit`, `agent-framework:open-plan-pr`) do not resolve these values themselves; they receive resolved values as explicit inputs from the orchestrator and stop blocked if any are missing.

When a policy decision is needed, resolve in this order. Use the first source that defines the value:

1. Explicit user override for the current task.
2. Project `CLAUDE.md` (e.g. `trunk branch`, `merge strategy`, `review policy`).
3. Repo metadata at runtime:
   - 3a. Local default branch (preferred): `git symbolic-ref refs/remotes/origin/HEAD --short | sed 's|^origin/||'` — use if exit code is 0 and output is non-empty. This is the fastest and most portable resolution: no network, no auth, available in all git versions.
   - 3b. GitHub default branch (fallback): `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` — use only when 3a fails (e.g., `origin/HEAD` is not set, as can happen with `git init` + manual remote add, or `git clone --no-checkout`). To refresh a stale `origin/HEAD` after a remote default-branch rename, run `git remote set-head origin --auto` (requires network).
   - Branch protection / required reviews: `gh api repos/{owner}/{repo}/branches/{branch}/protection` when accessible.
4. Framework defaults below.

If a value cannot be resolved from sources 1-3, use the framework default and note it in the orchestrator's report.

## Framework Defaults

These defaults apply when sources 1-3 are silent:

- Trunk branch: `main`.
- Merge strategy into trunk: squash merge.
- Review requirement: at least one approving review from a human reviewer (account type = User on GitHub) before merge. Codex and other automated reviewers are external review sources but do not satisfy this requirement.
- One approved plan = one working branch = one PR.
- PR target: the resolved trunk branch.
- Trunk must remain stable and deployable.

## Hard Rules (apply regardless of resolution source)

1. Never commit directly to the resolved trunk branch.
2. Never push directly to the resolved trunk branch.
3. Develop all changes on a non-trunk working branch.
4. Workers must not perform git write actions unless explicitly delegated and allowed by policy.

## Branch Taxonomy

Use exactly one prefix:

- `feature/<topic>` — features or new capabilities
- `bugfix/<topic>` — non-emergency defects
- `hotfix/<topic>` — urgent production fixes
- `refactor/<topic>` — structural improvement without intended behavior change
- `chore/<topic>` — maintenance
- `docs/<topic>` — documentation-only
- `test/<topic>` — test-only
- `ci/<topic>` — CI/CD or workflow changes

Branch format:

- `<prefix>/<topic>`
- `<prefix>/<ticket>-<topic>`

Naming constraints:

- lowercase only
- numbers allowed
- words separated by hyphens
- no spaces
- no underscores
- no extra slashes beyond the prefix separator
- include ticket/issue ID when one exists

## Plan-to-Branch Mapping

Default: one approved plan maps to one branch and one PR.

Use multiple branches/PRs only when the planner explicitly decomposes the request into multiple plans where each plan's PR can be merged without requiring any other plan's PR to be merged first.

## Required Git Preflight

Before implementation begins, the orchestrator must define:

- work classification
- base branch (resolved per resolution order)
- trunk freshness (fetch + divergence check)
- working branch name
- whether the branch exists or must be created
- whether worktrees are used
- checkpoint commit policy
- intended PR target (resolved per resolution order)

If any item is undefined, implementation must not begin.

### Preflight Command Recipes

Each item below includes the resolution command and expected output shape. Run these (or equivalent) to establish preflight values before implementation begins. If any command fails or returns an unexpected shape, the item is undefined and implementation must not begin.

| Preflight Item | Command | Expected Output |
|---|---|---|
| Work classification | (determined from plan or user input) | One of: `feature\|bugfix\|hotfix\|refactor\|chore\|docs\|test\|ci` |
| Base branch | Try `git symbolic-ref refs/remotes/origin/HEAD --short \| sed 's\|^origin/\|\|'` first (exits 0 + non-empty = done). Fall back to `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` when 3a fails. | Branch name string — resolved via local `origin/HEAD` first, then GitHub API fallback, unless overridden by user or `CLAUDE.md` |
| Trunk freshness | `git fetch origin <trunk>:refs/remotes/origin/<trunk> && git rev-list --left-right --count <local-trunk>...origin/<trunk>` | Two tab-separated integers (LEFT RIGHT): `0\t0` = fresh (proceed); LEFT>0 = local trunk has unpushed commits (diverged); RIGHT>0 = stale (N commits behind origin); any non-zero = block branch creation, present user choice |
| Working branch name | (constructed from classification + topic per Branch Taxonomy) | `<prefix>/<topic>` matching naming constraints |
| Branch exists vs create | `git branch --list <name>` (local); `git ls-remote --heads origin <name>` (remote — required only when the workflow will push or open a PR; skip when using a no-PR opt-out or when no remote is configured) | Empty = create; non-empty = exists. Local check alone is sufficient for no-PR/offline scenarios |
| Worktree decision | (determined from plan parallelism requirements per Worktrees section) | `yes` or `no` |
| Checkpoint commit policy | (derived from plan phase count and risk flags per Commit Policy section) | One of: `none\|checkpoint allowed\|checkpoint expected` |
| PR target | Same resolution as base branch | Branch name string |

### Trunk Freshness Gate

Purpose: detect a stale local trunk before branching. A stale trunk leads to rebase pain later and can cause wrong-baseline version bumps when the remote trunk has already been bumped.

The fetch command (`git fetch origin <trunk>:refs/remotes/origin/<trunk>`) is a single-ref, read-only fetch — it updates only `origin/<trunk>` and has no side effects on the working tree or local branches.

**Divergence check:** use `--left-right --count` with a three-dot range (`<local-trunk>...origin/<trunk>`, not `HEAD...origin/<trunk>`). The three-dot range computes the symmetric difference — commits reachable from either side but not both. Output is two tab-separated integers: LEFT = commits in `<local-trunk>` not in `origin/<trunk>` (local-only commits); RIGHT = commits in `origin/<trunk>` not in `<local-trunk>` (origin-only commits). Both must be zero for fresh. When the orchestrator is already on a working branch at preflight time, `HEAD` points at the working branch, not trunk. Always use the resolved local trunk branch name for the left side of the range.

**Threshold:** any non-zero LEFT or RIGHT count = not fresh.

**Blocking behavior:** when any count is non-zero, the orchestrator must NOT invoke `agent-framework:create-working-branch`. Instead, surface the counts and present the user with two choices:

1. **Fix and continue** — update the local trunk ref using the checkout-safe approach for the current branch state, then re-check divergence to confirm `0\t0`:
   - When currently on trunk: `git pull --ff-only origin <trunk>` (safe while trunk is checked out).
   - When currently on a working branch: `git fetch origin <trunk>:<trunk>` (updates the local trunk ref directly without switching). If the local trunk cannot be fast-forwarded, git returns a non-zero exit; treat that as a blocker and report to user.
   - When LEFT>0 (local trunk has unpushed commits): the local trunk has diverged from origin. Present user with additional sub-choice: push the local commits (`git push origin <trunk>`) or reset local trunk to match origin (`git fetch origin <trunk>:<trunk>` — only safe when not on trunk; otherwise `git reset --hard origin/<trunk>`). Confirm `0\t0` after the chosen action before proceeding.
2. **Proceed anyway (your risk)** — orchestrator records the appropriate state in Session facts and proceeds to branch creation without updating local trunk:
   - RIGHT>0 only: `trunk-freshness: stale (N behind)`
   - LEFT>0 only: `trunk-freshness: stale (diverged — local N ahead)`
   - Both>0: `trunk-freshness: stale (diverged — local M ahead, N behind)`

**When fresh:** record `trunk-freshness: fresh` in Session facts.

**Skip conditions:** skip the fetch and divergence check entirely when any of the following is true:

- The workflow will not push or open a PR (no-PR opt-out), matching the existing "Remote reachable" skip condition in Safe Git State Check.
- No remote is configured.

When any skip condition applies, record `trunk-freshness: skipped` in Session facts before invoking `agent-framework:create-working-branch`.

**When local trunk branch does not exist:** skip the divergence check and warn the user. The fetch will still update `origin/<trunk>`, but without a local tracking branch the rev-list comparison has no left side. The orchestrator should note this in the report and proceed — branch creation from `origin/<trunk>` is still valid. Record `trunk-freshness: skipped` in Session facts before invoking `agent-framework:create-working-branch`.

**When `git fetch origin <trunk>:refs/remotes/origin/<trunk>` fails despite remote being reachable:** treat the trunk as stale, surface the fetch error, and present the same two choices (pull and continue, or proceed anyway).

### Safe Git State Check

Run before any git write operation. Each check maps to a condition from the Unsafe git state definition in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions). Do not begin implementation if any check fails.

| Check | Command | Pass Condition |
|---|---|---|
| Not on trunk | `git branch --show-current` | Output is not the resolved trunk branch |
| No detached HEAD | `git symbolic-ref HEAD` | Exits 0 (attached to a branch) |
| No unmerged paths | `git ls-files -u` | Empty output |
| No in-progress operation | For each sentinel in `MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG`: resolve via `git rev-parse --git-path <sentinel>`, then `test ! -f <resolved path>` | All resolved sentinel paths are absent (do not hardcode `.git/`; the git dir may be a pointer file in linked worktrees) |
| No out-of-scope changes | `git status --porcelain` | Empty output, or every listed path is within the agent's assigned file scope |
| Trunk branch identifiable | Try `git symbolic-ref refs/remotes/origin/HEAD --short \| sed 's\|^origin/\|\|'` first (exits 0 + non-empty = done). Fall back to `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`. | Returns a non-empty branch name string from either command |
| Remote reachable | `git ls-remote --exit-code origin HEAD` | Exits 0. Required only when the workflow will push or open a PR; skip when using a no-PR opt-out or when no remote is configured |

## Branch Creation

The orchestrator creates or confirms the working branch only after:

- the planner returns a complete plan or the trivial fast path applies
- open questions are resolved
- implementation is ready to begin
- repo state is safe

Use the `agent-framework:create-working-branch` skill when creating/switching branches.

## Commit Policy

Workers do not commit automatically.

Checkpoint commits are allowed only when one of the following is true:

- a phase from the orchestrator's plan has been verified per the Phase Verification list in `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md`
- a milestone has been verified — a milestone is any plan item whose `Outcome:` is reachable only after two or more phases AND the orchestrator's plan explicitly labels the item `Milestone: <name>`
- the next planned phase touches more than 5 files OR requires a database/schema migration OR is flagged `risk=high` in the plan, and a recovery point is needed before that phase begins
- a review-remediation fix is complete, validated per the Validation procedure definition, and ready to push
- a version bump is complete, version files are consistent across required artifacts per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`, and changelog/release notes are updated when required

Default commit owner: orchestrator through `agent-framework:checkpoint-commit`.

Coder may commit only when explicitly delegated. Designer never commits.

Commit messages use conventional-style types:

- `feat`
- `fix`
- `hotfix`
- `refactor`
- `docs`
- `test`
- `chore`
- `ci`

Do not mix unrelated changes. Stage only files that belong to the completed phase, milestone, version bump, or review-remediation item.

## Version Bumps

See `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`.

A PR is not ready to merge until required version/release metadata changes are included.

Version bumps are included in the same PR as the triggering change unless the user explicitly directs otherwise.

## Pull Requests

The orchestrator opens PRs using `agent-framework:open-plan-pr` only when:

- the approved plan is complete
- the Validation procedure returned either every declared command passed, OR `Not run (no validation commands defined)`; PR is not opened if the procedure returned Blocked or any command failed
- outputs are coherent and in scope
- required version/release metadata is included per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`
- the working branch has been pushed
- the branch is ready to merge into the target branch

Default target: the resolved trunk branch (per resolution order above).

Use draft PRs only when explicitly requested or when the planner split staged reviewable deliverables.

PR content must include:

- summary of 5 sentences or fewer
- every file path modified in the PR diff, grouped under the planner's `Files:` list per step (one bullet per step naming each file)
- validation performed (matching the Validation procedure definition output)
- version/release notes when the change matches the Bump Trigger in `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`
- every item from the planner's `Constraints` output and every item from the planner's `Open questions` output

Never include any of the following in commit messages or PR content:

- the literal string `Co-Authored-By:` (any case)
- the literal string `Generated with` (any case)
- the literal string `🤖 Generated`
- the literal string `Created with Claude` (any case)
- any `Authored-by:` line whose value names a bot, AI, or automated agent
- any other line whose intent is to attribute generated-content authorship

## External Review Remediation

See `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`.

The orchestrator owns review replies, resolution, re-review requests, remediation commits, and pushes.

External review remediation stays on the same PR branch unless:

- feedback is outside the approved plan
- feedback requires a separate independently shippable change
- the PR is already merged or closed

## Merge Policy

Changes reach the resolved trunk only through PR.

Before merge readiness, all of the following must be satisfied per the resolution order:

- required CI passes
- the Validation procedure returned either every declared command passed, OR `Not run (no validation commands defined)`; merge is blocked if the procedure returned Blocked or any command failed
- required version/release metadata is present
- the project's review requirement is met (framework default: at least one human review)
- the project's merge strategy is followed (framework default: squash merge)

## Syncing With Trunk

When a branch falls behind the resolved trunk, use rebase. Use merge only when one of the following is true:

- the working branch has been pushed and other contributors have committed to it
- the rebase produces conflicts in more than 3 files
- the user explicitly requests merge

Stop and reassess if conflict resolution requires any of:

- editing a file not in the approved plan's file scope
- editing a public API signature, exported function/method signature, exported type, schema declaration, or generated-stub source listed in `CLAUDE.md`
- more than 10 lines of conflict-resolution code in any single hunk

## Hotfix Standard

For urgent production fixes:

1. create `hotfix/<topic>` from the resolved trunk
2. implement the "Smallest correct fix" per `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions)
3. validate
4. open PR to the resolved trunk
5. merge per the project's merge strategy after required approval, unless the user explicitly directs a different emergency process

## Worktrees

Worktrees are optional.

Use worktrees only when every one of the following is true:

1. the orchestrator's plan has two or more phases that can run concurrently with no shared file in their assigned scopes
2. the assigned file scopes for those phases share no path
3. two or more Claude sessions are running concurrently against this repo
4. the estimated wall-clock savings of parallel execution exceed 30 minutes versus running the same phases sequentially

Do not create one worktree per agent by default.

## Branch Cleanup

After PR merge, delete the working branch.

After PR closure without merge, create a new branch for follow-up unless the same PR is immediately resumed.

## Scope Drift

If implementation reveals extra work outside the approved plan:

1. stop
2. reassess scope
3. invoke `agent-framework:planner` via the Agent tool again whenever the added work changes any of: file scope, owner agent, edge cases, dependencies, delivery shape, version impact, or branch classification

Remain on the same branch only when the added work fits inside the same approved plan's file scope and does not change any of the items above.
