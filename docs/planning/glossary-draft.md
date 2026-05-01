# Glossary (Draft)

> **Status:** Draft planning aid. This document is not active governance. No agent, skill, or governance rule depends on it. It collects working definitions to support planning discussions for CLR-5.
>
> **Depends on:** `docs/planning/execution-state-machine.md`

## Terms

### plan

The output of the planner agent: a complete specification of file scopes, phases, dependencies, delivery shape, versioning implications, and open questions for a task. One approved plan maps to one working branch and one PR unless the planner explicitly decomposes into independently mergeable plans. The plan is the unit of branch ownership, execution, checkpoint-commit decisions, PR submission, and external review remediation.

- **Canonical source:** `plugin/governance/branching-pr-workflow.md` (Purpose, Plan-to-Branch Mapping, Required Git Preflight); `docs/planning/execution-state-machine.md` (state 2: Plan)

### phase

A discrete unit of implementation work within a plan, delegated by the orchestrator to a single worker (coder or designer) with an exact file scope. Phases run sequentially by default; independent non-overlapping phases may run in parallel when worktree conditions are met. A completed and verified phase is one of the conditions that permits a checkpoint commit.

- **Canonical source:** `plugin/governance/branching-pr-workflow.md` (Commit Policy); `docs/planning/execution-state-machine.md` (state 6: Implement, state 7: Validate)

### milestone

A plan item whose outcome is reachable only after two or more phases AND that the orchestrator's plan explicitly labels `Milestone: <name>`. A verified milestone is one of the conditions that permits a checkpoint commit.

- **Canonical source:** `plugin/governance/branching-pr-workflow.md` (Commit Policy)

### artifact

An independently versioned deliverable defined by the project: a package, library, application, plugin, container, distributable binary, or similar. Each artifact has one canonical version source, and changes affecting its public API, runtime behavior, generated output, package contents, or compatibility contracts may require a version bump.

- **Canonical source:** `plugin/governance/versioning.md` (Scope, Bump Trigger, Bump Execution)

### candidate

A plan, change, or PR that has met all prerequisite gates but has not yet received final approval (e.g., a PR awaiting human review, or a plan awaiting user confirmation of open questions). The term is used informally across the framework; no single governance section provides a canonical definition.

- **Canonical source:** None (informal usage across governance files)

### thread

A review thread on a GitHub pull request: an inline comment or conversation attached to a specific code location or a top-level PR comment chain. Threads are the primary unit of feedback in the review remediation loop. The orchestrator owns thread replies and resolution; workers must not reply to or resolve threads unless explicitly delegated.

- **Canonical source:** `plugin/governance/pr-review-remediation-loop.md` (Ownership, Feedback Sources, Fix Rules, Thread Resolution Rule); `plugin/governance/agent-system-policy.md` (Definitions: Same finding)

### review summary

A GitHub review object with state `CHANGES_REQUESTED` or `COMMENTED` whose body contains actionable feedback not captured in inline threads. Review summaries are one of the feedback sources checked during the remediation loop, alongside inline review comments, top-level PR comments, and unresolved review threads.

- **Canonical source:** `plugin/governance/pr-review-remediation-loop.md` (Feedback Sources); `plugin/agents/orchestrator.md` (Execution Algorithm step 15)

### monitor

A read-only background mechanism (backed by the Monitor tool, a scheduled task, routine, channel, or equivalent real trigger) that detects new events on a watched resource and routes them to remediation skills. A monitor is not a remediator. Monitoring must be read-only, deterministic, bounded, and parser-stable, and must terminate when the watched resource reaches a terminal state.

- **Canonical source:** `plugin/governance/agent-system-policy.md` (Monitoring Policy); `plugin/governance/pr-review-remediation-loop.md` (Monitoring)

### blocked

A terminal workflow state indicating that a required gate has failed and user intervention is needed to resume. The orchestrator produces a Blocked Report Contract specifying: status, stage, blocker, retry status, fallback used, impact, and next action. Blocked is reachable from any state that has a required gate.

- **Canonical source:** `plugin/governance/agent-system-policy.md` (Blocked Report Contract); `docs/planning/execution-state-machine.md` (state 13: Blocked, Blocked Reachability)
