# Hivemind

Domain glossary for the hivemind Claude Code plugin — a multi-agent system that orchestrates planning, implementation, review, and delivery through governed specialist agents.

## Language

### Agents

**Cerebrate**:
The control-plane agent — session-level commander that owns task intake, spawn sequencing, branch/PR decisions, version bump detection, and review routing. Directs work but never implements. Multiple cerebrates operate in a brood, each commanding its own strain.
_Alias_: orchestrator
_Avoid_: coordinator, dispatcher, controller, queen, prime

**Overlord**:
A read-only agent that scans the problem territory and produces a psionic map with file scopes, step sequencing, and risk assessment before execution begins. Provides vision and intelligence — reports back but does not modify.
_Alias_: planner
_Avoid_: architect, analyst, scout

**Drone**:
A modifying agent — builder caste that implements code changes within an explicitly assigned file scope.
_Alias_: coder
_Avoid_: developer, implementer, worker

**Changeling**:
A modifying agent — shapeshifter that owns presentational markup, styling, and static accessibility within an explicitly assigned file scope. Reshapes visual form, presentation, and UI.
_Alias_: designer
_Avoid_: UI agent, stylist

**Local-Reviewer**:
The agent that runs pre-PR Codex review in a loop, classifies findings, and reports terminal results to the cerebrate before the PR is opened.
_Avoid_: linter, pre-check

**GitHub-Reviewer**:
The agent that monitors or processes post-PR review feedback, classifies comments, and reports terminal results to the cerebrate.
_Avoid_: PR bot, review handler

### Execution

**Phase**:
A single spawn round-trip: one worker agent receives a step, executes, and reports back.
_Avoid_: stage, iteration (when meaning a sequential plan step)

**Spawn**:
A structured message from cerebrate to a specialist agent, creating an agent instance with an embedded purpose — containing task objective, file scope, step ID, and completion criteria.
_Alias_: delegation
_Avoid_: assignment, dispatch, handoff (which has a different meaning)

**Essence**:
The distilled knowledge artifact (worker report) produced at phase completion and passed forward to enable the next phase to reconstruct context.
_Alias_: handoff
_Avoid_: transfer, relay, spawn

**Checkpoint Commit**:
A git commit made at a phase boundary or milestone, preserving incremental progress on the working branch. Also called a **molt**.
_Avoid_: save point, intermediate commit

**Psionic Map**:
The overlord's output document containing steps, file scopes, decisions, risks, and assumptions — the psychic scan of the problem territory. Required before execution begins for non-trivial tasks.
_Alias_: plan artifact
_Avoid_: spec, design doc, blueprint

**Reflex**:
An instinctive response that bypasses the overlord when all reflex conditions are met: one owner, one known file, trivial change, clear branch classification, no version impact, no review remediation.
_Alias_: trivial fast path (TFP)
_Avoid_: quick path, shortcut

**Session Facts**:
Cached resolved values (trunk name, task-type, claude-mem status, active-step) that persist within a task to avoid redundant lookups.
_Avoid_: state, config, environment

### Governance

**Governance Doc**:
A markdown file under `plugin/governance/` loaded by agents at runtime as binding policy.
_Avoid_: reference doc, guide, spec

**Scope**:
The explicit list of files a modifying agent is permitted to touch during a spawn.
_Avoid_: assignment, context, area

**Validation**:
The set of project-declared commands (from CLAUDE.md) that must pass before a phase is accepted.
_Avoid_: tests, checks (which is broader)

**Flare**:
An urgent signal from any agent back to the cerebrate when a condition is encountered that cannot be safely resolved. The mandatory stop-and-report action.
_Alias_: escalation
_Avoid_: error, block (which has a different meaning)

### Git / Delivery

**Working Branch**:
The non-trunk branch created for a single approved psionic map's implementation and PR.
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

**Adaptation Cycle**:
The iterative cycle where a reviewer agent invokes Codex, classifies findings, fixes simple issues directly (≤2 files), flares complex ones to the cerebrate, validates, and repeats until stable or a stop condition fires.
_Alias_: review loop
_Avoid_: review cycle (ambiguous with remediation cycle), feedback loop

**Remediation**:
The act of addressing a review finding: classify, fix directly (≤2 files) or flare to cerebrate, validate, checkpoint-commit, push.
_Avoid_: resolution, fix (too generic)

**Mutation Decay**:
The detected oscillation where fixing one finding reintroduces a previously fixed finding (2-of-3 signal match), indicating unstable evolution. Forces a mandatory stop.
_Alias_: break-fix-break cycle
_Avoid_: regression loop, flip-flop

**Fix Ledger**:
The persisted YAML artifact (`.hivemind/review-loop/fix-ledger.yaml`) tracking finding status across adaptation cycle iterations; status transitions: open → fixing → fixed/regressed, fixed → cycling.
_Avoid_: review log, finding tracker

**Fix Mode**:
The one-shot operating mode of the github-reviewer agent that processes existing unresolved feedback in a single remediation pass without polling.
_Avoid_: one-shot mode, immediate mode

**Watch Mode**:
The continuous operating mode of the github-reviewer agent that polls for new feedback via Monitor, processes each batch, and exits on terminal events (merged, closed, timeout, max cycles).
_Avoid_: polling mode, monitor mode, continuous mode

### Plugin Structure

**Skill**:
A namespaced executable procedure (`hivemind:<name>`) invoked by agents via the Skill tool, with its own SKILL.md defining trigger conditions and behavior.
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
The YAML artifact produced by a modifying agent at phase completion, in one of three schemas: complete (with decisions, risks, and essence fields), blocked (with stage, blocker, and next), or trivial (minimal for single-file changes).
_Avoid_: phase report, agent output, result

### Brood (fleet)

**Brood**:
A set of parallel cerebrate sessions working on independent tasks in the same repository, each in its own git worktree. Spawned by the cerebrate in hatchery mode via brood-dispatch.
_Alias_: fleet
_Avoid_: cluster, swarm, pool

**Hatchery**:
The cerebrate execution mode entered when a fleet-plan is dispatched; the cerebrate remains on trunk in the main checkout, owns the fleet manifest, and serves as the status dashboard and on-demand helper for the brood lifecycle.
_Alias_: coordinator mode
_Avoid_: manager mode, supervisor mode

**Fleet-Plan**:
The overlord's output artifact when work decomposes into multiple independent strains. Contains strain-level descriptions and scope boundaries, not step-level detail. Each strain becomes a separate child cerebrate session with its own full pipeline.
_Avoid_: multi-plan (which means sequential PRs, not parallel), meta-plan

**Strain**:
One independent unit of work within a fleet-plan, assigned to a single child cerebrate session. Each strain has its own worktree, branch, pipeline execution, and PR.
_Alias_: stream
_Avoid_: task (too generic), work item, lane

**Fleet Manifest**:
The YAML file at `.hivemind/fleet/manifest.yaml` in the main checkout, tracking active brood sessions, their worktree paths, branches, tmux sessions, and status.
_Avoid_: fleet config, fleet state, registry

## Relationships

- A **Cerebrate** (orchestrator) spawns exactly one **Overlord**, **Drone**, **Changeling**, **Local-Reviewer**, or **GitHub-Reviewer** per **Phase**
- A **Psionic Map** (plan artifact) contains one or more steps (`STEP-NNN`), each assigned to exactly one **Drone** or **Changeling**
- A **Spawn** (delegation) targets exactly one **Step** (`STEP-NNN`) from the **Psionic Map**, or a single task when the **Reflex** (trivial fast path) applies
- A **Phase** produces exactly one **Essence** (handoff) on success
- A **Working Branch** maps to exactly one **Psionic Map** and one PR
- An **Adaptation Cycle** (review loop) may produce zero or more **Remediation** cycles
- A **Mutation Decay** (break-fix-break cycle) terminates an **Adaptation Cycle** with mandatory **Flare** (escalation)
- A **Bump Trigger** fires at most one version increment per PR
- Each agent loads specific **Governance Docs** per its `Load and follow` list

- A **Fix Ledger** persists across iterations of an **Adaptation Cycle**, tracking finding status from open through fixed or cycling
- The **Destructive Fix Gate** overrides normal **Remediation** flow, requiring human approval before commit
- A **Fix Mode** invocation processes existing unresolved feedback in a single **Remediation** pass
- A **Watch Mode** invocation produces zero or more **Remediation** cycles, bounded by `max_remediation_cycles`
- A **Worker Report** is the structured output of every **Phase**, consumed as input to an **Essence**
- **Intent-Based Governance** defines which rules remain mechanical (**Unsafe Git State**, **Destructive Fix Gate**, **External Content Boundary**, report schemas) vs intent-described
- An **Unsafe Git State** blocks all modifying agent operations until resolved

- A **Brood** (fleet) contains one or more **Strains** (streams), each running in a separate git worktree
- A **Fleet-Plan** produces exactly one **Strain** per independent work bucket
- Each **Strain** maps to exactly one child **Cerebrate** session, one **Working Branch**, and one PR
- A **Hatchery** (coordinator mode) cerebrate dispatches one **Brood** and monitors via the **Fleet Manifest**
- A **Fleet-Plan** is distinct from a **Psionic Map**: fleet-plans contain strain descriptions, psionic maps contain steps (`STEP-NNN`)

- A **Spawn** carries the **Psionic Map**'s step assignment to exactly one specialist agent
- A completed phase produces **Essence** consumed by the next phase's **Spawn**
- A **Flare** terminates a phase and returns control to the **Cerebrate**
- A **Reflex** bypasses the **Overlord** entirely — **Cerebrate** spawns directly
- An **Adaptation Cycle** may trigger **Mutation Decay**, forcing a **Flare**

## Example dialogue

> **Dev:** "This is a one-line typo fix in a governance doc — do I still need the **Overlord** (planner)?"
> **Domain expert:** "Check the **Reflex** (trivial fast path) conditions. If they all pass — one owner, one known file, trivial change, clear **Branch Classification**, no version impact, not **Remediation** — the **Cerebrate** skips the **Overlord** and spawns a **Drone** directly."

> **Dev:** "The **Adaptation Cycle** (review loop) keeps flipping between two states — what happens?"
> **Domain expert:** "That's **Mutation Decay** (break-fix-break). When 2-of-3 signals fire (line-range overlap, git revert, N-2 oscillation), the cycle stops and the **Cerebrate** flares to the user. No more automatic **Remediation** until a human decides."

> **Dev:** "The **GitHub-Reviewer** is in **Watch Mode** and found a fix that removes an auth check — does it apply it?"
> **Domain expert:** "No. That hits the **Destructive Fix Gate** — category 1, removing authentication. The reviewer returns blocked and surfaces the proposed change for human approval before committing."

> **Dev:** "I have three independent features to build — should I use a brood (fleet)?"
> **Domain expert:** "If the **Overlord** confirms they decompose into independent **Strains** (streams) with minimal file overlap, yes. The **Cerebrate** will present the **Fleet-Plan** for your confirmation, then enter **Hatchery** (coordinator mode) to dispatch each **Strain** as a separate session via **spawn-brood**. Each child session runs a full pipeline independently — same as any solo task."

## Flagged ambiguities

- "phase" vs "step" — resolved: a **step** is the overlord's unit of work (`STEP-NNN`); a **phase** is the cerebrate's unit of execution (one spawn round-trip). They correspond 1:1 for planned work; reflex tasks have a single phase with no plan step.
- "essence" vs "spawn" — resolved: **Spawn** (delegation) flows downward (cerebrate to worker); **Essence** (handoff) flows upward/forward (worker report stored for future phases).
- "scope" — resolved: always means file scope (the explicit file list in a spawn), never task scope or project scope.
- "validation" vs "verification" — resolved: **Validation** means running declared project commands; verification means the cerebrate's post-phase acceptance checks (scope compliance, report schema conformance, git state safety).
