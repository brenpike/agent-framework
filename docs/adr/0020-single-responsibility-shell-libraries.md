# New engine logic is factored into focused, unit-tested `_shared/` function libraries composed behind a thin entrypoint

**Status:** accepted — 2026-06-01

## Context

Engine and skill shell logic has trended toward large monolithic scripts. `spawn-brood.sh` is the clearest example: it handles input validation, path derivation, canonical-containment, manifest emission, tmux session management, readiness polling, and task injection in one file. Monolithic scripts are hard to unit-test (every test must drive the full script), hard to reuse (a second consumer must either copy or source the whole thing), and hard to review (a single change touches all concerns at once).

The repo already has one counter-example: `plugin/skills/_shared/containment.sh`. It provides focused, sourced functions (`hivemind_assert_contained`, `hivemind_assert_file_contained`, `hivemind_assert_inputs_contained`) with no top-level side effects and no `exit` — independently auditable, sourced by three different consumers (`init-run-ledger.sh`, `record-state-result.sh`, `spawn-brood.sh`). That library emerged from a security need (canonical-containment guards, ADR-0019); its structure is the right model for new logic generally.

Issue #161 (brood-status read-side ledger projection) was the first deliberate application of this pattern. Rather than extending an existing script or adding new logic inline in `brood-status`'s SKILL.md body, the projection work was factored into three focused libraries from the start.

## Decision

**New engine logic is factored into focused, individually unit-tested `plugin/skills/_shared/*.sh` function libraries (single responsibility, source-safe: no top-level side effects, no `exit`) composed behind a THIN executable entrypoint.**

Concretely:

- Each `_shared/` library has one responsibility and exposes named shell functions only. It carries no top-level side effects and never calls `exit` — it is always sourced, never executed directly.
- Each library is individually unit-tested. Tests live in `tools/test_shared_libs.sh` and are wired into the `policy-check` CI gate.
- A THIN executable entrypoint sources the required libraries, invokes their functions in sequence, and owns only the orchestration and I/O surface. It may carry `set -euo pipefail`, an EXIT trap (guaranteed-zero `:` on clean exit), and self-location via `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P`. It does NOT duplicate logic already in a library.
- Engineering conventions carry into every library: `set -u`, EXIT-trap guaranteed-zero (`:`) on the entrypoint, `cd && pwd -P` for self-location, no `realpath`/`readlink` (BSD/macOS portability), no top-level side effects in sourced files.

**#161 established this pattern** with three new libraries and one thin entrypoint:

- `plugin/skills/_shared/allowlist.sh` — safe-token gate: validates a string against an allowlist regex and emits a fixed failure token on mismatch. Reusable by any script that must gate untrusted input before shell use.
- `plugin/skills/_shared/manifest.sh` — manifest field extraction: reads a named scalar from a YAML manifest via `jq`, applies the allowlist gate, and returns a fixed failure token on mismatch. Reused by `brood-status-project.sh`; reusable by spawn-brood (#168 follow-up).
- `plugin/skills/_shared/ledger-project.sh` — ledger scalar projection and validation: reads a named scalar from a JSON ledger via `jq`, validates it against a caller-supplied pattern and length bound, and returns a fixed `MALFORMED`/`MISSING` token on failure. Never emits raw ledger bytes.
- `plugin/skills/brood-status/scripts/brood-status-project.sh` — the thin entrypoint: sources the three libraries, takes a trusted manifest path as its only identifier input, derives every other path out-of-band, and orchestrates the projection of child-ledger scalars. Layout-agnostic: reusable when the manifest layout changes (#168).

**Existing monoliths are tech debt, not models.** `spawn-brood.sh` is the primary example. It MUST NOT be extended with new logic inline; new logic belonging to it should be factored into (or reuse) `_shared/` libraries. Incremental reduction of `spawn-brood.sh` toward the thin-entrypoint model is tracked as a follow-up issue; it is not required before merging work that touches it for unrelated reasons.

## Considered Options

| Option | Rejected because |
|---|---|
| Continue inline logic in SKILL.md navigator bodies | Cannot be unit-tested; load-bearing shell mixed with prose; grows the navigator surface reviewed on every change |
| Committed monolithic scripts per skill | Established pattern (`spawn-brood.sh`); hard to test, reuse, or review in isolation; new monoliths compound the problem |
| Per-skill `scripts/` with no shared libs | Reuse requires copy; divergence of containment/allowlist logic across scripts is the root cause of ADR-0019's multi-script guard drift |
| Single large `_shared/helpers.sh` | One responsibility per file is the point; a single large shared file recreates the monolith problem at the library layer |

## Consequences

**Benefits:**

- Each library is testable in isolation: unit tests drive individual functions without standing up a full script execution context.
- Shared logic (`allowlist.sh`, `manifest.sh`) is reusable by multiple consumers without copy-paste; `spawn-brood.sh`'s adoption of the shared allowlist and manifest libs is tracked as a follow-up issue.
- Review surface per change is smaller: a change to ledger projection touches only `ledger-project.sh` and its tests.
- Composition: the thin entrypoint is a manifest of which concerns are combined, making the dependency graph explicit and auditable.

**Costs:**

- More files: each concern is a file. Navigating requires knowing where to look.
- Sourcing discipline: every library must stay side-effect-free and `exit`-free, or sourcing it in a caller that also sources other libs will produce surprising interactions. This is a convention, not a language constraint — it must be maintained by review.

**Carry-forward conventions** (apply to every new `_shared/` library and thin entrypoint):

- `set -u` in every file (including sourced libs, where it takes effect in the sourcing shell).
- EXIT trap ends in guaranteed-zero `:` on entrypoints — not on libs (libs do not install traps).
- Self-location via `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P` on entrypoints — not required on libs (they are sourced, not executed).
- No `realpath` or `readlink -f` (absent or differently spelled on BSD/macOS); use the `cd && pwd -P` idiom.
- No top-level side effects in sourced files: no variable mutations, no I/O, no subshell launches at source time.

**Follow-up:** `spawn-brood.sh` adoption of `_shared/allowlist.sh` and `_shared/manifest.sh` (reuse of the safe-token gate and manifest-field extraction already present in those libs rather than maintaining parallel inline implementations) is tracked as a follow-up issue.
