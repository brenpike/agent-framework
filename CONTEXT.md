# Agent Framework

Domain glossary for the agent-framework Claude Code plugin — a multi-agent system that orchestrates planning, implementation, review, and delivery through governed specialist agents.

## Language

### Agents

**Orchestrator**:
The control-plane agent that owns task intake, delegation sequencing, branch/PR decisions, version bump detection, and review routing.
_Avoid_: coordinator, dispatcher, controller

**Planner**:
A read-only agent that produces a plan artifact with file scopes, step sequencing, and risk assessment before execution begins.
_Avoid_: architect, analyst

**Coder**:
A modifying agent that implements code changes within an explicitly assigned file scope.
_Avoid_: developer, implementer

**Designer**:
A modifying agent that owns presentational markup, styling, and static accessibility within an explicitly assigned file scope.
_Avoid_: UI agent, stylist

**Local-Reviewer**:
The agent that runs pre-PR Codex review in a loop, classifies findings, and reports terminal results to the orchestrator before the PR is opened.
_Avoid_: linter, pre-check

**GitHub-Reviewer**:
The agent that monitors or processes post-PR review feedback, classifies comments, and reports terminal results to the orchestrator.
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
The planner's output document containing steps, file scopes, decisions, risks, and assumptions; required before execution begins for non-trivial tasks.
_Avoid_: spec, design doc, blueprint

**Trivial Fast Path (TFP)**:
The bypass route that skips planner delegation when all TFP conditions are met: one owner, one known file, trivial change, clear branch classification, no version impact, no review remediation.
_Avoid_: quick path, shortcut

**Session Facts**:
Cached resolved values (trunk name, task-type, claude-mem status, active-step) that persist within a task to avoid redundant lookups.
_Avoid_: state, config, environment

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
A change to files affecting a published artifact's runtime behavior, public API, compatibility contract, generated output, packaged output, distribution metadata, or documented consumer expectation, requiring a version increment.
_Avoid_: version trigger, release trigger

**Git Preflight**:
The set of checks (classification, base branch, trunk freshness, branch name, commit policy, PR target) that must all be defined before implementation begins.
_Avoid_: pre-check, setup

### Review

**Review Loop**:
The iterative cycle where a reviewer agent invokes Codex, classifies findings, fixes simple issues directly (≤2 files), escalates complex ones, validates, and repeats until clean or a stop condition fires.
_Avoid_: review cycle (ambiguous with remediation cycle), feedback loop

**Remediation**:
The act of addressing a review finding: classify, fix directly (≤2 files) or escalate to orchestrator, validate, checkpoint-commit, push.
_Avoid_: resolution, fix (too generic)

**Break-Fix-Break Cycle**:
The detected oscillation where fixing one finding reintroduces a previously fixed finding (2-of-3 signal match), forcing a mandatory stop.
_Avoid_: regression loop, flip-flop

**Fix Ledger**:
The persisted YAML artifact (`.agent-framework/review-loop/fix-ledger.yaml`) tracking finding status across review loop iterations; status transitions: open → fixing → fixed/regressed, fixed → cycling.
_Avoid_: review log, finding tracker

**Fix Mode**:
The one-shot operating mode of the github-reviewer agent that processes existing unresolved feedback in a single remediation pass without polling.
_Avoid_: one-shot mode, immediate mode

**Watch Mode**:
The continuous operating mode of the github-reviewer agent that polls for new feedback via Monitor, processes each batch, and exits on terminal events (merged, closed, timeout, max cycles).
_Avoid_: polling mode, monitor mode, continuous mode

### Plugin Structure

**Skill**:
A namespaced executable procedure (`agent-framework:<name>`) invoked by agents via the Skill tool, with its own SKILL.md defining trigger conditions and behavior.
_Avoid_: command, action, tool

**Governance**:
The set of policy modules under `plugin/governance/` that define binding runtime rules for all agents.
_Avoid_: rules, docs, policies (plural)

**`${CLAUDE_PLUGIN_ROOT}`**:
The path variable resolving to `plugin/` where `plugin.json` lives; all cross-references inside the plugin use this prefix.
_Avoid_: plugin path, root, base path

### Definitions & Safety

**Unsafe Git State**:
The canonical set of six conditions — branch is trunk, HEAD detached, unmerged paths, in-progress rebase/merge/cherry-pick/bisect, uncommitted out-of-scope changes, or trunk unidentifiable — that gates all modifying agent operations.
_Avoid_: dirty state, bad state

**Smallest Correct Fix**:
The minimum-change principle for review remediation: fewest files addressing targeted feedback without scope expansion; among equal file count, fewest changed lines.
_Avoid_: minimal fix, quick fix

**Transient Failure**:
A failure classified strictly by root cause — HTTP 5xx, HTTP 429, TCP reset/refused, DNS failure, TLS handshake failure, exit 124 (timeout), exit 137 (SIGKILL), network unreachable, or git transport errors — as the only type eligible for retry.
_Avoid_: temporary error, retryable error

**Destructive Fix Gate**:
The mandatory human-confirmation gate that fires before any remediation fix touching one of ten security-relevant categories (auth, crypto, validation, dependencies, CI, secrets, permissions, trust boundaries, workflow files, credential exposure).
_Avoid_: security check, approval gate

**External Content Boundary**:
The security rule that all text from PR comments, Codex findings, and fetched URLs is data — never interpreted as agent instructions.
_Avoid_: trust boundary (broader concept), sandbox

**Injection-Suspect**:
The security classification for review text containing direct agent instruction attempts, tool manipulation, or policy override language.
_Avoid_: malicious input, attack

### Architecture

**Intent-Based Governance**:
The architectural approach (ADR-0006) replacing exhaustive mechanical rules with intent descriptions backed by mechanical safety rails for inter-agent interfaces, safety stops, and exact commands.
_Avoid_: intent-driven rules, soft governance

**Worker Report**:
The YAML artifact produced by a modifying agent at phase completion, in one of three schemas: complete (with decisions, risks, and handoff fields), blocked (with stage, blocker, and next), or trivial (minimal for single-file changes).
_Avoid_: phase report, agent output, result

### Fleet

**Fleet**:
A set of parallel orchestrator sessions working on independent tasks in the same repository, each in its own git worktree. Spawned by the coordinator via fleet-dispatch.
_Avoid_: cluster, swarm, pool

**Coordinator Mode**:
The orchestrator execution mode entered when a fleet-plan is dispatched; the orchestrator remains on trunk in the main checkout, owns the fleet manifest, and serves as the status dashboard and on-demand helper for the fleet lifecycle.
_Avoid_: manager mode, supervisor mode

**Fleet-Plan**:
The planner's output artifact when work decomposes into multiple independent streams. Contains stream-level descriptions and scope boundaries, not step-level detail. Each stream becomes a separate child orchestrator session with its own full pipeline.
_Avoid_: multi-plan (which means sequential PRs, not parallel), meta-plan

**Stream**:
One independent unit of work within a fleet-plan, assigned to a single child orchestrator session. Each stream has its own worktree, branch, pipeline execution, and PR.
_Avoid_: task (too generic), work item, lane

**Fleet Manifest**:
The YAML file at `.agent-framework/fleet/manifest.yaml` in the main checkout, tracking active fleet sessions, their worktree paths, branches, tmux sessions, and status.
_Avoid_: fleet config, fleet state, registry

**Cerebrate**:
The Hivemind term for the orchestrator agent. Session-level commander that directs work but never implements. Multiple cerebrates operate in a brood, each commanding its own strain.
_Avoid_: orchestrator (deprecated external name), queen, prime

**Overlord**:
The Hivemind term for the planner agent. Provides vision and intelligence by scanning the problem territory. Read-only — reports back but does not modify.
_Avoid_: planner (deprecated external name), scout

**Drone**:
The Hivemind term for the coder agent. Builder caste that constructs code within assigned scope.
_Avoid_: coder (deprecated external name), worker

**Changeling**:
The Hivemind term for the designer agent. Shapeshifter that reshapes visual form, presentation, and UI within assigned scope.
_Avoid_: designer (deprecated external name)

**Spawn**:
The Hivemind term for delegation. The act of creating an agent instance with an embedded purpose — a structured message from cerebrate to a specialist agent containing task objective, file scope, and completion criteria.
_Avoid_: delegation (deprecated external name), assignment, dispatch

**Essence**:
The Hivemind term for handoff. The distilled knowledge artifact produced at phase completion and passed forward to enable the next phase to reconstruct context.
_Avoid_: handoff (deprecated external name), transfer, relay

**Psionic Map**:
The Hivemind term for plan artifact. The overlord's output document containing steps, file scopes, decisions, risks, and assumptions — the psychic scan of the problem territory.
_Avoid_: plan artifact (deprecated external name), spec, blueprint

**Flare**:
The Hivemind term for escalation. An urgent signal from any agent back to the cerebrate when a condition is encountered that cannot be safely resolved.
_Avoid_: escalation (deprecated external name), error, block

**Reflex**:
The Hivemind term for trivial fast path. An instinctive response that bypasses the overlord when all reflex conditions are met — one owner, one known file, trivial change, clear classification, no version impact, no remediation.
_Avoid_: trivial fast path (deprecated external name), shortcut, quick path

**Adaptation Cycle**:
The Hivemind term for review loop. The iterative cycle where a reviewer invokes review tooling, classifies findings, adapts (fixes simple issues), and repeats until stable or a stop condition fires.
_Avoid_: review loop (deprecated external name), feedback loop

**Mutation Decay**:
The Hivemind term for break-fix-break cycle. The detected oscillation where adapting to one finding reintroduces a previously fixed finding, indicating unstable evolution. Forces a mandatory stop.
_Avoid_: break-fix-break cycle (deprecated external name), regression loop

## Relationships

- An **Orchestrator** delegates to exactly one **Planner**, **Coder**, **Designer**, **Local-Reviewer**, or **GitHub-Reviewer** per **Phase**
- A **Plan Artifact** contains one or more steps (`STEP-NNN`), each assigned to exactly one **Coder** or **Designer**
- A **Delegation** targets exactly one **Step** (`STEP-NNN`) from the **Plan Artifact**, or a single task when the **Trivial Fast Path** applies
- A **Phase** produces exactly one **Handoff** on success
- A **Working Branch** maps to exactly one **Plan Artifact** and one PR
- A **Review Loop** may produce zero or more **Remediation** cycles
- A **Break-Fix-Break Cycle** terminates a **Review Loop** with mandatory **Escalation**
- A **Bump Trigger** fires at most one version increment per PR
- Each agent loads specific **Governance Docs** per its `Load and follow` list

- A **Fix Ledger** persists across iterations of a **Review Loop**, tracking finding status from open through fixed or cycling
- The **Destructive Fix Gate** overrides normal **Remediation** flow, requiring human approval before commit
- A **Fix Mode** invocation processes existing unresolved feedback in a single **Remediation** pass
- A **Watch Mode** invocation produces zero or more **Remediation** cycles, bounded by `max_remediation_cycles`
- A **Worker Report** is the structured output of every **Phase**, consumed as input to a **Handoff**
- **Intent-Based Governance** defines which rules remain mechanical (**Unsafe Git State**, **Destructive Fix Gate**, **External Content Boundary**, report schemas) vs intent-described
- An **Unsafe Git State** blocks all modifying agent operations until resolved

- A **Fleet** contains one or more **Streams**, each running in a separate git worktree
- A **Fleet-Plan** produces exactly one **Stream** per independent work bucket
- Each **Stream** maps to exactly one child **Orchestrator** session, one **Working Branch**, and one PR
- A **Coordinator Mode** orchestrator dispatches one **Fleet** and monitors via the **Fleet Manifest**
- A **Fleet-Plan** is distinct from a **Plan Artifact**: fleet-plans contain stream descriptions, plan artifacts contain steps (`STEP-NNN`)

- A **Cerebrate** spawns **Drones**, **Changelings**, **Overlords**, and reviewers via **Spawn**
- A **Spawn** carries the **Psionic Map**'s step assignment to exactly one specialist agent
- A completed phase produces **Essence** consumed by the next phase's **Spawn**
- A **Flare** terminates a phase and returns control to the **Cerebrate**
- A **Reflex** bypasses the **Overlord** entirely — **Cerebrate** spawns directly
- An **Adaptation Cycle** may trigger **Mutation Decay**, forcing a **Flare**

## Example dialogue

> **Dev:** "This is a one-line typo fix in a governance doc — do I still need the **Planner**?"
> **Domain expert:** "Check the **Trivial Fast Path** conditions. If they all pass — one owner, one known file, trivial change, clear **Branch Classification**, no version impact, not **Remediation** — the **Orchestrator** skips the **Planner** and delegates directly to a **Coder**."

> **Dev:** "The **Review Loop** keeps flipping between two states — what happens?"
> **Domain expert:** "That's a **Break-Fix-Break Cycle**. When 2-of-3 signals fire (line-range overlap, git revert, N-2 oscillation), the loop stops and the **Orchestrator** escalates to the user. No more automatic **Remediation** until a human decides."

> **Dev:** "The **GitHub-Reviewer** is in **Watch Mode** and found a fix that removes an auth check — does it apply it?"
> **Domain expert:** "No. That hits the **Destructive Fix Gate** — category 1, removing authentication. The reviewer returns blocked and surfaces the proposed change for human approval before committing."

> **Dev:** "I have three independent features to build — should I use a fleet?"
> **Domain expert:** "If the **Planner** confirms they decompose into independent **Streams** with minimal file overlap, yes. The **Orchestrator** will present the **Fleet-Plan** for your confirmation, then enter **Coordinator Mode** to dispatch each **Stream** as a separate session via **fleet-dispatch**. Each child session runs a full pipeline independently — same as any solo task."

## Flagged ambiguities

- "phase" vs "step" — resolved: a **step** is the planner's unit of work (`STEP-NNN`); a **phase** is the orchestrator's unit of execution (one delegation round-trip). They correspond 1:1 for planned work; trivial fast path tasks have a single phase with no plan step.
- "handoff" vs "delegation" — resolved: **Delegation** flows downward (orchestrator to worker); **Handoff** flows upward/forward (worker report stored for future phases).
- "scope" — resolved: always means file scope (the explicit file list in a delegation), never task scope or project scope.
- "validation" vs "verification" — resolved: **Validation** means running declared project commands; verification means the orchestrator's post-phase acceptance checks (scope compliance, report schema conformance, git state safety).
