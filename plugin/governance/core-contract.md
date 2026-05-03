# Core Contract

Always-loaded baseline for all agent-framework agents. Every agent and skill operates under these rules.

## Mandatory Governance

Governance rules are embedded in each agent definition. Reference docs in `${CLAUDE_PLUGIN_ROOT}/governance/`.

## Agents

Allowed specialist agents: `agent-framework:planner`, `agent-framework:coder`, `agent-framework:designer`.

## Mandatory Modules

These 8 governance modules are always loaded for every workflow. No activation condition, user override, or workflow classification can suppress them:

- `agent-system-policy.md`
- `branching-pr-workflow.md`
- `git-policy.md`
- `scope-policy.md`
- `communication-policy.md`
- `escalation-policy.md`
- `CLAUDE.md` — project-specific adapter: paths, commands, packages, artifact rules
- `core-contract.md` — always-loaded module classification, mandatory/conditional lists, and core definition cross-references

## Conditional Modules

These 4 governance modules activate only when their condition is met. Fail-open: when uncertain, include.

| Module | Activation Condition |
|---|---|
| `versioning.md` | Planner's file scope includes files matching the Bump Trigger list in `${CLAUDE_PLUGIN_ROOT}/governance/versioning.md` (and not exclusively matching the "No bump is required by default" list), OR `CLAUDE.md` defines versioned artifacts |
| `validation-policy.md` | Workflow includes a validation phase |
| `pr-review-remediation-loop.md` | Workflow includes PR feedback or review remediation |
| `monitoring-policy.md` | User request contains `watch`, `monitor`, `wait`, `poll`, or `loop` |

## Core Definitions

Canonical definitions live in `${CLAUDE_PLUGIN_ROOT}/governance/agent-system-policy.md` (Definitions). Summary and cross-reference for each:

| Definition | Summary | Canonical source |
|---|---|---|
| Unsafe git state | Conditions that make git operations unsafe (e.g., merge/rebase/cherry-pick in progress, detached HEAD) | `agent-system-policy.md` (Definitions → Unsafe git state) |
| Validation procedure | Steps to run declared validation commands and report results | `agent-system-policy.md` (Definitions → Validation procedure) |
| Trivial change | 4-condition test for single-file, low-risk changes eligible for the trivial fast path | `agent-system-policy.md` (Definitions → Trivial change) |
| Smallest correct fix | The minimum change that addresses the root cause without expanding scope | `agent-system-policy.md` (Definitions → Smallest correct fix) |
| Transient failure | Failures that may succeed on retry (network, rate-limit, timeout) | `agent-system-policy.md` (Definitions → Transient failure) |
| Same finding | A review finding that repeats after attempted remediation | `agent-system-policy.md` (Definitions → Same finding) |
| Material visual decision | A visual change requiring a new color, spacing, typography, or component variant not derivable from existing tokens or documented patterns | `agent-system-policy.md` (Definitions → Material visual decision) |
| One-time vs watch routing | Route PR feedback to `address-pr-feedback` by default; use `watch-pr-feedback` only when user request contains `watch`, `monitor`, `wait`, `poll`, or `loop` | `agent-system-policy.md` (Definitions → One-time vs watch routing) |
