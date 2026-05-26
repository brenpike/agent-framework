# Meta-pipeline skills are path-agnostic artifact transforms

**Status:** accepted — 2026-05-25

`hivemind:plan-to-prd` and `hivemind:prd-to-issues` produce durable work artifacts (a PRD, then vertically-sliced GitHub issues) and have zero bearing on the execution path. Whether the resulting work runs single-branch or as a brood is decided solely by the cerebrate's overlap analysis at implementation time (or by explicit Overmind direction) — independent of how the work items were created.

## Context

The meta-pipeline initiative adds two new artifact-producing skills: `plan-to-prd` (interrogated plan → `docs/prds/<slug>.md`) and `prd-to-issues` (PRD → vertically-sliced GitHub issues). The original ideation coupled them to the brood path — framed as "PRD/issues = brood tier only" — which implied that producing a PRD or issues forces a brood. Interrogation found this conflates two unrelated concerns: **artifact production** (decompose an interrogated idea into trackable work) and **execution routing** (decide single-branch vs brood). The single-vs-brood gate already exists upstream (overlord step 3a/3b + cerebrate overlap analysis) and fires at implementation time, not at artifact-production time.

## Decision

`plan-to-prd` and `prd-to-issues` are artifact producers with no bearing on the execution path. The single-branch-vs-brood decision is made solely by the cerebrate's overlap analysis at implementation time (or by explicit Overmind direction) — independent of how the work items were created. Well-sliced, minimal-overlap issues *tend* to be good brood candidates, but nothing about invoking these skills forces a brood. A PRD and its issue set are equally valid inputs to sequential single-branch work.

## Considered Options

| Option | Rejected because |
|---|---|
| Coupled pipeline (gate → single-branch OR plan-to-prd → prd-to-issues → brood) | Conflates artifact production with execution routing; falsely implies invoking the skills mandates a brood; prevents using a PRD/issue set for sequential single-branch work |
| Path-agnostic transforms (chosen) | Skills usable standalone and on any path; brood is one possible consumer of the output, not its purpose |

## Consequences

- The skills are usable standalone and on any execution path — the output never dictates routing
- Brood is one possible consumer of the issue set, not the purpose of producing it
- The cerebrate single-vs-brood gate is unchanged (overlord step 3a/3b); it stays the sole path decider and fires at implementation
- Docs and skill prose must not couple artifact production to the brood path; the "PRD/issues = brood tier only" framing is removed everywhere
- The false-independence guard (ADR-0007) is unaffected: the cerebrate still owns the file-overlap verdict and re-derives it fresh at brood-time, regardless of how issues were sliced
