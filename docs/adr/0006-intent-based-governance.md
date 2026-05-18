# Intent-based governance over mechanical state machines

**Status:** accepted — 2026-05-18

We're replacing the framework's exhaustive mechanical governance (80-row state transition tables, bypass code matrices, guard condition permutations, budget profiles, anchor ID conventions) with intent-based agent definitions backed by mechanical safety rails. Agents receive intent for flow and judgment calls, mechanical precision only for inter-agent interfaces, safety stops, and exact commands.

## Context

The framework loaded ~150,000-200,000 governance tokens per session across 12+ files. Reviewer agents loaded ~2,800 lines of governance before processing a single finding. Re-invocation reloaded everything. The mechanical encoding was expensive (tokens), fragile (contradictions between files), often unnecessary (the model would do the right thing without the rule), and actively harmful (attention spent parsing state transition tables was attention not spent solving the problem). LLMs reason better from intent than from lookup tables.

## Where mechanical survived

- Inter-agent interfaces: report schemas (complete/trivial/blocked YAML), delegation contracts, invocation/output contracts for reviewer agents
- Safety rails: hard stops that prevent destructive actions regardless of context (never commit to trunk, never push without branch check, destructive fix gate, external content boundary)
- Exact commands: git operations, GitHub API/GraphQL operations, version bump procedures
- Version/bump triggers: SemVer rules, bump-trigger paths

## Where intent replaced mechanical

- Workflow sequencing (was: 80-row STT with 17 after= tokens; now: prose workflow description)
- Routing and classification (was: 8-category taxonomy with routing table; now: "fix what's simple, escalate what's complex")
- Edge case handling (was: exhaustive guard condition enumeration; now: model judgment)
- Error recovery (was: transient/non-transient classification matrix; now: "retry once if it looks transient, report blocked otherwise")
- Context management (was: budget profiles, auto-clear triggers, anchor discipline; now: eliminated — agents manage their own context naturally)

## Considered Options

| Option | Rejected because |
|---|---|
| Keep mechanical governance, just trim redundancy (40-50% reduction) | Still treats LLM as state machine; rules compete with reasoning; token cost stays high even after dedup |
| Hybrid: intent for agents, mechanical STT for orchestrator | Orchestrator is the primary consumer of governance; keeping mechanical there preserves the core problem |
| Pure intent with no mechanical content anywhere | Inter-agent interfaces and safety stops genuinely require precision; hallucination in report schemas or git commands causes real damage |

## Consequences

- ~80-85% token reduction per session (from ~150-200K to ~25-35K governance + agent overhead)
- Agent definitions: ~100-150 lines each instead of 400-700 lines
- 17 files deleted; 4 new governance files created (~155 lines total, down from ~2,400)
- Edge case variance accepted: model may handle the same edge case differently across sessions. This is the explicit trade-off for clarity and token efficiency.
- Safety is NOT relaxed: hard stops, injection scanning, destructive fix gate, external content boundary all survive in mechanical form
- Reviewer agents gain fix capability (Write/Bash for ≤2 file changes) with minimal fix guidance instead of full coder principles
