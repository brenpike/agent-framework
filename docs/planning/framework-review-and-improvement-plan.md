# Agent Framework Review And Improvement Plan

## Purpose

This document captures a review of the current agent framework, recommended improvements, the ranked/dependent improvement backlog, the phased execution plan, and the detailed implementation plan for Phase 1.

The guiding constraint is that improvements must not weaken workflow enforcement, safety, or control. Simplification should only happen after guardrails exist to prove safety behavior was preserved.

## Current-State Assessment

| Area | Rating | Findings |
|---|---:|---|
| Token consumption | 4/10 | The framework is prose-heavy, with substantial content spread across agent definitions, governance files, and skills. References help, but common workflows can still require several large files to be loaded or re-read. |
| Reliability | 6/10 | The framework has strong gates: planner-first routing, explicit scopes, blocked reports, unsafe git checks, validation rules, and PR remediation controls. The weak point is that most enforcement depends on instruction-following rather than executable checks. |
| Efficiency | 5/10 | The workflow is appropriate for serious PR work but heavy for common changes. Planner-first behavior, branch preflight, validation, versioning, and review routing can turn small edits into many tool and agent hops. |
| Clarity | 7/10 | Roles and ownership are clear, and the system explains workflow expectations concretely. The cost is density: rules are distributed across agents, governance, and skills, so the full execution path has to be reconstructed. |
| Complexity | 4/10 | The framework has outgrown a simple plugin. It includes multiple agents, workflow skills, governance documents, review remediation logic, versioning policy, and monitor policy. Some complexity is justified, but some exists because rules are duplicated or scattered. |
| Performance | 5/10 | Performance cost comes mostly from agent latency and tool churn. Strong models, strict validation, GitHub pagination, and repeated policy reads will slow real workflows. |
| Durability | 5/10 | The central governance docs help, but behavior is brittle because it depends on textual cross-references, keyword routing, host-tool support, and consistent agent compliance after future edits. |
| Safety / control | 8/10 | This is the strongest area. Explicit file scope, no trunk commits, validation gates, blocked states, and PR review discipline provide meaningful protection. |
| Adoptability | 6/10 | README setup is usable, but projects must provide good `CLAUDE.md` and `AGENTS.md` files. Without those, versioning and validation often become unknown or blocked. |
| Maintainability | 5/10 | Rules are thoughtful but duplicated. Validation and unsafe git state are referenced in many places. Manual edits can easily create drift. |
| Observability | 7/10 | Field-based reports, blocked contracts, and review ledgers give useful auditability. Report structure is a strength, though it can become noisy. |
| Extensibility | 5/10 | Adding a role, workflow, or review source would be risky because routing and authority rules are hardcoded in several places. |

## Key Takeaway

The current framework is a cautious, process-heavy safety system optimized for preventing bad autonomous edits. It is less optimized for speed, low-token operation, and easy evolution.

The correct improvement strategy is not to remove rules. It is to make rules harder to bypass with fewer words by adding executable checks, report validators, rule ownership, policy indexes, and regression tests.

The existing framework should be modified in place rather than replaced. Starting fresh would likely reintroduce the same safety rules over time, with new failure modes and a period of weaker control.

## Planning Constraints

- Phase 1 planning documents are human/dev-tooling reference material only. They live outside the plugin payload under `docs/planning/` and must not be treated as runtime governance.
- Active runtime governance lives under `plugin/governance/` and must be referenced by agents or skills when it is intended to affect behavior.
- Development tooling and tests live at the repository root under `tools/` and `tests/`, not under `plugin/`, so they are not distributed as plugin runtime data.
- Phase 1 must not change agent behavior. It may expose current gaps through advisory checks, fixtures, and documentation.
- Phase 1 requires no plugin version bump because planned docs, tools, and tests live outside `plugin/`, do not change the plugin runtime payload, and do not affect packaged output or consumer behavior.

## Improvement Backlog

`Depends on` means "best done after." It is not always a hard blocker.

### Token Consumption

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| TC-1 | Create a short always-loaded core contract; move long workflow detail behind workflow-specific references. | 3 | 5 | CPX-1 |
| TC-2 | Replace repeated prose with named rule IDs, e.g. `GIT-PREFLIGHT-01`, `VALIDATION-01`. | 3 | 5 | DUR-4 |
| TC-3 | Design and, only if still justified, generate static agent files from canonical governance fragments. Claude Code must load generated markdown output, and tooling must prove generated files are in sync. | 5 | 3 | TC-2 |
| TC-4 | Add compact checklists at the top of each skill. | 2 | 4 | TC-2 |
| TC-5 | Split `agent-system-policy.md` into modules: scope, git, validation, review, monitor, communication. | 3 | 4 | CPX-1 |

### Reliability

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| REL-1 | Add a policy linter for contradictions, forbidden terms, missing sections, stale references, unsupported tools. | 3 | 5 | DUR-4 |
| REL-2 | Add golden-path workflow tests for trivial edit, feature, PR open, review remediation, monitor request. | 4 | 5 | REL-4 |
| REL-3 | Convert preflight checks into explicit command recipes with expected outputs. | 3 | 5 | CLR-1 |
| REL-4 | Add machine-checkable report validators for planner, worker, blocked, PR, and remediation outputs. | 4 | 5 | CLR-4 |
| REL-5 | Require every safety gate to have one owner, one canonical definition, and one test fixture. | 3 | 5 | DUR-4 |

### Efficiency

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| EFF-1 | Validate and harden the existing safe fast path for trivial single-file changes while preserving branch preflight, scope, validation, and final report. | 3 | 5 | REL-2 |
| EFF-2 | Let planner return `Workflow loadout:` naming only required governance modules. Two-part delivery: (a) design mandatory/conditional module classification spec as a docs/planning artifact, (b) implement in planner.md once spec is approved. | 3 | 4 | TC-5 |
| EFF-3 | Add explicit "no PR requested" and "no review requested" workflow branches. | 2 | 4 | CLR-1 |
| EFF-4 | Batch validation and git checks at phase boundaries instead of repeating nearby checks. | 3 | 3 | REL-3 |
| EFF-5 | Define remediation batching rules for same owner, same files, same validation path. | 4 | 4 | CPX-2 |

### Clarity

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| CLR-1 | Add a one-page execution state machine using the target term "trivial fast path": Intake -> Plan -> Preflight -> Branch -> Implement -> Validate -> Commit -> PR -> Review. | 2 | 5 | None |
| CLR-2 | Add a routing matrix from user intent to skill/agent. | 2 | 5 | CLR-1 |
| CLR-3 | Rename planner-first exception to "trivial fast path" and make the checklist shorter/testable. | 1 | 3 | EFF-1 |
| CLR-4 | Add examples of valid blocked reports, worker reports, and remediation reports. | 2 | 4 | None |
| CLR-5 | Add a glossary for overloaded terms: plan, phase, artifact, candidate, thread, monitor, etc. | 2 | 3 | None |

### Complexity

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| CPX-1 | Separate policy from procedure: governance defines invariants; skills define command procedures; agents define ownership. | 4 | 5 | CLR-1 |
| CPX-2 | Collapse overlapping review-routing rules into one canonical remediation decision table. | 3 | 5 | CLR-2 |
| CPX-3 | Remove duplicated unsafe-git/validation wording after rule IDs and generated references exist. | 4 | 4 | TC-2 |
| CPX-4 | Make versioning an optional module activated only by artifact paths or `CLAUDE.md` artifact config. | 3 | 4 | TC-5 |
| CPX-5 | Add a policy index mapping every rule ID to canonical source and consumers. | 3 | 5 | DUR-4 |

### Performance

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| PERF-1 | Assign haiku to specialist agents (planner, coder) for routine/low-risk invocations; keep sonnet on orchestrator and high-risk paths (architecture, versioning, review remediation, multi-file). Do not attempt per-path model routing within a single agent. | 2 | 4 | EFF-1 |
| PERF-2 | Add bounded discovery commands for planner: file map first, targeted reads second. | 2 | 4 | CLR-1 |
| PERF-3 | Cache resolved repo facts in session reports: trunk, validation commands, artifact paths, review policy. | 3 | 4 | REL-3 |
| PERF-4 | Make GitHub review fetching incremental using seen IDs in the session ledger. | 4 | 3 | CPX-2 |
| PERF-5 | Add validation tiers in `CLAUDE.md`: required quick checks before commit, full checks before PR/merge. | 4 | 4 | REL-5 |
| PERF-6 | Investigate whether Claude Code supports per-invocation model overrides to enable true per-path model routing within orchestrator. | 3 | 3 | PERF-1 |

### Durability

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| DUR-1 | Add policy regression tests for no trunk commits, no silent scope expansion, no PR after failed validation. | 4 | 5 | REL-4 |
| DUR-2 | Add compatibility tests for plugin metadata, frontmatter tools, skill names, namespaced invocations, unsupported fields. | 3 | 4 | REL-1 |
| DUR-3 | Add changelog entries for policy behavior changes. | 2 | 3 | None |
| DUR-4 | Add rule ownership metadata: owner, source, consumers, test coverage. | 4 | 5 | None |
| DUR-5 | Add migration notes for rule renames or module splits so project `CLAUDE.md` files do not silently break. | 3 | 4 | DUR-3 |

## Prioritized Phased Plan

### Selection Rule

Include items that meet one of these conditions:

- Value 5, regardless of difficulty, when the item protects safety or control.
- Value 4 with difficulty 2-3 when the item improves maintainability, clarity, or execution cost.
- Value 4 with difficulty 4 only when the item unlocks important later work.

### Phase 1: Make The Workflow Measurable

| Order | ID | Why Now |
|---:|---|---|
| 1 | CLR-1 | Establishes the canonical execution flow before changing anything else. |
| 2 | CLR-4 | Gives concrete examples for report contracts, enabling validators and tests. |
| 3 | DUR-4 | Adds rule ownership metadata, the foundation for rule IDs, linting, and safe deduplication. |
| 4 | REL-4 | Makes report compliance testable instead of purely instructional. |
| 5 | REL-1 | Catches contradictions, stale references, unsupported fields, and forbidden language. |
| 6 | DUR-1 | Locks down core safety invariants before simplification begins. |
| 7 | DUR-2 | Verifies plugin compatibility so refactors do not silently break Claude plugin behavior. |
| 8 | CLR-5 | Adds a minimal glossary stub so the state machine does not introduce undefined terminology. |

### Phase 2: Canonicalize The Policy Surface

| Order | ID | Why Now |
|---:|---|---|
| 9 | TC-2 | Rule IDs reduce repeated prose and make rules easier to reference precisely. |
| 10 | CPX-5 | Policy index maps rule IDs to source and consumers, preventing drift. |
| 11 | REL-5 | Every safety gate gets one owner, canonical definition, and test fixture. |
| 12 | CPX-1 | Separates invariants from procedures and agent ownership. Treat this as multi-PR structural work before moving on. |
| 13 | TC-5 | Splits the large policy file into modules after ownership/source mapping is clear. |
| 14 | TC-4 | Adds compact skill checklists that reference canonical rules without weakening them. |

Known risk: Phases 2 and 3 make structural changes before full golden-path workflow tests exist. Mitigation is to keep Phase 2 changes small, land CPX-1 as multi-PR work, and require the Phase 1 safety regression checks to pass before each structural change.

### Phase 3: Improve Routing And Workflow Shape

| Order | ID | Why Now |
|---:|---|---|
| 15 | CLR-2 | A routing matrix makes skill/agent selection clearer and easier to lint. |
| 16 | CPX-2 | Collapses review remediation routing into one canonical decision table. |
| 17 | REL-3 | Turns git preflight into command recipes with expected outputs. |
| 18 | EFF-3 | Makes "no PR requested" and "no review requested" explicit. |

### Phase 4: Add Safe Efficiency Paths

| Order | ID | Why Now |
|---:|---|---|
| 20 | REL-2 | Golden-path workflow tests prove main scenarios still work. |
| 21 | EFF-1 | Validates and hardens the existing safe trivial fast path while preserving branch, scope, validation, and reporting gates. |
| 22 | EFF-2 | TC-5 complete (Phase 2). Part (a): design mandatory/conditional governance module classification spec. Part (b): implement `Workflow loadout:` in planner.md after spec approval. |
| 23 | PERF-1 | Option B: assign haiku to specialist agents for routine invocations; keep sonnet on orchestrator and high-risk paths. Safe once fast-path boundaries are tested. |
| 24 | PERF-2 | Bounded planner discovery improves speed without changing governance. |
| 25 | PERF-3 | Caches resolved repo facts to reduce repeated checks and rereads. |

### Phase 5: Reduce Loaded Context And Duplication

| Order | ID | Why Now |
|---:|---|---|
| 26 | TC-1 | Creates the always-loaded core contract after canonical modules and tests exist. |
| 27 | CPX-3 | Removes duplicated unsafe-git/validation wording only after rule IDs and tests protect behavior. |
| 28 | CPX-4 | Makes versioning module activation more targeted while preserving versioning stops. |

### Phase 6: Later Optimizations

| Order | ID | Why Now |
|---:|---|---|
| 29 | EFF-5 | Remediation batching is valuable but risky; wait until routing is canonical and tested. |
| 30 | PERF-5 | Validation tiers can help but need careful semantics to avoid weakening validation. |
| 31 | DUR-5 | Migration notes become important once rule renames or module splits happen. |
| 32 | DUR-3 | Policy changelog is useful but not foundational. Add it alongside the first behavioral refactor. |
| 33 | PERF-6 | Investigate per-invocation model overrides in Claude Code once PERF-1 Option B is delivered. |

### Deferred Items

| ID | Reason |
|---|---|
| CLR-3 | The target term "trivial fast path" is folded into `CLR-1`; detailed checklist cleanup remains part of `EFF-1`. |
| TC-3 | High-risk and low value-to-difficulty after review. Reconsider only after static generation design proves Claude Code loads generated output and sync tests are reliable. |
| EFF-4 | Batching validation/git checks risks weakening enforcement. Revisit after validators and tests exist. |
| PERF-4 | Incremental GitHub fetching is lower value relative to difficulty. Optimize after remediation flow is stable. |
| EFF-2 | Moved to Phase 4. TC-5 dependency resolved (Phase 2 complete). Two-part delivery: mandatory/conditional module spec design, then implementation in planner.md. |

## Phase 1 Implementation Plan

### Phase 1 Goal

Make the framework measurable before simplifying it. Phase 1 should add documentation structure plus validation tooling that detects weakened workflow rules, without changing actual workflow behavior.

### Phase 1 Scope

Included:

1. `CLR-1` execution state machine
2. `CLR-4` report contract examples
3. `DUR-4` rule ownership metadata
4. `REL-4` report validators
5. `REL-1` policy linter
6. `DUR-1` safety regression tests
7. `DUR-2` plugin compatibility tests
8. `CLR-5` minimal glossary stub for terms used by the state machine

Do not refactor agent behavior in this phase. Phase 1 documents are planning/dev-tooling artifacts outside `plugin/`; they are not active governance and are not referenced from agents.

### Phase 1 Versioning Conclusion

Phase 1 requires no plugin version bump. The planned additions are outside the plugin source directory (`plugin/`) and therefore do not change installed plugin runtime behavior, packaged output, published agent/skill definitions, or consumer-facing governance. If implementation later moves any Phase 1 artifact into `plugin/` or changes agent/skill behavior, reassess versioning before PR opening.

### Step 1: Add Execution State Machine (`CLR-1`)

Create:

- `docs/planning/execution-state-machine.md`

Content:

- Canonical workflow states:
  - Intake
  - Plan
  - Trivial Fast Path
  - Git Preflight
  - Branch
  - Implement
  - Validate
  - Checkpoint Commit
  - PR
  - External Review
  - Remediation
  - Final Report
  - Blocked
- Allowed transitions
- Required gates before each transition
- Which agent or skill owns each state

Acceptance criteria:

- Every existing workflow path maps to a state.
- No state permits implementation before git preflight.
- Blocked is explicit from any failed gate.
- The state machine uses the target term `Trivial Fast Path` so a later rename is not required.

### Step 2: Add Report Examples (`CLR-4`)

Create:

- `docs/planning/report-examples.md`

Add examples for:

- Planner compact report
- Planner full report
- Worker complete report
- Worker blocked report
- Orchestrator final report
- PR feedback remediation report
- Monitor not-active report

Acceptance criteria:

- Examples match current contracts.
- Examples contain no new rules.
- Examples are minimal and validator-friendly.
- Examples are clearly labeled non-normative unless and until promoted into active governance.

### Step 3: Add Rule Ownership Metadata (`DUR-4`)

Create:

- `docs/planning/rule-index-draft.md`

Phase 1 creates the index with descriptive rule names only. Formal rule IDs such as `GIT-PREFLIGHT-01` are assigned later by `TC-2` in Phase 2.

Initial format:

```markdown
| Descriptive Rule Name | Future Rule ID | Source | Owner | Consumers | Test Coverage | Notes |
|---|---|---|---|---|---|---|
```

Start with core safety rules:

- no trunk commits
- explicit file scope
- planner-first/default planning
- required git preflight
- validation gate
- blocked report contract
- no silent scope expansion
- PR only after validation
- monitor truthfulness
- review remediation ownership

Acceptance criteria:

- Every listed rule has one canonical source.
- Every listed rule has at least one consumer.
- Test coverage can initially be `planned`.
- `Future Rule ID` may be `TBD` in Phase 1; Phase 2 owns assigning stable IDs.

### Step 3a: Add Minimal Glossary Stub (`CLR-5`)

Create:

- `docs/planning/glossary-draft.md`

Define only terms used by the Phase 1 state machine and report examples:

- plan
- phase
- milestone
- artifact
- candidate
- thread
- review summary
- monitor
- blocked

Acceptance criteria:

- The glossary is explicitly a draft planning aid.
- No active governance rule depends on it in Phase 1.
- Definitions point to existing canonical sources where one already exists.

### Step 4: Add Test And Lint Harness Structure

Create:

- `tools/policy_check.ps1` at the repository root
- `tools/validate_reports.ps1` at the repository root
- `tests/policy/` at the repository root
- `tests/reports/` at the repository root
- `tests/plugin/` at the repository root

Keep the harness PowerShell-friendly because the primary development environment for this repository is Windows/PowerShell. The plugin skill frontmatter is a separate runtime execution context and is not the reason for the dev-tooling shell choice.

Suggested command:

```powershell
./tools/policy_check.ps1
```

Acceptance criteria:

- One command can run all Phase 1 checks.
- Checks are deterministic and local.
- No network or GitHub access is required.
- Tooling is outside `plugin/` and therefore outside the plugin payload.

### Step 5: Implement Report Validators (`REL-4`)

Create fixtures:

- `tests/reports/valid-worker-complete.txt`
- `tests/reports/valid-blocked.txt`
- `tests/reports/invalid-missing-status.txt`
- `tests/reports/invalid-unstructured-line.txt`

Validator checks:

- Required headings exist.
- `Status:` exists and has an allowed value.
- Blocked reports include `Stage`, `Blocker`, `Retry status`, `Fallback used`, `Impact`, and `Next action`.
- Worker reports include `Changed`, `Validated`, `Need scope change`, and `Issues`.
- No standalone prose lines outside the allowed contract shape.

Acceptance criteria:

- Valid fixtures pass.
- Invalid fixtures fail with specific messages.
- No agent prompt behavior changes are introduced.

### Step 6: Implement Policy Linter (`REL-1`)

Initial linter checks:

- Forbidden hedge contradiction: policy says not to use `ambiguous` as a hedge. The linter must not flag every occurrence. It should flag gate-level uncertainty wording such as "unsafe or ambiguous" or "project root is ambiguous"; descriptive classifications such as reviewer/source categories are allowed.
- Required files exist.
- Skill names referenced by orchestrator exist.
- Agent names referenced by orchestrator exist.
- Unsupported plugin frontmatter fields are absent.
- Every governance reference path resolves.
- Every skill has `name`, `description`, `allowed-tools`, and `shell`.
- `plugin/governance/AGENTS.template.md` exists and is referenced from README as the project-level reviewer template.

Advisory vs strict mode:

- Advisory mode reports findings and exits successfully unless the harness itself fails.
- Strict mode exits non-zero for findings not listed in the allowlist.
- Phase 1 runs advisory mode by default.

Allowlist mechanism:

- Create `tests/policy/policy-lint-allowlist.json`.
- Each allowlist entry contains `rule`, `path`, optional `line`, and `reason`.
- Allowlist entries must be exact enough that moving the finding or changing the text reopens the finding.

Acceptance criteria:

- Linter reports current issues clearly.
- Linter can run in advisory mode first, then strict mode later.
- Linter does not require external dependencies.
- Known current findings can be allowlisted so Phase 1 can land without forcing behavior edits.
- The `ambiguous` check does not produce known false positives for descriptive, non-hedge usage.

### Step 7: Add Safety Regression Tests (`DUR-1`)

Create policy fixture tests asserting that these rules exist and remain wired:

- no direct trunk commit rule exists
- workers require explicit file scope
- planner cannot write files
- orchestrator cannot implement product changes
- PR opening requires validation pass or no validation commands defined
- validation blocked state blocks PR
- monitor cannot claim active without real monitor startup
- review remediation must commit, push, and reply before resolve

Acceptance criteria:

- Tests verify presence and linkage of rules.
- Tests fail if canonical rule text or references disappear.
- Tests do not attempt to simulate Claude behavior yet.

### Step 8: Add Plugin Compatibility Tests (`DUR-2`)

Checks:

- `plugin/.claude-plugin/plugin.json` has required fields.
- `.claude-plugin/marketplace.json` references the plugin correctly.
- Agent frontmatter has valid `name`, `description`, `model`, and `tools`.
- Skill frontmatter has valid `name`, `description`, `allowed-tools`, and `shell`.
- README skill names match actual skill directories.
- README agent names match actual agent files.
- Unsupported fields listed in README do not appear in agent frontmatter.
- `plugin/governance/AGENTS.template.md` exists and README points to it.
- `docs/planning/` files are not referenced as active governance from plugin agents or skills.

Acceptance criteria:

- Tests detect broken namespaced invocations.
- Tests detect stale README tables.
- Tests detect missing skill or agent files.

### Step 9: Wire Documentation References

Update root-level documentation, if needed, to distinguish runtime plugin governance from planning artifacts:

- `plugin/governance/` remains the active runtime governance directory.
- `docs/planning/` contains advisory planning material and implementation backlog documents.
- README references `plugin/governance/AGENTS.template.md` as the project-level Codex reviewer template (required by Steps 6 and 8 validation).

Do not rewrite the main workflow yet.

Acceptance criteria:

- New docs are discoverable.
- New docs are not listed in the active `plugin/governance/` table unless they are promoted and referenced by agents.
- README still reflects current install and setup flow.
- README contains a reference to `plugin/governance/AGENTS.template.md` consistent with what REL-1 (Step 6) and DUR-2 (Step 8) compatibility checks validate.

### Recommended Phase 1 PR Boundary

One PR should:

- Add docs, fixtures, and local validation tooling.
- Avoid changing workflow semantics.
- Document known existing lint findings as expected failures or advisory warnings.
- Keep all new planning docs, tooling, and tests outside `plugin/`.

### Done When

- `./tools/policy_check.ps1` runs locally.
- Report validator fixtures prove pass/fail behavior.
- Plugin compatibility checks pass.
- Safety regression checks exist for core invariants.
- Current framework contradictions are visible as lint findings instead of hidden in prose.
- The PR states no version bump is required because `plugin/` runtime payload is unchanged.

---

## Phase 2 Implementation Plan

### Phase 2 Goal

Phase 2 assigns stable rule IDs to every safety rule inventoried in Phase 1, builds a machine-readable policy index mapping each rule ID to its canonical source and consumers, ensures every safety gate has exactly one owner and one test fixture, then performs the structural separation of policy from procedure — splitting `agent-system-policy.md` into focused modules and adding compact checklists to skills. No safety rule may be weakened. Phase 1 safety checks (`tools/policy_check.ps1`) must pass before and after every structural change.

### Phase 2 Scope

1. **TC-2 (Step 9)**: Assign stable rule IDs to the rules in `docs/planning/rule-index-draft.md`. IDs appear in the planning index and skill checklists only; governance prose embedding deferred to Phase 5 (CPX-3).
2. **CPX-5 (Step 10)**: Create `docs/planning/policy-index.json` mapping every rule ID to canonical source, owner, consumers, and test fixture.
3. **REL-5 (Step 11)**: Fill coverage gaps in `tests/policy/` so every rule ID has one fixture.
4. **CPX-1 Step 12a**: Classify every governance section as Policy, Procedure, Ownership, or Definition. Create `docs/planning/policy-procedure-ownership-map.md`. No `plugin/` changes.
5. **CPX-1 Steps 12b–12c**: Extract procedure duplication (conservative) and verify agent ownership boundaries. Touches `plugin/`.
6. **TC-5 (Step 13)**: Split `plugin/governance/agent-system-policy.md` into `<domain>-policy.md` modules. Definitions section stays in core file to preserve all existing `(Definitions → ...)` cross-references.
7. **TC-4 (Step 14)**: Add compact `## Quick Reference` checklists to all 7 skill files. Lands in same PR as Step 13.

### Phase 2 Versioning

Steps 9–11 and 12a touch only `docs/planning/` and `tests/policy/`. No version bump required.

Steps 12b–12c, 13, and 14 modify files inside `plugin/`. Internal restructuring with updated cross-references constitutes documented consumer expectations within the plugin. Bump type: **PATCH**. Each plugin-touching PR gets its own increment.

Canonical version file: `plugin/.claude-plugin/plugin.json`.

### Phase 2 PR Boundary

| PR | Steps | Touches `plugin/` | Version bump |
|---|---|---|---|
| PR A | 9, 10, 11, 12a | No | None |
| PR B | 12b, 12c | Yes | `0.2.1 → 0.2.2` |
| PR C | 13, 14 | Yes | `0.2.2 → 0.2.3` |

Phase 1 safety checks must pass before each PR is opened.

### Step 9: Assign Rule IDs (TC-2)

Modify:

- `docs/planning/rule-index-draft.md` — replace `TBD` values in `Future Rule ID` column; add ID scheme section.

**ID scheme:** `<DOMAIN>-<NN>` — uppercase domain token plus zero-padded two-digit number. Domain identifies the governing concern, not the source file, so IDs remain stable across file moves.

**First-draft rule ID list:**

| Descriptive Rule Name | Rule ID |
|---|---|
| No trunk commits | `GIT-01` |
| Required git preflight | `GIT-02` |
| Explicit file scope | `SCOPE-01` |
| No silent scope expansion | `SCOPE-02` |
| Planner-first / default planning | `PLAN-01` |
| Validation gate | `VAL-01` |
| PR only after validation | `VAL-02` |
| Blocked report contract | `REPORT-01` |
| Monitor truthfulness | `MON-01` |
| Review remediation ownership | `REVIEW-01` |

Acceptance criteria:

- Every row has a stable rule ID with no `TBD` entries.
- IDs follow `<DOMAIN>-<NN>` format consistently.
- No two rules share an ID.
- ID scheme section is added to the rule index.
- `tools/policy_check.ps1` passes.

### Step 10: Policy Index (CPX-5)

Create:

- `docs/planning/policy-index.json`

Modify:

- `docs/planning/rule-index-draft.md` — add cross-reference to `policy-index.json`.

**Schema per entry:**

```json
{
  "ruleId": "GIT-01",
  "name": "No trunk commits",
  "source": {
    "file": "plugin/governance/branching-pr-workflow.md",
    "section": "Hard Rules",
    "pattern": "Never commit directly to trunk"
  },
  "owner": "orchestrator",
  "consumers": [
    {
      "file": "plugin/agents/orchestrator.md",
      "referenceType": "enforces",
      "pattern": "no trunk commits"
    }
  ],
  "testFixture": "tests/policy/safety-no-trunk-commit.json"
}
```

`referenceType` values: `enforces`, `depends-on`, `duplicates`. `testFixture` is `null` where Step 11 must add coverage.

Acceptance criteria:

- `policy-index.json` parses as valid JSON.
- Every rule ID from Step 9 appears exactly once.
- Every consumer file exists under `plugin/`.
- Every non-null `testFixture` names an existing file under `tests/policy/`.
- Index is consistent with existing safety fixtures.
- `tools/policy_check.ps1` passes.

### Step 11: Safety Gate Ownership (REL-5)

Audit all 8 existing `tests/policy/safety-*.json` fixtures and map each to a rule ID.

Create new fixtures for gaps identified in `policy-index.json` (where `testFixture` is `null`). Known gaps to investigate:

- `GIT-02` (required git preflight) — no current fixture.
- `SCOPE-02` (no silent scope expansion) — may need a distinct fixture from `SCOPE-01`.
- `PLAN-01` (planner-first routing rule) — existing `safety-planner-no-write.json` tests tool restrictions, not the routing rule itself.
- `REPORT-01` (blocked report contract) — verify current coverage.

Modify:

- `docs/planning/policy-index.json` — fill in `testFixture` fields after fixtures are created.

Acceptance criteria:

- Every rule ID in `policy-index.json` has a non-null `testFixture`.
- Every fixture exists and parses as valid JSON.
- Every fixture's `source.pattern` matches text in its source file.
- Every consumer `pattern` matches or is confirmed absent via `"absent": true`.
- `tools/policy_check.ps1` passes.

### Step 12a: Classify Governance Sections (CPX-1, part 1)

Create:

- `docs/planning/policy-procedure-ownership-map.md`

Classify every top-level section of every governance file as:

- **Policy** — invariant/constraint (must always be true)
- **Procedure** — how to do something (step-by-step, command sequences)
- **Ownership** — who owns what (authority, delegation)
- **Definition** — shared vocabulary
- **Mixed** — multiple concerns; note the sub-tags

Source files to classify:

- `plugin/governance/agent-system-policy.md`
- `plugin/governance/branching-pr-workflow.md`
- `plugin/governance/pr-review-remediation-loop.md`
- `plugin/governance/versioning.md`

Acceptance criteria:

- Every section of every governance file appears in the map.
- Each section has exactly one classification or `Mixed` with sub-tags.
- Map identifies sections confirmed to be duplicated in a skill file.
- No `plugin/` files modified.

### Step 12b: Extract Procedure Duplication (CPX-1, part 2)

Modify conservatively — only sections confirmed duplicated in a skill file per the Step 12a map:

- `plugin/governance/agent-system-policy.md`
- `plugin/governance/branching-pr-workflow.md` (if applicable)
- `plugin/governance/pr-review-remediation-loop.md` (if applicable)

The following section headers are referenced by name from multiple consumers. Update all cross-references atomically in the same commit as any section move:

- `(Definitions → Validation procedure)` — referenced from 6 files
- `(Shared Worker Report Contract)` and `(Blocked Report Contract)` — referenced from 8 files
- `(Explicit Scope Rule)` — referenced from agents and skills

Acceptance criteria:

- No governance file contains step-by-step procedures already present in a skill file.
- All cross-references use `${CLAUDE_PLUGIN_ROOT}/...` paths.
- All safety fixture patterns still match.
- `tools/policy_check.ps1` passes.

### Step 12c: Verify Agent Ownership Boundaries (CPX-1, part 3)

Verify each agent's `Own` section and prohibitions are consistent with the Authority Matrix in `agent-system-policy.md`. No new ownership rules invented. Modify only if gaps or contradictions are found:

- `plugin/agents/orchestrator.md`
- `plugin/agents/planner.md`
- `plugin/agents/coder.md`
- `plugin/agents/designer.md`

Acceptance criteria:

- Every cell in the Authority Matrix maps to an explicit statement in the corresponding agent file.
- No agent file claims ownership contradicting the Authority Matrix.
- `tools/policy_check.ps1` passes.

### Step 13: Split agent-system-policy.md (TC-5)

Reduce:

- `plugin/governance/agent-system-policy.md` — keep only Definitions, topology, authority, and role boundaries.

Create:

| New file | Content moved into it |
|---|---|
| `plugin/governance/scope-policy.md` | Explicit Scope Rule, Accessibility Ownership Split |
| `plugin/governance/git-policy.md` | Git Workflow Enforcement |
| `plugin/governance/validation-policy.md` | Versioning/review enforcement sections |
| `plugin/governance/monitoring-policy.md` | Monitoring Policy, Shell and Parser Policy, Retry and Failure Policy |
| `plugin/governance/escalation-policy.md` | Escalation Rules |
| `plugin/governance/communication-policy.md` | Communication Standard, Shared Worker Report Contract, Blocked Report Contract |

Definitions stay in `agent-system-policy.md`. All `(Definitions → ...)` cross-references remain valid and need no changes.

Update cross-references in agent and skill files for moved sections. Example: `agent-system-policy.md (Monitoring Policy)` becomes `${CLAUDE_PLUGIN_ROOT}/governance/monitoring-policy.md`.

Acceptance criteria:

- `agent-system-policy.md` contains only core definitions, topology, authority, and role boundaries.
- Each new module file has a `## Purpose` section.
- Every cross-reference in every agent and skill file resolves to the correct module.
- All references use `${CLAUDE_PLUGIN_ROOT}/...` paths.
- All `tests/policy/safety-*.json` patterns still match (update `source.file` fields in fixtures if needed).
- `tools/policy_check.ps1` passes.
- No content is lost — every section present before the split appears in the result.

### Step 14: Compact Skill Checklists (TC-4)

Add a `## Quick Reference` section immediately after the YAML frontmatter closing `---` and before the existing skill body in all 7 skill files:

- `plugin/skills/checkpoint-commit/SKILL.md`
- `plugin/skills/create-working-branch/SKILL.md`
- `plugin/skills/open-plan-pr/SKILL.md`
- `plugin/skills/request-codex-review/SKILL.md`
- `plugin/skills/address-pr-feedback/SKILL.md`
- `plugin/skills/watch-pr-feedback/SKILL.md`
- `plugin/skills/setup-project/SKILL.md`

**Format example (checkpoint-commit):**

```markdown
## Quick Reference

Rules: `GIT-01` (no trunk commits), `GIT-02` (git preflight), `VAL-01` (validation gate)

Before:
- [ ] Current branch is not trunk
- [ ] Git state is not unsafe
- [ ] Files belong to completed phase or milestone

After:
- [ ] Commit message follows `<type>(<scope>): <subject>` format
- [ ] No unrelated files included
- [ ] No push, no PR, no branch creation
```

Acceptance criteria:

- Every skill has a `## Quick Reference` section immediately after frontmatter.
- Every rule ID referenced exists in `docs/planning/rule-index-draft.md`.
- Checklists introduce no new rules and do not modify existing rule semantics.
- No checklist exceeds 10 items.
- `tools/policy_check.ps1` passes.

### Phase 2 Done When

- Every safety rule has a stable rule ID in `docs/planning/rule-index-draft.md`.
- `docs/planning/policy-index.json` exists, parses as valid JSON, and maps every rule ID to source, owner, consumers, and test fixture.
- Every rule ID has a corresponding `tests/policy/safety-*.json` fixture with passing assertions.
- `docs/planning/policy-procedure-ownership-map.md` classifies every governance section.
- `plugin/governance/agent-system-policy.md` is split into focused `<domain>-policy.md` modules with no content loss.
- Every cross-reference in `plugin/` uses `${CLAUDE_PLUGIN_ROOT}/...` paths and resolves to an existing file and section.
- Every skill has a compact `## Quick Reference` checklist referencing canonical rule IDs.
- `tools/policy_check.ps1` passes after every PR lands.
- All `tests/policy/safety-*.json` patterns match their source files.
- Plugin version reflects structural changes: `0.2.2` after PR B, `0.2.3` after PR C.

---

## Phase 3 Implementation Plan

### Phase 3 Goal

Phase 3 improves routing clarity and workflow shape. It creates a routing matrix mapping user intent to skill/agent selection, collapses scattered review remediation routing into one canonical decision table, converts git preflight checks into explicit command recipes with expected outputs, and adds explicit "no PR requested" and "no review requested" workflow branches. No safety rule may be weakened. Phase 1 safety checks (`tools/policy_check.ps1`) must pass before and after every structural change.

### Phase 3 Scope

1. **CLR-2 (Step 15)**: Routing matrix from user intent to skill/agent.
2. **CPX-2 (Step 16)**: Collapse review remediation routing into one canonical decision table.
3. **REL-3 (Step 17)**: Git preflight as command recipes with expected outputs.
4. **EFF-3 (Step 18)**: Explicit "no PR requested" and "no review requested" workflow branches.

Excluded: EFF-2 (Step 19) is deferred to Phase 4. See Deferred Items table.

### Phase 3 Versioning

Steps 15–16 (PR A): Step 15 creates a planning doc in `docs/planning/`, no bump on its own. Step 16 modifies `plugin/governance/pr-review-remediation-loop.md` and updates cross-references in `plugin/agents/orchestrator.md`. This is the first Phase 3 PR touching `plugin/` and carries the version catch-up bump: `0.2.1 → 0.2.4`. The catch-up accounts for two Phase 2 plugin/ PRs that landed without bumping (PR B at `0.2.2` and PR C at `0.2.3` were planned but the version file was not updated) plus one Phase 3 PATCH increment.

Steps 17–18 (PR B): Both steps modify files inside `plugin/`. Bump type: PATCH. Version: `0.2.4 → 0.2.5`.

Canonical version file: `plugin/.claude-plugin/plugin.json`.

### Phase 3 PR Boundary

| PR | Steps | Touches `plugin/` | Version bump |
|---|---|---|---|
| PR A | 15, 16 | Yes (Step 16) | `0.2.1 → 0.2.4` (catch-up) |
| PR B | 17, 18 | Yes | `0.2.4 → 0.2.5` |

Phase 1 safety checks must pass before each PR is opened.

### Step 15: Routing Matrix (CLR-2)

Create:

- `docs/planning/routing-matrix.md`

Modify:

- `docs/planning/execution-state-machine.md` — add cross-reference to routing matrix in the Intake state section.

**Content of routing matrix:**

The matrix maps user intent patterns to the correct skill or agent. It consolidates routing logic currently distributed across:

- `plugin/agents/orchestrator.md` Skill Routing section
- `plugin/agents/orchestrator.md` Execution Algorithm steps 14–15
- `plugin/governance/pr-review-remediation-loop.md` Routing section
- `plugin/governance/pr-review-remediation-loop.md` Skill Selection section

**Matrix structure:**

```markdown
| User Intent Pattern | Target | Selection Rule | Source |
|---|---|---|---|
| [intent description or keyword pattern] | [skill or agent name] | [condition that selects this target] | [canonical source file and section] |
```

**Rows to include (derive from current sources):**

1. Task requires planning → `agent-framework:planner` (Planner-First Rule)
2. Task meets all six planner-skip conditions → orchestrator handles directly (Trivial Fast Path)
3. Implementation work → `agent-framework:coder` or `agent-framework:designer` (delegation by file type/role)
4. Branch creation needed → `agent-framework:create-working-branch` (Skill Routing item 1)
5. Phase/milestone/version complete → `agent-framework:checkpoint-commit` (Skill Routing item 2)
6. Plan complete, validation passed → `agent-framework:open-plan-pr` (Skill Routing item 3)
7. User says `review`/`codex`/`audit` or project requires review → `agent-framework:request-codex-review` (Skill Routing item 4)
8. User says `watch`/`monitor`/`wait`/`poll`/`loop` for PR feedback → `agent-framework:watch-pr-feedback` (Skill Selection)
9. PR feedback fix (no watch keywords) → `agent-framework:address-pr-feedback` (Skill Selection)
10. Remediation routing: `actionable-code-change`/`actionable-test-change`/`actionable-doc-change` → `coder` (Routing)
11. Remediation routing: `design-or-UX-concern` → `designer` (Routing)
12. Remediation routing: `architecture-or-contract-concern`/`version-or-release-concern`/cross-step fix → `planner` (Routing)
13. Remediation routing: product/API/security/compatibility/release decision → user (Routing)

**Additional sections:**

- Selection priority order (matching the orchestrator's "most specific first" list)
- Conflict resolution: when multiple rows match, which wins
- Cross-reference to `docs/planning/execution-state-machine.md` states

Acceptance criteria:

- Every skill in the orchestrator's Skill Routing section has at least one row in the matrix.
- Every agent delegation path has at least one row.
- Every remediation routing target in `pr-review-remediation-loop.md` (Routing) has a row.
- The matrix is consistent with the execution state machine transitions.
- No new routing rules are introduced; the matrix documents existing behavior.
- The document is marked as planning/advisory material (not active governance).
- `tools/policy_check.ps1` passes.

### Step 16: Canonical Remediation Decision Table (CPX-2)

Modify:

- `plugin/governance/pr-review-remediation-loop.md` — replace the separate Classification, Routing, and Skill Selection sections with a single unified Remediation Decision Table.
- `plugin/agents/orchestrator.md` — simplify Execution Algorithm step 15 cross-reference to reference `(Remediation Decision Table)` instead of `(Classification)`.
- `plugin/.claude-plugin/plugin.json` — bump version from `0.2.1` to `0.2.4`.

**Decision table structure:**

Replace the current three separate sections (Classification list, Routing list, Skill Selection) with one table under a new `## Remediation Decision Table` section:

| Classification | Worker | Skill | Escalate to |
|---|---|---|---|
| `actionable-code-change` | `coder` | `address-pr-feedback` / `watch-pr-feedback` | — |
| `actionable-test-change` | `coder` | `address-pr-feedback` / `watch-pr-feedback` | — |
| `actionable-doc-change` | `coder` | `address-pr-feedback` / `watch-pr-feedback` | — |
| `architecture-or-contract-concern` | — | — | `planner` (then `coder`) |
| `design-or-UX-concern` | `designer` | `address-pr-feedback` / `watch-pr-feedback` | — |
| `version-or-release-concern` | — | — | `planner` (then `coder`) |
| `question-needs-user-input` | — | — | user |
| `non-actionable` | — | — | — (reply only) |
| `incorrect-or-rejected` | — | — | — (reply with rationale) |

The `Skill` column value depends on user-request keywords (`watch`/`monitor`/`wait`/`poll`/`loop` selects `watch-pr-feedback`; otherwise `address-pr-feedback`). This keyword rule is stated once in the table footnote, not repeated.

**What moves and what stays:**

- Classification values list: stays as a standalone enumeration above the table (the table references these values).
- Routing section: content absorbed into the Worker and Escalate columns of the decision table. Section removed.
- Skill Selection section: content absorbed into the Skill column and keyword footnote. Section removed.
- Fix Rules, Rejected Feedback, Re-review, Stop Conditions, Thread Resolution Rule, Remediation Ledger: unchanged.

Acceptance criteria:

- Unified decision table contains every classification value from the current Classification list.
- Every routing target from the current Routing section appears in Worker or Escalate column.
- Every skill selection rule from the current Skill Selection section appears in Skill column or footnote.
- No classification value, routing target, or skill selection rule is lost.
- Routing section and Skill Selection section are removed (content in the table).
- Orchestrator Execution Algorithm step 15 references `(Remediation Decision Table)`.
- All cross-references use `${CLAUDE_PLUGIN_ROOT}/...` paths.
- All `tests/policy/safety-*.json` patterns still match.
- `docs/planning/policy-index.json` entry for `REVIEW-01` is updated if its `source.section` changed.
- `plugin/.claude-plugin/plugin.json` version is `0.2.4`.
- `tools/policy_check.ps1` passes.

### Step 17: Git Preflight Command Recipes (REL-3)

Modify:

- `plugin/governance/branching-pr-workflow.md` — expand the Required Git Preflight section with concrete command recipes and expected outputs for each of the seven preflight items, plus a safe git state check subsection.
- `docs/planning/execution-state-machine.md` — add cross-reference from the Git Preflight state to the new command recipes subsection.

**Command recipes structure (additive subsection after the existing seven-item list):**

```markdown
### Preflight Command Recipes

Each preflight item below includes the resolution command and the expected output shape. The orchestrator runs these commands (or equivalent) to establish preflight values. If any command fails or returns an unexpected shape, the item is undefined and implementation must not begin.
```

| Preflight Item | Command | Expected Output |
|---|---|---|
| Work classification | (determined from plan or user input) | One of: `feature\|bugfix\|hotfix\|refactor\|chore\|docs\|test\|ci` |
| Base branch | `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` | Branch name string (e.g., `main`) — unless overridden by user or `CLAUDE.md` |
| Working branch name | (constructed from classification + topic per Branch Taxonomy) | `<prefix>/<topic>` matching naming constraints |
| Branch exists vs create | `git branch --list <working-branch-name>` and `git ls-remote --heads origin <working-branch-name>` | Empty = create; non-empty = exists |
| Worktree decision | (determined from plan parallelism requirements) | `yes` or `no` |
| Checkpoint commit policy | (derived from plan phase count and risk flags) | One of: `none\|checkpoint allowed\|checkpoint expected` |
| PR target | Same as base branch resolution | Branch name string |

Safe git state check subsection:

| Check | Command | Pass condition |
|---|---|---|
| Not on trunk | `git branch --show-current` | Output is not the resolved trunk branch |
| Clean working tree | `git status --porcelain` | Empty output or only expected changes |
| No detached HEAD | `git symbolic-ref HEAD` | Exits 0 |
| Remote reachable | `git ls-remote --exit-code origin HEAD` | Exits 0 |

Acceptance criteria:

- Every one of the seven Required Git Preflight items has a command recipe with expected output.
- Safe git state check covers conditions in the "Unsafe git state" definition.
- Command recipes use only read-only git/gh commands.
- The existing seven-item list is unchanged; recipes are an additive subsection.
- The execution state machine Git Preflight state cross-references the recipes.
- All existing cross-references to `(Required Git Preflight)` continue to resolve (header not renamed).
- All `tests/policy/safety-*.json` patterns still match.
- `tools/policy_check.ps1` passes.

### Step 18: Explicit No-PR and No-Review Workflow Branches (EFF-3)

Modify:

- `plugin/agents/orchestrator.md` — update Execution Algorithm steps 14–15 and Final Report to handle explicit "no PR requested" and "no review requested" branches.
- `docs/planning/execution-state-machine.md` — add transitions for no-PR and no-review paths in the PR and External Review states.
- `plugin/.claude-plugin/plugin.json` — bump version from `0.2.4` to `0.2.5`.

**Changes to Execution Algorithm step 14:**

Current text: "Open PR when the approved plan is complete."

New text:

```text
14. If the user explicitly requested no PR (task input contains "no PR", "skip PR", "don't open PR", or equivalent), skip PR opening. Proceed to final report with `PR: not opened (user opted out)`. All other gates (validation, version bump, scope check) still apply.
    Otherwise, open PR when the approved plan is complete.
```

**Changes to Execution Algorithm step 15:**

After the existing condition text, add:

```text
    If neither (a) nor (b) is true, skip external review. Proceed to final report with `Review: not requested`. This is the default — external review is opt-in.
```

**Changes to Final Report template:** Document new opt-out field values:
- `PR: not opened (user opted out)`
- `Review: not requested`

**Changes to execution-state-machine.md:** Add no-PR transition to PR state and note no-review as explicit default in External Review state.

Acceptance criteria:

- Execution Algorithm step 14 explicitly handles "no PR requested" opt-out.
- Execution Algorithm step 15 explicitly handles "no review requested" as the default path.
- No safety gate is bypassed by opt-out — validation, scope, version bump still run.
- Final Report template supports new field values.
- Execution state machine PR state includes no-PR transition to Final Report.
- All `tests/policy/safety-*.json` patterns still match.
- `plugin/.claude-plugin/plugin.json` version is `0.2.5`.
- `tools/policy_check.ps1` passes.

### Phase 3 Done When

- `docs/planning/routing-matrix.md` exists and maps every skill and agent delegation path to user intent patterns.
- `plugin/governance/pr-review-remediation-loop.md` contains a single Remediation Decision Table covering all classification, routing, and skill selection logic.
- The separate Routing and Skill Selection sections in `pr-review-remediation-loop.md` are removed (content consolidated into the table).
- `plugin/governance/branching-pr-workflow.md` Required Git Preflight section includes command recipes with expected outputs for all seven preflight items plus a safe git state check.
- `plugin/agents/orchestrator.md` Execution Algorithm explicitly handles "no PR requested" and "no review requested" workflow branches.
- `docs/planning/execution-state-machine.md` transitions updated for no-PR and no-review paths and cross-reference the preflight recipes.
- All cross-references in `plugin/` use `${CLAUDE_PLUGIN_ROOT}/...` paths and resolve to existing files and sections.
- `tools/policy_check.ps1` passes after every PR lands.
- All `tests/policy/safety-*.json` patterns match their source files.
- Plugin version reflects changes: `0.2.4` after PR A, `0.2.5` after PR B.
