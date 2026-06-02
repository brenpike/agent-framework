# Per-brood-id namespacing dissolves the singleton-manifest races; reads anchor on git ground truth, not manifest paths

**Status:** accepted — 2026-06-01

ADR-0017 settled the brood SPAWN MECHANISM but left brood STATE as a singleton pair (`.hivemind/brood/{inputs,manifest}.json`) anchored to one checkout. ADR-0019's fifth amendment then retracted the "liveness guard serializes spawns" exemption and named the singleton layout itself as the residual: the liveness guard is a check-then-act read with a TOCTOU window, not a reservation, and the singleton `inputs.json` is clobberable between the navigator Write and the script exec. This ADR records the STRUCTURAL fix tracked there (#168) as one coherent decision: per-brood-id namespacing of all brood state, worktrees, and branches; ground-truth-anchored reads that no longer trust manifest paths; and a floor-at-input / encode-at-output value-class model for the read side.

## Context

Four pressures converged on the singleton brood layout:

1. **Singleton-manifest spawn TOCTOU (ADR-0019 fifth amendment).** Two concurrent same-checkout spawns both pass the liveness check before either writes a manifest; both launch `--dangerously-skip-permissions` children, and the later manifest write hides the earlier child from monitoring. The shared `inputs.json` is likewise clobberable. ROOT CAUSE: the manifest is the sole shared mutable artifact per checkout (RUN-OWNERSHIP-01).
2. **PR #154 deferred findings.** The earlier per-brood-id attempt (ADR-0017, later amputated to single-brood) left three unresolved shapes: F1 slug injectivity (a timestamp-derived slug could collapse two distinct instants), F2-deep worktree/branch un-namespacing (two same-checkout broods reusing a strain name collide on worktree path and branch), and F3 session-name grammar (the producer's emitted tmux name must match the consumer's expected grammar).
3. **Read-side manifest-path trust (ADR-0019 Boundary 3).** The #161 read side confined each child ledger beneath the manifest's own `worktree_path` — an UNTRUSTED field. A tampered `worktree_path` could redirect the bounded ledger reader within its confinement rules; the manifest path was load-bearing for the anchor.
4. **Value-class charset treadmill (#177).** The read side's `path` value-class enumerated a per-byte charset; every legitimate path byte the enumeration omitted produced a spurious `MALFORMED` that suppressed ledger projection — a recurring false-reject treadmill.

All four trace to the same two root causes: brood state is SHARED (singleton), and the read side TRUSTS manifest-supplied paths and enumerates charsets at the input floor.

## Decision

**Each brood owns a disjoint per-brood-id directory; brood-id propagates into every derived name; the read side anchors on git ground truth and never consumes a manifest path; value classes floor-at-input and encode-at-output.**

### 1. Per-brood-id state layout

State moves from singleton `.hivemind/brood/{manifest,inputs}.json` to per-brood `.hivemind/broods/<brood-id>/{manifest.json,inputs.json}`. Each brood resolves to its own directory, so two concurrent same-checkout spawns NEVER share an inputs file or a manifest.

### 2. Brood-id format and generation

The brood-id is machine-generated INSIDE `spawn-brood.sh` as `brood-<uuidv4>` (charset `^brood-[0-9a-f-]+$`, lowercased). Any caller-supplied `brood_id` in the inputs is IGNORED — the script owns the id. Generation is portable (`uuidgen`, else the kernel uuid file, else `/dev/urandom` hex regrouped as a uuid) and FAILS CLOSED if no source is available. The generated id is asserted against the charset and re-checked for `..`/path separators before it derives any path.

- **Injective by construction** (closes PR #154 F1): a uuidv4 is unique per generation, so two broods cannot collide on a brood-id — no timestamp canonicalization, no slug-collapse risk. The earlier timestamp-derived-slug injectivity problem is structurally absent.
- **The `brood-` prefix is retained** (closes PR #154 F3): it anchors the read-side discovery glob (`.hivemind/broods/brood-*/manifest.json`) and the tmux-session-name grammar contract (`<brood-id>-<short>`, which the reader re-validates against `^brood-[0-9a-f-]+$`-prefixed shapes).

### 3. Liveness guard removed; no replacement lock

The ADR-0017 singleton-manifest liveness guard is REMOVED, and NO per-checkout lock or per-invocation token replaces it. Per-brood-id disjoint directories dissolve both the spawn TOCTOU and the singleton inputs-clobber by construction: there is no shared manifest to overwrite and no shared inputs file to clobber, so there is nothing for a lock to protect. This is the same posture as #167 (where per-run worktree isolation, not a lock, is the serialization primitive) and the same dissolution move ADR-0019 used when it removed the singleton sharing rather than locking it. **Isolation replaces the lock.**

### 4. Brood-id propagates into worktree path and branch

The brood-id carries through EVERY derived name so two same-checkout same-strain-name broods get disjoint resources (closes PR #154 F2-deep):

- state dir: `.hivemind/broods/<brood-id>/`
- branch: `strain/<brood-id>/<short>` (DERIVED; no longer caller-supplied — any caller `branch` is ignored)
- worktree: `.claude/worktrees/<brood-id>/<short>`
- tmux session: `<brood-id>-<short>`

`<brood-id>` is a single safe path component (asserted `^brood-[0-9a-f-]+$`) and `<short>` is sanitized to `[a-z0-9-]`, so the joins introduce no traversal, `.lock`, or doubled-slash hazard; each branch is additionally `git check-ref-format`-validated.

### 5. Atomic manifest write

The manifest is written to a temp file under the per-brood state dir and `mv`'d into place. The `mv` is a same-filesystem rename (temp created under `$STATE`, not `$TMPDIR`), so a concurrent reader observes either the OLD or the COMPLETE NEW manifest — never a truncated/partial file. Per-brood namespacing already removes cross-brood truncation; temp+mv additionally closes same-brood re-write read-skew.

### 6. Manifest v4

`manifest_version: 4`. Relative to v3:

- ADD top-level `brood_id` (the generated GUID) and `created_at` (UTC ISO-8601 `…Z`).
- Per-strain `branch` is DERIVED (`strain/<brood-id>/<short>`) and `worktree_path` is RETAINED as a DISPLAY-ONLY field.
- DROP `run.suggested_ledger` (the read side derives it now — recording it was redundant manifest-path trust). KEEP `run.suggested_id` (the lineage reconciliation key). The child `task.md` still carries the suggested ledger so the child knows where to initialize its own.

### 7. Ground-truth-anchored reads replace the manifest-path residency gate

The read side (`brood-status-project.sh`) no longer trusts the manifest's `worktree_path` as a ledger anchor; the residency gate over that field is REMOVED (the field is display-only). Instead:

- It parses `git worktree list --porcelain` ONCE into a branch→path map. The manifest's per-strain `branch` is UNTRUSTED and is used ONLY as a lookup KEY among the git-reported paths — it never becomes a path itself. A garbage/non-matching branch selects NOTHING and fails closed; a branch git reports on two worktrees is rendered `MALFORMED` (ambiguous, never silently resolved).
- The ledger path is DERIVED as `<git-worktree>/.hivemind/runs/<suggested_id>/state.json`, where only `<suggested_id>` is manifest-sourced and is gated as a strict single-component identifier (no slash). The `.hivemind/runs/.../state.json` segment is a literal the reader owns.
- The full containment chain is `CHECKOUT_ROOT ⊇ git-worktree ⊇ ledger`: the git-derived worktree must canonically sit beneath the checkout (git may report linked/sibling worktrees deliberately OUTSIDE the checkout — those fail closed), and the ledger leaf must sit beneath that worktree.
- Multi-brood discovery globs `.hivemind/broods/brood-*/manifest.json`; the helper remains a SINGLE-manifest projector and emits `brood_id` as the first field of every `STRAIN` line so the navigator attributes each strain to its brood.

The `path` value-class is consequently REMOVED from the read side: no manifest path is consumed any longer.

### 8. Floor-at-input / encode-at-output value-class model

Value safety splits into two layers:

- **Floor-at-input** (`_shared/allowlist.sh`): every value is gated against ONE shared security floor (reject `$`/backtick command-substitution, `..`, leading `-`, TAB/LF/CR framing, empty) at the moment it enters the engine. The `path` class is now FLOOR-ONLY — no per-byte charset enumeration — which kills the #177 treadmill: any byte that survives the floor is accepted as inert quoted data.
- **Encode-at-output** (the projector's `encode_cell` at the emit boundary): Markdown-cell and residual-control safety moves to OUTPUT-ENCODING — escape `|` → `\|` and strip C0/DEL — applied UNIFORMLY to every display cell, not as per-class carve-outs. The render boundary owns cell safety, deterministically, in the committed script rather than in the agent-driven navigator.

### 9. #178 unified extraction-fidelity contract

The manifest read uses a single unified extraction contract: single-document slurp (F1 — `jq -s` + `length == 1`, so a multi-document file fails closed rather than projecting one length per document), a `type == "string"` gate (F3 — a present non-string scalar is a tamper indicator → `MALFORMED`, never coerced), and an out-of-band exit-code presence-vs-rejection signal (F2 — `0` present+valid, `1` absent → `MISSING`, `2` present-but-invalid → `MALFORMED`), so a rejected value is never collapsed into `MISSING`.

### 10. Item-4 leaf symlink-swap is an ACCEPTED BOUNDED RESIDUAL

The single-open micro-TOCTOU between the leaf `[ -L ]` re-check and the `cat` of the child ledger is an ACCEPTED BOUNDED RESIDUAL — it is NOT structurally closed by #168. Per-brood namespacing isolates broods FROM EACH OTHER; it does NOT isolate the hatchery FROM the children. The hatchery reads untrusted child ledgers BY DESIGN (that is the monitoring feature), so a child swapping its own ledger leaf to a symlink in the micro-window is in-scope for the read, not dissolved by namespacing. Defense-in-depth bounds (not closes) the residual: a post-read `realpath` re-assert of containment beneath the git-worktree, never echoing raw bytes (only the validated `run.status` enum and `state.current` charset ever surface), and informational-only projection that never overrides observable status. bash has no portable `O_NOFOLLOW`; the window is deliberately narrowed, not engineered shut.

### 11. No migration

Single-user, unreleased at 2.20.0. The read side reads ONLY `.hivemind/broods/brood-*/`; the legacy singleton `.hivemind/brood/manifest.json` becomes invisible (never read). Operators **drain any running brood before upgrade** — a brood spawned under the singleton layout will not be discovered after upgrade.

## Considered Options

| Option | Rejected because |
|---|---|
| Keep the singleton manifest + add a per-checkout lock or per-invocation token | Throwaway once namespacing lands; a lock re-adds the stale-lock finding ADR-0017 already removed, and isolation is the correct primitive (same as #167) |
| Per-brood-id dirs but keep trusting the manifest `worktree_path` as the ledger anchor | Leaves the read side anchored on an untrusted field; a tampered path still drives the bounded reader. Git ground truth removes the trusted-path dependency entirely |
| Timestamp-derived brood-id (the PR #154 form) | Not injective without UTC canonicalization (F1); a uuidv4 is injective by construction with no canonicalization step |
| Keep per-byte charset enumeration on the `path` class | The #177 false-reject treadmill: every omitted legit byte suppresses ledger projection. Floor-at-input + encode-at-output moves cell safety to the render boundary |
| Migrate the legacy singleton manifest on upgrade | Unreleased, single-user, ephemeral gitignored state; documenting "drain before upgrade" is sufficient and avoids migration code for a throwaway layout |

## Consequences

- Concurrent same-checkout broods are now SUPPORTED: disjoint dirs/worktrees/branches/sessions, no lock. The liveness guard and any same-brood in-flight reservation are gone.
- The read side no longer trusts any manifest path. The only manifest-sourced value that drives a path is `suggested_id` (strict single-component identifier); everything else comes from git or is a literal the reader owns.
- The `path` value-class is removed from the read side; `worktree_path` is display-only and rendered through `encode_cell`, never an anchor.
- The item-4 leaf symlink-swap micro-TOCTOU remains an ACCEPTED BOUNDED RESIDUAL. Any prior text claiming per-brood isolation "structurally dissolves" it is corrected to "accepted bounded residual" (see ADR-0019 and `plugin/governance/security-policy.md`).
- No version re-bump: this folds into the unreleased 2.20.0.
- Operators must drain running broods before upgrading; the legacy singleton layout becomes invisible to monitoring.
