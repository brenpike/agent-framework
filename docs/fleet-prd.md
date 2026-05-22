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

### US-2: Fleet Status Monitoring
As a user, I want to check the status of all fleet sessions from the coordinator tab, so that I can see progress at a glance without switching to every tab.

**Acceptance Criteria:**
- fleet-status skill shows per-stream: tmux session alive/dead, branch exists, PR open/merged/none
- Invocable from coordinator session on demand
- External-only detection — no child self-reporting required

### US-3: Independent Child Execution
As a user, I want each fleet session to behave exactly like a normal Claude Code session, so that I can interact with it naturally — answer questions, approve actions, course-correct.

**Acceptance Criteria:**
- Child sessions are standard orchestrator instances with no fleet awareness
- Task description delivered via tmux send-keys (appears as user's first message)
- Full pipeline: planner (if needed) → branch → implement → version bump → review → PR
- User can interact at any stop condition

### US-4: Conflict Resolution
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

### AD-3: Orchestrator Role
**Decision:** Parent orchestrator enters "coordinator mode" after fleet dispatch. Stays on trunk in main checkout. Responsibilities: dispatch, monitor (fleet-status), on-demand help, final report.
**Rationale:** Clean lifecycle — coordinator's job is done once children are running. Idle parent serves as natural home for fleet-status queries. See ADR-0007.

### AD-4: Child Awareness
**Decision:** Children have zero fleet awareness. They are standard orchestrator sessions receiving a task description.
**Rationale:** No orchestrator agent changes for fleet support. Simplicity. Human team analogy — developers don't know about each other's work in progress. See ADR-0007.

### AD-5: Version Bumps
**Decision:** Each child handles its own version bump per standard pipeline. Conflicts resolved via rebase.
**Rationale:** Matches human team workflow. First PR to merge sets the version. Subsequent PRs rebase and re-evaluate.

### AD-6: Merge Strategy
**Decision:** No automated merge orchestration. PRs merge in completion order. Conflicts handled as they arise.
**Rationale:** Planner decomposition minimizes overlap. Remaining conflicts are exceptional and best handled by user. Automated rebase of active worktrees is unsafe.

### AD-7: Task Injection
**Decision:** `tmux send-keys` to inject stream description as first user message in each child session.
**Rationale:** Most natural — child session looks exactly like user typed the task. User can interact normally after.

### AD-8: Branch Naming
**Decision:** Fleet-dispatch controls worktree/branch naming to match planned branch classification. `claude --worktree feature/stream-name` creates both worktree and correctly named branch.
**Rationale:** Existing create-working-branch skill works as-is — detects branch already exists and confirms. No skill modifications needed.

### AD-9: Fleet Manifest Location
**Decision:** `.agent-framework/fleet/manifest.yaml` in main checkout.
**Rationale:** Coordinator stays on trunk in main checkout — direct access. Children don't need to find it. fleet-status from child tabs resolves main checkout via `git worktree list`.

### AD-10: Config Propagation
**Decision:** `.claude/settings.json` (tracked) carries all workflow permissions — propagates to worktrees via git. Fleet-dispatch copies `.claude/settings.local.json` (gitignored, machine-specific paths only) to each worktree as catch-all.
**Rationale:** Workflow-critical config should not be in gitignored files. Only genuinely machine-specific paths (e.g., Codex cache path) stay in settings.local.json.

### AD-11: Cost Tracking
**Decision:** Deferred to v2. Not in v1 manifest schema.
**Rationale:** Claude Code does not expose per-session token usage programmatically. Terminal scraping is fragile. Track externally observable metrics only (session duration, PR state, commit count).

### AD-12: Parallelism Limits
**Decision:** No `max_parallel` parameter. Spawn as many sessions as streams in the plan.
**Rationale:** Planner determines stream count based on work decomposition. Rate limit handling is built into each child's error recovery. User can constrain informally by modifying the plan before confirming fleet deployment.

### AD-13: Fleet Deployment Confirmation
**Decision:** Planner recommends `delivery: fleet`. Orchestrator always confirms with user before dispatching.
**Rationale:** Prevents surprise fleet deployments. User maintains control over resource allocation (N parallel sessions = N× context windows).

## Fleet Manifest Schema (v1)

```yaml
fleet_id: "<ISO-8601 timestamp>"
coordinator_session: "<session_id>"
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
