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

## Improvement Backlog

`Depends on` means "best done after." It is not always a hard blocker.

### Token Consumption

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| TC-1 | Create a short always-loaded core contract; move long workflow detail behind workflow-specific references. | 3 | 5 | CPX-1 |
| TC-2 | Replace repeated prose with named rule IDs, e.g. `GIT-PREFLIGHT-01`, `VALIDATION-01`. | 3 | 5 | DUR-4 |
| TC-3 | Generate agent files from canonical governance fragments. | 4 | 4 | TC-2 |
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
| EFF-1 | Add a safe fast path for trivial single-file changes while preserving branch preflight, scope, validation, and final report. | 3 | 5 | REL-2 |
| EFF-2 | Let planner return `Workflow loadout:` naming only required governance modules. | 3 | 4 | TC-5 |
| EFF-3 | Add explicit "no PR requested" and "no review requested" workflow branches. | 2 | 4 | CLR-1 |
| EFF-4 | Batch validation and git checks at phase boundaries instead of repeating nearby checks. | 3 | 3 | REL-3 |
| EFF-5 | Define remediation batching rules for same owner, same files, same validation path. | 4 | 4 | CPX-2 |

### Clarity

| ID | Enhancement | Difficulty | Value | Depends on |
|---|---|---:|---:|---|
| CLR-1 | Add a one-page execution state machine: Intake -> Plan -> Preflight -> Branch -> Implement -> Validate -> Commit -> PR -> Review. | 2 | 5 | None |
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
| PERF-1 | Use lower-cost models only for low-risk paths; keep strongest models for architecture, versioning, review remediation, multi-file work. | 2 | 4 | EFF-1 |
| PERF-2 | Add bounded discovery commands for planner: file map first, targeted reads second. | 2 | 4 | CLR-1 |
| PERF-3 | Cache resolved repo facts in session reports: trunk, validation commands, artifact paths, review policy. | 3 | 4 | REL-3 |
| PERF-4 | Make GitHub review fetching incremental using seen IDs in the session ledger. | 4 | 3 | CPX-2 |
| PERF-5 | Add validation tiers in `CLAUDE.md`: required quick checks before commit, full checks before PR/merge. | 4 | 4 | REL-5 |

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

### Phase 2: Canonicalize The Policy Surface

| Order | ID | Why Now |
|---:|---|---|
| 8 | TC-2 | Rule IDs reduce repeated prose and make rules easier to reference precisely. |
| 9 | CPX-5 | Policy index maps rule IDs to source and consumers, preventing drift. |
| 10 | REL-5 | Every safety gate gets one owner, canonical definition, and test fixture. |
| 11 | CPX-1 | Separates invariants from procedures and agent ownership. |
| 12 | TC-5 | Splits the large policy file into modules after ownership/source mapping is clear. |
| 13 | TC-4 | Adds compact skill checklists that reference canonical rules without weakening them. |

### Phase 3: Improve Routing And Workflow Shape

| Order | ID | Why Now |
|---:|---|---|
| 14 | CLR-2 | A routing matrix makes skill/agent selection clearer and easier to lint. |
| 15 | CPX-2 | Collapses review remediation routing into one canonical decision table. |
| 16 | REL-3 | Turns git preflight into command recipes with expected outputs. |
| 17 | EFF-3 | Makes "no PR requested" and "no review requested" explicit. |
| 18 | EFF-2 | Lets planner name exact governance modules needed for the task. |

### Phase 4: Add Safe Efficiency Paths

| Order | ID | Why Now |
|---:|---|---|
| 19 | REL-2 | Golden-path workflow tests prove main scenarios still work. |
| 20 | EFF-1 | Adds a safe trivial fast path while preserving branch, scope, validation, and reporting gates. |
| 21 | PERF-1 | Lower-cost models become safer once fast-path boundaries are tested. |
| 22 | PERF-2 | Bounded planner discovery improves speed without changing governance. |
| 23 | PERF-3 | Caches resolved repo facts to reduce repeated checks and rereads. |

### Phase 5: Reduce Loaded Context And Duplication

| Order | ID | Why Now |
|---:|---|---|
| 24 | TC-1 | Creates the always-loaded core contract after canonical modules and tests exist. |
| 25 | CPX-3 | Removes duplicated unsafe-git/validation wording only after rule IDs and tests protect behavior. |
| 26 | TC-3 | Generates agent files from canonical fragments after the structure stabilizes. |
| 27 | CPX-4 | Makes versioning module activation more targeted while preserving versioning stops. |

### Phase 6: Later Optimizations

| Order | ID | Why Now |
|---:|---|---|
| 28 | EFF-5 | Remediation batching is valuable but risky; wait until routing is canonical and tested. |
| 29 | PERF-5 | Validation tiers can help but need careful semantics to avoid weakening validation. |
| 30 | DUR-5 | Migration notes become important once rule renames or module splits happen. |
| 31 | DUR-3 | Policy changelog is useful but not foundational. Add it alongside the first behavioral refactor. |

### Deferred Items

| ID | Reason |
|---|---|
| CLR-3 | Low difficulty but mostly a rename/reframe. Fold into `EFF-1` later. |
| CLR-5 | Useful but lower value. Add opportunistically if terminology confusion blocks implementation. |
| EFF-4 | Batching validation/git checks risks weakening enforcement. Revisit after validators and tests exist. |
| PERF-4 | Incremental GitHub fetching is lower value relative to difficulty. Optimize after remediation flow is stable. |

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

Do not refactor agent behavior in this phase except where needed to add metadata or examples.

### Step 1: Add Execution State Machine (`CLR-1`)

Create:

- `governance/execution-state-machine.md`

Content:

- Canonical workflow states:
  - Intake
  - Plan
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

### Step 2: Add Report Examples (`CLR-4`)

Create:

- `governance/report-examples.md`

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

### Step 3: Add Rule Ownership Metadata (`DUR-4`)

Create:

- `governance/rule-index.md`

Initial format:

```markdown
| Rule ID | Source | Owner | Consumers | Test Coverage | Notes |
|---|---|---|---|---|---|
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

### Step 4: Add Test And Lint Harness Structure

Create:

- `tools/policy_check.ps1`
- `tools/validate_reports.ps1`
- `tests/policy/`
- `tests/reports/`
- `tests/plugin/`

Keep the harness PowerShell-friendly because the plugin skills declare `shell: powershell`.

Suggested command:

```powershell
./tools/policy_check.ps1
```

Acceptance criteria:

- One command can run all Phase 1 checks.
- Checks are deterministic and local.
- No network or GitHub access is required.

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

- Forbidden contradiction: policy says not to use `ambiguous`, while repo content currently still uses it.
- Required files exist.
- Skill names referenced by orchestrator exist.
- Agent names referenced by orchestrator exist.
- Unsupported plugin frontmatter fields are absent.
- Every governance reference path resolves.
- Every skill has `name`, `description`, `allowed-tools`, and `shell`.

Acceptance criteria:

- Linter reports current issues clearly.
- Linter can run in advisory mode first, then strict mode later.
- Linter does not require external dependencies.
- Known current findings can be allowlisted so Phase 1 can land without forcing behavior edits.

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

- `.claude-plugin/plugin.json` has required fields.
- `.claude-plugin/marketplace.json` references the plugin correctly.
- Agent frontmatter has valid `name`, `description`, `model`, and `tools`.
- Skill frontmatter has valid `name`, `description`, `allowed-tools`, and `shell`.
- README skill names match actual skill directories.
- README agent names match actual agent files.
- Unsupported fields listed in README do not appear in agent frontmatter.

Acceptance criteria:

- Tests detect broken namespaced invocations.
- Tests detect stale README tables.
- Tests detect missing skill or agent files.

### Step 9: Wire Documentation References

Update `README.md` governance table to include:

- `execution-state-machine.md`
- `report-examples.md`
- `rule-index.md`

Do not rewrite the main workflow yet.

Acceptance criteria:

- New docs are discoverable.
- README still reflects current install and setup flow.

### Recommended Phase 1 PR Boundary

One PR should:

- Add docs, fixtures, and local validation tooling.
- Avoid changing workflow semantics.
- Document known existing lint findings as expected failures or advisory warnings.

### Done When

- `./tools/policy_check.ps1` runs locally.
- Report validator fixtures prove pass/fail behavior.
- Plugin compatibility checks pass.
- Safety regression checks exist for core invariants.
- Current framework contradictions are visible as lint findings instead of hidden in prose.
