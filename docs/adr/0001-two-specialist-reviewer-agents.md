# Two specialist reviewer agents over a unified reviewer

**Status:** accepted — 2026-05-18 (updated)

We're introducing two separate reviewer agents (`local-reviewer` and `github-reviewer`) rather than a single unified `reviewer` agent to handle code review logic currently embedded in the orchestrator.

The two flows — pre-PR local Codex review and post-PR GitHub review — diverge substantially in their I/O boundaries, tool requirements, and loop mechanics. Context isolation is the primary driver: local review may consume 5-10 iterations before GitHub review even starts; a unified agent would carry both sessions' state into GitHub review with no clean boundary. Peripheral tool surfaces also differ: GitHub review needs GraphQL, git push, and thread resolution; local review needs break-fix detection and a fix ledger. A unified agent carries both surfaces regardless of which flow is active.

> Updated by ADR-0011: the `Monitor` tool is no longer part of `github-reviewer`'s surface. The watch loop moved to the main-session `hivemind:github-review-loop` skill executed by the overlord, so the `Monitor` grant moved to the overlord's frontmatter (a skill arms it in the overlord's tool context). The two-agent decision still holds; the asymmetry only grows — `local-reviewer` retains a synchronous in-agent loop, while `github-reviewer` no longer has any loop.

Separate agents mean each starts with a fresh context window focused on its specific flow, carries only the tools it needs, and can fail independently.

## Considered Options

| Option | Rejected because |
|---|---|
| Single unified `reviewer` | Mixed concerns; large tool surface; no context isolation between flows; a 10-iteration local review pollutes context for subsequent GitHub review |
| Reviewer without fix delegation (classify-only) | Tried during the ADR-0005 era; superseded when reviewers gained self-fix capability — classify-only forces all simple fixes through the orchestrator, adding unnecessary round-trips |

## Consequences

- Two agent definition files to maintain instead of one (~80 and ~150 lines respectively)
- No shared reference files needed — each reviewer is self-contained; classification and routing logic is inlined as ~10 lines of intent
- Fresh context per invocation is cheap at these definition sizes; context isolation is low-cost to maintain
- Agent topology remains at 6; no additional governance changes required
