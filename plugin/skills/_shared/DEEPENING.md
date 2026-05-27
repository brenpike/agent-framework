# Deepening

How to deepen a cluster of shallow modules safely, given its dependencies. The dependency category drives how the deepened module is tested across its seam — the same classification serves whether you are identifying a candidate or performing the refactor. Assumes the architecture vocabulary (**module**, **interface**, **seam**, **adapter**) defined in `${CLAUDE_PLUGIN_ROOT}/skills/_shared/LANGUAGE.md`.

## Contents

- [Dependency categories](#dependency-categories)
- [Seam discipline](#seam-discipline)
- [Testing: replace, do not layer](#testing-replace-do-not-layer)

## Dependency categories

Classify each dependency of the cluster into one of four categories. The category determines how the deepened module is tested across its seam.

### 1. In-process

Pure computation, in-memory state, no I/O. Always deepenable — merge the modules and test through the new interface directly. No adapter needed.

### 2. Local-substitutable

Dependencies with a local test stand-in (PGLite for Postgres, an in-memory filesystem). Deepenable when the stand-in exists. Test the deepened module with the stand-in running in the suite. The seam is internal; no port at the module's external interface.

### 3. Remote but owned — port + adapter

Your own services across a network boundary (microservices, internal APIs). Define a **port** (interface) at the seam: the deep module owns the logic, the transport is injected as an **adapter**. Tests use an in-memory adapter; production uses an HTTP/gRPC/queue adapter.

End-state phrasing: *"A port at the seam, with an HTTP adapter for production and an in-memory adapter for testing, so the logic sits in one deep module even though it deploys across a network."*

### 4. True external — mock + inject

Third-party services you do not control (Stripe, Twilio, and the like). The deepened module takes the external dependency as an injected port; tests provide a mock adapter.

## Seam discipline

- **One adapter means a hypothetical seam. Two adapters means a real one.** Do not introduce a port unless at least two adapters are justified (typically production + test). A single-adapter seam is just indirection — treat it as such rather than building it.
- **Internal seams vs external seams.** A deep module can have internal seams (private to its implementation, used by its own tests) as well as the external seam at its interface. Do not expose internal seams through the interface merely because tests use them.

## Testing: replace, do not layer

The expected end-state once a cluster is deepened:

- Old unit tests on the shallow modules become waste once tests at the deepened module's interface exist — they should be deleted, not kept alongside.
- New tests live at the deepened module's interface. The **interface is the test surface**.
- Tests assert on observable outcomes through the interface, not on internal state.
- Tests should survive internal refactors — they describe behaviour, not implementation. If a test must change when the implementation changes, it is testing past the interface, and the seam is misplaced.
