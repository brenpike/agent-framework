# Policy-Procedure-Ownership Classification Map

Planning artifact. Not active governance. Updated as part of Phase 2 (CPX-1 Step 12a).

## Classification Tags

- **Policy** -- invariant/constraint (must always be true)
- **Procedure** -- how to do something (step-by-step, command sequences)
- **Ownership** -- who owns what (authority, delegation rules)
- **Definition** -- shared vocabulary referenced by policy and procedure
- **Mixed** -- section contains more than one concern; sub-tags listed

## Governance Files

### plugin/governance/agent-system-policy.md

| Section | Level | Classification | Notes |
|---|---|---|---|
| Purpose | H2 | Policy | States what this file is and its invariants |
| Definitions | H2 | Definition | Introduces shared vocabulary block |
| Transient failure | H3 | Definition | Enumerates retryable failure causes |
| Unsafe git state | H3 | Definition | Enumerates unsafe git conditions |
| Trivial change | H3 | Definition | Four-part predicate for low-risk changes |
| Same finding (repeat detection) | H3 | Definition | Match criteria for duplicate review findings |
| Smallest correct fix | H3 | Definition | Constrains fix scope to fewest files/lines |
| Validation procedure | H3 | Mixed (Definition, Procedure) | Defines term and prescribes execution steps |
| Material visual decision | H3 | Definition | Enumerates non-derivable visual choices |
| One-time vs watch routing (PR feedback) | H3 | Mixed (Definition, Procedure) | Defines routing terms and prescribes selection |
| Mandatory Governance Files | H2 | Policy | Lists files agents must always follow |
| Allowed Agent Topology | H2 | Policy | Restricts agent types to four |
| Authority Matrix | H2 | Ownership | Canonical who-owns-what table |
| Role Boundaries | H2 | Ownership | Introduces per-agent boundary rules |
| orchestrator | H3 | Ownership | Orchestrator capabilities and prohibitions |
| planner | H3 | Ownership | Planner capabilities and prohibitions |
| coder | H3 | Ownership | Coder capabilities and prohibitions |
| designer | H3 | Ownership | Designer capabilities and prohibitions |
| Explicit Scope Rule | H2 | Policy | File-scope constraint for modifying agents |
| Accessibility Ownership Split | H2 | Ownership | Designer vs coder accessibility areas |
| Git Workflow Enforcement | H2 | Mixed (Policy, Procedure) | States invariants and lists preflight items |
| Versioning Enforcement | H2 | Mixed (Policy, Ownership) | States bump rules and who owns decisions |
| External Review Policy | H2 | Mixed (Policy, Ownership) | States review rules and skill routing |
| Tool and MCP Policy | H2 | Policy | Per-agent tool allowlist table |
| Shell and Parser Policy | H2 | Policy | Constrains parser/shell behavior |
| Monitoring Policy | H2 | Mixed (Policy, Procedure) | States invariants and prescribes stop behavior |
| Retry and Failure Policy | H2 | Mixed (Policy, Procedure) | States constraints and prescribes retry steps |
| Escalation Rules | H2 | Policy | Enumerates stop-and-report conditions |
| Communication Standard | H2 | Policy | Field-based report format constraint |
| Shared Worker Report Contract | H2 | Mixed (Definition, Procedure) | Defines report format and optional fields |
| Blocked Report Contract | H2 | Definition | Defines blocked report format |

### plugin/governance/branching-pr-workflow.md

| Section | Level | Classification | Notes |
|---|---|---|---|
| Purpose | H2 | Policy | States mandatory scope and unit of work |
| Resolution Order for Branch / Merge / Review Policy | H2 | Procedure | Four-step resolution cascade |
| Framework Defaults | H2 | Definition | Default values when sources 1-3 are silent |
| Hard Rules (apply regardless of resolution source) | H2 | Policy | Four inviolable git constraints |
| Branch Taxonomy | H2 | Definition | Prefix list and naming constraints |
| Plan-to-Branch Mapping | H2 | Policy | One plan = one branch = one PR default |
| Required Git Preflight | H2 | Mixed (Policy, Procedure) | Lists required items and blocks if undefined |
| Branch Creation | H2 | Procedure | When and how to create working branch |
| Commit Policy | H2 | Mixed (Policy, Procedure, Ownership) | Checkpoint rules, commit types, and who commits |
| Version Bumps | H2 | Policy | Points to versioning.md; states PR readiness |
| Pull Requests | H2 | Mixed (Policy, Procedure) | PR preconditions, content rules, forbidden strings |
| External Review Remediation | H2 | Mixed (Policy, Ownership) | Points to loop file; states branch policy |
| Merge Policy | H2 | Mixed (Policy, Procedure) | Merge preconditions and strategy |
| Syncing With Trunk | H2 | Procedure | Rebase vs merge decision and conflict rules |
| Hotfix Standard | H2 | Procedure | Five-step hotfix workflow |
| Worktrees | H2 | Policy | Four conditions required for worktree use |
| Branch Cleanup | H2 | Procedure | Post-merge and post-close branch handling |
| Scope Drift | H2 | Procedure | Three-step scope-change response |

### plugin/governance/pr-review-remediation-loop.md

| Section | Level | Classification | Notes |
|---|---|---|---|
| Purpose | H2 | Policy | States what this file governs |
| Ownership | H2 | Ownership | Orchestrator owns the full loop |
| Entry Criteria | H2 | Policy | Four preconditions to start the loop |
| Feedback Sources | H2 | Definition | Enumerates where feedback is found |
| Classification | H2 | Definition | Nine classification labels |
| Routing | H2 | Mixed (Ownership, Procedure) | Maps classifications to agent owners |
| Fix Rules | H2 | Procedure | Nine-step fix workflow |
| Rejected Feedback | H2 | Procedure | Three-step rejection workflow |
| Re-review | H2 | Mixed (Policy, Procedure) | Four preconditions and default request text |
| Stop Conditions | H2 | Policy | Enumerates loop termination triggers |
| Thread Resolution Rule | H2 | Policy | Four preconditions to resolve a thread |
| Remediation Ledger | H2 | Procedure | Session-local tracking fields |
| Skill Selection | H2 | Mixed (Definition, Procedure) | Defines keyword routing and skill responsibilities |
| Monitoring | H2 | Mixed (Policy, Procedure) | States monitor constraints and fallback |

### plugin/governance/versioning.md

| Section | Level | Classification | Notes |
|---|---|---|---|
| Purpose | H2 | Policy | States SemVer scope |
| Scope | H2 | Policy | Defines which artifacts are versioned |
| SemVer Rules | H2 | Definition | MAJOR/MINOR/PATCH trigger table |
| Bump Trigger | H2 | Mixed (Policy, Definition) | Defines when a bump is required and exemptions |
| Bump Type Determination | H2 | Procedure | Multi-step algorithm for dominant row |
| Bump Execution | H2 | Mixed (Procedure, Ownership) | Orchestrator delegates; lists required artifacts |
| CHANGELOG / Release Notes | H2 | Procedure | Keep a Changelog format and reset template |
| Tags | H2 | Procedure | Tag format and project-defined rules |
| Agent Rules | H2 | Ownership | Per-agent version-editing permissions |

## Duplication Findings

Sections confirmed to have equivalent content in a skill file:

| Governance section | Governance file | Duplicate in skill | Finding |
|---|---|---|---|
| Skill Selection (keyword routing) | pr-review-remediation-loop.md | watch-pr-feedback/SKILL.md (Invocation Boundary) and address-pr-feedback/SKILL.md (Invocation Boundary) restate the same watch-vs-address keyword split | Cross-ref already exists; Mixed content — no extraction |
| Classification | pr-review-remediation-loop.md | address-pr-feedback/SKILL.md (step 3/4) re-applies the same nine-label classification inline | Skill cross-references governance — not a true duplicate |
| Routing | pr-review-remediation-loop.md | address-pr-feedback/SKILL.md (step 5) re-applies the same agent routing rules | Skill cross-references governance — not a true duplicate |
| Monitoring Policy (shell/parser constraints) | agent-system-policy.md | watch-pr-feedback/SKILL.md (Monitor Rules) restates deterministic/bounded/parser-stable constraints and Shell and Parser Policy | Short summary + cross-ref; endorsed isolation pattern |
| Stop Conditions (repeat detection, unsafe git) | pr-review-remediation-loop.md | watch-pr-feedback/SKILL.md (Defaults) restates same-finding, unsafe-git, and question-needs-user-input stop conditions | Skill uses defined terms via cross-ref — not a true duplicate |
| Commit Policy (forbidden strings) | branching-pr-workflow.md | checkpoint-commit/SKILL.md (step 4) references the same forbidden-string list | Skill cross-references governance — not a true duplicate |
| Rejected Feedback | pr-review-remediation-loop.md | address-pr-feedback/SKILL.md (step 3, incorrect-or-rejected rule) restates the rationale-reply and high-severity stop procedure | Skill cross-references + adds skill-specific escalation logic |

**Conclusion (Step 12b):** No pure-procedure duplicates without cross-references found.
Conservative threshold not met for any entry. Zero plugin/ extractions required.
