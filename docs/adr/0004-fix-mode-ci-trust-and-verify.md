# Fix-mode reports clean without waiting for CI re-run

Fix-mode processes all review candidates in a single pass, pushes fixes, and returns `exit_reason: clean` to the orchestrator. It does not poll CI or wait for required checks to re-run before reporting.

The alternative — blocking until the pushed fix produces a green check — was prototyped as a `ci-verification-pending` exit reason (implemented in ed4c062, reverted in b23f37f). It created an unhandled terminal state: fix-mode is one-shot, so a pending-verification outcome had no path to resolution within that invocation. The agent would either block indefinitely (CI runs take minutes to hours) or surface a result the orchestrator couldn't act on. Neither is acceptable.

The `hivemind:github-review-loop` skill already owns the re-failure detection path. Its next poll captures exactly this case: a fix was pushed, the check has not yet re-run, and the subsequent poll cycle will confirm pass or detect regression. Duplicating that loop inside fix-mode would mean two owners of the same problem, with the added cost of indefinite blocking in the one-shot context.

The trust-and-verify pattern is the standard practice in CI workflows: push the fix, trust it resolves the failure, let the next pipeline run verify. The `hivemind:github-review-loop` skill's next poll is the canonical CI re-run verification path; fix-mode pushes-and-trusts, the skill verifies on the subsequent poll.

## Considered Options

| Option | Rejected because |
|---|---|
| `ci-verification-pending` exit reason (block until check passes) | One-shot context has no resolution path; blocks agent indefinitely while CI runs; unhandled exit reason surfaced to orchestrator |
| Poll CI inline before returning clean | Duplicates the github-review-loop skill's poll; fixes the wrong layer; adds minutes of latency to every fix-mode run even when fix is obviously correct |

## Consequences

- Fix-mode CAN report clean while a required check is still pending or re-running; this is expected and acceptable
- The `hivemind:github-review-loop` skill's next poll → reviewer confirmation pass → re-failure detection is the canonical verification path for CI re-run results
- If a fix does not resolve the underlying CI failure, the skill catches it on the subsequent poll cycle and routes accordingly
- No new exit reason is needed in fix-mode for the CI re-run scenario
