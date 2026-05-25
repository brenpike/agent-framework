# Review loop lives in a main-session skill; github-reviewer is a stateless fix-mode worker

**Status:** accepted — 2026-05-24 (supersedes ADR-0009)

The post-PR review loop moves out of the `github-reviewer` subagent and into a new main-session skill, `hivemind:github-review-loop`, executed by the overlord. `github-reviewer` is stripped to a stateless fix-mode-only worker. The Monitor tool grant moves from `github-reviewer`'s frontmatter to the overlord's.

## Context

ADR-0009 placed the watch loop inside the `github-reviewer` subagent and required it to block on a Monitor until a terminal event. That design is unsatisfiable. Monitor is a MAIN-SESSION cross-turn primitive: its re-invocation is a property of the main session's turn loop. A subagent runs exactly ONE turn and returns the moment it stops emitting tool calls, so a Monitor armed inside a subagent is orphaned at return — ADR-0009 admits this ("the Monitor trigger does not survive the subagent's return") then adopts a Decision that depends on the opposite.

Forensic evidence (38MB of session logs): across 11 `github-reviewer` watch invocations, 0 ever ran a second poll — every watch run returned after cycle-0 while narrating "Monitor armed / I will not return." All 5 fix-mode runs returned clean with real remediation. Fix mode is the only path that ever worked.

Constraints that rule out the obvious alternatives: no `ANTHROPIC_API_KEY` and no willingness to supply credentials (rules out a GitHub-hosted CI runner); a local, non-public environment with no inbound endpoint (rules out webhooks); foreground `sleep` is harness-blocked, so Monitor is the only sanctioned wait primitive — and Monitor only works in the main session.

## Decision

The `hivemind:github-review-loop` skill owns the Monitor and the entire loop lifecycle (cycle counting, continue/stop decisions, terminal reporting) in the MAIN session. The skill is EXECUTED BY THE OVERLORD: per ADR-0005 the Claude Code runtime honors the `Agent(...)` tool only in the top-level orchestrator, so the overlord is the only context that can both host Monitor AND spawn the `github-reviewer` subagent — the two capabilities the loop needs. The skill is written intent-based per ADR-0006 (intent plus mechanical safety rails: Monitor wiring, terminal conditions, dispatch contract), deliberately NOT an 80-step state machine.

`github-reviewer` becomes a stateless fix-mode-only worker: it owns all GitHub interpretation and remediation (deep GraphQL fetch, classification, injection scan, ≤2-file fixes, push, fix-SHA replies, thread resolution, fix-SHA dedup) and returns structured results to the skill. The `/tmp` stop-file machinery is removed: Monitor stops natively, so no out-of-band stop signal is needed.

Because a skill executes in its host agent's tool context and holds no tools of its own, the Monitor tool surface MOVES from `github-reviewer`'s frontmatter `tools:` list to the OVERLORD's frontmatter `tools:` list. The overlord-executed skill arms Monitor in the overlord's tool context; the overlord's restrictive allowlist (previously Read/Bash/Skill/Agent only) gains `- Monitor`, and `github-reviewer` loses it. NET EFFECT: Monitor is a move (`github-reviewer` → overlord), not a deletion.

## Considered Options

| Option | Rejected because |
|---|---|
| Skill-owned main-session loop (CHOSEN) | — |
| Overlord-hardcoded poll loop in `overlord.md` | Bloats the control plane with loop state the overlord should not carry; the explicit "no 80-step state machine" complaint |
| `/loop` stateless tick as the driver | Loses cross-cycle continuity and main-session ownership of the loop; iteration would live between turns, not in a coherent owned lifecycle |
| In-subagent blocking Monitor (the ADR-0009 design) | The root-cause bug: Monitor does not survive a subagent's return, so the loop dies at cycle-0; foreground `sleep` is also harness-blocked |
| CI runner with API key / inbound webhooks | No `ANTHROPIC_API_KEY` and no credentials supplied; no public endpoint for GitHub to reach |

## Consequences

- The overlord gains the `- Monitor` tool grant in its frontmatter `tools:` list; `github-reviewer` loses it. The grant is the operational counterpart of the agent simplification — a move, not new capability sprawl.
- STEP-000 (a Monitor-survival spike) validated the single load-bearing assumption UPFRONT, before any build: a Monitor armed in the main session survives across a subagent dispatch and keeps delivering output lines afterward. Run in a vanilla session because Monitor is a default main-session primitive that the restrictive overlord allowlist excludes until granted. PASS was the gate to proceed.
- The D11 smoke gate validates the finished feature end-to-end before merge, including PARITY: that the FRONTMATTER-GRANTED overlord Monitor arms, streams, and survives subagent dispatch identically to the default main-session Monitor proven in STEP-000.
- Asymmetry between the two reviewer agents grows (extends ADR-0001): `local-reviewer` retains a synchronous in-agent adaptation loop; `github-reviewer` no longer has any loop at all — the skill owns it.
- The overlord stays lean: it routes the watch (invokes the skill) and handles ONE terminal report via existing exit-reason logic; it gains zero new loop state.
