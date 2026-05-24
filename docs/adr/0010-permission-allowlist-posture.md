# Permission-allowlist posture and Claude Code permission-engine behavior

**Status:** accepted — 2026-05-24

The hivemind workflow generated excessive permission-elevation prompts. A log study of 162 session transcripts (2,440 tool calls) found ~1,023 default-mode would-prompts; the single largest source was decorative `echo` banners. This ADR captures the least-privilege allowlist posture we adopted to reduce them and — load-bearing — the empirically established Claude Code permission-engine behavior that justifies it, so a false premise that drove ~6 review iterations of churn does not get re-litigated.

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

1. GRANT read/output helpers: `jq`, `head`, `tail`, `ls`, `wc`, `sort`, `uniq`, `cat`, `echo`, `printf`.
2. GRANT scoped git reads: `git ls-files`, `git grep`, `git tag` (list-only forms: bare, `-l*`, `--list*`), `git stash list`, `git stash show *`.
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
