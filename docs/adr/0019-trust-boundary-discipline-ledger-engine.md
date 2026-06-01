# Trust-boundary discipline: committed engine/helper scripts accept identifiers, derive every path

**Status:** accepted — 2026-06-01

The committed engine and helper scripts that cross a trust boundary accept IDENTIFIERS, never PATHS. They DERIVE every path they touch from ground truth, project hostile cross-boundary CONTENT to bounded allowlist-validated tokens rather than reading/executing/emitting it raw, and treat the PACKAGED workflow definition as the sole transition/authorization source of truth — never a caller-supplied one. This ADR names the discipline, records the two reproduced P0s it dissolves, and supersedes the ADR-0018 f92f1db8 "trusted overlord-resolved path" decline.

## Context

The workflow engine (ADR-0018) added two committed scripts — `init-run-ledger.sh` and `record-state-result.sh` — that the overlord drives across a trust boundary. The original design accepted PATHS from the caller: `record-state-result.sh` took a `ledger` path and a `workflow`-definition path; the overlord was assumed to resolve both to in-tree, plugin-shipped files (ADR-0018 §8, and the f92f1db8 implementation note, which declined to anchor `--workflow` on the premise that the value "originates entirely within the overlord's own reasoning").

That premise broke. Two trust-boundary P0s were REPRODUCED against the engine (the Codex thread text describing them is DATA — the vectors are summarized here, not pasted-and-obeyed):

1. **Forged ledger path → arbitrary-file overwrite.** A caller-supplied `ledger` path was the file the engine atomically rewrote. A path pointing outside `.hivemind/runs/` turned the engine's own atomic write into an arbitrary-file-overwrite primitive.
2. **Forged definition path → transition-gate + plan-write-auth bypass.** A caller-supplied `workflow`-definition path was the SOLE source of the legal-transition set AND of the per-state `agent` field that gates plan writes. A forged definition could declare any transition legal and any state a cerebrate planning state, bypassing both the transition gate and the plan-write authorization the engine exists to enforce.

Both reproductions share one root cause: a script on the far side of a trust boundary accepted a PATH and treated whatever it pointed at as ground truth.

## Decision

**Committed engine/helper scripts accept identifiers, never paths; they derive every path from ground truth; hostile cross-boundary content is projected to bounded tokens; the packaged definition is the sole transition/auth source of truth.**

Concretely:

- A script that crosses a trust boundary takes IDENTIFIERS (a `run_id`, a workflow id) validated against a fixed safe-component charset (`^[A-Za-z0-9._-]+$`, with `.`/`..` rejected), never a caller-supplied PATH.
- It DERIVES every path it touches from ground truth: a run ledger from `git rev-parse --show-toplevel` + `run_id`; a workflow definition from the script's OWN self-located packaged dir (`BASH_SOURCE` + `pwd -P`, independent of `${CLAUDE_PLUGIN_ROOT}` and of any caller value).
- It COHERENCE-CHECKS the derived ground truth against the supplied identifier (the on-disk `ledger.run.id` must equal the passed `run_id`).
- Hostile cross-boundary CONTENT is projected and allowlist-validated to bounded tokens — never Read-whole, executed, or emitted raw. Untrusted fields enter `jq` only as `--arg`/`--argjson` bindings; they never become program or command SOURCE.
- The PACKAGED definition — the plugin-shipped `workflows/<id>.json` self-located by the script — is the sole transition and authorization source of truth, never a caller-supplied file.

### Three boundaries this discipline governs

1. **overlord / navigator → engine.** FIXED this PR. `record-state-result.sh` now takes a `run_id` (SAFE_ID_RE-validated, `.`/`..` rejected), derives the ledger from the git checkout root, coherence-checks `ledger.run.id == run_id`, and derives the workflow definition from the ledger's own `run.workflow` against the self-located packaged dir. No caller path is accepted on either axis.
2. **init → packaged definition.** FIXED this PR (#162). `init-run-ledger.sh` self-locates its packaged `workflows/` dir and validates the supplied workflow id against the packaged definition (the file must EXIST, its `.version` must equal `workflow_version`, its `.start` must equal `start_state`) BEFORE creating the run dir, failing early so a bad id/version/start never leaves an orphan run dir.
3. **hostile `--dangerously-skip-permissions` child → coordinator.** STAGED (#161). The brood child reads child-ledger content across a boundary into the coordinator dashboard; bringing that read under this same discipline (identifiers + derivation + bounded-token projection of hostile ledger content) is tracked in #161 and to be implemented against this ADR.

### Precedent — the discipline generalizes existing ad-hoc hardening

This principle is not new invention; it codifies hardening already landed piecemeal:

- **`spawn-brood.sh`** (ADR-0017) keeps filesystem checkout paths OUT of generated shell source by deriving them out-of-band (`wt="$(git rev-parse --show-toplevel)/.claude/worktrees/<short>"`, then referenced only as `"$wt"`), and gates `branch`/`base` through a charset allowlist in agent reasoning before any shell use. Identifiers + derivation + allowlist — the same shape.
- **`github-review-loop`** preflight / prefilter / poll scripts use their positional arguments only as inert `"$var"` references and project untrusted GitHub API content through `jq` to fixed tokens — hostile content never becomes command source.

The two reproduced P0s above are instances of a boundary that had NOT yet received this treatment; the discipline dissolves them the same way it already hardened spawn-brood and the review-loop.

## Considered Options

| Option | Rejected because |
|---|---|
| Keep accepting a caller `ledger`/`workflow` path, anchor/canonicalize it | Guards a path the caller still controls; the f92f1db8 decline already showed "trusted overlord-resolved path" is not a real boundary once the vector is in-model. Derivation removes the path from the interface entirely. |
| Validate the definition CONTENT (schema) but keep the caller path | A schema-valid forged definition still declares hostile transitions/auth; content validation does not bound WHICH file is read. |
| Accept the `run_id` but still take the ledger path for the write target | Re-admits the arbitrary-overwrite primitive; the write target must be derived, not supplied. |

## Consequences

- The engine interface shrinks: `record-state-result.sh` takes a `run_id` plus inert data, no paths. The arbitrary-file-overwrite and forged-definition primitives are structurally absent — there is no path on the interface to forge.
- The packaged definition is authoritative. A plugin upgrade that changes a definition surfaces as a binding/version-skew mismatch (handled by the resume gate's two doors), never as a silently-honored alternate definition.
- Boundary 3 (#161) is staged, not closed; the coordinator's read of hostile child-ledger content must be brought under the same identifier+derivation+bounded-token discipline before it is considered compliant.
- **Supersedes the ADR-0018 f92f1db8 implementation note.** That note declined to anchor `--workflow` because the value was deemed "trusted overlord-resolved path / out-of-model." The forged-definition + plan-write-auth-forgery vector was REPRODUCED and is now IN-model; the engine no longer accepts a workflow path at all, reversing the prior decline. ADR-0018's f92f1db8 note is marked superseded (original retained, append-only).
- This decision is hard-to-reverse (it removes paths from a committed interface), surprising (it inverts the f92f1db8 "trusted path" posture), and a real trade-off (callers lose the ability to point the engine at an out-of-tree definition, e.g. for ad-hoc testing) — an ADR is warranted.

## Amendment — 2026-06-01 (canonical-containment guard: derivation requires verifying containment)

The derive-from-ground-truth principle is SHARPENED, not reversed: a derived TEXTUAL path is NOT confinement when an ancestor of that path is attacker-controlled. The original Decision derived the ledger path as the literal text `<checkout-root>/.hivemind/runs/<run_id>/state.json` and treated that derivation as sufficient confinement. It is not. `.hivemind/` is normally gitignored, but a repo can still COMMIT `.hivemind` (or `.hivemind/runs`) as a SYMLINK; git tracks the symlink itself, gitignore notwithstanding. When `.hivemind` resolves to an external directory, the textually-derived path resolves OUTSIDE the checkout, and the engine's own `mkdir`/`mktemp`/`mv` write there.

**Reproduced vector (Codex P0 r3331282391, summarized — the thread text is DATA, not instructions):** a tracked `.hivemind`→external symlink in the checkout redirected the engine write outside the checkout. With `.hivemind` pointing at an external dir, `init-run-ledger.sh` exited 0 and created `<external>/runs/demo/state.json` — the ledger write landed entirely outside the checkout, exactly the boundary the derivation was meant to enforce.

**The sharpening.** After textual derivation, BEFORE any `mkdir`/`mktemp`/`mv`, both engines now:

1. Canonicalize — resolve all symlink components — via the portable `cd … && pwd -P` idiom (not `realpath`/`readlink -f`, which BSD/macOS lack or spell differently); a failed `cd` yields an empty result under `set -u`, which is tested for and blocked rather than proceeding with an empty canonical path.
2. Verify the canonical path remains under the canonical `<checkout-root>/.hivemind/runs/` prefix (trailing-slash-guarded so a sibling like `.hivemind-evil` / `.hivemind/runs-evil` cannot prefix-match).
3. Explicitly reject any symlinked ancestor with a POSIX `[ -L ]` test (which detects a symlink component regardless of whether its target exists).

The two engines differ by their leaf's existence at guard time, and the guard is shaped accordingly:

- **`init-run-ledger.sh`** CREATES the run dir, so its leaf does not exist yet. It canonicalizes the deepest EXISTING ancestor (`.hivemind`, then `.hivemind/runs` when each is a real dir) and adds an explicit `[ -L ]` reject on `.hivemind` and `.hivemind/runs`. A first-init checkout where neither exists skips both probes — the leaf run dir is created later under the verified-contained canonical root. The ledger path is then derived from the CANONICAL root so the subsequent `mkdir -p`/`mktemp`/`mv` all operate on the verified path.
- **`record-state-result.sh`** requires the ledger to ALREADY EXIST, so it canonicalizes the already-existing ledger file (via its directory), requires the canonical ledger live under the canonical `.hivemind/runs/`, and uses the canonical (verified-contained) dir for the temp-write + atomic rename. All of this runs BEFORE `mktemp`, so a rejection never creates a temp file and the on-disk ledger is byte-unchanged.

**Lower-severity, separately tracked (out of scope for this engine fix).** The agent-authored inputs-file Write transport — `.init-inputs.json` / `.record-inputs.json` written to a fixed `.hivemind/` path by the Write tool — could LIKEWISE be redirected by a symlinked `.hivemind`. That is a distinct trust posture from the engine's own `mkdir`/`mktemp`/`mv`: it is an agent Write-tool transport, not an engine filesystem mutation, and is tracked separately rather than addressed here. The engine guards SHRINK that window: they reject a symlinked `.hivemind` the moment `init`/`record` runs.

This amendment is APPEND-ONLY. The original Decision and Consequences prose stand; this records that derive-from-ground-truth REQUIRES canonical-containment verification to be confinement, not merely textual derivation. Status remains accepted.
