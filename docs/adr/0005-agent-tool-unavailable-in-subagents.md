# Agent tool unavailable in subagents — reviewers ship as review-only classifiers

The Claude Code plugin runtime does not honor `Agent(...)` invocations in subagent frontmatter. Only the top-level orchestrator agent can spawn other agents via the Agent tool. Reviewer agents (`local-reviewer`, `github-reviewer`) cannot delegate fix work to coder or designer agents at runtime, despite ADR-0002 designing them with self-owning delegation authority.

This constraint was not discovered until runtime testing. ADR-0002 was premised on Agent tool access being available to any agent; that premise is false.

**Decision:** ship the reviewer agents as review-only classifiers. They classify findings, surface terminal results to the orchestrator, and delegate nothing. All fix delegation flows through the orchestrator via the planner-escalation path. Full reviewer autonomy (the ADR-0002 model) is deferred until the Claude Code platform adds subagent Agent tool support.

This ADR supersedes ADR-0002.

**Status:** accepted — 2026-05-18

## Considered Options

| Option | Rejected because |
|---|---|
| Block reviewer promotion until platform adds subagent Agent tool | Indefinite block; reviewers already provide classification and routing value without fix delegation |
| Simulate delegation inside reviewer (inline coder logic) | Violates separation of concerns; duplicates the entire coder agent inside the reviewer; outside assigned scope |
| Ship ADR-0002 model as designed, accept silent no-op on Agent calls | Silent failures are worse than documented constraints; no fix would occur and the orchestrator would not be notified |

## Consequences

- Reviewer agents function as classifiers only: classify findings, route to the appropriate exit reason, return terminal results to the orchestrator
- All fix delegation (simple and complex) goes through the orchestrator; the planner-escalation path is the single fix-routing channel
- ADR-0002's authority matrix grants (fix delegation, checkpoint-commit invocation) are moot until platform support arrives
- CONTEXT.md definitions for Local-Reviewer and GitHub-Reviewer updated to reflect review-only capability
- When Claude Code adds subagent Agent tool support, ADR-0002's delegation model can be reinstated without structural changes to the reviewer agents — the classification and exit-reason logic is already in place
