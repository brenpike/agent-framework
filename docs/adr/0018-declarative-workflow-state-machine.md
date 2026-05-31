# Declarative workflow state machine with intent-driven execution

**Status:** accepted — 2026-05-30

We are adding deterministic, resumable workflow execution to Hivemind by externalizing the *transition skeleton* of each workflow into declarative data (JSON workflow definitions + a per-run JSON ledger), while the *judgment inside each state* remains intent-driven by the agents and skills. This is an enhancement layered on top of intent-based execution (ADR-0006), not a replacement for it.

## Context

ADR-0006 deleted the framework's mechanical governance — including an 80-row state-transition table and dense sequencing prose embedded in the orchestrator body — because that encoding burned attention and LLMs reason better from intent than from lookup tables. ADR-0006 explicitly accepted the trade-off: "model may handle the same edge case differently across sessions."

A new requirement emerged that ADR-0006 traded away: **deterministic, stateful, resumable** workflow execution — including parallel brood children that must run autonomously and a future PRD-driven workflow whose shape differs from standard delivery. The catalog of workflows is expected to grow over time (analysis-only, standard-delivery, pr-feedback-remediation, hatchery-dispatch, exploratory, prd-driven, and more).

The tension: does re-introducing workflow definitions reverse ADR-0006? The resolution is that ADR-0006's target was *how rules are encoded and where they live* (dense prose inside the agent). This decision operates on a **different axis** — separating the legal-transition *skeleton* (declarative, external, inspectable, validated) from the *judgment* inside a state (intent, owned by the agent/skill the state points to). Done this way, the orchestrator gets **smaller**, not larger: per-workflow sequencing knowledge leaves the agent body and becomes data the agent reads.

## Decision

1. **WHO/WHAT-not-WHY invariant.** A workflow state may name WHO acts (agent / skill / overlord decision) and WHAT named outcomes are legal next. It may never encode WHY an outcome was chosen — every classification, judgment, and edge call lives in the agent/skill the state points to. (Consequence: `decision`-type states list legal outcome names; the overlord supplies the "why." A construct like `agent_from: current_step.owner` violates the invariant and is replaced by a static `allowed_agents` list + overlord intent.)

2. **Format follows consumer.** Machine-parsed persisted artifacts that the deterministic engine reads/writes — workflow definitions and the run ledger — are **JSON**, read and written with `jq` (already a required runtime dependency per ADR-0017; `--arg` gives injection-safe serialization of untrusted fields). All inter-agent / human-read communication and contracts — router I/O, skill I/O, the cerebrate plan block, the injected child task, delegation payloads — stay **YAML** for readability. No file is read by both `jq` and "only a human." `description` fields replace inline comments in JSON defs.

3. **Replace, don't layer.** The workflow-state-execution loop replaces the imperative pipeline and reviewer-return-handling prose in `overlord.md`; it is not added alongside it. What remains imperative in the overlord: a generic workflow-agnostic loop, the Reflex prose tail, and the mechanical safety rails.

4. **One trivial concept (Reflex).** Ledger-skip == Reflex (the existing trivial fast path). A Reflex task skips the router and the ledger entirely; the overlord drives its short delivery tail (molt → validate → PR) by intent, exactly as today. Everything that is not a Reflex enters the state machine.

5. **Router is the sole classifier.** A dedicated `route-workflow` skill (not overlord prose) selects the workflow by judgment — never a keyword lookup table. This keeps the overlord flat as the catalog grows: a new workflow = a new JSON def + one routing rule, overlord untouched. Individual workflow `intake` states must not re-classify across workflow boundaries.

6. **Exploratory catch-all is the codification nursery.** When the router matches no known workflow, it routes to `exploratory-intent-session` rather than dead-ending. The exploratory workflow handles novel requests in a bounded, ledgered, observable way and emits an **advisory** recommendation on whether the pattern should be codified into a new workflow. It never auto-authors a workflow definition — codifying one is a human decision (interrogation/ADR). The router must prefer concrete workflows; exploratory is the last resort.

7. **Intent-driven execution is the universal fallback.** Whenever the deterministic substrate is unavailable or invalidated — workflow-definition version skew across a plugin upgrade, a torn/corrupt ledger, a missing definition, or a `state.current` the engine cannot resolve — the overlord degrades to intent-driven completion rather than hard-failing. It reads the ledger for facts, finishes by judgment, and keeps appending events as an observability log (transition gating suspended, run marked `intent_fallback`). Determinism can only ever ADD safety/observability; it can never strand a run. Worst case = today's pure-intent behavior, never worse.

8. **Transition engine and ledger init are committed scripts.** `record-state-result.sh` and `init-run-ledger.sh` (mirroring the `spawn-brood.sh` precedent) own the deterministic read-validate-mutate-write. The ledger is written via temp-write + atomic rename so a concurrent reader (the hatchery reading a child ledger) never sees a torn file. The skills are thin navigators.

## Considered Options

| Option | Rejected because |
|---|---|
| Ledger-only, no workflow definitions (prose still sequences) | Loses the determinism/auditability of explicit legal transitions; the headline requirement |
| Full STT that gates AND classifies inside the YAML (expression language, `condition:`, `foreach`) | Re-creates the monster ADR-0006 killed; violates WHO/WHAT-not-WHY |
| All-YAML definitions + ledger, adopt `yq` | New, less-ubiquitous, ambiguous runtime dependency (two different `yq` programs); requires superseding ADR-0017; reopens the untrusted-text YAML-serialization injection class closed during the spawn-brood hardening arc — all to buy comments-in-defs |
| All-JSON everywhere, including communication payloads | Needlessly sacrifices YAML readability of inter-agent/human-read contracts for no determinism gain |
| Workflow selection as overlord prose (no router skill) | Overlord balloons as the workflow catalog grows — the exact failure mode this avoids |
| Hard-block (dead-end) on unroutable requests | Bounces the novel requests most worth learning from; no path to grow the catalog from real usage |

## Consequences

- The overlord ends **smaller** than before: dense pipeline + reviewer-return prose collapses into transition edges in the JSON definitions plus a generic loop.
- Two delivery drivers coexist (state machine for non-Reflex; short prose tail for Reflex). The drift surface is small and bounded (Reflex by definition has no version bump or review remediation).
- The run ledger becomes the source of truth for progress; resume-on-start + a version-skew gate (start-fresh / deterministic-resume / intent-driven-proceed) make runs resumable across sessions and, degradedly, across plugin upgrades.
- Determinism is mechanically enforced by CI: a workflow-definition structural validator + engine behavior tests (valid/illegal/stale/terminal/atomicity) + brood-manifest back-compat, wired into `policy-check.yml`. (`spawn-brood.sh` still lacks equivalent execution tests — recorded as backlog, out of scope here.)
- Relationship to ADR-0006: **clarified, not superseded.** Intent remains the execution floor; the state machine is a declarative skeleton on top. Mechanical encoding returns only for the legal-transition skeleton (an inter-agent/interface concern, where ADR-0006 already kept mechanical precision), never for in-state judgment.
- Brood children remain normal overlord instances (ADR-0007): they use the same engine, own their own ledger in their own worktree, and the hatchery reads child ledgers read-only. PR-4 spawn-brood edits stay purely additive to protect the hardened substrate (ADR-0017).
