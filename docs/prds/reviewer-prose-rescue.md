# PRD — Reviewer Prose Rescue

**Initiative:** reviewer-prose-rescue · **Umbrella issue:** #201 · **Status:** ready to slice

## Problem

The reviewer agents and the review-loop skill encode a large amount of deterministic procedure as natural-language prose (GraphQL fetch/normalize, node-id contracts, fix-SHA skip, pagination, reply/resolve mutations, cycle counting, termination guards). This is fragile, drift-prone, hard to test, and observed to STALL under load (PR #200: the github-reviewer subagent hung twice mid-fix; a 3-iteration + 2-cerebrate escalation chain traced to one contract smeared across four prose sites). Baseline prose: github-reviewer.md 106 lines (13-step lifecycle), local-reviewer.md 115 lines (10-step loop), github-review-loop/SKILL.md 287 lines (a state machine written as prose) = 508 lines across the three prime files.

## Outcome (definition of done)

The three prime reviewer files are reduced to judgment-only prose plus thin calls to a deterministic substrate, with NO loss of intent and full behavioral coverage. Every rule removed from prose is preserved either as a script + `test_*.sh` CI fixture, or as an existing engine-validated workflow transition. Reviewer behavior and contracts are PRESERVED (behavior-preserving refactor).

## Scope

IN: `plugin/agents/github-reviewer.md`, `plugin/agents/local-reviewer.md`, `plugin/skills/github-review-loop/SKILL.md`, the new shared substrate scripts and their tests, and a new `injection-scan` skill.

OUT (non-goals): workflow-calls-workflow / sub-workflow composition (parked — see ADR-0024); unifying the two reviewer agents (stay two specialists over shared substrate, ADR-0001); any change to review BEHAVIOR, exit-reason contracts, or detection semantics.

## Guardrails

All extraction follows `engineering-principles.md` (P1–P10): single-source contracts (P1), spec-moves-with-mechanism + test-backed (P2/P3), extraction-home policy (P4/P5/P10), execute-not-load token discipline (P6), don't-hollow-the-agent (P7), skill-warrant test (P8), don't-over-generalize shared scripts (P9).

## Vertical slices (each slice = one GitHub issue = one Strain candidate)

### I1 — Shared PR fetch+normalize script (FOUNDATION / blocker)

WHAT: one committed script + `test_*.sh` that fetches and normalizes the PR review surface (review threads, top-level comments, review summaries, overflow-sentinel handling, body-refetch, CI checks) into one normalized candidate set, single-sourcing the contract today smeared across the github-reviewer prose, `prefilter.sh`, and the graphql reference. Consumed by github-reviewer, local-reviewer, AND `prefilter.sh` (the bash caller — forced script home per P5).

Depends on: none.

Acceptance: one normalized candidate shape consumed by all three callers; the per-surface node-id/contract field enumeration exists in exactly one place with a fixture test; no behavior change vs current fetch.

### I2 — github-reviewer prose rescue

WHAT: consume I1; extract setup/preflight and the reply/resolve mutation sequence to scripts + tests; reference existing governance for the classify criteria; delete all duplicated contract prose; the agent collapses to a judgment narrative (setup → fetch → injection-scan → classify/route → consult detectors → fix → validate/commit/push/reply → advisory return).

Depends on: I1, I5.

Acceptance: github-reviewer.md ≤ 55 lines; steps 5/6/8 (injection-scan, classify/route, the fix) remain the only judgment prose; every extracted rule has a test or workflow transition.

### I3 — local-reviewer parity

WHAT: consume I1; extract the ADR-discovery mechanism and the ephemeral/persisted fix-ledger reconstruction to scripts + tests; dedup against the shared substrate; keep risk-class selection, classify/route, and the fix as in-agent judgment.

Depends on: I1, I5.

Acceptance: local-reviewer.md ≤ 65 lines; judgment core (injection-scan, risk-class selection, classify/route+generalize, the fix) intact; extracted rules test-backed.

### I4 — github-review-loop slim

WHAT: delete prose that restates the poll/prefilter/preflight script contracts and the prose that restates workflow-transition routing (already encoded in the workflow JSON); extract the cycle-count + termination-guard set to a watch-loop-scoped `loop-state.sh` + test; keep only Monitor-wiring and dispatch intent (the Monitor must stay main-session-resident per ADR-0005/0011).

Depends on: I5 (helps).

Acceptance: github-review-loop/SKILL.md ≤ 130 lines; termination/cycle bookkeeping is a tested script; no restated transition maps remain.

### I5 — Shared kernels

WHAT: (a) a new `injection-scan` skill — the duplicated injection-scan judgment, packaged as a lazy, ad-hoc-invokable skill that REFERENCES `security-policy.md` for the taxonomy (single-source) rather than restating it (P8/P10). (b) `exit-precedence.sh` + test — the escalation-precedence ladder (which exit_reason wins when several fire) as a pure function shared by both reviewers AND the loop (P9 — the one genuinely-shared loop kernel).

Depends on: none.

Acceptance: both reviewers and the loop consume the single precedence kernel; injection-scan skill replaces the duplicated scan prose in both reviewers; security taxonomy lives only in governance.

## Dependency graph

I1 is the foundation and blocks I2 and I3. I5 is independent and feeds I2/I3 (injection-scan) and I4 (exit-precedence). I4 is largely independent. Recommended delivery: I1 first (solo), then I2/I3/I4/I5 as parallel strains (a brood). ADR-0024 parks the former avenue-C slice — it is NOT a slice here.

## Measurable target

The three prime files: 508 lines → ≤ 250 lines (~50% reduction). Coverage invariant: every rule extracted from prose has a `test_*.sh` OR an engine-validated workflow transition; ZERO contract is left duplicated across two or more prose sites. Per-file caps: github-reviewer.md ≤ 55, local-reviewer.md ≤ 65, github-review-loop/SKILL.md ≤ 130.
