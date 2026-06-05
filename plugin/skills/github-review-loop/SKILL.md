---
name: github-review-loop
description: Watch an open PR and remediate review feedback in a loop until a terminal condition. Arms a main-session Monitor on a thin change-detect poll and dispatches `hivemind:github-reviewer` in fix mode per actionable event. Executed by the overlord only — loop must run in the main session where Monitor survives subagent dispatches (ADR-0005).
allowed-tools:
  - Read
  - Monitor
  - Agent(hivemind:github-reviewer)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/preflight.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/pr-change-detect-poll.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/prefilter.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/exit-precedence.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/loop-state.sh *)
shell: bash
---

# GitHub Review Loop

Watch one open PR and drive remediation to a terminal state. Does NOT classify feedback — that is `hivemind:github-reviewer` fix-mode work.

Load and follow: `${CLAUDE_PLUGIN_ROOT}/governance/definitions.md`, `${CLAUDE_PLUGIN_ROOT}/governance/safety-rails.md`, `${CLAUDE_PLUGIN_ROOT}/governance/security-policy.md`.

## Why this runs in the main session

Monitor is a main-session cross-turn primitive — a subagent dispatch orphans any Monitor armed inside it. The loop lives here so Monitor survives across reviewer dispatches; only the top-level orchestrator can spawn the reviewer (ADR-0005).

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `pr` | (required) | PR number or URL. |
| `working_branch` | (required) | Branch the reviewer pushes fixes to. |
| `base` | (required) | PR base/target branch. |
| `reviewer_filter` | `codex-only` | Actionable reviewer identities (`codex-only` \| `all` \| `<author>`). |
| `max_watch_duration` | `3600` | Seconds before timeout (1h). |
| `max_remediation_cycles` | `3` | Max real remediation rounds (findings_resolved ≥ 1). |
| `poll_interval` | `60` | Seconds between polls. |

## Lifecycle

**1. Preflight.** Run `${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/preflight.sh`
with `pr`, `working_branch`, `base` as positional args. Any `PREFLIGHT_ERROR=`
line or non-zero exit → terminal `blocked`. Confirm git state is not unsafe per
`${CLAUDE_PLUGIN_ROOT}/governance/definitions.md` (Unsafe Git State).

**2. Cycle 0.** Dispatch `hivemind:github-reviewer` fix mode (see Dispatch contract)
over pre-existing PR feedback before arming the Monitor. NEVER prefiltered. Handle
return per Reviewer-return handling. Arm Monitor only after a `clean` return.

**3. Arm Monitor.** Arm a Monitor in the main session on:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/pr-change-detect-poll.sh <OWNER> <REPO> <PR_NUMBER> <max_watch_duration> <poll_interval> <reviewer_filter> <SELF_LOGIN>
```

Resolved preflight values / skill inputs as positional args in that order. Poll
emits ONLY on a real delta or terminal state. Read lines directly — never into a
functional pipe.

**4. Per event.** `CHANGED` → run
`${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/prefilter.sh <OWNER> <REPO> <PR_NUMBER> <reviewer_filter> <SELF_LOGIN>`:
`PREFILTER_SKIP` → keep Monitor armed, no dispatch, no cycle/`Routed` increment.
`PREFILTER_DISPATCH` or `PREFILTER_ERROR=<reason>` → dispatch reviewer fix mode
(no `target`); `PREFILTER_ERROR` is fail-open. Handle return per Reviewer-return
handling. `CODEX_APPROVED` → confirmation pass (no `target`); terminal `clean`
ONLY if reviewer finds nothing actionable; use only the latest poll's approval —
a stale prior 👍 must never short-circuit later pushback. `STATE=MERGED` →
`pr-merged`. `STATE=CLOSED` → `pr-closed`. `WATCH_TIMEOUT` →
`max-cycles-reached`. `POLL_ERROR` → stop Monitor; `blocked`. For the last four,
use `${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/loop-state.sh token-map <signal>`.

**5. Reviewer-return handling.** `clean` → keep watching. `planner-escalation` |
`blocked` | `injection-suspect` | `high-severity-rejection` | `user-input-required`
→ HARD-STOP; ONE terminal with matching `exit_reason` + escalation-conditional
fields. `root-cluster-suspected` → HARD-STOP; ONE terminal with reviewer's cluster
payload; overlord routes to cerebrate zoom-out (classification-free — loop
propagates only). `merge-advised` → HARD-STOP; ONE `merge-advised` terminal with
`advisory_reason` + `recommendation_text`; ADVISORY ONLY — loop NEVER merges
(classification-free). Use `${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/loop-state.sh cycle-decision`
for cycle increments, ceiling, `same-finding-repeat`, and terminal-vs-cycle. When
multiple tokens fire, delegate to `loop-state.sh resolve-precedence` (→
`${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/exit-precedence.sh`).
When any guard fires, stop Monitor and emit ONE terminal report.

## Dispatch contract

Spawn `hivemind:github-reviewer` with `mode: fix`, `pr`, `working_branch`, `base`,
`reviewer_filter` (scoped per `${CLAUDE_PLUGIN_ROOT}/references/github-pr-review-graphql.md`
Author Filtering). Omit `target` — absent target is the full pass over unresolved
feedback. Returns `exit_reason ∈ {clean, injection-suspect, user-input-required,
planner-escalation, high-severity-rejection, root-cluster-suspected, merge-advised,
blocked}` plus `findings_resolved` / `findings_open` and escalation-conditional
fields. Skill consumes; does not re-fetch or re-classify.

## Termination guard set

Terminates on: `max_remediation_cycles` reached; `max_watch_duration` timeout;
`same-finding-repeat` oscillation (→ `max-cycles-reached`); any reviewer
`planner-escalation` / `blocked` / `injection-suspect` / `high-severity-rejection`
/ `user-input-required` / `root-cluster-suspected` / `merge-advised`; PR merged
or closed; Codex approval with nothing actionable remaining.
Cycle arithmetic, ceiling, terminal-vs-cycle, and `same-finding-repeat` mapping:
`${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/loop-state.sh`.
Multi-token precedence ORDER:
`${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/exit-precedence.sh`.
No persisted ledger — GitHub is the ledger (`Fixed in <SHA>` replies; fix-SHA skip
makes re-invocation idempotent on restart).

## Terminal report

Emit exactly ONE terminal report (validated by `tools/validate_reports.sh`
watch-pr-feedback). Fields: `Status: complete`; `PR` (Number / State / Branch /
Target); `Watch` (Mode: Monitor | Monitoring: stopped | Parser: gh --jq | Cycles |
Seen comments | New actionable comments); `Routed: github-reviewer: <count>`;
`Stopped because: <exit_reason> — <explanation>`; `Next action`; `Issues`.

`exit_reason` drawn from: `clean | pr-merged | pr-closed | max-cycles-reached | planner-escalation | root-cluster-suspected | merge-advised | blocked | injection-suspect | high-severity-rejection | user-input-required`. For `root-cluster-suspected`: cluster payload under `Issues`; cerebrate zoom-out under `Next action`. For `merge-advised`: `advisory_reason` + `recommendation_text` under `Issues`. For escalation/blocked: escalation-conditional fields under `Issues`. `Cycles` = `cycles_completed`; `New actionable comments` = `findings_resolved`; restate `findings_open` in `Issues` when non-zero.

## Safety

- Never merge, close, or approve PRs.
- Never request external review or re-review.
- Do not start a second Monitor.
- Never claim the watch is still active in a returned report — a returned run is no
  longer monitoring (`Monitoring: stopped`).
- Single PR per invocation.
