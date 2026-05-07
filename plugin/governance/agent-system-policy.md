# Agent System Policy

## Purpose

Canonical cross-agent policy for the Claude Code multi-agent framework.

This file defines shared constraints once. Agent files define role-specific deltas. Skill files define executable procedures. Project facts live in `CLAUDE.md`.

Do not copy this policy into agents or skills. Reference it, and duplicate only short safety-critical stop rules where isolation requires it.

## Definitions

Canonical definitions referenced by every other section and by agent/skill files. When any rule uses a term defined here, the definition below is binding.

### Transient failure

A failure is transient if and only if its root cause matches one of:

- HTTP 5xx response
- HTTP 429 response
- TCP connection reset, refused, or aborted
- DNS resolution failure
- TLS handshake failure
- command exit code 124 (timeout) or 137 (SIGKILL)
- network unreachable / no route to host
- Git transient failure: `Connection timed out`, `RPC failed`, `early EOF`, `index-pack failed`

Every other failure is non-transient and must not be retried. This includes: HTTP 4xx (except 429), JSON/parser errors, missing-tool errors, permission denials, file-not-found, command exit codes 1–123 (other than the listed timeouts), and any failure whose stderr matches the auth/protected-branch patterns enumerated in `${CLAUDE_PLUGIN_ROOT}/skills/open-plan-pr/SKILL.md`.

### Unsafe git state

Git state is unsafe if any of the following is true at the moment of the check:

- current branch is the resolved trunk branch
- HEAD is detached
- the index has unmerged paths (`git ls-files -u` returns non-empty output, or `git status --porcelain=v1` reports any file with `U` in its XY status)
- a rebase, merge, cherry-pick, or bisect is in progress (`.git/MERGE_HEAD`, `.git/REBASE_HEAD`, `.git/CHERRY_PICK_HEAD`, `.git/BISECT_LOG` exists)
- the working tree contains uncommitted changes to files outside the agent's currently assigned file scope
- the resolved trunk branch cannot be identified

### Trivial change

A change is trivial if and only if all of the following are true:

- the sum of added plus removed lines in the diff is ≤ 20 (excluding generated files, lockfiles, and pure whitespace)
- diff touches exactly one file
- the file is not in any of: public API surface (exported declarations, package entry points), configuration schema files, database schema files, dependency manifests (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc.), build scripts, CI files, or canonical version files identified by `CLAUDE.md`
- the change does not add a new exported symbol, remove an exported symbol, or rename an exported symbol

The terms "low-risk change", "small change", "non-architectural change", and "minor change" appearing elsewhere in this framework are aliases for "trivial change" as defined here.

### Same finding (repeat detection)

A review finding repeats when any of the following matches a finding seen in a prior remediation cycle on the same PR:

- same review-thread ID, OR
- same comment ID, OR
- the tuple (file path, line number, classification per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` Classification list), OR
- comment body text after lower-casing, removing surrounding whitespace, and collapsing internal whitespace runs to a single space

A finding "repeats after attempted remediation" when one of the above matches and at least one full remediation cycle (delegate → commit → push) has run on that finding since it first appeared.

### Smallest correct fix

The smallest correct fix is the change with the fewest changed files that addresses the targeted feedback or task without modifying any file outside the assigned scope, unless cross-file change is required to make the project build, typecheck, or pass referenced tests. Among fixes with equal file count, choose the one with the fewest changed lines.

The terms "smallest safe remediation path" and "smallest correct change" are aliases for this definition.

### Validation procedure

To "run validation" means: execute every command listed under the project's `CLAUDE.md` validation section (typical names: `validation`, `validate`, `test command`, `lint command`, `typecheck command`).

Rules:

- Run every declared command. There is no duration cap; long-running commands are not skipped. The Validation procedure does not silently exclude slow checks.
- If a declared command cannot be run (missing dependency, sandbox restriction, environment misconfiguration, etc.), do not skip it silently. Return the Blocked Report Contract with `Stage: validation`, naming the specific command and the concrete reason it cannot run. Workflow gates that require validation must not pass on a Blocked validation result.
- If `CLAUDE.md` lists no validation commands, validation is "Not run" and the report must say so explicitly. Do not invent validation commands.
- A skill or agent may set its own time budget (for example to bound a single Monitor poll), but that budget belongs to the skill/agent, not to this Definition. The skill must not advertise validation as run when it skipped a declared command on a time budget; instead it must return Blocked with the budget as the reason.

### Material visual decision

A visual decision is material when it requires one of:

- a color value not derivable from existing design tokens or theme files in the repo
- a spacing/sizing value not derivable from the existing scale
- a typography choice (family, size, weight, line-height) not present in existing component CSS/tokens
- a new component variant, state, or composition pattern not documented in the repo's design-system files referenced by `CLAUDE.md`
- any change requiring a new design token

Visual changes that reuse existing tokens, scales, and documented patterns are not material.

### One-time vs watch routing (PR feedback)

Two skills handle PR feedback. Choose by user-request keywords only — the comment author never decides which skill is used, and missing PR identifiers do not exclude the skill at routing time.

- `agent-framework:watch-pr-feedback` — when the user request contains at least one of: `watch`, `monitor`, `wait`, `poll`, `loop`
- `agent-framework:address-pr-feedback` — every other PR-feedback request, including one-time fixes for Codex, human, or bot comments

PR identification is the skill's responsibility, not the router's. If the user request matches `watch-pr-feedback` but does not name a PR, the orchestrator still routes to `watch-pr-feedback` and passes the available context (current branch, current repo). The skill resolves the PR via `gh pr view --json number,state` against the current branch. If no open PR is associated with the current branch, the skill returns the Blocked Report Contract with `Stage: skill selection` or `Stage: fetch` and `Blocker: no PR identified`. The same applies to `address-pr-feedback`.

The author of the comment (Codex, human reviewer, bot, automated reviewer) affects classification per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` (Classification), not skill selection.

Do not use the word "ambiguous" as a hedge anywhere in this framework. Where a rule must gate on missing context, enumerate the concrete missing inputs instead.

## Mandatory Governance Files

Agents must follow these files whether or not the user restates them. Mandatory modules are always loaded for every workflow; no activation condition, user override, or workflow classification can suppress them.

- `branching-pr-workflow.md` — branching, commits, PRs, merge path, validation, trunk-based delivery
- `scope-policy.md` — explicit file-scope enforcement and accessibility ownership boundaries
- `git-policy.md` — git workflow enforcement rules
- `escalation-policy.md` — conditions requiring agent escalation instead of guessing
- `communication-policy.md` — agent-to-agent communication standards and report contracts
- `context-management-policy.md` — task-type classification (intake), per-task budget profile enforcement, progressive-evidence-loading (inline-evidence caps + always-externalize categories), retrieval-anchor rules (in particular `EVD-NNN` anchors required by Mandatory Externalization), and the Path B auto-clear procedure (N-tool-call / scope-pivot / explicit-reset triggers, using the synthetic `TASK-NNN` identifier for `STEP-NNN`-bypass work) apply to every task, including the trivial fast path; phase-handoff transition rules, reconstruction-test gating, cross-handoff contradiction detection, and the Path A (phase-completion) auto-clear procedure additionally apply when the workflow includes more than one execution phase or the plan contains `STEP-NNN` identifiers
- `CLAUDE.md` — project-specific adapter: paths, commands, packages, artifact rules
- `core-contract.md` — always-loaded module classification, mandatory/conditional lists, and core definition cross-references

See `${CLAUDE_PLUGIN_ROOT}/governance/core-contract.md` (Mandatory Modules) for the canonical list.

## Conditional Governance Files

These modules are loaded only when their activation condition is met. When it is uncertain whether a condition is met, include the module (fail-open).

- `versioning.md` — SemVer, release metadata, changelog, tags. **Condition:** Planner's file scope includes files matching the Bump Trigger list in `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` (and not exclusively matching the "No bump is required by default" list), OR `CLAUDE.md` defines versioned artifacts.
- `validation-policy.md` — versioning enforcement and external review policy. **Condition:** workflow includes a validation phase.
- `pr-review-remediation-loop.md` — external PR review feedback handling. **Condition:** workflow includes PR feedback or review remediation.
- `monitoring-policy.md` — shell/parser constraints, monitoring rules, retry/failure handling. **Condition:** user request contains `watch`, `monitor`, `wait`, `poll`, or `loop`.

See `${CLAUDE_PLUGIN_ROOT}/governance/core-contract.md` (Conditional Modules) for canonical activation conditions.

Silence about git workflow, versioning, validation, or review remediation is not permission to ignore the governance files.

## Allowed Agent Topology

Allowed Claude Code agents:

- `orchestrator`
- `planner`
- `coder`
- `designer`

No other agent type may be called, requested, invented, or used as a fallback.

External reviewers, CI, GitHub, Codex, and other services are not Claude Code subagents.

## Authority Matrix

| Area | orchestrator | planner | coder | designer |
|---|---|---|---|---|
| Coordination | owns | no | no | no |
| Planning | coordinates | owns | no | no |
| Implementation | no | no | owns | presentational only |
| Visual design | coordinates | plan only | no new design without guidance | owns |
| Static accessibility | coordinates | plan only | no | owns |
| Runtime accessibility | coordinates | plan only | owns | no |
| Branch/worktree decision | owns | recommend only | no | no |
| Branch creation | owns via skill | no | no | no |
| Checkpoint commit | owns via skill | no | delegated only | no |
| PR submission | owns via skill | no | no | no |
| Version bump decision | owns | recommend only | no | no |
| Version/release file edits | delegates | no | delegated only | no |
| External review request | owns | no | no | no |
| Feedback classification/routing | owns | recommend when delegated | no | no |
| Remediation planning | coordinates | owns when delegated | no | no |
| Remediation implementation | no | no | owns | presentational only |
| Review replies/resolution | owns | no | no | no |

## Role Boundaries

Authority Matrix above is canonical. Per-agent files in `${CLAUDE_PLUGIN_ROOT}/agents/` define role-specific deltas.

### orchestrator

Coordinates the workflow. Owns delegation, sequencing, branch/worktree decisions, checkpoint-commit decisions, PR submission, version bump decisions, and external review-feedback routing.

The orchestrator must not implement product/application changes directly. The orchestrator must not use Write, Edit, or implementation Bash commands to make source changes — implementation belongs to `coder` or `designer`.

### planner

Plans only. Reads and researches, assigns exact file scopes, identifies risks, dependencies, delivery shape, versioning implications, and open questions.

The planner must not modify files, create branches, commit, push, open PRs, or resolve review threads.

### coder

Implements assigned code, tests, docs, build/package/release metadata, runtime behavior, and assigned review-remediation fixes within explicit file scope.

The coder must not silently expand scope, decide version bump type, reply to review threads, resolve review threads, request external review, or invent visual design.

### designer

Implements assigned presentational UI/UX, design tokens, layout, semantic markup, static ARIA, visual states, responsive presentation, and presentation accessibility within explicit file scope.

The designer must not implement business logic, data flow, persistence, routing, state derivation, runtime keyboard behavior, runtime focus movement, live-region behavior, or version/release metadata changes.

## Tool and MCP Policy

| Tool / MCP | orchestrator | planner | coder | designer | Notes |
|---|---|---|---|---|---|
| WebFetch/WebSearch | only when delegation requires external doc lookup | use when the task references a specific external library, framework, or API by name AND the answer is not in the repo | same condition as planner | same condition as planner | permitted only against libraries, frameworks, or APIs named by exact identifier in the task input or in the repo's dependency manifests |
| claude-mem | optional | invoke `claude-mem:mem-search` before planning whenever the plugin is installed (skip only if the repo has no commits or the user opts out) | use when prior decisions about the same files exist in memory | same condition as coder | continuity and token efficiency |
| local repo tools | only those listed in this agent's tools frontmatter | only the read-only set listed in `${CLAUDE_PLUGIN_ROOT}/agents/planner.md` tools frontmatter | only those listed in `${CLAUDE_PLUGIN_ROOT}/agents/coder.md` tools frontmatter | only those listed in `${CLAUDE_PLUGIN_ROOT}/agents/designer.md` tools frontmatter | each agent's frontmatter is the binding allowlist |
| GitHub CLI/API | orchestration and review-thread management | `gh pr view`, `gh pr list`, `gh pr diff`, `gh issue view`, `gh issue list`, `gh repo view` only | only when explicitly delegated for a remediation step | not allowed | respect PR/review ownership |
| Monitor | only after the user request contains `watch`, `monitor`, `wait`, `poll`, or `loop` | not allowed | not allowed | not allowed | read-only, bounded, deterministic, parser-stable |

Do not use broad tools to bypass role boundaries.
