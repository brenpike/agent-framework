# Seeded hooks use exec (argv) form; structural identity replaces substring matching

**Status:** accepted — 2026-08-25

## Context

While fixing issue #352 (the seeded caveman `SubagentStart` hook command was cwd-relative), a local Codex review returned `root-cluster-suspected` on `plugin/skills/_shared/settings-merge.sh` with the root class:

> the hook command string serves as both identity key and execution payload.

The hook was wired as an unparsed shell-command STRING doing two incompatible jobs at once:

- the IDENTITY KEY the merge matched on, by substring containment, to decide whether the hook was already present, and
- the EXECUTION PAYLOAD a shell later parsed, with execution-safety obtained by embedding literal shell quotes inside stored data (`"${CLAUDE_PROJECT_DIR}"/.claude/hooks/caveman-ultra-subagent.sh`).

Two review findings hit that one string from opposite ends — one patching how the string is PARSED for identity, one patching how it is SERIALIZED for execution. Neither can be right at the same time as the other: any quoting that makes the string safe for a shell to parse changes the bytes the identity match depends on, and any normalization that makes identity robust discards the bytes execution depends on. A third confirmed issue (RISK-001) landed on the same surface from a third direction: an independent `any()` classification predicate computed the "already present" / "added" report token separately from the merge that actually wrote the file, so the report could disagree with what was written.

Three findings against one string, each with a different fix-framing, is the **Same-Framing Test** answering yes: the next finding would be the same shape with a different byte or a different shell metacharacter. The string, not any of its three defects, is the root.

## Findings — Claude Code hook execution behavior

Verified, not recalled. Recorded here per ADR-0010's AUTHORITY bullet: a NEW engine claim not already verified and recorded elsewhere is established and recorded where it is first verified.

- The official Claude Code hooks reference documents an `args` field for `command` hooks and states that when `args` is present the command is resolved as an executable and spawned DIRECTLY with NO shell, with `${...}` substituted per element as plain strings.
- Verified against the installed binary 2.1.243: the hook exec function branches on whether `args` is defined.
  - **Exec branch** (`args` defined): substitutes `${CLAUDE_PROJECT_DIR}` per element and spawns with NO `shell:` option.
  - **Shell branch** (`args` absent): spawns with `shell: true` on POSIX and NEVER runs the substitution — the shell's own environment expansion is what made the previous form work at all.
- The Zod schema in the binary is `args: z.array(z.string()).optional()`. An EMPTY array is valid and DOES select exec form, because the branch tests `!== undefined`, not length.
- `args` was introduced in Claude Code 2.1.139 (2026-05-12).
- **Corollary — a prior claim in this repo was false.** The previous header comment in `settings-merge.sh` asserted that "the harness substitutes it before execution, so no shell is required". That was FALSE for the shell form actually shipped: under the shell branch the harness runs no substitution, and the expansion observed in practice was the spawned shell's, not the harness's. The literal embedded quotes were therefore load-bearing for exactly the wrong reason.

## Decision

**Emit the hook in Claude Code's EXEC (argv) form, and derive identity STRUCTURALLY from the emitted object rather than by matching substrings of a command string.**

### 1. Canonical emitted form

```json
{
  "type": "command",
  "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/caveman-ultra-subagent.sh",
  "args": []
}
```

The `command` value is UNQUOTED. Under exec form the substituted string reaches `execve` verbatim, so embedded quotes would become literal path characters and the spawn would fail on a path that does not exist. The empty `args` array is what SELECTS exec form; it is not decorative.

This retires the split of concerns that caused the cluster: the harness owns argv construction, so the stored value is a path and only a path. There is no shell to defend against, and therefore no quoting to encode into stored data.

### 2. Structural identity predicate

An existing entry is the canonical hook if and only if ALL of:

- `.type == "command"`, AND
- `.args == []`, AND
- `.command` EXACTLY EQUALS the canonical command string.

All three conjuncts are EXACT VALUE equality against what seed-hive EMITS. No field is judged by TYPE. An earlier form of this predicate tested `(.args | type) == "array"`, which admitted `args: [null]` and `args: [1]` as "the canonical entry" even though the schema above requires every element to be a string — so a malformed, unexecutable entry reported as present and suppressed the valid append. Type-testing one field of an identity key is the same defect shape as substring-matching another: it accepts a FAMILY of shapes rather than the one value we wrote.

A consequence, accepted deliberately and on the same terms as the user-authored shell wrapper below: an entry carrying the canonical command with any non-empty `args` (including a well-formed `args: ["--x"]`) is user-authored variation, not our entry. It is left byte-untouched and does NOT suppress the append, so such a project gains one additional entry, once. The failure direction is a context hook that fires twice — visible, harmless, bounded, idempotent — rather than a hook that is silently never wired.

Plus a FROZEN authored-shell-command migration list — the two shell-form commands hivemind itself wrote:

1. `.claude/hooks/caveman-ultra-subagent.sh` — the bare relative form, released at 2.40.10.
2. `"${CLAUDE_PROJECT_DIR}"/.claude/hooks/caveman-ultra-subagent.sh` — the quoted-anchored form, added unreleased at 2.40.11.

That list is CLOSED BY OUR OWN GIT HISTORY. It enumerates commands this project authored and shipped, so it can be completed by reading the repository; it never grows from user input, and no consumer-authored string can ever join it.

**What this makes impossible** (per the **Closed-by-Construction Acceptance Test** — the answer names eliminated classes, not newly handled cases):

- **The substring false-positive class.** Substring containment is no longer the key, so a value that merely CONTAINS the path can no longer report the hook as present. The reviewer reproduced `echo <path>`, `/some/other/project/<path>`, and `true # <path>` all reporting "already present" and suppressing the append — meaning the project's hook was never wired, silently. Under exact-equality-on-a-structural-shape, a command that is not the canonical command is not a match, whatever it contains.
- **The loosely-judged-field class.** Every conjunct of the identity key is now exact equality against an EMITTED value, so there is no field left whose "acceptable" values could be enumerated one reviewer comment at a time (`args` an array → array of strings → non-empty array of strings → ...). The key is the value we write, so "which nearby shapes also count as ours" is UNREPRESENTABLE rather than answered case by case.
- **The shell-parse class.** Nothing the merge writes is ever handed to a shell, so trailing `;`, `sh -c '...'`, unbraced variables, PowerShell `$env:` spellings, and spaces or backticks in the project root become UNREPRESENTABLE rather than handled. There is no parse to get wrong, so there is no next quoting finding to file.

### 3. Derive the report from the mutation

The independent `any()` classification predicate is DELETED. The report token is DERIVED from the mutation itself: "already present" iff the post-build `.hooks.SubagentStart` deep-equals the canon-normalized pre-state, else "added".

This dissolves RISK-001 BY CONSTRUCTION rather than by adding another conjunct to a second predicate: with one computation feeding both the write and the report, a report that disagrees with what was written is arithmetically impossible. A second predicate that merely gained the missing case would have been complete-the-known-set, and the next divergence would have been the next finding.

### 4. The deliberate drop, and its failure direction

A consumer's OWN shell-form wrapper — anything outside the frozen authored list — is still left BYTE-UNTOUCHED: the merge never rewrites what it did not author. But such an entry no longer SUPPRESSES the canonical append, so a project carrying one gains one additional entry, once.

This is deliberate, and the reason is the FAILURE DIRECTION:

- Suppression-by-heuristic fails as **the hook is silently never wired** — invisible, unbounded in duration, and indistinguishable from working.
- Exact identity fails as **the context hook fires twice** — visible, harmless, bounded to one extra entry, and idempotent on every subsequent re-seed.

Suppression across consumer-authored variants was only ever implementable as the heuristic that IS the root cause. Keeping suppression means keeping the cluster open, so the suppression is what gets dropped.

## Considered Options

| Option | Rejected because |
|---|---|
| Version-gated dual-form emission — emit shell form for clients below 2.1.139 and exec form at or above it | Two canonical values REOPEN the heuristic-identity problem this decision closes. With two possible canonical forms, identity can no longer be exact equality against one string; it goes back to matching by heuristic, which is the root class. The engine floor is accepted instead |
| Keep the shell form and harden the quoting | Patches the SERIALIZATION half of the root class while leaving the IDENTITY half broken, and every quoting fix changes the bytes identity matches on. This is one of the two opposed findings, not a fix for the pair |
| Keep the shell form and normalize before matching for identity | The mirror-image half-fix: makes identity robust by discarding bytes execution depends on. Also still hands a string to a shell, so the shell-parse class stays representable |
| Add the missing case to the independent `any()` classification predicate | Complete-the-known-set: the predicate and the builder remain two computations that can disagree, so the next divergence is the next finding. Deriving the report from the mutation eliminates the disagreement instead |

## Consequences

- **A minimum-engine floor of Claude Code 2.1.139 now applies to the emitted hook.** Exec form is unrecognized below that version. This is not a floor on the plugin as a whole; it is a floor on the seeded hook working as written.
- **That floor lands in consumers' COMMITTED `settings.json`.** The emitted value is written into a team-shared, version-controlled file, so a consumer on a pre-2.1.139 client picks up the value through the repository rather than through their own upgrade decision. The floor is therefore a real compatibility statement, not an internal implementation detail.
- **Stored hook data is now a path, not a program.** Nothing in the seeded hook is shell source, so the class of "what happens when the project root contains a space / a backtick / a quote" is answered by the harness's argv construction rather than by this repo's quoting.
- **Consumers with a hand-authored shell-form wrapper gain one extra `SubagentStart` entry, once.** Their entry is untouched; the canonical entry is appended alongside it. The hook is idempotent, so the observable effect is that the context hook fires twice.
- **Re-seeding remains idempotent for every hivemind-authored form.** The frozen migration list carries both previously shipped commands forward to the canonical entry, so an existing seeded consumer converges rather than accumulating.

References: issue #352; `plugin/skills/_shared/settings-merge.sh`, `plugin/skills/_shared/file-guard.sh`; `plugin/governance/remediation-doctrine.md` (Same-Framing Test, Closed-by-Construction Acceptance Test); ADR-0010 (AUTHORITY bullet — new engine claims recorded where first verified).

Relationship to ADR-0010's **Amendment — 2026-08-25**: that amendment stays VALID and UNTOUCHED. It records the six seeded `Edit(.hivemind/...)` permission rules as a NON-FINDING that deliberately stays relative, on the grounds that no correct anchoring primitive exists for permission rules. That reasoning is unaffected here: permission-rule patterns are a DIFFERENT SURFACE with NO expansion primitive — they perform no `${...}` substitution at all — whereas hook `command` values under exec form are substituted per element by the harness. This ADR anchors the hook precisely because an anchoring primitive DOES exist there; "no correct anchoring primitive exists" still holds for permission rules.

## Amendment — 2026-08-25 — element access is total

While generalizing the seeded caveman `SubagentStart` hook merge (issue #355, deferred from PR #356 with full scope, now resolved), a second defect surfaced on the same jq program fixed by the Decision above: every field read inside the hook block took the RAW array element as its subject, so a non-object element aborted the whole jq program rather than being skipped.

- **The defect.** `{"hooks":{"SubagentStart":["x"]}}` failed with `Cannot index string with string "hooks"`, and `{"hooks":{"SubagentStart":[{"hooks":["x"]}]}}` failed with `Cannot index string with string "type"` — a malformed or foreign-shaped element anywhere in the array aborted the merge for the whole file, not just for that element.
- **The chosen contract — normalize-and-preserve.** Every element access is total. A non-conforming element is never migrated, never counted present, and always preserved. This is NOT a new contract: the file already applies exactly this rule to entries carrying the wrong `.type` (§2, Structural identity predicate, above). The fix makes that existing rule TOTAL by extending the file's own `canon_obj`/`canon_arr` normalization law from container-key positions to element positions.
- **Rejected alternative — route to `malformed`.** Routing a wrong-typed element to the documented `malformed` fail-closed status was considered and rejected: it invents a new failure path for input the merge can simply walk past, and it overclaims relative to the accurate statement "this element isn't ours".
- **Placement — local, not a shared primitive.** The fix is a LOCAL `def canon_elem: canon_obj(.);` inside settings-merge.sh's own jq program, not a new primitive in the shared `json-normalize.sh`. Verified rule-of-three evidence: `canon_obj`/`canon_arr` have exactly one functional consumer (settings-merge.sh) — `claude-mem-path.sh` names them only in prose comments, with no call; the unguarded-element idiom exists nowhere else in `plugin/`; and the nearest relative, `plugin/skills/next-wave/scripts/next-wave.sh`, FILTERS non-conforming elements where settings-merge must PRESERVE them — a different kernel, so P9 says do not fold them. The primitive would ship with one consumer; rule-of-three is unmet, so it stays local.
- **Class-closure.** The closed class is "a jq element access inside the hook block aborts the merge because the element's type was never established". It is closed because the subject of every read becomes a value that is an object BY CONSTRUCTION over jq's CLOSED, FINITE type domain, so no un-enumerated residual shape remains. Guard count becomes a function of the data's NESTING DEPTH (fixed by the settings schema), not of the NUMBER OF FIELD READS (unbounded, growing with every added conjunct). A second class dies with it: a non-object element can never satisfy the structural identity predicate in §2, so it can never suppress the canonical append.

References: issue #355; `plugin/skills/_shared/settings-merge.sh`.
