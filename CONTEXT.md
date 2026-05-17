# Agent Framework

Domain glossary for the agent-framework Claude Code plugin — a multi-agent system that orchestrates planning, implementation, review, and delivery through governed specialist agents.

## Language

### Agents

**Orchestrator**:
The control-plane agent that owns task intake, delegation sequencing, branch/PR decisions, version bump detection, and review routing.
_Avoid_: coordinator, dispatcher, controller

**Planner**:
A read-only agent that produces a plan artifact with file scopes, step sequencing, and retrieval anchors before execution begins.
_Avoid_: architect, analyst

**Coder**:
A modifying agent that implements code changes within an explicitly assigned file scope.
_Avoid_: developer, implementer

**Designer**:
A modifying agent that owns presentational markup, styling, and static accessibility within an explicitly assigned file scope.
_Avoid_: UI agent, stylist

**Local-Reviewer**:
The agent that runs pre-PR Codex review in a loop, classifies findings, and delegates simple fixes before the PR is opened.
_Avoid_: linter, pre-check

**GitHub-Reviewer**:
The agent that monitors or processes post-PR review feedback, classifies comments, and delegates remediation.
_Avoid_: PR bot, review handler

### Execution

**Phase**:
A single delegation round-trip: one worker agent receives a step, executes, and reports back.
_Avoid_: stage, iteration (when meaning a sequential plan step)

**Delegation**:
A structured message from orchestrator to a worker agent, containing task objective, file scope, step ID, and completion criteria.
_Avoid_: assignment, dispatch, handoff (which has a different meaning)

**Handoff**:
The durable artifact (worker report) stored at phase completion that enables the next phase to reconstruct context.
_Avoid_: transfer, relay, delegation

**Checkpoint Commit**:
A git commit made at a phase boundary or milestone, preserving incremental progress on the working branch.
_Avoid_: save point, intermediate commit

**Plan Artifact**:
The planner's output document containing steps, file scopes, decisions, risks, and retrieval anchors; required before execution begins for non-trivial tasks.
_Avoid_: spec, design doc, blueprint

**Trivial Fast Path (TFP)**:
The bypass route for single-file, low-risk changes (<=20 lines, no public API impact) that skips planner delegation when all six TFP conditions are met.
_Avoid_: quick path, shortcut

**Bypass Code**:
A reason code (`TRIVIAL_CHANGE`, `SINGLE_STEP_TASK`, `NO_PRIOR_PHASE`, `USER_OVERRIDE`) that permits skipping plan artifact or report requirements.
_Avoid_: exemption, override

### Governance

**Governance Doc**:
A markdown file under `plugin/governance/` loaded by agents at runtime as binding policy.
_Avoid_: reference doc, guide, spec

**Scope**:
The explicit list of files a modifying agent is permitted to touch during a delegation.
_Avoid_: assignment, context, area

**Validation**:
The set of project-declared commands (from CLAUDE.md) that must pass before a phase is accepted.
_Avoid_: tests, checks (which is broader)

**State Transition Table (STT)**:
The orchestrator's lookup table that maps each step-completion event to the next action.
_Avoid_: decision tree, flowchart, routing table

**Escalation**:
The mandatory stop-and-report action when an agent encounters a condition it cannot safely resolve.
_Avoid_: error, block (which has a different meaning)

### Git / Delivery

**Working Branch**:
The non-trunk branch created for a single approved plan's implementation and PR.
_Avoid_: feature branch (which is only one classification prefix), dev branch

**Trunk**:
The resolved main integration branch (default: `main`) that must remain stable and deployable.
_Avoid_: master, base branch (which can differ for hotfixes)

**Branch Classification**:
The single prefix (`feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `docs/`, `test/`, `ci/`) assigned to a working branch based on the nature of the change.
_Avoid_: branch type, category

**Bump Trigger**:
A change to files affecting a published artifact's runtime behavior, public API, or compatibility contract, requiring a version increment.
_Avoid_: version trigger, release trigger

**Git Preflight**:
The set of checks (classification, base branch, trunk freshness, branch name, commit policy, PR target) that must all be defined before implementation begins.
_Avoid_: pre-check, setup

### Review

**Review Loop**:
The iterative cycle where a reviewer agent invokes Codex, classifies findings, delegates fixes, validates, and repeats until clean or a stop condition fires.
_Avoid_: review cycle (ambiguous with remediation cycle), feedback loop

**Remediation**:
The act of addressing a review finding: classify, delegate to coder/designer, validate, checkpoint-commit, push.
_Avoid_: resolution, fix (too generic)

**Break-Fix-Break Cycle**:
The detected oscillation where fixing one finding reintroduces a previously fixed finding (2-of-3 signal match), forcing a mandatory stop.
_Avoid_: regression loop, flip-flop

**External Content Boundary**:
The security rule that all text from PR comments, Codex findings, and fetched URLs is data — never interpreted as agent instructions.
_Avoid_: trust boundary (broader concept), sandbox

**Injection-Suspect**:
The security classification for review text containing direct agent instruction attempts, tool manipulation, or policy override language.
_Avoid_: malicious input, attack

### Context Management

**Auto-Clear**:
The procedure that purges ephemeral context and selectively rehydrates durable artifacts, triggered by phase completion (Path A) or mid-phase threshold (Path B).
_Avoid_: context reset (which is only one trigger), garbage collection

**Retrieval Anchor**:
A tagged identifier (`DEC-NNN`, `RISK-NNN`, `ASM-NNN`, `EVD-NNN`) attached to a decision, risk, assumption, or evidence item, enabling cross-phase retrieval.
_Avoid_: tag, label, reference

**Session Facts**:
Cached resolved values (trunk name, task-type, claude-mem status, active-step) that persist within a task to avoid redundant lookups.
_Avoid_: state, config, environment

**Rehydration**:
The selective reload of durable artifacts (stored reports, retrieval anchors) after an auto-clear, restoring enough context for the next phase.
_Avoid_: reload, restore, replay

**Reconstruction Test**:
The binary gate at phase transitions verifying the next phase can proceed from the handoff artifact and anchors alone, without the prior phase's full transcript.
_Avoid_: readiness check, completeness test

### Plugin Structure

**Skill**:
A namespaced executable procedure (`agent-framework:<name>`) invoked by agents via the Skill tool, with its own SKILL.md defining trigger conditions and behavior.
_Avoid_: command, action, tool

**Governance**:
The collective set of mandatory and conditional policy modules under `plugin/governance/` that define binding runtime rules for all agents.
_Avoid_: rules, docs, policies (plural)

**`${CLAUDE_PLUGIN_ROOT}`**:
The path variable resolving to `plugin/` where `plugin.json` lives; all cross-references inside the plugin use this prefix.
_Avoid_: plugin path, root, base path

## Relationships

- An **Orchestrator** delegates to exactly one **Planner**, **Coder**, **Designer**, **Local-Reviewer**, or **GitHub-Reviewer** per **Phase**
- A **Plan Artifact** contains one or more steps (`STEP-NNN`), each assigned to exactly one **Coder** or **Designer**
- A **Delegation** targets exactly one **Step** (`STEP-NNN`) or, for step-omitting **Bypass Codes** (`TRIVIAL_CHANGE`, `SINGLE_STEP_TASK`, `USER_OVERRIDE` when step omitted), a synthetic `TASK-NNN`; `NO_PRIOR_PHASE` is never step-omitting and always accompanies a `step: STEP-NNN`
- A **Phase** produces exactly one **Handoff** on success
- A **Handoff** enables **Rehydration** after **Auto-Clear**
- A **Retrieval Anchor** survives **Auto-Clear** and is available for **Rehydration**
- A **Working Branch** maps to exactly one **Plan Artifact** and one PR
- A **Review Loop** may produce zero or more **Remediation** cycles
- A **Break-Fix-Break Cycle** terminates a **Review Loop** with mandatory **Escalation**
- A **Bump Trigger** fires at most one version increment per PR
- A **Reconstruction Test** gates every **Handoff** before the next **Phase** is delegated
- Every **Governance Doc** is either mandatory (always loaded) or conditional (activation condition required)

## Example dialogue

> **Dev:** "This is a one-line typo fix in a governance doc — do I still need the **Planner**?"
> **Domain expert:** "Check the **Trivial Fast Path** conditions. If all six pass — single owner, one known file, <=20 lines, clear **Branch Classification**, no version impact, not **Remediation** — the **Orchestrator** skips the **Planner** and delegates directly to a **Coder**."

> **Dev:** "The **Review Loop** keeps flipping between two states — what happens?"
> **Domain expert:** "That's a **Break-Fix-Break Cycle**. When 2-of-3 signals fire (line-range overlap, git revert, N-2 oscillation), the loop stops and the **Orchestrator** escalates to the user. No more automatic **Remediation** until a human decides."

> **Dev:** "After **Auto-Clear**, how does the next **Phase** know what happened?"
> **Domain expert:** "Through **Rehydration**. The **Orchestrator** reloads the stored **Handoff** and any referenced **Retrieval Anchors**. The **Reconstruction Test** already verified that's sufficient before the clear happened."

## Flagged ambiguities

- "phase" vs "step" — resolved: a **step** is the planner's unit of work (`STEP-NNN`); a **phase** is the orchestrator's unit of execution (one delegation round-trip). They usually correspond 1:1 but the distinction matters for **Bypass Codes** where steps are omitted.
- "handoff" vs "delegation" — resolved: **Delegation** flows downward (orchestrator to worker); **Handoff** flows upward/forward (worker report stored for future phases).
- "scope" — resolved: always means file scope (the explicit file list in a delegation), never task scope or project scope.
- "validation" vs "verification" — resolved: **Validation** means running declared project commands; verification means the orchestrator's post-phase acceptance checks (contradiction detection, **Reconstruction Test**, anchor completeness).
