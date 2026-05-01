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
   - GitHub default branch: `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`
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
- working branch name
- whether the branch exists or must be created
- whether worktrees are used
- checkpoint commit policy
- intended PR target (resolved per resolution order)

If any item is undefined, implementation must not begin.

## Branch Creation

The orchestrator creates or confirms the working branch only after:

- the planner returns a complete plan or the planner-skip exception applies
- open questions are resolved
- implementation is ready to begin
- repo state is safe

Use the `agent-framework:create-working-branch` skill when creating/switching branches.

## Commit Policy

Workers do not commit automatically.

Checkpoint commits are allowed only when one of the following is true:

- a phase from the orchestrator's plan has been verified per the Phase Verification list in `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md`
- a milestone explicitly named in the orchestrator's plan or delegation has been verified
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
- key files/areas changed
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
- editing a public API signature, exported type, or contract
- more than 10 lines of conflict-resolution code in any single hunk

## Hotfix Standard

For urgent production fixes:

1. create `hotfix/<topic>` from the resolved trunk
2. implement minimal safe change
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
3. invoke `agent-framework:planner` again whenever the added work changes any of: file scope, owner agent, edge cases, dependencies, delivery shape, version impact, or branch classification

Remain on the same branch only when the added work fits inside the same approved plan's file scope and does not change any of the items above.
