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
5. `setup-project` seeds this least-privilege set via an opt-in `seed_allowlist` input (append-if-absent; never overwrites a consumer's existing entries).
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

This amendment refines the DIAGNOSIS recorded above. It does not rewrite the accepted record: the False-premise narrative, the engine Findings, the Considered Options, and the Consequences all stand. A 2026-05-25 24h log study (93 Bash calls) corrected the root-cause attribution and a remediation shipped accordingly.

- **Corrected attribution.** The 2026-05-24 framing that "decorative `echo` banners are the single largest source" of permission prompts was a misattribution. `echo` was ALREADY allowlisted, so banner echos never triggered a prompt on their own — the banner is a CORRELATED SYMPTOM, not the cause. Decision #4's agent-prose suppression lever therefore could not reduce the prompts and is SUPERSEDED for that purpose.
- **Actual mechanism.** COMPOUND-COMMAND BATCHING. CC splits a compound command (`&&` / `||` / `;` / `|` / newline) and matches each subcommand independently; one unlisted segment forces a prompt for the whole chain. 51 of 61 (84%) banner-decorated commands contained such an unlisted chain-mate. Measured unlisted triggers: `grep` flag near-misses (`grep -c`, `grep -v`, `grep -E`, `grep -nE`, `grep -rln`, `grep -rEn` — the seed had only `grep -n` / `grep -rn` / `grep -rE`), `git ls-tree`, and repo validation invocations (`bash tools/policy_check.sh`, `bash tools/validate_reports.sh`, `bash -n`).
- **Remediation (shipped v2.8.2 / PR #132).** Static allowlist widening only: added `Bash(grep *)` and `Bash(git ls-tree *)` (both read-only) to the seed. Repo-local `bash ...` validation grants were kept OUT of the consumer seed. No hook, no new behavioral prose.
- **Engine model unchanged.** The engine facts in the Findings section remain valid and load-bearing — the out-of-cwd write/redirect re-prompt and the compound-command split behavior are exactly what this amendment leans on. `grep` and `git ls-tree` are read-only and safe for the same engine reasons; the debunked "redirect-write tail" premise stays debunked.

---

## Naming update (2026-05-27)

The `setup-project` skill referenced in this ADR has been renamed to `seed-hive`. The substantive decision recorded here (permission-allowlist posture) is unchanged; only the skill identifier rotated. Legacy invocations continue to match via trigger aliases.
