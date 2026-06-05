---
name: github-review-loop
description: >-
  Watch an open pull request and remediate review feedback in a loop until a
  terminal condition. Arms a main-session Monitor on a thin change-detect poll
  and dispatches the `hivemind:github-reviewer` agent in fix mode per actionable
  event. Use when the user asks to watch a PR, monitor PR review feedback, or
  keep handling Codex review until merge/approval. Executed by the overlord only —
  the loop must run in the main session, where Monitor survives subagent
  dispatches and the orchestrator can spawn the reviewer (per ADR-0005). The
  overlord supplies the tools at runtime; the skill declares its permitted
  surface via allowed-tools.
allowed-tools:
  - Read
  - Monitor
  - Agent(hivemind:github-reviewer)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/preflight.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/pr-change-detect-poll.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/prefilter.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/exit-precedence.sh *)
shell: bash
---

# GitHub Review Loop

Watch one open PR and drive review-feedback remediation to a terminal state. This
skill owns the loop lifecycle; it does NOT read, interpret, or classify feedback
content — that is `hivemind:github-reviewer` fix-mode work. The skill's only
GitHub footprint is a thin, cheap, predefined change-detect poll that answers
"did anything change?" and "is the PR terminal?".

This skill is intent-based: it describes intent plus mechanical safety rails
(Monitor wiring, terminal conditions, dispatch contract). It is deliberately NOT
a step-by-step state machine.

Load and follow: `${CLAUDE_PLUGIN_ROOT}/governance/definitions.md`, `${CLAUDE_PLUGIN_ROOT}/governance/safety-rails.md`, `${CLAUDE_PLUGIN_ROOT}/governance/security-policy.md`.

## Why this runs in the main session

Monitor is a main-session cross-turn primitive. A subagent runs exactly one turn
and returns when it stops emitting tool calls, orphaning any Monitor armed inside
it. The loop therefore lives here, in the overlord's tool context, where Monitor
survives across the reviewer-subagent dispatches this skill makes. The overlord
spawns the reviewer (only the top-level orchestrator can — ADR-0005).

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `pr` | (required) | PR number or URL to watch. |
| `working_branch` | (required) | The branch the reviewer pushes fixes to. |
| `base` | (required) | The PR's base/target branch. |
| `reviewer_filter` | `codex-only` | Which reviewer identities count as actionable (`codex-only` \| `all` \| `<author>`). |
| `max_watch_duration` | `3600` | Seconds before the watch times out (1h). |
| `max_remediation_cycles` | `3` | Max real remediation rounds (findings_resolved ≥ 1) before stopping. |
| `poll_interval` | `60` | Seconds between change-detect polls. |

## Lifecycle (intent + rails)

### 1. Preflight

Run `${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/preflight.sh`,
passing `pr`, `working_branch`, `base` as positional arguments, in that order.
It resolves PR number,
owner, repo, OPEN state, the current branch (must equal `working_branch`), base,
and `SELF_LOGIN`, and emits labeled `KEY=VALUE` lines. If it exits non-zero (any
`PREFLIGHT_ERROR=` line), stop and return a terminal report with
`exit_reason: blocked`. Also confirm git state is not unsafe per
`${CLAUDE_PLUGIN_ROOT}/governance/definitions.md` (Unsafe Git State) — unsafe git
state is `blocked`.

### 2. Cycle 0 — remediate-then-watch

Before establishing any poll baseline, dispatch `hivemind:github-reviewer` in fix
mode over the feedback already on the PR (see Dispatch contract). This is a full
pass over pre-existing feedback — "watch PR #X" means remediate what is there now,
THEN watch for new. Handle its return per Reviewer-return handling. Only after a
non-terminal (`clean`) cycle-0 return do you arm the Monitor. The cycle-0 dispatch is NEVER prefiltered — it runs unconditionally over whatever pre-existing feedback is on the PR.

### 3. Arm the Monitor

Arm a Monitor in the main session on

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/pr-change-detect-poll.sh <OWNER> <REPO> <PR_NUMBER> <max_watch_duration> <poll_interval> <reviewer_filter> <SELF_LOGIN>
```

where `<OWNER>`, `<REPO>`, `<PR_NUMBER>` are the concrete values resolved from
preflight output, `<max_watch_duration>` and `<poll_interval>` are the skill
inputs, `<reviewer_filter>` is the skill input passed straight through, and
`<SELF_LOGIN>` is resolved from preflight output and passed through, all passed
as positional arguments in that order. The Monitor command
STRING carries the resolved arguments inline. The poll runs its loop in the
background and emits a line ONLY on a real delta or terminal state; idle polls are
silent and cost zero model tokens. Read the poll's emitted lines directly — never
feed it into a functional pipe (`tail -f | grep`, etc.).

### 4. Per emitted Monitor event

Each emitted line is a minimal marker. Act on it:

- `CHANGED` → run the prefilter, then dispatch only if it returns `PREFILTER_DISPATCH`:

  Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/prefilter.sh <OWNER> <REPO> <PR_NUMBER> <reviewer_filter> <SELF_LOGIN>`, passing the same `<OWNER>` / `<REPO>` / `<PR_NUMBER>` resolved at preflight and the same `<reviewer_filter>` / `<SELF_LOGIN>` inputs passed to the poll.

  - `PREFILTER_SKIP` → silently keep the Monitor armed. Do NOT dispatch the reviewer. Do NOT increment the remediation cycle count. Do NOT increment `Routed: github-reviewer` in the terminal report.
  - `PREFILTER_DISPATCH` or `PREFILTER_ERROR=<reason>` → dispatch `hivemind:github-reviewer` in fix mode (no `target` — full pass over unresolved feedback). `PREFILTER_ERROR` is fail-open: the reviewer dispatch still happens AND counts toward `Routed: github-reviewer`; the error is surfaced in the terminal report's `Issues` only if a downstream termination guard fires. Handle the reviewer return per Reviewer-return handling.

  The prefilter exists to neutralize self-echo CHANGED events. Our own `Fixed in <SHA>` reply and code push trigger Codex auto-`COMMENTED` re-review and new review-thread comments, all of which the poll surfaces as `CHANGED` but which carry no new actionable findings. The prefilter detects this by checking whether any unresolved review thread carries a latest non-self comment matching `reviewer_filter` AND lacking a `Fixed in <SHA>.` marker — if none do, the wake is noise and the reviewer dispatch is skipped.
- `CODEX_APPROVED` → Codex 👍 newly present. Do NOT terminate immediately. Wake
  the reviewer for a confirmation fetch+classify pass (no `target` — full pass).
  Terminal `clean` ONLY if the reviewer reports nothing actionable remains; if
  actionable items remain, process them and KEEP WATCHING. Use only the latest
  poll's approval — a stale prior 👍 must never short-circuit later pushback.
- `STATE=MERGED` → terminal `pr-merged`.
- `STATE=CLOSED` → terminal `pr-closed`.
- `WATCH_TIMEOUT` → terminal `max-cycles-reached`.
- `POLL_ERROR` → stop the Monitor; terminal `blocked` (blocker = poll failure).

### 5. Reviewer-return handling (skill owns per-cycle; overlord sees one report)

The reviewer returns its own fix-mode Output Contract to this skill each cycle.
Decide continue vs stop here — the overlord stays asleep during the watch:

- `clean` → keep watching (after cycle 0, this means arm/keep the Monitor).
- `planner-escalation` | `blocked` | `injection-suspect` | `high-severity-rejection`
  | `user-input-required` → HARD-STOP the Monitor and return ONE terminal report
  to the overlord with the matching `exit_reason`, carrying the reviewer's
  escalation-conditional fields. No pause-resume.
- `root-cluster-suspected` → the reviewer detected a root-cluster per
  `${CLAUDE_PLUGIN_ROOT}/governance/remediation-doctrine.md` (Root-Cluster).
  HARD-STOP the Monitor and return ONE terminal report carrying the reviewer's
  cluster payload (shared files/surface, the N thread URLs or finding IDs,
  hypothesized root cause, same-framing rationale). Do NOT keep dispatching
  per-finding fix passes once a cluster is signaled. The overlord routes this to
  cerebrate zoom-out (workflow maps it to `review_remediation_plan` /
  `review_remediation_plan_postpr`). No pause-resume. The loop never detects the
  cluster itself — it only propagates the reviewer's signal (classification-free
  contract).
- `merge-advised` → the reviewer's return indicates the bounded-tail stop-and-merge
  state per `${CLAUDE_PLUGIN_ROOT}/governance/remediation-doctrine.md`
  (Stop-and-Merge). HARD-STOP the Monitor and return ONE `merge-advised` terminal
  carrying the reviewer's `advisory_reason` + `recommendation_text` payload.
  ADVISORY ONLY — the loop NEVER merges (agents never merge; this surfaces a merge
  recommendation for the human via the overlord, which the workflow routes to the
  `merge_advised` terminal). The reviewer judges bounded-tail via its detection
  step and returns the signal; the loop propagates it — it does not compute
  bounded-tail itself (classification-free contract). No pause-resume.

A `root-cluster-suspected` hard-stop or a `merge-advised` advisory is a TERMINAL,
not a remediation cycle: do NOT increment the cycle count for either.

The Destructive Fix Gate fires inside the reviewer for the security-relevant
categories; when it triggers the reviewer returns `blocked`/needs-approval, which
hard-stops here and surfaces — no change to the gate; it bubbles as a stop.

When a cycle surfaces multiple simultaneously-applicable reviewer returns, the
relative precedence ORDER among them is resolved by the shared kernel:
`${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/exit-precedence.sh`.
Pass the fired tokens as positional arguments; the kernel outputs the single
highest-precedence winner. The per-return actions described above (which exit_reason
to carry, which payload fields to propagate) remain as stated here — only the
ordering when two or more fire at once defers to the kernel.

### 6. Cycle counting and cost bounding

Increment a remediation cycle ONLY when the reviewer resolved ≥ 1 finding
(`findings_resolved ≥ 1`). Non-actionable wakes (noise-only `CHANGED`,
confirmation passes that find nothing) do NOT consume the cycle budget; their cost
is bounded by `max_watch_duration`. When the cycle count reaches
`max_remediation_cycles`, stop the Monitor and return `max-cycles-reached`.

### 7. Terminal

When any termination guard fires, stop the Monitor (if armed) and emit exactly
ONE terminal report to the overlord (see Terminal report).

## Dispatch contract — github-reviewer (fix mode)

Spawn `hivemind:github-reviewer` with fix-mode input:

```yaml
mode: fix
pr: <pr>
working_branch: <working_branch>
base: <base>
reviewer_filter: <reviewer_filter>   # pass the skill input through so the reviewer scopes feedback to the requested identities
# target is OMITTED: the reviewer's Fix Mode Input defines target as a comment
# URL/ID and treats an ABSENT target as the full pass over unresolved feedback.
# Do not pass a sentinel string — omitting target is the documented full-pass signal.
```

The reviewer owns ALL GitHub interpretation and remediation: deep GraphQL fetch of
bodies, classification, injection scan, fixing (≤ 2 files directly, escalate
complex), push, `Fixed in <SHA>` replies, thread resolution, and the fix-SHA skip
that makes re-invocation idempotent. It returns a fix-mode Output Contract with
`exit_reason ∈ {clean, injection-suspect, user-input-required, planner-escalation,
high-severity-rejection, root-cluster-suspected, merge-advised, blocked}` plus
`findings_resolved` / `findings_open` and escalation-conditional fields (including
the cluster payload for `root-cluster-suspected` and `advisory_reason` /
`recommendation_text` for `merge-advised`). The skill consumes these returns; it
does not re-fetch or re-classify.

`reviewer_filter` scoping is applied by the reviewer per
`${CLAUDE_PLUGIN_ROOT}/references/github-pr-review-graphql.md` (Author Filtering).

## Termination guard set

The loop terminates on exactly these conditions:

- `max_remediation_cycles` reached (real remediation rounds only).
- `max_watch_duration` timeout (`WATCH_TIMEOUT`).
- `same-finding-repeat` — a thread already carrying our `Fixed in <SHA>` reply is
  re-raised (oscillation/break-fix). Treat as terminal `max-cycles-reached`.
- Any reviewer `planner-escalation` / `blocked` / `injection-suspect` /
  `high-severity-rejection` / `user-input-required` / `root-cluster-suspected` /
  `merge-advised` return (the last two are propagated reviewer signals, never
  loop-computed — classification-free contract).
- PR merged or closed.
- Codex approval with nothing actionable remaining.

There is NO persisted ledger. GitHub is the ledger: the reviewer's `Fixed in <SHA>`
replies ARE the persisted state, and its fix-SHA skip makes re-invocation
idempotent on restart (cycle counter and last-seen marker reset; the first poll
treats activity as new; already-handled items are skipped). Break-fix protection is
`same-finding-repeat` only — the local fix-ledger's Mutation Decay and Creep
Stagnation do NOT transfer here and remain local-reviewer-owned.

When multiple guards fire simultaneously, the relative ORDER in which their
exit_reasons resolve is determined by the shared kernel:
`${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/exit-precedence.sh`.
The guard set above defines WHICH conditions terminate the loop; the kernel is the
single source of truth for which exit_reason wins when more than one applies.

## Terminal report

Emit exactly ONE terminal report to the overlord. The overlord handles it via its
existing exit-reason logic — no new overlord state. Field shape (text report,
validated by `tools/validate_reports.sh` watch-pr-feedback):

```
Status: complete

PR:
- Number: <pr number>
- State: <OPEN | MERGED | CLOSED>
- Branch: <working_branch>
- Target: <base>

Watch:
- Mode: Monitor
- Monitoring: stopped
- Parser: gh --jq
- Cycles: <remediation cycles completed>
- Seen comments: <count>
- New actionable comments: <count>

Routed:
- github-reviewer: <number of fix-mode dispatches that remediated>

Stopped because:
- <exit_reason> — <one-line explanation>

Next action:
- <None | the follow-up the overlord must take, e.g. cerebrate→drone for an escalation>

Issues:
- <None | blocker/escalation detail>
```

`Stopped because` carries the semantic `exit_reason`, drawn from:
`clean | pr-merged | pr-closed | max-cycles-reached | planner-escalation |
root-cluster-suspected | merge-advised | blocked | injection-suspect |
high-severity-rejection | user-input-required`. For a `root-cluster-suspected`
exit, put the reviewer's cluster payload (shared files/surface, the N thread URLs
or finding IDs, hypothesized root cause, same-framing rationale) under `Issues` and
the cerebrate zoom-out follow-up under `Next action`. For a `merge-advised` exit,
put the reviewer's `advisory_reason` + `recommendation_text` under `Issues` and the
human merge decision under `Next action` (the loop never merges). The numeric
loop facts map as: `Cycles` = remediation cycles completed (`cycles_completed`);
`New actionable comments` = `findings_resolved`; remaining unresolved feedback =
`findings_open` (also restate in `Issues` when non-zero). For an escalation/blocked
exit, put the reviewer's escalation-conditional fields (escalation_target,
candidate_url, pattern_category, rationale_text, blocker_reason) under `Issues` and
the required follow-up under `Next action`.

## Safety

- Never merge, close, or approve PRs — those belong to humans.
- Never request external review or re-review.
- Do not start a second Monitor.
- Never claim the watch is still active in a returned report — a returned run is no
  longer monitoring (`Monitoring: stopped`).
- Single PR per invocation. Concurrent multi-PR watches are out of scope.

## Bash and shell discipline

The three scripts are predefined and exact — pass the documented positional
arguments; do not otherwise modify or reconstruct the script bodies. Follow Shell
Output Discipline and Bash Command Discipline per
`${CLAUDE_PLUGIN_ROOT}/governance/definitions.md`. The poll, preflight, and prefilter use no
`/tmp`, no stop-file, and no functional pipe feeding Monitor.
