# Two specialist reviewer agents over a unified reviewer

We're introducing two separate reviewer agents (`local-reviewer` and `github-reviewer`) rather than a single unified `reviewer` agent to handle code review logic currently embedded in the orchestrator.

The two flows — pre-PR local Codex review and post-PR GitHub review — share ~56% of their logic (classification taxonomy, routing table, injection scanning) but diverge substantially in their I/O boundaries, tool requirements, state management, loop mechanics, and exit conditions. A unified agent would carry both tool surfaces (Monitor + gh API + git push for GitHub; fix ledger + break-fix detection for local) and couldn't provide context isolation between flows — local review may consume 5-10 iterations before GitHub review even starts.

Separate agents mean each starts with a fresh context window focused on its specific flow, carries only the tools it needs, and can fail independently.

## Considered Options

| Option | Rejected because |
|---|---|
| Single unified `reviewer` | Mixed concerns; large tool surface; no context isolation between flows; a 10-iteration local review pollutes context for subsequent GitHub review |
| Reviewer without fix delegation (classify-only) | Marginal improvement over current skill-based approach; doesn't solve the core round-trip problem |

## Consequences

- Two agent definition files to maintain instead of one (~400-500 lines each)
- Shared logic (classification taxonomy, break-fix algorithm, routing table) extracted to `skills/_shared/` references to avoid duplication
- Agent topology expands from 4 to 6, requiring governance updates (agent-system-policy.md, core-contract.md, authority matrix)
