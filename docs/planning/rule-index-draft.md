# Rule Ownership Index -- DRAFT

Machine-readable index: `docs/planning/policy-index.json`

Status: Phase 1 draft -- establishes structure only. Phase 2 assigns rule IDs.

Tracking: DUR-4

## Purpose

Canonical index of the ten core safety rules in the agent framework. Each rule maps to exactly one source file, lists every known consumer (agent or skill that depends on it), and reserves a column for the formal Rule ID to be assigned in Phase 2.

## Index

| Descriptive Rule Name | Future Rule ID | Source | Owner | Consumers | Test Coverage | Notes |
|---|---|---|---|---|---|---|
| No trunk commits | `GIT-01` | `plugin/governance/branching-pr-workflow.md` (Hard Rules 1-3) | orchestrator | orchestrator, coder, designer, create-working-branch, checkpoint-commit, open-plan-pr | planned | Hard Rules 1-3: never commit/push directly to trunk; develop on non-trunk branch. Workers enforce via Hard Stop Rules referencing git preflight. |
| Explicit file scope | `SCOPE-01` | `plugin/governance/agent-system-policy.md` (Explicit Scope Rule) | orchestrator | orchestrator, planner, coder, designer | planned | Modifying agents work only in explicitly assigned files. Violations block phase verification. Coder/designer Hard Stop Rules enforce the boundary. |
| Planner-first / default planning | `PLAN-01` | `plugin/agents/orchestrator.md` (Planner-First Rule) | orchestrator | orchestrator, planner | planned | Planner must be called before delegation/branch creation/implementation unless all six skip conditions are met. Skip decision must be stated explicitly. |
| Required git preflight | `GIT-02` | `plugin/governance/branching-pr-workflow.md` (Required Git Preflight) | orchestrator | orchestrator, coder, designer, create-working-branch | planned | Seven items must be defined before implementation begins. Undefined items block implementation. Coder/designer Hard Stop Rules independently enforce this. |
| Validation gate | `VAL-01` | `plugin/governance/agent-system-policy.md` (Definitions -- Validation procedure) | orchestrator | orchestrator, coder, designer, open-plan-pr, checkpoint-commit, address-pr-feedback, watch-pr-feedback | planned | Validation must run every declared command. Cannot skip silently. PR and merge readiness depend on validation passing or being explicitly reported. |
| Blocked report contract | `REPORT-01` | `plugin/governance/agent-system-policy.md` (Blocked Report Contract) | orchestrator | orchestrator, planner, coder, designer, all skills | planned | Standardized blocked-state reporting format. Required whenever planning, execution, validation, git, versioning, review, monitoring, or skill selection is blocked. |
| No silent scope expansion | `SCOPE-02` | `plugin/governance/agent-system-policy.md` (Explicit Scope Rule) | orchestrator | coder, designer | planned | If a file outside assigned scope is needed, agents must stop, report the file, explain why, and wait for reassignment. Reinforced in coder and designer Hard Stop Rules. |
| PR only after validation | `VAL-02` | `plugin/governance/branching-pr-workflow.md` (Pull Requests) | orchestrator | orchestrator, open-plan-pr | planned | PR may be opened only when approved plan is complete, validation passed (or "Not run" with no commands defined), outputs are in scope, and version metadata is included. |
| Monitor truthfulness | `MON-01` | `plugin/governance/agent-system-policy.md` (Monitoring Policy) | orchestrator | orchestrator, watch-pr-feedback | planned | Must not claim monitoring is active unless a real background mechanism started successfully and first poll completed without parser error. Covers Monitoring Policy and orchestrator Hard Prohibitions. |
| Review remediation ownership | `REVIEW-01` | `plugin/governance/pr-review-remediation-loop.md` (Ownership) | orchestrator | orchestrator, coder, designer, planner, address-pr-feedback, watch-pr-feedback | planned | Orchestrator owns the full loop: classify, route, verify, reply, resolve, re-review, stop. Workers remediate within scope but do not reply/resolve. Planner is invoked for cross-step or architecture concerns. |

## Rule ID Scheme

Format: `<DOMAIN>-<NN>`

- `DOMAIN` is an uppercase token identifying the governing concern (not the source file).
- `NN` is a zero-padded two-digit number.
- IDs are stable across file moves and merges.
- Reserve `01`–`09` per domain initially; extend to three digits if a domain exceeds 99 rules.

Domains in use:

| Domain | Concern |
|---|---|
| `GIT` | Git workflow enforcement |
| `SCOPE` | File scope enforcement |
| `PLAN` | Planning workflow |
| `VAL` | Validation gates |
| `REPORT` | Report contracts |
| `MON` | Monitoring policy |
| `REVIEW` | Review remediation |

## Column Definitions

- **Descriptive Rule Name**: Human-readable name for the safety rule.
- **Future Rule ID**: Formal identifier to be assigned in Phase 2 (all TBD in this draft).
- **Source**: Repo-relative path to the canonical file and section where the rule is defined.
- **Owner**: The agent that owns enforcement of the rule.
- **Consumers**: Agents and skills that depend on or enforce the rule.
- **Test Coverage**: Current test coverage status (all "planned" in Phase 1).
- **Notes**: Brief description of rule scope, enforcement mechanism, and cross-references.

## Methodology

Sources were identified by reading the canonical governance and agent files:

1. `plugin/governance/agent-system-policy.md` -- cross-agent policy definitions, scope rule, blocked contract, monitoring policy
2. `plugin/governance/branching-pr-workflow.md` -- branching hard rules, git preflight, PR gates, commit policy
3. `plugin/governance/pr-review-remediation-loop.md` -- review loop ownership, classification, routing, stop conditions
4. `plugin/agents/orchestrator.md` -- planner-first rule, git preflight enforcement, execution algorithm, delegation

Consumers were identified by tracing which agent files (`orchestrator.md`, `planner.md`, `coder.md`, `designer.md`) and skill files reference each rule via governance cross-references or embed equivalent Hard Stop Rules.
