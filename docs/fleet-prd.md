# Fleet Parallel Execution — Product Requirements Document

**Status:** Draft
**Date:** 2026-05-22
**Feature:** Parallel multi-orchestrator fleet execution

## Problem Statement

The agent-framework orchestrator currently executes one task pipeline at a time. When a user has multiple independent features or work streams, they must execute them sequentially — each going through the full plan → implement → review → PR cycle before the next can begin. This is inefficient when the work streams have minimal file overlap and could safely proceed in parallel.

## Solution Overview

Enable running multiple orchestrator instances in parallel against the same git repository using Claude Code's native `--worktree` and `--tmux` flags. A "fleet" is deployed when work decomposes into multiple large, independent streams with minimal overlap.

## User Stories

### US-1: Fleet Deployment
As a user, I want to give a large task to the orchestrator and have it automatically identify independent work streams and offer to deploy them as parallel sessions, so that I can complete multiple features simultaneously.

**Acceptance Criteria:**
- Planner analyzes task and returns `delivery: fleet` when work decomposes into independent streams
- Orchestrator presents fleet-plan to user for confirmation before dispatching
- User can override to single-session execution
- Each stream spawns as a separate tmux session tab
- User can switch between tabs to monitor and interact with each session

### US-2: User-Directed Fleet Initiation
As a user, I want to explicitly request a fleet by providing multiple tasks, features, issues, or plan files, so that I can control what gets parallelized rather than relying solely on planner decomposition.

**Acceptance Criteria:**
- User can request fleet via natural language: "dispatch a fleet for X, Y, Z", "implement these features using a fleet", "fleet these GitHub issues", "implement plan-A.md and plan-B.md using fleets"
- Orchestrator resolves inputs into stream descriptions (reads plan files, fetches GitHub issue details via `gh issue view`, accepts plain text descriptions)
- Input resolution is orchestrator's responsibility, delegable to source-specific skills as they're built (e.g., future ADO skill, GitHub issue skill)
- Resolved descriptions sent to planner for independence validation and overlap analysis
- Planner returns overlap risk assessment: low, medium, or high
- Low overlap: proceed to fleet confirmation
- Medium/high overlap: user warned with overlap details before confirmation; user can approve, restructure, or cancel

### US-3: Fleet Status Monitoring
As a user, I want to check the status of all fleet sessions from the coordinator tab, so that I can see progress at a glance without switching to every tab.

**Acceptance Criteria:**
- fleet-status skill shows per-stream: tmux session alive/dead, branch exists, PR open/merged/none
- Invocable from coordinator session on demand
- External-only detection — no child self-reporting required

### US-4: Independent Child Execution
As a user, I want each fleet session to behave exactly like a normal Claude Code session, so that I can interact with it naturally — answer questions, approve actions, course-correct.

**Acceptance Criteria:**
- Child sessions are standard orchestrator instances with no fleet awareness
- Task description delivered via tmux send-keys (appears as user's first message)
- Full pipeline: planner (if needed) → branch → implement → version bump → review → PR
- User can interact at any stop condition

### US-5: Conflict Resolution
As a user, I want merge conflicts between parallel streams to be handled naturally as they arise, so that I don't need a complex coordination layer.

**Acceptance Criteria:**
- Each child opens its own PR independently when ready
- PRs merge in the order they're completed/approved
- Subsequent PRs rebase onto updated trunk if needed
- Coordinator can help with rebases on user request

## Architecture Decisions

### AD-1: Coordination Layer
**Decision:** Claude Code native `--worktree` + `--tmux`. No agent teams.
**Rationale:** Proven, stable flags. Agent teams are experimental with known limitations.

### AD-2: Planning Model
**Decision:** Parent planner produces stream-level decomposition only. Each child orchestrator runs its own planner for detailed planning if needed.
**Rationale:** Matches existing model (one orchestrator = one planner). Parent planner's job is decomposition + overlap assessment, not detailed step planning.

### AD-3: Fleet Initiation Paths
**Decision:** Two fleet initiation paths: (1) planner-detected — planner decomposes a single large task and recommends `delivery: fleet`; (2) user-directed — user explicitly requests fleet with N items, orchestrator resolves inputs, planner validates independence.
**Rationale:** Users often know their work is independent before the planner does. Supporting explicit fleet requests gives users direct control. Both paths converge at the same point: planner validates, orchestrator confirms, fleet-dispatch executes.

### AD-4: Input Resolution and Overlap Analysis
**Decision:** Orchestrator resolves external inputs (plan files, GitHub issues, plain text) into stream descriptions. Planner receives resolved descriptions and performs overlap analysis, returning `overlap_risk: low | medium | high` with details. Medium/high risk triggers a warning gate before fleet confirmation.
**Rationale:** Orchestrator already owns input resolution (PR branch resolution, trunk freshness). Planner focuses on analysis. Source-specific resolution can be extended via future skills (ADO, GitHub, etc.) without changing the fleet architecture.

### AD-5: Orchestrator Role
**Decision:** Parent orchestrator enters "coordinator mode" after fleet dispatch. Stays on trunk in main checkout. Responsibilities: dispatch, monitor (fleet-status), on-demand help, final report.
**Rationale:** Clean lifecycle — coordinator's job is done once children are running. Idle parent serves as natural home for fleet-status queries. See ADR-0007.

### AD-6: Child Awareness
**Decision:** Children have zero fleet awareness. They are standard orchestrator sessions receiving a task description.
**Rationale:** No orchestrator agent changes for fleet support. Simplicity. Human team analogy — developers don't know about each other's work in progress. See ADR-0007.

### AD-7: Version Bumps
**Decision:** Each child handles its own version bump per standard pipeline. Conflicts resolved via rebase.
**Rationale:** Matches human team workflow. First PR to merge sets the version. Subsequent PRs rebase and re-evaluate.

### AD-8: Merge Strategy
**Decision:** No automated merge orchestration. PRs merge in completion order. Conflicts handled as they arise.
**Rationale:** Planner decomposition minimizes overlap. Remaining conflicts are exceptional and best handled by user. Automated rebase of active worktrees is unsafe.

### AD-9: Task Injection
**Decision:** `tmux send-keys` to inject stream description as first user message in each child session.
**Rationale:** Most natural — child session looks exactly like user typed the task. User can interact normally after.

### AD-10: Branch Naming
**Decision:** Fleet-dispatch controls worktree/branch naming to match planned branch classification. `claude --worktree feature/stream-name` creates both worktree and correctly named branch.
**Rationale:** Existing create-working-branch skill works as-is — detects branch already exists and confirms. No skill modifications needed.

### AD-11: Fleet Manifest Location
**Decision:** `.agent-framework/fleet/manifest.yaml` in main checkout.
**Rationale:** Coordinator stays on trunk in main checkout — direct access. Children don't need to find it. fleet-status from child tabs resolves main checkout via `git worktree list`.

### AD-12: Config Propagation
**Decision:** `.claude/settings.json` (tracked) carries all workflow permissions — propagates to worktrees via git. Fleet-dispatch copies `.claude/settings.local.json` (gitignored, machine-specific paths only) to each worktree as catch-all.
**Rationale:** Workflow-critical config should not be in gitignored files. Only genuinely machine-specific paths (e.g., Codex cache path) stay in settings.local.json.

### AD-13: Cost Tracking
**Decision:** Deferred to v2. Not in v1 manifest schema.
**Rationale:** Claude Code does not expose per-session token usage programmatically. Terminal scraping is fragile. Track externally observable metrics only (session duration, PR state, commit count).

### AD-14: Parallelism Limits
**Decision:** No `max_parallel` parameter. Spawn as many sessions as streams in the plan.
**Rationale:** Planner determines stream count based on work decomposition. Rate limit handling is built into each child's error recovery. User can constrain informally by modifying the plan before confirming fleet deployment.

### AD-15: Fleet Deployment Confirmation
**Decision:** Planner recommends `delivery: fleet`. Orchestrator always confirms with user before dispatching.
**Rationale:** Prevents surprise fleet deployments. User maintains control over resource allocation (N parallel sessions = N× context windows).

## Fleet Manifest Schema (v1)

```yaml
fleet_id: "<ISO-8601 timestamp>"
coordinator_session: "<session_id>"
overlap_risk: low | medium | high
overlap_details: "<planner's overlap assessment, if any>"
streams:
  - name: "<stream-name>"
    description: "<stream description from fleet-plan>"
    worktree_path: "<absolute path to worktree>"
    branch: "<branch name>"
    tmux_session: "<tmux session name>"
    status: running | complete | blocked | failed
    pr: null | <number>
    merged: false | true
    rebased_after: []  # list of merged stream names this branch incorporated
merge_order: []  # ordered list of merged stream names
```

## Out of Scope (v1)

- Source-specific input resolution skills (ADO, GitHub issues — orchestrator handles natively for v1)
- Per-session cost/token tracking
- Automatic merge orchestration
- Inter-stream communication
- Parallelism limits
- Event-driven merge detection (polling only)
- Fleet persistence across terminal restarts
- Nested fleets (fleet within a fleet)

## Dependencies

- Claude Code `--worktree` flag (stable, current version 2.1.146)
- Claude Code `--tmux` flag (stable)
- tmux installed on user's system
- Git worktree support (git 2.5+)
