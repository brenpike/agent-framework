# Permission-allowlist posture and Claude Code permission-engine behavior

**Status:** accepted — 2026-05-24

The hivemind workflow generated excessive permission-elevation prompts. A log study of 162 session transcripts (2,440 tool calls) found ~1,023 default-mode would-prompts; the single largest source was decorative `echo` banners (see **Amendment — 2026-05-25**: this attribution was later corrected). This ADR captures the least-privilege allowlist posture we adopted to reduce them and — load-bearing — the empirically established Claude Code permission-engine behavior that justifies it, so a false premise that drove ~6 review iterations of churn does not get re-litigated.

## Context

The reduction effort had three levers: a project `.claude/settings.json` `permissions.allow` allowlist, an opt-in `setup-project` seed template, and agent-prose changes that suppress decorative shell output at the source.

A FALSE belief drove the churn: that a `Bash(<prefix> *)` rule auto-approves a "redirect-write tail" (e.g. `echo x > /etc/passwd`), making read/output-helper grants an arbitrary-file-write vector. Acting on this premise, echo/printf/cat/sort were repeatedly removed and re-added across review iterations. The premise is false; the findings below establish why.

## Findings — Claude Code permission-engine behavior

Empirically established by source-analyzing the installed Claude Code v2.1.150 binary and the official docs at code.claude.com/docs/en/permissions. The load-bearing facts:

- After a Bash prefix rule yields `allow`, CC runs a redirect/path validator that RE-PROMPTS (`ask`/`deny`) on ANY write or redirect to a path OUTSIDE the session working directory (plus configured additional dirs). Only `> /dev/null` is exempt.
- CC splits compound commands on `&&`, `||`, `;`, `|`, `|&`, `&`, and newlines, and requires EACH subcommand to match an allow rule independently.
- `cd` into the working tree is auto-allowed without a rule.
- Over-broad wildcard rules such as `Bash(cd:*)` are a footgun (the trailing `*` swallows `&& rm -rf …`), but a clean `Bash(jq *)`-style prefix does not have this problem.
- Tool-intrinsic write flags not in CC's safe-flag tables (e.g. `sort -o`) re-prompt. A minor read/write misclassification exists (`uniq in out` labels the output arg as read) but stays bounded to readable/in-cwd paths.

CONSEQUENCE: a `Bash(cmd *)` read/output-helper grant is NOT an arbitrary-file-write vector. The only silent write it permits is into the working directory — uniformly true for jq/head/ls as for echo/printf/cat/sort. The earlier "redirect-write tail" premise was false.

- **NON-FINDING (open question, recorded 2026-08-24).** Whether a skill's `allowed-tools` entry — for example `Bash(node *)` — suppresses the permission prompt for a provider binary invoked via node, including in a subagent context, is NOT established by this ADR's evidence. No surface in this repository may assert it until it is verified empirically against an installed Claude Code binary and the official permissions documentation. The consumer-correct instruction is UNAFFECTED either way: the per-contributor grant in the gitignored `.claude/settings.local.json` is correct regardless of how the question resolves.
- **AUTHORITY (scoped to the open question).** The prohibition above binds ONLY that unverified question: no surface — this one included — may state an answer to it until it is verified and recorded here. It is NOT a general claim that every permission-engine statement in this repository must live in this section. Engine facts already VERIFIED and recorded elsewhere STAND exactly as written and are NOT conscripted into compliance by this designation: `plugin/governance/security-policy.md` (a skill's `allowed-tools` entry pre-approves a tool but never PROVISIONS it, the calling agent's `tools:` is the ceiling, and plugin frontmatter cannot path-scope a `Write` grant), ADR-0013 (`allowed-tools` only pre-approves and cannot restrict a skill), and ADR-0018 (the same non-path-scoping fact, as its enforcement model) are correct and mutually consistent with these Findings — several of them recorded by this ADR's own **Amendment — 2026-07-27**. Do not "clean up" those documents against this bullet. What this section remains authoritative for: a NEW engine claim not already verified and recorded elsewhere is established and recorded HERE first, and other surfaces then operationalize the resulting instruction or point here. CHECK 15 in `tools/policy_check.sh` enforces that structurally, and its allowlist — which includes `docs/adr/` and `plugin/governance/security-policy.md` — is the operative set of surfaces permitted to carry the claim token.

## Decision — allowlist posture

1. GRANT read/output helpers: `jq`, `head`, `tail`, `ls`, `wc`, `sort`, `uniq`, `cat`, `echo`, `printf`, `grep` (read-only; `Bash(grep *)` supersedes the narrow `grep -n`/`-rn`/`-rE` forms — see **Amendment — 2026-05-25**).
2. GRANT scoped git reads: `git ls-files`, `git grep`, `git ls-tree` (read-only object lister), `git tag` (list-only forms: bare, `-l*`, `--list*`), `git stash list`, `git stash show *`.
3. EXCLUDE — for GENUINE reasons, NOT the debunked one:
   - `Bash(node *)` — arbitrary code execution.
   - `Edit` / `Write` / `acceptEdits` — broad unprompted write.
   - `Bash(find *)` — `-delete` / `-exec` deletion and arbitrary execution.
   - `Bash(git switch *)` — `-f` discards uncommitted changes.
   - broad `Bash(git stash *)` — `drop` / `clear` / `pop` lose work.
   - broad `Bash(git tag *)` — `-d` / `-f` mutate tags.
4. Decorative shell output (section banners, progress narration, terse status tokens) is suppressed at the source via agent-prose directives (cerebrate, local-reviewer, drone, overlord, github-reviewer) rather than by granting echo — ~93% of echo/printf prompts were gratuitous scaffolding. Load-bearing `printf` routing-data emissions (the pipeline-skill contract output) are exempt.
5. `setup-project` seeds this least-privilege set via the `seed_allowlist` input, which now **defaults to `yes`** — the least-privilege template is union-merged by default and consumers opt OUT via `seed_allowlist=no` (append-if-absent; never overwrites, removes, or reorders a consumer's existing entries). See **Amendment — 2026-05-29**.
6. The follow-up issue proposing to harden pipeline-skill `printf` routing emission (#123) was CLOSED: it rested on the same debunked arbitrary-write premise; skill-level `printf` is not an arbitrary-write vector.

## Considered Options

| Option | Rejected because |
|---|---|
| Omit echo/printf/cat/sort from the allowlist to avoid the "redirect-write tail" | Premise false: CC re-prompts on out-of-cwd writes/redirects and splits compound commands, so these grants are no more write-capable than jq/head/ls; omitting them just keeps the prompt noise |
| Grant `Edit`/`Write`/`node`/`find` to cut more prompts | Genuine arbitrary-write or arbitrary-execution surface; excluded on real risk, not the debunked premise |
| Grant echo to silence banner prompts | Treats the symptom; ~93% of those prompts are gratuitous scaffolding better removed at the source via agent prose |
| Harden pipeline-skill `printf` routing emission (#123) | Rests on the debunked arbitrary-write premise; skill-level `printf` is not an arbitrary-write vector — issue closed |

## Consequences

- Materially fewer permission prompts, plus a documented rationale that prevents re-litigating the false premise (it recurred across multiple review iterations).
- The in-cwd redirect-overwrite is an ACCEPTED, bounded surface, uniform across all Bash grants. Defense relies on CC's out-of-cwd re-prompt and on deny rules — not on omitting read/output helpers.
- A future redesign of routing-data emission (non-shell / exact-match invocation) remains OPTIONAL; it is not required for safety.

## Amendment — 2026-05-25

> Active end-state (Decision #4 echo-banner suppression lever only): the compound-command-batching attribution in this 2026-05-25 amendment. The allowlist-posture decision in this ADR still governs; only Decision #4's agent-prose suppression lever is superseded.

This amendment refines the DIAGNOSIS recorded above. It does not rewrite the accepted record: the False-premise narrative, the engine Findings, the Considered Options, and the Consequences all stand. A 2026-05-25 24h log study (93 Bash calls) corrected the root-cause attribution and a remediation shipped accordingly.

- **Corrected attribution.** The 2026-05-24 framing that "decorative `echo` banners are the single largest source" of permission prompts was a misattribution. `echo` was ALREADY allowlisted, so banner echos never triggered a prompt on their own — the banner is a CORRELATED SYMPTOM, not the cause. Decision #4's agent-prose suppression lever therefore could not reduce the prompts and is SUPERSEDED for that purpose.
- **Actual mechanism.** COMPOUND-COMMAND BATCHING. CC splits a compound command (`&&` / `||` / `;` / `|` / newline) and matches each subcommand independently; one unlisted segment forces a prompt for the whole chain. 51 of 61 (84%) banner-decorated commands contained such an unlisted chain-mate. Measured unlisted triggers: `grep` flag near-misses (`grep -c`, `grep -v`, `grep -E`, `grep -nE`, `grep -rln`, `grep -rEn` — the seed had only `grep -n` / `grep -rn` / `grep -rE`), `git ls-tree`, and repo validation invocations (`bash tools/policy_check.sh`, `bash tools/validate_reports.sh`, `bash -n`).
- **Remediation (shipped v2.8.2 / PR #132).** Static allowlist widening only: added `Bash(grep *)` and `Bash(git ls-tree *)` (both read-only) to the seed. Repo-local `bash ...` validation grants were kept OUT of the consumer seed. No hook, no new behavioral prose.
- **Engine model unchanged.** The engine facts in the Findings section remain valid and load-bearing — the out-of-cwd write/redirect re-prompt and the compound-command split behavior are exactly what this amendment leans on. `grep` and `git ls-tree` are read-only and safe for the same engine reasons; the debunked "redirect-write tail" premise stays debunked.

## Amendment — 2026-05-29

The `seed_allowlist` input default FLIPPED from `no` to `yes` (Decision #5 above updated in place). This makes least-privilege seeding the out-of-the-box behavior: the recommended template is union-merged into the consumer's `.claude/settings.json` unless `seed_allowlist=no` is passed.

- **Merge semantics unchanged.** Append-if-absent / union only — existing consumer entries are NEVER overwritten, removed, or reordered. Re-running is idempotent.
- **Seeded surface unchanged.** Still seeds only read/output helpers, scoped git reads, and the codex-companion node entry. Still seeds NO `acceptEdits` / `Edit` / `Write`.
- **Opt-out preserved.** Consumers retain full opt-out via `seed_allowlist=no`.
- **Safety rationale unchanged.** The template is safe to default-on for the same engine reasons recorded in Findings: Claude Code re-prompts on any write/redirect to a path outside the working directory and splits compound commands, so each granted helper's only silent write is bounded to the working directory. The debunked "redirect-write tail" premise stays debunked.

## Amendment — 2026-07-27

Decision #3's exclusion of BROAD `Edit`/`Write` grants STANDS. One narrow exception is admitted, and one engine fact about rule spelling is corrected.

- **Narrow exception.** The orchestrator's own agent definition (`plugin/agents/overlord.md`) now carries `Write`; `Edit` stays absent. It is bounded to the fixed-literal inputs-file transport paths under the gitignored `.hivemind/` tree (Inert Inputs-File Navigator Pattern, `plugin/governance/security-policy.md`). Reason: a skill's `allowed-tools` PRE-APPROVES a permission but never PROVISIONS a tool, and the calling agent's `tools:` is the ceiling — so the transport several skills documented was unreachable, and the ADR-0017-forbidden heredoc fallback was being used instead on every ledgered state transition.
- **Rule spelling (verified).** From Claude Code 2.1.210 onward a `Write(<pattern>)` allow rule is ACCEPTED but NEVER MATCHED by file permission checks; only `Edit(<pattern>)`/`Read(<pattern>)` rules are, and `Edit` rules cover every file-editing tool including Write. Verified against the official permissions documentation and the installed 2.1.220 binary (warning string `is not matched by file permission checks — only ${a}(path) rules are`). The RULE namespace and the TOOL namespace are different things: an `Edit(...)` rule does NOT grant the `Edit` tool.
- **Consequence.** This repo's pre-existing `Write(.hivemind/review-loop/*)` rule in `.claude/settings.json` is ineffective as written; it takes effect only spelled `Edit(.hivemind/review-loop/*)`.

## Amendment — 2026-08-24

The codex-companion node entry is REMOVED from the `seed-hive` permissions template. This SUPERSEDES the **Amendment — 2026-05-29** bullet "Seeded surface unchanged" insofar as that bullet names the codex-companion node entry as part of the seeded surface; the rest of that amendment (merge semantics, opt-out, safety rationale) stands.

- **The entry was UNMATCHABLE AS SHIPPED.** The seeded rule was `Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)`. `/path/to/` is a documentation placeholder that was frozen into runtime data by a single-quoted heredoc in `plugin/skills/_shared/settings-merge.sh`, so it was never expanded to a real `$HOME`. The rule therefore matched no invocation on any machine and never granted anything to anyone — it was dead text in every consumer's committed `.claude/settings.json`, re-added on every re-seed.
- **Standing rule.** No local-review provider grant — `codex` today, or any future provider (a `copilot` adapter or otherwise) — may be seeded into the committed `.claude/settings.json`. Two reasons: (a) that file is committed and team-shared, so a machine-specific `$HOME` cache path is wrong for everyone but the seeder; (b) per-contributor grants belong in the gitignored `.claude/settings.local.json`, which is what `.devcontainer/postCreate.sh` already does.
- **This REINFORCES Decision #3.** Decision #3 excludes `Bash(node *)` from the seeded allowlist for arbitrary-code-execution reasons. Removing a provider-specific `node` grant from the seed keeps that exclusion whole.
- **Append-if-absent consequence.** Because merge semantics are union-only (never remove, never reorder), already-seeded consumers RETAIN the dead entry until they delete it by hand. Automatic removal is DELIBERATELY not implemented: it would break the never-remove invariant recorded in **Amendment — 2026-05-29**, and it could delete a rule a user had already repaired to their real `$HOME`.

---

## Naming update (2026-05-27)

The `setup-project` skill referenced in this ADR has been renamed to `seed-hive`. The substantive decision recorded here (permission-allowlist posture) is unchanged; only the skill identifier rotated. Legacy invocations continue to match via trigger aliases.
