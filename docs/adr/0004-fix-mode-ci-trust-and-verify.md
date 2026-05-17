# Fix-mode reports clean without waiting for CI re-run

Fix-mode processes all review candidates in a single pass, pushes fixes, and returns `exit_reason: clean` to the orchestrator. It does not poll CI or wait for required checks to re-run before reporting.

The alternative — blocking until the pushed fix produces a green check — was prototyped as a `ci-verification-pending` exit reason (implemented in ed4c062, reverted in b23f37f). It created an unhandled terminal state: fix-mode is one-shot, so a pending-verification outcome had no path to resolution within that invocation. The agent would either block indefinitely (CI runs take minutes to hours) or surface a result the orchestrator couldn't act on. Neither is acceptable.

Watch-mode already owns the re-failure detection path. Its `fix-pushed-awaiting-rerun` state captures exactly this case: a fix was pushed, the check has not yet re-run, and the next poll cycle will confirm pass or detect regression. Duplicating that state machine inside fix-mode would mean two owners of the same problem, with the added cost of indefinite blocking in the one-shot context.

The trust-and-verify pattern is the standard practice in CI workflows: push the fix, trust it resolves the failure, let the next pipeline run verify. Fix-mode pushes; watch-mode verifies.

## Considered Options

| Option | Rejected because |
|---|---|
| `ci-verification-pending` exit reason (block until check passes) | One-shot context has no resolution path; blocks agent indefinitely while CI runs; unhandled exit reason surfaced to orchestrator |
| Poll CI inline before returning clean | Duplicates watch-mode state machine; fixes the wrong layer; adds minutes of latency to every fix-mode run even when fix is obviously correct |

## Consequences

- Fix-mode CAN report clean while a required check is still pending or re-running; this is expected and acceptable
- Watch-mode's `fix-pushed-awaiting-rerun` → confirmation query → re-failure detection is the canonical verification path for CI re-run results
- If a fix does not resolve the underlying CI failure, watch-mode catches it on the subsequent poll cycle and routes accordingly
- No new exit reason is needed in fix-mode for the CI re-run scenario
