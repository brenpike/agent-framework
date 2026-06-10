# PRD — Meta-Pipeline

> The standardized ideation-to-implementation workflow for hivemind. This PRD specifies WHAT the Meta-Pipeline Initiative delivers; the HOW (steps, file scope, sequencing) belongs to the build directive, not this document.

## Problem Statement

Hivemind has a strong front half — interrogate an idea into a hardened plan — and a strong back half — implement work through governed agents on a single branch or across a brood. Between them, the conversion of a refined idea into durable, individually-trackable units of work is improvised every time. There is no repeatable way to turn an interrogated plan into a committed specification of WHAT will be built, and no repeatable way to turn that specification into vertically-sliced, grabbable work items.

This improvisation causes three recurring problems:

- **Lost durability.** The interrogated reasoning lives in ephemeral scaffolding that is gitignored and disposable. The decisions that justify the work are not captured in a committed, referable artifact, so they decay between sessions and are silently relitigated.
- **No trackable decomposition.** Work is carried as a single monolithic plan rather than as independent units that can be tracked, grabbed, and reasoned about separately. There is no standard unit a parallel-execution path can consume cleanly.
- **Conflated concerns.** The original framing tied the act of producing a specification and its work items to the brood execution path — implying that decomposing an idea forces parallel execution. This wrongly couples *what work exists* to *how that work runs*, and discourages producing a clean specification for sequential single-branch work.

A further structural problem: any attempt to bridge these gaps as a single monolithic procedure would break resumability. A session may end at any boundary, and work must be able to restart from a persisted artifact in a fresh session without replaying everything that came before.

## Solution

A standard, repeatable pipeline that converts an interrogated idea into durable, vertically-sliced, individually-trackable work, delivered as three independently-invocable capabilities:

- **Create a session-resumption handoff** — synthesize the volatile state needed to resume an initiative in a fresh session: the locked decisions, the first action to take, the open questions, and pointers to the durable artifacts. Optional and disposable; it points to the plan rather than duplicating it.
- **Produce a PRD from an interrogated plan** — synthesize the interrogated plan into a committed specification of WHAT the initiative delivers, expressed as problem, solution, user stories, acceptance criteria, architectural/contract-level decisions, testing decisions, success metrics, and scope boundaries.
- **Produce vertically-sliced issues from a PRD** — decompose the PRD into thin, end-to-end units of behavior, each small enough to be independently grabbable, each tracked as its own work item.

Two properties define the solution and distinguish it from the rejected framing:

- **Decoupled leaves (ADR-0013).** The three capabilities read as a sequence but do not chain. None references or invokes another. Each is fully functional on its own given its inputs. Composing them end-to-end, if ever wanted, is the job of a separate future orchestrator — never of the leaves themselves.
- **Path-agnostic output (ADR-0012).** Producing a PRD or a set of sliced issues has zero bearing on the execution path. Whether the resulting work runs on a single branch or as a parallel brood is decided solely by the strategist's overlap analysis at implementation time, independent of how the work items were created. Well-sliced, minimal-overlap issues *tend* toward parallel candidacy, but nothing about producing them forces it. A PRD and its issue set are equally valid inputs to sequential single-branch work.

Each capability accepts its primary artifact either from live conversation context or from a persisted file, plus an optional handoff. The handoff is never required. This makes the pipeline resumable at any boundary: an initiative can pick up from a persisted plan, a persisted PRD, or a freshly synthesized handoff in a brand-new session.

The interrogation methodology is graduated, not repeated at every stage. Heavy interrogation stays upstream where the plan is hardened. Producing the PRD applies only light confirmation. Slicing the PRD into issues applies one focused interrogation loop. Synthesizing a handoff applies none.

A single slug correlates an initiative's plan, handoff, PRD, and issue set. Plans and handoffs are ephemeral scaffolding; the PRD and its supporting decision records are durable, committed artifacts.

## User Stories

- As the Overmind, I want to convert a hardened, interrogated plan into a committed specification of WHAT will be built, so that the reasoning behind an initiative survives between sessions and is not silently relitigated.

- As the Overmind, I want to decompose a specification into independent, individually-trackable work items, so that progress is visible per-unit rather than buried in one monolithic plan.

- As the Overmind, I want each capability to be invocable on its own, so that I can produce just a PRD, just an issue set, or just a handoff without being forced through the whole sequence.

- As the Overmind, I want to resume an initiative in a fresh session from a persisted artifact, so that a long context-heavy session can be ended deliberately and picked up later without replaying everything.

- As the Overmind, I want producing a specification or its issue set to have no effect on whether the work runs single-branch or as a brood, so that I can decompose an idea cleanly and still choose sequential execution.

- As the Overmind, I want a handoff offered only when I ask for it or when a session is context-rich enough to warrant one, so that I am never forced to create disposable scaffolding I do not need.

- As the Overlord, I want each pipeline capability to be invoked through ordinary intent intake or an explicit command, so that routing to the right specialist is decided at runtime by what was asked, not hard-wired into the capability.

- As the Overlord, I want a PRD that specifies only WHAT an initiative delivers, so that I can hand it to the strategist to produce the HOW without duplicated or conflicting content.

- As the Overlord, I want the issue set to express behavior only — never self-declared file scope and never an independence claim — so that the strategist remains the single authority on file overlap and re-derives it fresh at brood time.

- As the Overlord, I want each sliced issue to map cleanly to one candidate unit of parallel work, so that a brood, if chosen, can consume the issues without further reshaping.

- As the Cerebrate, I want to remain the sole authority over the single-branch-versus-brood decision, fired downstream at implementation time, so that artifact production never pre-empts or constrains the execution routing I own.

- As the Cerebrate, I want issues that carry behavior and dependencies but not independence claims, so that I can re-derive true file overlap myself and never trust a slice's self-description blindly.

- As a future maintainer, I want each capability documented as an independent transform with explicit inputs and outputs, so that any one of them can be changed or tested in isolation without rippling into the others.

## Acceptance Criteria

- Three capabilities exist and each is independently invocable on its own inputs; none requires another to have run first, and none invokes another.
- Each capability accepts its primary artifact from either live context or a persisted file, plus an optional handoff that is never required.
- An initiative can be resumed in a fresh session starting from a persisted artifact alone.
- The PRD capability produces a specification containing exactly the WHAT-only section set: problem statement, solution, user stories, acceptance criteria, implementation decisions at the architectural/contract level, testing decisions, success metrics, out of scope, and further notes.
- The PRD contains no file paths, no code, and no step sequencing; those remain the directive's responsibility.
- The issue capability produces vertically-sliced work items whose bodies express initiative reference, behavior to build, acceptance criteria, and dependencies — and nothing else.
- Issue bodies never self-declare file scope and never assert independence.
- Each sliced issue corresponds to one thin end-to-end unit of behavior and one candidate unit of parallel work.
- Producing a PRD or an issue set does not initiate, require, or imply a brood; the single-branch-versus-brood decision remains the strategist's call at implementation time.
- Initiative work items are grouped as native sub-issues under a parent (epic) issue, and blocking relationships are expressed through native cross-references between work items.
- A handoff, when produced, carries volatile session state and points to the durable plan and PRD rather than duplicating them.
- A handoff is offered only on explicit request or an Overlord suggestion when the session is context-rich — never as an automatic prompt embedded inside another capability.
- One slug correlates an initiative's plan, handoff, and PRD; the corresponding issue set is grouped under the parent (epic) issue as native sub-issues.
- The heavy interrogation methodology is not re-run by any of the three capabilities; each inherits the upstream interrogated output and applies at most its own graduated confirmation or slicing step.

## Implementation Decisions

These are architectural and contract-level decisions only. They constrain WHAT the capabilities guarantee, not HOW they are built.

- **Decoupled leaf transforms (ADR-0013).** The three capabilities do not chain. Each consumes explicit, session-agnostic inputs and produces its own output. Any future end-to-end composition is owned by a separate orchestrator that calls each leaf in succession; the leaves never gain awareness of one another.
- **Path-agnostic artifacts (ADR-0012).** The output of the PRD and issue capabilities has no bearing on the execution path. The single-branch-versus-brood decision is made solely by the strategist's overlap analysis at implementation time, or by explicit Overmind direction. Documentation and capability behavior must never couple artifact production to the brood path.
- **WHAT/HOW separation.** A PRD specifies WHAT an initiative delivers — stories, acceptance criteria, success metrics, architectural/contract decisions. A directive specifies HOW — steps, file scope, sequence. The two carry no duplicated content. Slicing is not part of the PRD; it belongs to the issue capability.
- **Behavior-only issues with central overlap authority (ADR-0007).** Issue bodies describe end-to-end behavior, acceptance criteria, and dependencies. They never self-declare file scope and never claim independence. The strategist is the sole authority on file overlap and re-derives it fresh at implementation time, honoring the false-independence guard: vertical slices that look independent may share files, and only the strategist's analysis decides parallel versus sequential.
- **Session-agnostic, resumable inputs.** Every capability accepts its primary artifact from live context or a persisted file, plus an optional handoff. The handoff is never a required input, and the pipeline is resumable at any boundary.
- **Intent-based invocation (ADR-0006).** Invocation comes from ordinary intent intake or an explicit command. Capabilities do not hard-wire which specialist handles them; routing is decided at runtime by the expressed intent.
- **Main-session execution rail (ADR-0005).** A capability that may route sub-work to a specialist must run in the main session, because the tool used to dispatch specialists is unavailable to a sub-session. Pure-synthesis capabilities are context-flexible.
- **Initiative correlation by slug.** One slug per initiative correlates its plan, handoff, and PRD. Plans and handoffs are ephemeral scaffolding; the PRD and its supporting decision records are durable, committed artifacts. The PRD is the initiative's durable spec anchor; the parent (epic) issue is the GitHub tracking work item that groups the sliced work items as native sub-issues.
- **Graduated interrogation.** The heavy interrogation methodology stays upstream and is inherited, not repeated. The PRD capability applies only light confirmation; the issue capability applies one focused slicing loop; the handoff capability applies none.

## Testing Decisions

- Verify each capability runs standalone on its own inputs, confirming the decoupled-leaf contract: a capability succeeds without any other having run, and none triggers another.
- Verify each capability accepts both input modes — primary artifact from live context and from a persisted file — and that the optional handoff is genuinely optional.
- Verify the pipeline is resumable: starting from a persisted artifact alone in a fresh session reproduces correct behavior.
- Verify the PRD output conforms to the WHAT-only section set and is free of file paths, code, and step sequencing.
- Verify issue output is behavior-only and contains no self-declared file scope and no independence claim.
- Verify that producing a PRD or an issue set never initiates or requires a brood, and that the execution-path decision remains separable from artifact production.
- Verify issue grouping via the parent epic's native sub-issues and that blocking cross-references resolve correctly when blockers are published before the items that depend on them.
- Verify the handoff, when produced, points to durable artifacts rather than duplicating them.
- Confirm capability documentation and prose nowhere couple artifact production to the brood path.

## Success Metrics

- An interrogated initiative can be carried from hardened plan to committed PRD to vertically-sliced work items using a standard, repeatable flow rather than ad-hoc improvisation.
- A PRD captures the durable WHAT of an initiative such that its decisions survive across sessions and are not silently relitigated.
- Each capability is demonstrably usable in isolation, and a session can be deliberately ended and resumed at any boundary from a persisted artifact.
- Sliced issues map one-to-one to candidate units of parallel work without further reshaping, while the execution path remains an independent downstream decision.
- The number of initiatives whose reasoning is lost to ephemeral scaffolding trends to zero, because the durable artifact is produced as a standard step.

## Out of Scope

- **The `idea-to-issues` orchestrator (future).** End-to-end composition that chains the three capabilities into a single flow is explicitly deferred. The leaves stay decoupled; any future orchestrator owns the coupling and is a separate piece of work, not part of this initiative.
- **A future scout agent.** A dedicated scouting/discovery agent is anticipated but not part of this initiative; routing to such an agent would be decided at runtime by intent if and when it exists.
- **Changes to the execution-routing decision.** The single-branch-versus-brood gate and the strategist's overlap analysis are unchanged. This initiative does not move, modify, or duplicate that gate; it only produces artifacts the gate may later consume.
- **Autonomous work-item queue grabbing.** There is no autonomous agent that grabs ready work items off a queue, so no labeling or tagging convention for such a consumer is introduced.
- **Re-running the interrogation methodology.** The heavy upstream interrogation is not reimplemented or re-run inside these capabilities; they inherit its output.
- **The build directive itself.** The steps, file scope, and sequencing that implement these capabilities are the directive's responsibility and are not specified here.

## Further Notes

- This initiative emerged organically while designing the GitHub review loop, then was interrogated as its own initiative. That session is the exemplar of the pipeline's front half — interrogation to hardened plan to handoff — and took the single-branch path, demonstrating that having a plan does not force parallel execution; the strategist decided sequential.
- The original framing — that producing a PRD or issues belongs only to the brood tier — was rejected during interrogation and superseded by the path-agnostic property. That framing should not be reintroduced anywhere in documentation or capability behavior.
- The two distinct orthogonal axes underpinning this design are execution routing (single-branch versus brood) and session continuity (continue in-session versus resume via handoff). They are independent: a choice on one never implies a choice on the other.
- Supporting decision records: ADR-0012 (path-agnostic artifact transforms) and ADR-0013 (decoupled leaf pipeline skills). Glossary terms for Initiative, PRD, Vertical Slice, and Handoff are recorded in the project domain glossary.
