# Agent tool unavailable in subagents — reviewers ship as review-only classifiers

The Claude Code plugin runtime does not honor `Agent(...)` invocations in subagent frontmatter. Only the top-level orchestrator agent can spawn other agents via the Agent tool. Reviewer agents (`local-reviewer`, `github-reviewer`) cannot delegate fix work to coder or designer agents at runtime, despite ADR-0002 designing them with self-owning delegation authority.

This constraint was not discovered until runtime testing. ADR-0002 was premised on Agent tool access being available to any agent; that premise is false.

**Decision:** Reviewer agents apply simple fixes (≤2 files) directly via Write/Bash and escalate complex fixes to the orchestrator. The framework is permanently designed around this constraint rather than treating it as a temporary limitation.

This ADR supersedes ADR-0002.

**Status:** accepted (updated) — 2026-05-18

## Considered Options

| Option | Rejected because |
|---|---|
| Block reviewer promotion until platform adds subagent Agent tool | Indefinite block; reviewers already provide classification and routing value without fix delegation |
| Simulate delegation inside reviewer (inline coder logic) | Violates separation of concerns; duplicates the entire coder agent inside the reviewer; outside assigned scope |
| Ship ADR-0002 model as designed, accept silent no-op on Agent calls | Silent failures are worse than documented constraints; no fix would occur and the orchestrator would not be notified |

## Consequences

- Reviewer agents classify findings AND apply simple fixes directly (≤2 files, using Write/Bash with minimal fix guidance)
- Complex fixes (>2 files, architecture changes) escalate to orchestrator → planner → coder
- ADR-0002's Agent()-based delegation model is permanently superseded, not deferred
- Framework designed around the constraint: reviewers are self-contained agents that own their fix loop for simple changes
- No platform dependency: the design does not depend on future Claude Code Agent tool changes
