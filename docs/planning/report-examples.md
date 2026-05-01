# Report Examples (Phase 1 -- CLR-4)

> **Non-normative.** These examples illustrate the report contracts defined in
> `plugin/governance/agent-system-policy.md` and `plugin/agents/orchestrator.md`.
> They do not introduce new rules. When an example conflicts with the
> normative contract, the contract wins.

---

## 1. Planner Compact Report

Source contract: `plugin/agents/planner.md` -- Compact Output.

```text
Plan
Summary: Add a missing null check to the config loader.

Memory reused:
- None

Steps:
1. Owner: coder
   Files: src/config/loader.ts
   Outcome: loader.ts returns a typed error instead of throwing on null input

Versioning:
- Impact: none
- Artifact(s): none

Open questions:
- None
```

---

## 2. Planner Full Report

Source contract: `plugin/agents/planner.md` -- Full Output.

```text
Plan
Summary: Refactor the auth middleware to replace in-memory session storage with
database-backed sessions. This addresses the compliance requirement for durable
token storage and affects both the middleware layer and the session model.

Memory reused:
- Prior decision: legal flagged in-memory token storage as non-compliant (2026-04-15 planning thread)

Steps:
1. Owner: coder
   Files: src/middleware/auth.ts, src/models/session.ts
   Outcome: auth middleware reads/writes sessions via the database adapter instead of the in-memory map
   Depends on: none

2. Owner: coder
   Files: src/middleware/__tests__/auth.test.ts
   Outcome: integration tests pass against a test database with the new session flow
   Depends on: 1

3. Owner: designer
   Files: src/components/SessionExpiredBanner.tsx
   Outcome: banner displays when a session is invalidated server-side
   Depends on: 1

Edge cases:
- S1: concurrent requests during session migration window must not lose writes
- S2: expired sessions must surface a user-visible banner, not a raw 401

Shared-file risks:
- src/middleware/auth.ts: touched by steps 1 and 2; step 2 must run after step 1

Versioning:
- Impact: required
- Artifact(s): @acme/auth-middleware
- Likely bump: minor
- Release files likely needed: packages/auth-middleware/package.json, CHANGELOG.md

Review remediation:
- Item(s): none
- Classification: none
- User decision needed: no

Delivery:
- Shape: single-plan
- Branch/PR: single feature branch, one PR to main
- Worktrees: no -- steps share auth.ts so parallel execution is unsafe

Open questions:
- None
```

---

## 3. Worker Complete Report (Shared Worker Report Contract) -- Minimal

Source contract: `plugin/governance/agent-system-policy.md` -- Shared Worker Report Contract.

This example includes only the required fields; all optional-line triggers are inactive.

```text
Status: complete

Changed:
- docs/planning/report-examples.md

Validated:
- JSON manifests parse: pass
- No bare path refs: pass

Need scope change:
- None

Issues:
- None
```

---

## 4. Worker Complete Report (Shared Worker Report Contract) -- With Optional Fields

Same contract as example 3. This example includes optional fields whose triggers
have fired.

```text
Status: complete

Changed:
- src/middleware/auth.ts
- src/models/session.ts

Validated:
- npm test: pass
- npm run lint: pass

Need scope change:
- None

Issues:
- None

Refs: prior commit abc1234 (session model schema), memory: compliance decision 2026-04-15
States handled: S1 concurrent writes during migration, S2 expired session banner trigger
Commit: a1b2c3d
Version: required
```

---

## 5. Worker Blocked Report (Blocked Report Contract)

Source contract: `plugin/governance/agent-system-policy.md` -- Blocked Report Contract.

```text
Status: blocked
Stage: implementation
Blocker: correctness requires editing src/db/adapter.ts which is not in the assigned file scope
Retry status: not attempted
Fallback used: none
Impact: auth middleware cannot call the new session persistence method without a db adapter change
Next action:
- Orchestrator must expand scope to include src/db/adapter.ts or re-plan
```

---

## 6. Orchestrator Final Report

Source contract: `plugin/agents/orchestrator.md` -- Final Report.

```text
Result: complete

Completed:
- Auth middleware refactored to database-backed sessions
- Integration tests passing against test database
- Session-expired banner component added

Files:
- src/middleware/auth.ts
- src/models/session.ts
- src/middleware/__tests__/auth.test.ts
- src/components/SessionExpiredBanner.tsx

Validation:
- npm test: pass
- npm run lint: pass

Git:
- Class: feature
- Base: main
- Work: feature/db-sessions
- Worktrees: no
- Checkpoints: 3 (one per phase)
- PR: opened to main

Versioning:
- Required: yes
- Completed: yes

Review:
- Requested: yes
- Remediated: not applicable
- Monitoring: not requested

Issues:
- None
```

---

## 7. PR Feedback Remediation Report

Source contract: `plugin/skills/address-pr-feedback/SKILL.md` -- Output.

```text
Status: complete

PR:
- Number: 42
- Branch: feature/db-sessions
- Target: main

Feedback:
- Source: Codex
- Author: codex-review[bot]
- URL: https://github.com/acme/repo/pull/42#discussion_r1234567
- Classification: actionable-code-change

Changed:
- src/middleware/auth.ts

Validated:
- npm test: pass
- npm run lint: pass

Git:
- Commit: d4e5f6a
- Pushed: yes

Reply:
- Posted: yes
- URL: https://github.com/acme/repo/pull/42#discussion_r1234999

Issues:
- None
```

---

## 8. Monitor Not-Active Report

Source contract: `plugin/governance/agent-system-policy.md` -- Monitoring Policy
(fallback when no background mechanism is active).

```text
Status: complete
Mode: manual
Monitoring: not active
Next action:
- User must invoke the skill again when new feedback appears
```

Extended form from `plugin/skills/watch-pr-feedback/SKILL.md` -- Output:

```text
Status: blocked

PR:
- Number: 42
- State: open
- Branch: feature/db-sessions
- Target: main

Watch:
- Mode: manual
- Monitoring: not active
- Parser: unavailable
- Cycles: 0
- Seen comments: 0
- New actionable comments: 0

Routed:
- None

Stopped because:
- Monitor startup failed; manual fallback check completed; no background mechanism is active

Next action:
- User must invoke the skill again when new feedback appears
- None
```
