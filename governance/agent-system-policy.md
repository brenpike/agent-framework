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

Agents must follow these files whether or not the user restates them:

- `branching-pr-workflow.md` — branching, commits, PRs, merge path, validation, trunk-based delivery
- `versioning.md` — SemVer, release metadata, changelog, tags
- `pr-review-remediation-loop.md` — external PR review feedback handling
- `CLAUDE.md` — project-specific adapter: paths, commands, packages, artifact rules

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
| Static accessibility | coordinates | plan only | partial | owns |
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

## Explicit Scope Rule

Any modifying agent must work only in explicitly assigned files.

If another file is required:

1. stop
2. report the exact file
3. explain why it is needed
4. wait for orchestrator reassignment

No agent may silently expand scope.

For mixed presentation-and-behavior files, default owner is `coder`. Designer is the owner when both:

(a) the assignment names files matching one of:
- stylesheet/token files: `*.css`, `*.scss`, `*.sass`, `*.less`, `*.module.css`, `*.style.*`, or files inside directories named `styles/`, `tokens/`, or `theme/`
- markup/component files: `*.html`, `*.htm`, `*.svg`, `*.vue`, `*.svelte`, `*.astro`, `*.mdx`, `*.jsx`, `*.tsx`

(b) the orchestrator's delegation states one of:
- "Do not modify behavior, state, handlers, imports, or non-style logic." (for stylesheet/token files), OR
- "Modify only presentational markup, semantic tags, accessibility attributes (`role`, `aria-*`, `tabindex`, `lang`, `alt`, `title`, `for`/`id` linkages), `className`/`class` values, inline style attributes, and visual ordering of existing elements. Do not modify state, event handlers, imports, props, hooks, business logic, data flow, or runtime behavior." (for markup/component files)

## Accessibility Ownership Split

Designer owns static/presentational accessibility:

- semantic structure
- static ARIA attributes
- accessible labels
- contrast
- visible focus treatment
- touch target sizing
- non-color-only communication
- visual treatment of loading, empty, error, disabled, hover, focus, and active states

Coder owns runtime accessibility:

- state derivation and transitions
- keyboard behavior driven by runtime state
- focus movement driven by application state
- live-region behavior
- accessibility behavior tied to business logic or app state

## Git Workflow Enforcement

`branching-pr-workflow.md` is mandatory. See `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md`.

Before implementation begins, the orchestrator must explicitly establish:

- work classification: `feature|bugfix|hotfix|refactor|chore|docs|test|ci`
- base branch
- working branch name
- branch exists vs create
- worktree decision
- checkpoint commit policy
- PR target

If any are undefined, do not begin implementation. Full preflight detail: `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Required Git Preflight).

Workers must stop and report `blocked` if required git context is missing, inconsistent, or unsafe.

No agent may commit or push directly to the resolved trunk branch.

## Versioning Enforcement

`versioning.md` is mandatory for versioned artifacts. See `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md`.

The orchestrator owns bump detection and bump type decisions. The coder may edit version/release metadata only when explicitly delegated.

A PR that requires a version bump is not ready until required version/release metadata is included.

If project-specific version paths or canonical version sources are unclear, stop and ask the user.

## External Review Policy

`pr-review-remediation-loop.md` is mandatory for external PR feedback. See `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md`.

The orchestrator owns review feedback classification, routing, replies, resolution, and re-review requests.

Skills may perform classification only as orchestrator-invoked workflow steps. Ownership remains with the orchestrator.

Workers may remediate assigned feedback within explicit file scope. They must not reply to or resolve review threads unless explicitly delegated and allowed by policy.

Use the narrowest matching skill:

- `agent-framework:address-pr-feedback` — one-time PR-feedback fix (Codex, human reviewer, or bot comments); user request lacks watch-mode keywords
- `agent-framework:watch-pr-feedback` — user request contains at least one of `watch`, `monitor`, `wait`, `poll`, or `loop`

Full routing rule: see Definitions → One-time vs watch routing.

## Tool and MCP Policy

| Tool / MCP | orchestrator | planner | coder | designer | Notes |
|---|---|---|---|---|---|
| WebFetch/WebSearch | only when delegation requires external doc lookup | use when the task references a specific external library, framework, or API by name AND the answer is not in the repo | same condition as planner | same condition as planner | permitted only against libraries, frameworks, or APIs named by exact identifier in the task input or in the repo's dependency manifests |
| claude-mem | optional | invoke `claude-mem:mem-search` before planning whenever the plugin is installed (skip only if the repo has no commits or the user opts out) | use when prior decisions about the same files exist in memory | same condition as coder | continuity and token efficiency |
| local repo tools | only those listed in this agent's tools frontmatter | only the read-only set listed in `${CLAUDE_PLUGIN_ROOT}/agents/planner.md` tools frontmatter | only those listed in `${CLAUDE_PLUGIN_ROOT}/agents/coder.md` tools frontmatter | only those listed in `${CLAUDE_PLUGIN_ROOT}/agents/designer.md` tools frontmatter | each agent's frontmatter is the binding allowlist |
| GitHub CLI/API | orchestration and review-thread management | `gh pr view`, `gh pr list`, `gh pr diff`, `gh issue view`, `gh issue list`, `gh repo view` only | only when explicitly delegated for a remediation step | not allowed | respect PR/review ownership |
| Monitor | only after the user request contains `watch`, `monitor`, `wait`, `poll`, or `loop` | not allowed | not allowed | not allowed | read-only, bounded, deterministic, parser-stable |

Do not use broad tools to bypass role boundaries.

## Shell and Parser Policy

Use deterministic shell/parser behavior.

Do not:

- shell-hop for routine parsing
- call `powershell -Command` from Bash for routine parsing
- call Bash from PowerShell for routine parsing
- dynamically probe Python, Node, standalone `jq`, PowerShell, or other parsers during normal execution
- restart Monitor with different parser strategies without explicit user approval
- continue monitor loops after parser failures without reporting the failure

Prefer:

1. native Claude shell for the current environment
2. `gh pr view --json ... --jq ...`
3. `gh api graphql --jq ...`
4. deterministic commands with bounded retries

If the approved shell/parser strategy fails, retry once only when the failure matches the "Transient failure" definition, then return `blocked` rather than improvising parser fallback chains.

## Monitoring Policy

A remediation skill is not a monitor. A monitor is not a remediator.

Use `agent-framework:watch-pr-feedback` only when the user request contains at least one of `watch`, `monitor`, `wait`, `poll`, or `loop`. See Definitions → One-time vs watch routing.

Monitoring must be:

- backed by Monitor, scheduled task, routine, channel, or equivalent real background trigger
- read-only while watching
- deterministic and parser-stable
- bounded by max watch duration and remediation cycles
- routed through remediation skills instead of editing directly

A monitor targeting a specific resource (PR, issue, branch, workflow run, deployment) must terminate when the watched resource reaches a terminal state (e.g., PR merged or closed, issue closed, run completed, branch deleted, deployment finished). Continued polling against a terminal resource is parser-stable but pointless drift and must be stopped immediately. Detection commands must include the resource's state field so terminal transitions are observable on every poll.

Do not say or imply active monitoring is running unless a real background mechanism started successfully.

If no background mechanism is active, report:

```text
Status: complete | blocked
Mode: manual
Monitoring: not active
Next action:
- User must invoke the skill again when new feedback appears
```

## Retry and Failure Policy

Failures are execution states, not waiting states.

After any tool error, timeout, failed delegation, unusable output, missing permission, parser failure, or internal runtime failure, the observing agent must immediately do one of:

1. retry exactly once if the failure matches the "Transient failure" definition
2. continue with a documented safe fallback (a fallback is "documented" when it appears in the agent's own file or in a referenced skill/governance file)
3. return `blocked` per the Blocked Report Contract

Rules:

- Do not repeat the same command (after argument normalization) more than once unless one of: at least one argument value changes, the working directory changes, or a prerequisite command in between has succeeded where it previously failed.
- Do not wait for the user to ask what happened.
- Do not abandon a failed skill, monitor, or delegation without a blocked report.
- Do not invoke a broader skill (one whose Invocation Boundary admits more cases) unless the user's request matches that broader skill's Invocation Boundary literally.

## Escalation Rules

Stop and report instead of guessing when any of the following is true:

- correctness requires editing a file not listed in the assignment
- the requested change crosses an ownership boundary in the Authority Matrix
- a designer task requires a "Material visual decision" (see Definitions) without project-level design guidance present
- a designer task requires runtime behavior, state derivation, data flow, routing, runtime keyboard handling, or live-region behavior
- git state matches the "Unsafe git state" definition
- any item from `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Required Git Preflight) is undefined
- the change matches more than one row of `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` Bump Type Determination, or matches none, or — for an artifact that requires a bump — `CLAUDE.md` does not list the full set of artifact files per `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` (Bump Execution): canonical version file, required mirrors, changelog/release notes, package/artifact metadata, documentation mirrors, and release validation files when applicable
- feedback's classification per `${CLAUDE_PLUGIN_ROOT}/governance/pr-review-remediation-loop.md` is one of `question-needs-user-input`, `architecture-or-contract-concern`, or `version-or-release-concern`; OR the comment body is tagged `P0`; OR the comment body names any of `CVE`, `CWE`, `auth`, `secret`, `credential`, `SSRF`, `RCE`, `injection`, `XSS`
- validation cannot be run AND the change touches any of: public API, runtime behavior, build/package output, version/release files, or files explicitly listed in `CLAUDE.md` as requiring validation

## Communication Standard

Agent-to-agent communication must be field-based.

Rules:

- every line of the report must be either a heading, a labeled field of the form `Field: value`, a list item under such a field, or blank — no standalone sentences outside a field
- include every required section in the contract being used (Shared Worker Report Contract or Blocked Report Contract)
- include an optional section only when at least one item exists for it; otherwise omit the section heading entirely
- report facts, blockers, scope needs, validation, versioning, review state, and git state directly
- do not restate policy or workflow rules inside routine reports

## Shared Worker Report Contract

Use this by default for planner-delegated worker output:

```text
Status: complete | partial | blocked

Changed:
- path/to/file
- None

Validated:
- [check]
- Not run

Need scope change:
- path/to/file: reason
- None

Issues:
- [issue]
- None
```

Optional lines. Include each line below only when its trigger fires; otherwise omit the line entirely.

- `Refs: ...` — when the worker consulted external docs, prior commits, or memory; list them
- `States handled: ...` — when the assignment had a `States:` or `Edge cases:` field; list each state addressed
- `Commit: ...` — when the worker is delegated to commit (per Authority Matrix); include the SHA
- `Version: required|none|unknown` — when the changed files match the project's bump-trigger paths or, when undefined, do not match the "No bump is required by default" list
- `Review item: ...` — when the work was review-remediation; include the comment ID or thread ID
- `Git issue: ...` — when git state matches the "Unsafe git state" definition or any preflight item is undefined
- `Ready to resolve: yes|no` — when the work was review-remediation

## Blocked Report Contract

Use this for blocked planning, execution, validation, git, versioning, review, monitoring, or skill states:

```text
Status: blocked
Stage: [planning | implementation | validation | git workflow | versioning | review remediation | monitoring | skill selection | fetch | parse | route]
Blocker: [one-line reason]
Retry status: [not attempted | retried once | exhausted]
Fallback used: [none | description]
Impact: [what cannot proceed]
Next action:
- [specific next step]
```
