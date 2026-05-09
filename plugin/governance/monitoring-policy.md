# Monitoring Policy

## Purpose

Defines shell/parser constraints, monitoring truthfulness rules, and retry/failure handling for all agents.

## Shell and Parser Policy

Use deterministic shell/parser behavior.

Do not:

- shell-hop for routine parsing
- dynamically probe Python, Node, standalone `jq`, or other parsers during normal execution
- restart Monitor with different parser strategies without explicit user approval
- continue monitor loops after parser failures without reporting the failure
- use `python3`, `python`, or any Python invocation to parse Monitor command output

Prefer:

1. native Claude shell for the current environment
2. `gh pr view --json ... --jq ...`
3. `gh api graphql --jq ...`
4. deterministic commands with bounded retries

### Shell Compatibility

Monitor commands must work across shell environments without modification.

- The Monitor tool's shell context may differ from the skill's declared `shell:` frontmatter value. Do not assume that tools available in the skill's interactive shell are available in the Monitor shell context.
- Do not assume `python3`, `python`, `node`, or standalone `jq` are on `PATH` in the Monitor shell context. These binaries are unreliable across environments.
- `gh --jq` and `gh api graphql --jq` use the `gh` CLI's built-in jq processor. This is the canonical cross-environment parsing tool and is the only approved parsing mechanism for Monitor commands.
- If a Monitor command relies on any binary other than `gh`, assume it may fail. Report `Monitoring: not active` rather than attempting parser substitution.

If the approved shell/parser strategy fails, retry once only when the failure matches the "Transient failure" definition, then return `blocked` rather than improvising parser fallback chains.

## Monitoring Policy

A remediation skill is not a monitor. A monitor is not a remediator.

Use `agent-framework:watch-github-pr-feedback` only when the user request contains at least one of `watch`, `monitor`, `wait`, `poll`, or `loop`. See Definitions → One-time vs watch routing.

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

## Non-Monitor Skills

`agent-framework:review-loop-controller` uses iterative invocation (not Monitor). It does not poll a remote resource; it invokes `agent-framework:local-codex-review` synchronously per iteration. Do not apply Monitor rules to the review loop controller.

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
