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
- Review requirement: at least one human review before merge.
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

Use multiple branches/PRs only when the planner explicitly decomposes the request into independently reviewable and independently shippable plans.

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

Checkpoint commits are allowed only when:

- a phase is complete
- a meaningful milestone is complete
- a recovery point is needed before higher-risk work
- a review-remediation fix is complete, validated, and ready to push
- a version bump is complete and verified

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
- required validation passed
- outputs are coherent and in scope
- required version/release metadata is included
- the working branch has been pushed
- the branch is ready to merge into the target branch

Default target: the resolved trunk branch (per resolution order above).

Use draft PRs only when explicitly requested or when the planner split staged reviewable deliverables.

PR content must include:

- concise summary
- key files/areas changed
- validation performed
- version/release notes when relevant
- notable constraints or unresolved issues

Never include `co-authored by`, `Generated by`, or similar generated-content signatures.

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
- required validation passes
- required version/release metadata is present
- the project's review requirement is met (framework default: at least one human review)
- the project's merge strategy is followed (framework default: squash merge)

## Syncing With Trunk

When a branch falls behind the resolved trunk, prefer rebase when practical. Avoid unnecessary merge commits.

If conflict resolution changes scope or risk materially, stop and reassess.

## Hotfix Standard

For urgent production fixes:

1. create `hotfix/<topic>` from the resolved trunk
2. implement minimal safe change
3. validate
4. open PR to the resolved trunk
5. merge per the project's merge strategy after required approval, unless the user explicitly directs a different emergency process

## Worktrees

Worktrees are optional.

Use worktrees only when all are true:

1. orchestrator identifies parallelizable phases
2. file scopes do not overlap
3. separate Claude sessions are actually being used
4. complexity is justified

Do not create one worktree per agent by default.

## Branch Cleanup

After PR merge, delete the working branch.

After PR closure without merge, create a new branch for follow-up unless the same PR is immediately resumed.

## Scope Drift

If implementation reveals extra work outside the approved plan:

1. stop
2. reassess scope
3. replan if needed

Remain on the same branch only if the added work is within the same approved deliverable.
