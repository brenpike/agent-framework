# Monitoring Policy

## Purpose

Defines shell/parser constraints, monitoring truthfulness rules, and retry/failure handling for all agents.

## Shell and Parser Policy

Use deterministic shell/parser behavior.

Do not:

- shell-hop for routine parsing
- call `powershell -Command` from Bash for routine parsing
- call Bash from PowerShell for routine parsing
- dynamically probe Python, Node, standalone `jq`, PowerShell, or other parsers during normal execution
- restart Monitor with different parser strategies without explicit user approval
- continue monitor loops after parser failures without reporting the failure

Prefer:

1. native Claude shell for the current environment
2. `gh pr view --json ... --jq ...`
3. `gh api graphql --jq ...`
4. deterministic commands with bounded retries

If the approved shell/parser strategy fails, retry once only when the failure matches the "Transient failure" definition, then return `blocked` rather than improvising parser fallback chains.

## Monitoring Policy

A remediation skill is not a monitor. A monitor is not a remediator.

Use `agent-framework:watch-pr-feedback` only when the user request contains at least one of `watch`, `monitor`, `wait`, `poll`, or `loop`. See Definitions → One-time vs watch routing.

Monitoring must be:

- backed by Monitor, scheduled task, routine, channel, or equivalent real background trigger
- read-only while watching
- deterministic and parser-stable
- bounded by max watch duration and remediation cycles
- routed through remediation skills instead of editing directly

A monitor targeting a specific resource (PR, issue, branch, workflow run, deployment) must terminate when the watched resource reaches a terminal state (e.g., PR merged or closed, issue closed, run completed, branch deleted, deployment finished). Continued polling against a terminal resource is parser-stable but pointless drift and must be stopped immediately. Detection commands must include the resource's state field so terminal transitions are observable on every poll.

Do not say or imply active monitoring is running unless a real background mechanism started successfully.

If no background mechanism is active, report:

```text
Status: complete | blocked
Mode: manual
Monitoring: not active
Next action:
- User must invoke the skill again when new feedback appears
```

## Retry and Failure Policy

Failures are execution states, not waiting states.

After any tool error, timeout, failed delegation, unusable output, missing permission, parser failure, or internal runtime failure, the observing agent must immediately do one of:

1. retry exactly once if the failure matches the "Transient failure" definition
2. continue with a documented safe fallback (a fallback is "documented" when it appears in the agent's own file or in a referenced skill/governance file)
3. return `blocked` per the Blocked Report Contract

Rules:

- Do not repeat the same command (after argument normalization) more than once unless one of: at least one argument value changes, the working directory changes, or a prerequisite command in between has succeeded where it previously failed.
- Do not wait for the user to ask what happened.
- Do not abandon a failed skill, monitor, or delegation without a blocked report.
- Do not invoke a broader skill (one whose Invocation Boundary admits more cases) unless the user's request matches that broader skill's Invocation Boundary literally.
