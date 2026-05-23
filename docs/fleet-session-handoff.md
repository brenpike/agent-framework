# Hivemind Fleet Feature — Session Handoff

**Date:** 2026-05-22
**Session:** Planning + interrogation session for fleet parallel execution feature
**Repo:** `brenpike/hivemind` (renamed from `brenpike/agent-framework` during this session)
**Branch:** All planning docs committed directly to `main` (docs-only, no plugin changes yet)

## What Happened This Session

1. **Initial planning** — planner agent produced a 12-step implementation plan for parallel multi-orchestrator execution using git worktrees and tmux
2. **Plan interrogation** — 18 questions resolved through structured interrogation, significantly refining the architecture
3. **Scope reduction** — 12 steps reduced to 8 (7 functional + 1 rebrand) by eliminating unnecessary skill modifications
4. **Rebrand decision** — `agent-framework` → `Hivemind` with alien swarm themed terminology
5. **Repo renamed** — GitHub repo renamed from `brenpike/agent-framework` to `brenpike/hivemind`
6. **All planning artifacts committed and pushed to main**

## Commits (chronological)

```
911aec5 docs: add fleet parallel execution planning artifacts
d43f9de docs: add user-directed fleet initiation path to PRD and plan
e755a02 docs: add Hivemind rebrand to planning artifacts
```

## Artifacts Created

| File | Purpose |
|---|---|
| `CONTEXT.md` | Updated — 5 fleet terms, 12 Hivemind terms, 11 relationships, 1 example dialogue |
| `docs/adr/0007-fleet-children-unaware-coordinator-dashboard.md` | ADR — children have zero fleet awareness; coordinator is status dashboard only |
| `docs/fleet-prd.md` | Product Requirements Document — 5 user stories, 15 architecture decisions, manifest schema, rebrand mapping |
| `docs/fleet-implementation-plan.md` | 8-step implementation plan with dependencies, risks, open items |
| `docs/hivemind-readme-domain-section.md` | Draft README content — bioform table, lifecycle diagram, brood mode, signals |

## Key Architecture Decisions

### 1. Coordinator Model (ADR-0007)
- Parent orchestrator (cerebrate) enters **hatchery** mode after dispatching a brood
- Stays on trunk in main checkout — serves as status dashboard + on-demand helper
- Does NOT manage merge ordering, version bump coordination, or cross-stream anything
- Children are fully autonomous standard orchestrator sessions with zero fleet awareness

### 2. Planning Model
- **Two fleet initiation paths:**
  - **Planner-detected:** user gives big task → overlord decomposes → recommends `delivery: fleet`
  - **User-directed:** user explicitly requests fleet with N items → cerebrate resolves inputs → overlord validates independence
- Parent overlord produces **stream-level decomposition only** (descriptions + scope boundaries)
- Each child session runs its own overlord for detailed planning if needed
- Overlord returns `overlap_risk: low | medium | high` — medium/high triggers warning gate

### 3. Child Independence
- Children receive task via `tmux send-keys` — looks like user typed it
- Run full standard pipeline: overlord → branch → implement → version bump → review → PR
- Handle their own version bumps, merge conflicts, PRs independently
- Same as human developers on a team — no centralized coordination

### 4. Fleet Lifecycle
```
User → Cerebrate → Overlord (decompose/validate) → Fleet-plan
     → Confirm with user → spawn-brood skill → N tmux sessions
     → Hatchery mode (monitor via brood-status)
     → On-demand help (rebases etc.) if user asks
     → Final report when all strains complete
```

### 5. Merge Strategy
- No automated merge orchestration
- PRs merge in completion order as each strain finishes
- Conflicts handled as they arise (expected to be rare given overlord's decomposition)
- If conflicts occur, it signals poor decomposition quality — planner improvement signal

### 6. Version Bumps
- Each child handles its own — first PR to merge sets version
- Subsequent PRs rebase and re-evaluate bump against new version
- No deferred/coordinated versioning

### 7. Config Propagation
- `.claude/settings.json` (tracked) carries all workflow permissions — propagates to worktrees via git
- `spawn-brood` copies `.claude/settings.local.json` to each worktree as catch-all for machine-specific paths
- `.worktreeinclude` does NOT exist as a Claude Code or git feature (investigated and confirmed)

### 8. Rebrand: agent-framework → Hivemind
- **Naming principle:** themed names for identity, plain descriptions for invocation
- Theme applies to framework-unique concepts only; universal dev concepts unchanged
- Skill descriptions carry both vocabularies — users can say "checkpoint commit" or "molt"

## Domain Language Mapping

| Framework Concept | Hivemind Term |
|---|---|
| Product | **Hivemind** |
| Orchestrator | **Cerebrate** |
| Planner | **Overlord** |
| Coder | **Drone** |
| Designer | **Changeling** |
| Fleet | **Brood** |
| Stream | **Strain** |
| Coordinator Mode | **Hatchery** |
| Delegation | **Spawn** |
| Handoff | **Essence** |
| Plan Artifact | **Psionic Map** |
| Escalation | **Flare** |
| Trivial Fast Path | **Reflex** |
| Review Loop | **Adaptation Cycle** |
| Break-Fix-Break | **Mutation Decay** |

**Unchanged:** trunk, working branch, checkpoint commit, validation, PR, scope, version bump, fix ledger, remediation, reviewer (local/github)

## Implementation Plan Summary

### STEP-001: `hivemind:spawn-brood` Skill (new)
- Spawns N Claude Code sessions via `claude --worktree <branch_name> --tmux`
- Injects task via `tmux send-keys`
- Copies `settings.local.json` to worktrees
- Writes fleet manifest to `.agent-framework/fleet/manifest.yaml`
- **Owner:** drone

### STEP-002: `hivemind:brood-status` Skill (new)
- Reads fleet manifest, reports per-strain status
- Resolves main checkout via `git worktree list` when invoked from worktree
- Checks: tmux alive, branch exists, PR state via `gh pr list`
- Interactive skill (user-invocable, not pipeline)
- **Owner:** drone

### STEP-003: Governance — workflow.md
- Add "Fleet Execution" section with coordinator mode, fleet route (3a planner-detected, 3b user-directed)
- **Owner:** drone

### STEP-004: Governance — definitions.md
- Add: Fleet, Coordinator Mode, Fleet-Plan, Stream definitions
- **Owner:** drone

### STEP-005: Orchestrator Agent (cerebrate)
- Add spawn-brood + brood-status to Skills section
- Add fleet route (3a/3b) to workflow
- **Owner:** drone

### STEP-006: CLAUDE.md + .gitignore
- Add `.claude/worktrees/` to `.gitignore`
- Add fleet documentation section to CLAUDE.md
- **Owner:** drone

### STEP-007: Rebrand — Plugin Rename
- Rename all agent files, skill namespaces, cross-references
- `agent-framework:` → `hivemind:` everywhere
- Agent files: `orchestrator.md` → `cerebrate.md`, `planner.md` → `overlord.md`, `coder.md` → `drone.md`, `designer.md` → `changeling.md`
- Update `plugin.json` name, `marketplace.json`
- Rewrite README.md with Hivemind branding (use `docs/hivemind-readme-domain-section.md` as input)
- **Owner:** drone
- **Note:** sweeping rename — isolate from functional changes

### STEP-008: Version Bump (MINOR)
- New backward-compatible capability
- Update `plugin/.claude-plugin/plugin.json` version
- Update CHANGELOG.md
- **Owner:** drone

### Dependencies
```
STEP-003 ──┐
STEP-004 ──┤
            ├── STEP-005
STEP-001 ──┘
STEP-002 (independent)
STEP-006 (independent, after STEP-001 + STEP-002)
STEP-007 (after STEP-001 through STEP-006)
STEP-008 (after all other steps)
```

## Fleet Manifest Schema (v1)

```yaml
fleet_id: "<ISO-8601 timestamp>"
coordinator_session: "<session_id>"
overlap_risk: low | medium | high
overlap_details: "<overlord's assessment>"
streams:
  - name: "<strain-name>"
    description: "<strain description>"
    worktree_path: "<absolute path>"
    branch: "<branch name>"
    tmux_session: "<tmux session name>"
    status: running | complete | blocked | failed
    pr: null | <number>
    merged: false | true
    rebased_after: []
merge_order: []
```

## Open Items

1. Determine exact `claude --worktree` session-ready signal for tmux send-keys timing
2. Determine tmux session naming convention used by `claude --tmux`
3. Clean up `.claude/settings.local.json` — move workflow permissions to tracked `settings.json`
4. Investigate fleet-status rendering: table format, colors, refresh behavior
5. Define overlord output schema for fleet-plan (strain descriptions + overlap_risk + overlap_details)
6. Determine orchestrator's native input resolution capabilities for v1
7. Determine if rebrand should be separate PR or same PR as fleet feature
8. Audit all governance doc cross-references for namespace completeness
9. Determine README structure and content

## Delivery Recommendation

**Single PR** for fleet feature (STEP-001 through STEP-006). All steps are tightly coupled.

**Separate PR** for rebrand (STEP-007) — isolates rename noise from functional changes. Rebrand touches nearly every file; mixing with fleet logic makes review harder.

**Separate PR** for version bump (STEP-008) — after both feature and rebrand land.

This gives 3 PRs:
1. `feature/fleet-parallel-execution` — STEP-001 through STEP-006
2. `refactor/hivemind-rebrand` — STEP-007
3. `chore/version-bump` — STEP-008

## How to Resume

1. Read this document
2. Read `docs/fleet-prd.md` for full requirements and architecture decisions
3. Read `docs/fleet-implementation-plan.md` for detailed step specifications
4. Read `CONTEXT.md` for domain language (both fleet and Hivemind terms)
5. Read `docs/adr/0007-fleet-children-unaware-coordinator-dashboard.md` for the core architecture decision
6. Start with STEP-001 (spawn-brood skill) or STEP-003 (governance) — both are entry points with no dependencies
