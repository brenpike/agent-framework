# Remediation Doctrine

Shared vocabulary and policy for root-cause review remediation. Loaded by the `github-reviewer` and `local-reviewer` agents, the overlord, and the cerebrate so all four reason about review loops with one vocabulary. This doc is definitional and policy only: it carries no detection algorithm and no case studies. The detection mechanics live in the `hivemind:detect-remediation-signals` skill; few-shot exemplars ship in that skill's `references/`.

When any rule uses a term defined here, this definition is binding.

## Root-Cluster

A set of N-or-more review findings that share a root cause, surface, or fix-framing. A root-cluster is the signal that per-finding patching must STOP and the loop must zoom out: the findings are symptoms of one defect, so patching them individually is a treadmill that spawns the next symptom on the next pass.

When a reviewer detects a root-cluster it returns the `root-cluster-suspected` exit_reason, carrying the cluster: the shared files/surface, the N thread URLs or finding IDs, the hypothesized root cause, and the same-framing rationale. The overlord consumes this signal to route to a structural fix (via cerebrate) instead of dispatching N narrow patches.

The cluster threshold N is tuned by severity per **Severity as Sensitivity Modifier**.

## Same-Framing Test

Before committing to any one-off fix, ask: would the next reviewer comment be this same shape with a different byte, field, or path? If yes, the root is unfixed — escalate to a structural fix rather than patch the instance.

The same-framing test is applied per-candidate during classification. A "yes" answer is a primary input to **Root-Cluster** detection: it converts a lone finding into evidence that a class, not an instance, is at fault.

## Closed-by-Construction Preference

When choosing a structural fix, prefer one that dissolves the whole class by construction over one that handles the observed instance. A closed-by-construction fix makes the next same-framing finding impossible rather than merely unobserved. Ordered preferences:

- positive allowlist over reject-enumeration (blacklist)
- a real parser over hand-parsing
- ground-truth derivation over validating untrusted input
- floor-at-input plus encode-at-output over per-context charset handling
- validate-where-bytes-are-intact over validate-after-a-lossy-round-trip

## Bounded-Impact Gating

Assess the actual blast radius of a finding independent of the reviewer's severity badge: is it informational-only? does it touch only already-validated enum/charset surfaces? does the attacker already control the input? The assessed impact — not the badge — informs the fix-now vs defer vs accept decision. A badge is an input to this assessment, never a substitute for it.

## Defer-with-Scope

A finding is never silently dropped. When a finding is the same family as a tracked structural change, it is deferred to that tracked issue WITH full root-cause scope, the linked threads, and a bounded-impact note (per **Bounded-Impact Gating**). The originating thread is then replied-to and resolved citing the tracking issue.

Defer-with-scope is the only permitted way to leave an actionable finding unfixed in the current loop. A deferral that omits scope, linkage, or impact rationale is a silent drop and is forbidden.

## Stop-and-Merge

Stop the loop and advise merge when ALL of the following hold:

- zero unresolved actionable threads remain
- remaining findings are a bounded tail on a heavily-hardened surface
- the structural home for that tail is a tracked issue (per **Defer-with-Scope**)
- every push spawns only a fresh bounded tail, never a new defect class

The stop signal is NOT round count. Chasing zero-findings-per-push on a complex security surface is itself the anti-pattern. Agents never merge — humans merge. The loop surfaces this as the `merge_advised` advisory terminal carrying `advisory_reason` and `recommendation_text`.

## Severity as Sensitivity Modifier

Severity does NOT by itself trigger zoom-out. A lone high-severity finding is patched or escalated as usual; a review that finds a real high-severity issue is the process WORKING, not a signal to cluster. There is NO standalone P0/P1 zoom-out gate: a cross-cutting single fix already routes through planner-escalation, and whack-a-mole is detected by recurrence, not by severity.

Severity only TUNES the **Root-Cluster** threshold N:

- **N=2** when a high-severity finding lands on a just-touched or same-framing surface
- **N=3** by default otherwise

## Relationship to Existing Detectors

Two review-loop detectors predate this doctrine and remain its companions; their policy meaning is unified here so both review loops share one vocabulary.

- **Mutation Decay** (break-fix-break cycle): fixing one finding reintroduces a previously fixed finding. Policy: a MANDATORY stop. Defined in CONTEXT.md.
- **Creep Stagnation** (diminishing-returns exit): the loop spreads across iterations but gains no new ground. Policy: an ADVISORY early exit — the reviewer recommends stopping and returns the decision to the overlord/Overmind. Defined in CONTEXT.md.

The operational detail of all three signals — Mutation Decay, Creep Stagnation, and Root-Cluster — lives in `hivemind:detect-remediation-signals`. This doctrine holds only their policy meaning. Mutation Decay and Stop-and-Merge are both stop conditions but differ in cause: Mutation Decay stops on instability (a fix that breaks a prior fix); Stop-and-Merge stops on a hardened surface with a tracked structural home and a bounded tail.
