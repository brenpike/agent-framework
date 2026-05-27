# The deepening refactor is an execution skill consuming the architecture blueprint, on shared vocabulary

**Status:** accepted — 2026-05-27

`hivemind:refactor-to-depth` is the execution counterpart to the read-only producer `hivemind:improving-architecture` (ADR-0014). The producer emits a path-agnostic refactoring blueprint of deepening candidates (shallow → deep modules); this consumer takes one chosen candidate and applies it via a behavior-preserving refactor-under-green loop. The two form a producer/consumer artifact-transform pair — the same shape as `plan-to-prd` → `prd-to-issues` (ADR-0012 path-agnostic transforms, ADR-0013 composition-by-intent). The one asymmetry: this consumer edits product code, so its executor runs under the host framework's governance/lifecycle rather than being a free-standing transform. Both skills share architecture vocabulary and deepening mechanics extracted into `plugin/skills/_shared/` — the first cross-skill use of that directory.

## Context

ADR-0014 settled what `improving-architecture` is: read-only analysis that emits a blueprint and stops. It named the *planned consumer* — `refactor-to-depth` — but deferred the consumer's own design. This ADR records that design.

The blueprint is a decoupled artifact (ADR-0012/0013): a producer emits it, a separate consumer acts on it, and the operator chains them. `refactor-to-depth` is that consumer. The design questions were:

- How does the consumer relate to the producer without coupling to it (re-deriving the path-agnostic transform pattern rather than inventing a bespoke architecture pipeline)?
- The consumer edits product code — unlike `prd-to-issues`, whose consumer only writes GitHub issues. What does that asymmetry imply for where the executor runs?
- Both skills speak the same architecture vocabulary (module/interface/depth/seam/adapter, the deletion test) and the same deepening mechanics. Where does that shared substance live so it is authored once?

## Decision

`hivemind:refactor-to-depth` is an independently-invocable execution skill that consumes **one chosen deepening candidate** — accepted path-agnostically from live context (default) or an optional saved blueprint file — and applies it via a **refactor-under-green** loop: pin current behavior with characterization tests and reach GREEN; deepen under green in small moves (merge shallow modules behind one small interface, place the seam by dependency category, honor the two-adapters-or-no-port seam discipline); relocate tests to the deepened interface and delete the now-redundant shallow-module tests (replace, do not layer); apply the deletion test to confirm the module concentrates complexity that would otherwise reappear across callers. The invariant is GREEN before and after every move — never deepen while RED; if no green baseline can be established (degrading to the project's documented Validation Procedure where there is no unit-test harness), stop and report rather than refactor blind. The skill never installs or bootstraps a test harness.

- **Producer/consumer artifact-transform pairing.** `improving-architecture` (producer, read-only) → `refactor-to-depth` (consumer, edits code) is the same shape as `plan-to-prd` → `prd-to-issues`: a producer emits a path-agnostic artifact (ADR-0012), a separate consumer acts on it, and the operator/host chains them. Per ADR-0013 (composition by intent), the consumer does **not** name or invoke the producer skill — it accepts the candidate as data from whatever source, so it survives the producer's absence and stays independently composable. Each is a decoupled leaf.

- **The one asymmetry vs `prd-to-issues`: the executor edits product code.** `prd-to-issues` produces GitHub issues — its output never touches the working tree, so it is a free-standing transform. `refactor-to-depth` modifies source and test files. A skill that edits product code cannot own the surrounding state: branch selection, checkpointing, validation, version impact, review, and PR all belong to the host framework's lifecycle, not to a transform. So while the *artifact-consumption model still holds* (a candidate in, a deepened module out), the executor runs **under the host framework's governance and lifecycle** rather than as an unsupervised standalone transform. This is described generically: the skill itself is framework-agnostic and carries no orchestration prose or host-agent names in its body; in hivemind specifically the governing lifecycle is branch → checkpoint → validate → version → review → PR, owned by the orchestrator — but the skill does not encode that.

- **Shared vocabulary extracted to `plugin/skills/_shared/`.** Both skills speak one architecture language and one set of deepening mechanics. To author that substance once, it lives in `${CLAUDE_PLUGIN_ROOT}/skills/_shared/LANGUAGE.md` (module / interface / implementation, depth / deep / shallow, seam, adapter, leverage, locality, and the deletion test) and `${CLAUDE_PLUGIN_ROOT}/skills/_shared/DEEPENING.md` (deepening mechanics and the dependency categories that drive seam treatment). This is the **first** real cross-skill use of `_shared/`. The rule: such shared references stay **one level deep** — a skill references a `_shared/` doc directly; `_shared/` docs do not chain into each other, and the shared docs carry shared vocabulary/mechanics only, never skill-specific procedure.

## Considered Options

| Option | Rejected because |
|---|---|
| One do-everything analyze-and-refactor skill | Rejected already by ADR-0014: it would force the read-only producer to edit code, and would own state belonging to the host's git lifecycle. Splitting producer (read-only) from consumer (edits, governed) preserves both invariants |
| Consumer hard-invokes the producer (`refactor-to-depth` calls `improving-architecture`) | Couples the leaves and breaks ADR-0013 composition-by-intent; the consumer would not survive the producer's absence and could not run standalone on a candidate described directly in context |
| A free-standing transform that edits code without host governance (mirror `prd-to-issues` exactly) | Ignores the asymmetry: editing product code means branch/checkpoint/validate/version/review/PR state must be owned somewhere. An unsupervised code-editing transform would own state that belongs to the host lifecycle |
| Duplicate the architecture vocabulary and deepening mechanics inside each skill | Two copies drift; a vocabulary change must be made twice. Extracting to `_shared/` authors it once. Chosen, with the one-level-deep reference rule |

## Consequences

- `improving-architecture` and `refactor-to-depth` are a producer/consumer pair in the path-agnostic artifact-transform family (ADR-0012/0013), analogous to `plan-to-prd` → `prd-to-issues`. The producer stays read-only; the consumer applies one candidate. Neither names nor invokes the other — composition is by intent and by operator chaining.
- The consumer edits product code, so its executor runs under the host framework's governance/lifecycle (in hivemind: branch → checkpoint → validate → version → review → PR). This is the single asymmetry vs `prd-to-issues`, whose output never touches the working tree. The skill body stays framework-agnostic — no host-agent names, no orchestration prose.
- `plugin/skills/_shared/` now has its first real cross-skill use: `LANGUAGE.md` and `DEEPENING.md`, referenced via `${CLAUDE_PLUGIN_ROOT}/skills/_shared/...` by both skills. Shared references stay one level deep — skills reference `_shared/` docs; `_shared/` docs do not chain. A future third architecture skill reuses the same two docs rather than re-authoring the vocabulary.
- The green-gate degradation path (run the documented Validation Procedure where no unit-test harness exists, never install one) keeps the skill usable in non-unit-tested repos — including this Markdown-plugin repo, whose green-gate is the policy linter — without manufacturing a harness.
- This ADR fulfils the consumer named-but-deferred by ADR-0014; it does not supersede ADR-0014, which still governs the read-only producer.
