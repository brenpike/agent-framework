# Watch mode is a foreground-blocking Monitor owned by github-reviewer

github-reviewer watch mode must poll a PR and remediate review feedback until a terminal event (merged, closed, timeout, max cycles, deferred escalation, injection-suspect, or Codex approval). Two failure modes drove this decision.

(1) A subagent that starts Monitor then returns kills the watch: the Monitor trigger does not survive the subagent's return, so the poll loop dies the moment the subagent emits its Output Contract. The overlord, seeing a returned run, then falsely reports monitoring active. A doc-removal refactor had stripped the guard (from commit `d9bfea3`) that kept the agent in the loop, reintroducing exactly this bug.

(2) A backgrounded Agent run (`run_in_background`) cannot answer the interactive permission prompts remediation requires — Write/Edit fixes, `git push`, and `gh api` thread-resolve mutations — so it stalls or errors.

**Decision:** github-reviewer owns the Monitor and runs watch mode as a foreground-blocking watch — it does not emit its Output Contract until a terminal Monitor event (merged, closed, timeout, max cycles, deferred escalation, injection-suspect, or Codex approval). An empty/clean poll never ends the watch. The overlord invokes it as a normal foreground `Agent()` call and cannot regain control or claim active monitoring until it returns terminal; a returned watch run means monitoring has ended.

**Status:** superseded by ADR-0011 — 2026-05-24

> The foreground-blocking watch was right in INTENT — keep the agent in the loop until a terminal event — but mis-placed in a subagent, where Monitor does not survive the agent's return (the contradiction this ADR itself notes). ADR-0011 relocates the loop to a main-session `hivemind:github-review-loop` skill executed by the overlord, where Monitor actually works.

## Considered Options

| Option | Rejected because |
|---|---|
| Backgrounded Agent run (`run_in_background`) | Cannot answer interactive permission prompts required by remediation (Write/Edit, `git push`, `gh` mutations); run stalls or errors |
| Overlord owns the Monitor | Overlord lacks the `Monitor` tool; and remediation fixes still need foreground permission prompts, so backgrounding the poll buys nothing |
| Subagent starts Monitor then returns (the broken prior state) | Monitor trigger does not survive the subagent's return; the watch dies and the overlord falsely claims active monitoring |

## Consequences

- The user's session is occupied for the duration of a watch (up to `max_watch_duration`, default 4h); the user can interrupt.
- The "monitoring active" claim is honest: the overlord is blocked until the watch returns terminal, so it cannot assert active monitoring for a returned run.
- Remediation permission prompts surface interactively and work.
- github-reviewer retains Monitor ownership; the foreground-blocking guard (restored from `d9bfea3`) is load-bearing: empty/clean polls never terminate the watch.
- Codex approval (a `THUMBS_UP` reaction by `chatgpt-codex-connector`) is a terminal event for the watch only when no unresolved non-self actionable items remain.
