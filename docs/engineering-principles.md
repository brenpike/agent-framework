# Engineering Principles

Project-specific engineering principles for the hivemind plugin, distilled from the issue #201 reviewer-prose-rescue interrogation. They govern how prose, scripts, and skills are factored across agents, skills, and governance. Where a principle is rooted in external best-practice it cites the source; otherwise it is a project decision. Referenced by `CLAUDE.md`.

## P1 — Single-source contract

A contract or spec lives in exactly ONE place. An extraction is not "done" until the duplicated prose copy is DELETED, not merely supplemented. Multi-site contracts drift, and one lagging site is a real defect — this was the root cause of the PR #200 node-id escalation chain, where the same contract was smeared across a jq header, two agent steps, and a graphql reference doc.

## P2 — Spec moves with the mechanism

When procedure is extracted to a script, its spec moves WITH it as a contract-only header — the input/output schema, the invariants, and the WHY. The spec never just evaporates into undocumented code. The header narrates the contract, not the code line-by-line.

## P3 — Header without a test is decoration

A header comment can drift from the code below it in the same file; nothing enforces it. The same logic extends to governance: a section header naming specific consumers is an assertion about coupling, and nothing enforces it without a fixture. The general principle: any load-bearing contract — whether a script or a governance section with named consumers — is decoration until a CI fixture asserts the coupling.

This produces two enforcement triples in this repo:

1. **Script triple:** the script, the contract header, and a `test_*.sh` CI fixture. The test is the behavioral guarantee; the header is human-readable intent. (Precedent: #198's `fix-history-classify.jq` paired with `test_fix_history_classify.sh`.)
2. **Governance triple:** the governance section, its named consumer list, and a `tests/policy/safety-*.json` consumer-assertion fixture. The fixture is the coupling guarantee; the section header is human-readable intent. (Precedent: during PR #229, a `## Worker Self-Check` governance section consumed by `drone.md` and `changeling.md` shipped WITHOUT a `tests/policy/safety-*.json` consumer-assertion fixture; Codex review caught the missing-fixture gap post-hoc — a P1-C finding — and the fixture was added as a follow-up within that same PR.)

## P4 — Extraction-home policy

Pure deterministic mechanism goes to a shared committed SCRIPT, called directly via Bash. Judgment-bearing procedure that is reusable or ad-hoc-invokable goes to a SKILL. Single-use judgment stays in the agent body as narrative. (Rooted in Anthropic guidance that deterministic work belongs in executed scripts and reusable procedure belongs in skills — see Sources.)

## P5 — Bash cannot invoke a Skill

A shell script can only call another script, never a Skill — skills are invoked by an LLM agent via the Skill tool. Therefore any substrate that must be shared with a bash caller MUST be a script, not a skill. This is a forced home, not a preference.

## P6 — Scripts are execute-not-load

An agent or subagent body is loaded in FULL as the system prompt on every dispatch — eager, permanent prompt weight. A skill body loads only on activation (lazy). A script invoked via Bash is EXECUTED, never read into context. Moving a dense contract out of agent prose into a script is therefore a runtime-token win, not just a tidiness win. (Rooted in Anthropic progressive-disclosure guidance — see Sources.)

## P7 — Don't hollow the agent (illegibility guard)

Over-extracting an agent's CORE judgment into opaque script or skill calls is its own failure mode. Extract the shared CRITERIA, but keep the per-instance decision in the agent so it still reads as a coherent judgment narrative.

## P8 — When a skill is warranted

Extract prose into a skill when BOTH hold: (1) it is judgment prose legitimately too complex to reduce to a deterministic script — an LLM must run it — AND (2) it has standalone or generic value, reusable by another agent OR ad-hoc user-invokable. (Rooted in Anthropic's create-a-skill trigger — see Sources.)

## P9 — Don't over-generalize a shared script

If forcing one script to serve two callers requires heavy parameterization or a leaky abstraction, keep the machines separate and extract only the genuinely-shared kernel — for example, an exit-precedence resolver shared by two otherwise-divergent review loops, not the whole loop.

## P10 — Procedure → skill; fact/binding-policy → governance

The deciding axis between a lazy skill and an always-loaded governance doc is procedure-vs-fact. Executable, procedural how-to that runs at a decision point goes to a skill (progressive disclosure, loaded on demand). Facts, definitions, invariants, glossary, and always-binding policy or safety posture go to governance docs (eager-loaded BY NECESSITY — a binding posture demoted to a lazy skill is silently OFF whenever it is not invoked). Do not put executable procedure in eager governance; do not demote always-binding policy to a lazy skill. This applies only when a skill genuinely makes sense (see P8). (Rooted in Anthropic's "procedure rather than a fact" guidance — see Sources.)

## P11 — Judgment is not extractable mechanism (P7 corollary)

Mechanism — deterministic, reproducible, contract-stable — is extractable to scripts (P5/P6 win). Judgment — holistic, context-dependent, operating on a lossy source — is not: encoding it as a heuristic produces a brittle approximation that satisfies a consumer's SCHEMA but not its SEMANTICS, and accretes endless edge-case patches. Two warning signs: the source is lossy for the question being asked (the data does not actually contain the answer), or the extraction keeps accumulating new special-cases as reviewers find edges. Extract to a script ONLY the lossless, factual skeleton; keep interpretation in the agent (P7). (Precedent: `ledger-reconstruct.sh` in #222/#223 tried to reconstruct fix-ledger judgments — "what is a prior fix", review-iteration grouping, oscillation-as-cycling — deterministically from `git log`, but git commits ≠ review iterations, a lossy source. It satisfied `detect-remediation-signals`' schema but not its semantics, and drew ~7 recurring Codex findings. The structural fix — Option A per #225 — was to stop encoding the judgment and de-scope the script to the genuinely-deterministic skeleton: machine-channel path parsing, JSON escaping, fail-closed I/O.)

## P12 — Reference skills by intent, not by name

Narrative prose invokes a skill by what it accomplishes, not by its name. ~~"when X, call `hivemind:zoom-out`"~~ → "when X, zoom out to understand the broader picture." A name in narrative is decoration: it survives no rename and adds no reasoning. The discriminator is the **rename test** — if renaming the skill would BREAK this reference, the name is load-bearing and stays; if renaming would leave the sentence true, the name is decoration and is replaced by intent. Carve-out (name REQUIRED, not narrative): dispatch registries, the agent's skill list, frontmatter, and invocation contracts — there the exact name IS the API the Skill tool dispatches on. (Shares a decoupling root with P13/P14; cf. ADR-0006 intent-based-governance.)

## P13 — Respect the ADR; don't cite it as justification

Instructional prose is written to be CORRECT under its governing ADR, not to quote the ADR as its reason. ~~"According to ADR-XYZ, do X"~~ → prose that simply does X correctly, the ADR governing silently. The discriminator: *is this prose telling someone what to DO, or recording why the contract IS what it is?* A DO step carries no citation; the reader executes, not audits genealogy. This **refines P2** — the WHY and ADR traceability still belong WITH the mechanism, in contract headers, design-record blocks, and commit trailers, where a maintainer reading the contract wants the lineage. The anti-pattern is only the in-line citation at the point of action. (Shares a decoupling root with P12/P14.)

## P14 — Name no concrete consumer in reusable-skill prose

A reusable skill names no single calling bioform as an incidental actor. ~~"The overlord resolves and passes these"~~ → "The caller resolves and passes these." Naming one consumer couples a reusable skill to one caller and violates its generic value (P8). The discriminator: *could a different caller satisfy this role unchanged?* Yes → genericize to "the caller"/"the consumer." No, because a hard capability constraint binds it (e.g. the review loop must run in a Monitor-hosting main session per ADR-0005) → keep it, but frame it as the REQUIREMENT (the capability the caller must have), not as the bare bioform name. Out of scope: governance consumer-assertion sections (P3) — naming consumers THERE is the coupling contract a fixture enforces, not a leak. (Shares a decoupling root with P12/P13.)

## P15 — Test-mode is a flag, not a presence

A script seam that swaps a live side-effect (network, `gh`, or filesystem mutation) for an offline test fixture gates on an explicit dedicated test-mode flag (e.g. `*_TEST_MODE=1`), NEVER on the mere PRESENCE of a fixture-path env var. Presence-activation means a single leaked env var in a CI or dev shell silently runs the whole loop offline against production intent — a benign-looking variable becomes a live/offline switch. Sibling seams move together: a one-sided hardening is worse than the uniform status quo, because it makes the convention look reliable where it is not. (Precedent: the offline-capture seams in `reply-resolve.sh` and `fetch-normalize.sh` activated on env-var presence alone — flagged twice, by the #205 pre-PR review and #219, as a cross-cutting convention defect, not a one-file bug.) Distinct from ADR-0019, which governs hostile cross-boundary CONTENT; this governs benign test/prod mode SELECTION — operator misconfiguration, not adversarial input.

## P16 — Concurrency safety is structural, not check-then-act

Concurrency safety is achieved by REMOVING the shared mutable resource — per-id namespacing so each writer owns a disjoint path — not by guarding one shared resource with a check-then-act liveness read. A check-then-act read across a time-of-check/time-of-use window is a non-reservation and is unsafe by default: two writers can both pass the check and both proceed. When a single shared artifact is genuinely unavoidable, ownership is explicit (RUN-OWNERSHIP-01) and writes are serialized by a lock, never by a prior read. (Precedent: the brood concurrency line cost ADR-0019 eleven amendments and ADR-0017 ten, clustered on TOCTOU; the residual singleton-manifest race was finally closed STRUCTURALLY by per-brood-id namespacing in ADR-0021, not by another guard. #167 — serialize same-run ledger writes — remains the open instance.) Distinct from ADR-0021 (a brood-scoped instance) and ADR-0019 (hostile content): this elevates the generalizable rule so the next concurrent-writer feature inherits it without re-deriving the lesson through its own multi-amendment ADR.

## P17 — Genericness is CI-guarded, not eyeballed

The reusable/project-coupled boundary in plugin prose is load-bearing, so a mechanizable genericness rule MUST be enforced by a CI guard, not left to reviewer vigilance. Project-specific tokens in generic governance/agent prose, and the P12–P14 decoupling violations (skill-by-name, ADR-as-justification, named-consumer leak), are pattern-detectable and therefore get a `policy_check` guard; an un-guarded mechanizable rule is decoration. This is **P3 applied to genericness** — "a load-bearing contract is decoration until a CI fixture asserts it" — extended from script/governance triples to the decoupling rules. Manual remediation of a leak without a guard only resets the clock; the leak class returns with the next skill. (Precedent: a project-token leak survived three Codex passes and a green gate, caught only by human review; the finding class spans #232, #234, #235.) The non-mechanizable residue — the judgment discriminators in P12–P14, like the rename test — stays in human review by design; P17 governs only the pattern-detectable subset.

## P18 — Fail-closed shell is the floor

Every NEW or CHANGED committed `*.sh` under the plugin MUST open with `set -euo pipefail` (or a documented, justified exception) as a non-negotiable hygiene floor, and existing scripts are brought to the floor as they are next touched. This is a prescriptive rule, not a claim about the current tree — today only a fraction of plugin scripts carry the floor, and the gap is closed incrementally plus tracked as a retrofit, never asserted as already-true. Default bash is fail-open: an unset variable expands to empty, a mid-pipeline failure is swallowed, execution marches past a failed command — so a broken script reports success while doing the wrong thing. The floor is enforced by convention and ideally a lightweight lint, not by per-author taste; the `#201` and `#224` initiatives are net-new-script-heavy and will otherwise propagate whatever neighbor they copy. Distinct from ADR-0019 (trust-boundary content handling) and ADR-0020 (single-responsibility libraries): this is a universal shell-EXECUTION hygiene floor for every script regardless of boundary, with the retrofit of currently-non-compliant scripts tracked as a separate follow-up.

## Sources

- https://code.claude.com/docs/en/skills — Claude Code "Extend Claude with skills": the create-a-skill trigger ("a section of CLAUDE.md has grown into a procedure rather than a fact"; "a skill's body loads only when it's used"). Roots for P4/P6/P8/P10.
- https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills — Agent Skills launch: deterministic reliability of code; progressive disclosure. Roots for P4/P6/P8/P10.
- https://agentskills.io/specification — Agent Skills spec: the `scripts/` directory is "executed, not loaded"; metadata / SKILL.md / resources disclosure levels. Roots for P4/P6/P8/P10.
