# spawn-brood reference

Security rationale, manifest discipline, and dependency notes for
`hivemind:spawn-brood`. The skill body (`SKILL.md`) is a navigator; the
deterministic engine is
`${CLAUDE_PLUGIN_ROOT}/skills/spawn-brood/scripts/spawn-brood.sh`. This file holds
the WHY that the navigator omits.

## Contents

- [Why the injection class is structurally gone](#why-the-injection-class-is-structurally-gone)
- [Three-layer manifest safety model](#three-layer-manifest-safety-model)
- [Block-scalar chomping: `|-` vs `|`](#block-scalar-chomping---vs-)
- [Allowlist gate: optional defense-in-depth](#allowlist-gate-optional-defense-in-depth)
- [The `hivemind:overlord` ready substring](#the-hivemindoverlord-ready-substring)
- [The `jq` dependency](#the-jq-dependency)

## Why the injection class is structurally gone

Earlier rounds tried to make the inline shell snippets safe by quoting every
dynamic token. Double-quoting is NOT a shell-safety encoding: when untrusted
LITERAL bytes appear in the SOURCE of a command, bash command substitution
`$(...)`, backticks, and `${}` STILL expand inside double quotes.
`git check-ref-format --branch` accepts a branch like `feat/x$(touch${IFS}/tmp/pwn)`,
so the moment those bytes are emitted into command source the substitution runs
before git ever validates the ref.

The refactor closes that class by ARCHITECTURE, not per-snippet quoting:

1. The agent writes inputs as a JSON file with the Write tool. Write performs no
   shell parsing — no delimiter to collide with, no path to hatchery-shell
   execution.
2. The script reads each value with `jq` into a shell VARIABLE
   (`branch="$(jq -r ... )"`).
3. Every later use references the value only as `"$branch"` / `"$wt"` / `"$desc"`.
   Bash does NOT re-evaluate command substitution from variable CONTENTS — a
   variable holding the literal bytes `$(touch pwn)` expands to that literal
   string, it does not run `touch`. The untrusted bytes never enter command
   source.

Because the untrusted bytes are never in command source, the command-substitution
injection class is structurally absent regardless of branch/path contents. The
checkout directory name (filesystem-controlled, may legally contain
metacharacters) is handled the same way: `repo_root` and the derived worktree
path are captured into variables and referenced only as `"$rr"`/`"$wt"`.

## Three-layer manifest safety model

The manifest records untrusted values (`name`, `branch`, `base`, `worktree_path`,
`description`, `overlap_details`). Three independent layers keep it both valid and
safe for `hivemind:brood-status` to consume:

1. **Write/printf authoring, no shell parse.** The script emits the manifest via
   `printf` block-scalar output; no untrusted byte is parsed as shell.
2. **YAML block scalars.** Every value derived from planner output, issue text, or
   a filesystem path is a YAML literal block scalar with content indented one
   level past the key. An inline double-quoted scalar is unsafe even for a branch
   (`git check-ref-format --branch 'feat/a"b'` is accepted, and the embedded
   quote would terminate an inline scalar and corrupt the manifest). Block scalars
   give YAML-injection safety.
3. **Consumer-side quoting.** `hivemind:brood-status` double-quotes every manifest
   value before its first shell use. Block scalars give YAML safety, `|-` gives
   exact values, consumer quoting gives shell safety — all three are required
   together.

## Block-scalar chomping: `|-` vs `|`

The chomping indicator differs by field role:

- **`|-` (STRIP)** for exact-value fields consumed as identifiers, paths, or shell
  arguments: `name`, `branch`, `base`, `worktree_path`. STRIP yields NO trailing
  newline. A plain `|` (CLIP) appends `\n`, so `branch: |` + `feat/x` parses as
  `feat/x\n`; a YAML-aware brood-status would then probe for `feat/x\n` and use
  the wrong PR head.
- **`|` (CLIP)** for free-text prose fields: `description`, `overlap_details`.
  These are multi-line human prose, never used as exact shell arguments; a
  conventional trailing newline is harmless.

Inline literals (fixed shape, no untrusted/path content): `brood_id`,
`hatchery_session`, `tmux_session` (`brood-<short>`), `status` (`running |
failed`), `pr` (`null`), `merged` (`false`), `rebased_after` (`[]`), `merge_order`
(`[]`), `overlap_risk` (enum). Field names MUST NOT be renamed — brood-status
consumes them by name.

## Allowlist gate: optional defense-in-depth

The script validates each `branch`/`base` against `^[A-Za-z0-9._/-]+$` (non-empty,
no leading `-`, no `..`). This is NO LONGER load-bearing for shell safety — the
values are inert variables that never reach command source. It is retained only as
a ref-shape sanity gate: a legitimate branch never needs a forbidden byte, and
clean rejection of a malformed name beats faithful execution of a hostile one.
`git check-ref-format` is likewise demoted to defense-in-depth ref-shape
validation; it was never the shell-safety boundary (it accepts injection-bearing
names).

## The `hivemind:overlord` ready substring

A booted child renders the claude-CLI TUI. The script polls
`tmux capture-pane -t <session> -p` until the captured pane contains the literal
substring `hivemind:overlord` — the default-agent header rendered once the session
prompt is interactive. This is the ONE remaining TUI-coupling maintenance point
(`READY_SUBSTRING` in the script). If the CLI chrome changes, update that
substring. If it never appears within `READY_TIMEOUT` (90s), the strain is a
POST-LAUNCH failure: the script marks it `status: failed` and leaves the
session/worktree/branch alive for debugging (no cleanup).

## The `jq` dependency

`jq` is a REQUIRED runtime dependency: the script parses the inputs JSON with it.
It is used for READING inputs only — ADR-0017 rejected a true YAML serializer
(`yq`/`python3 -c`) for manifest WRITING because (a) it adds a runtime dependency
not guaranteed on consumers and (b) passing untrusted input into a `-c` program
reintroduces the injection class unless values are first written to files. The
script checks `command -v jq` and emits a verbose blocker + exit 1 if absent,
never bubbling a raw jq error. `tmux` and `claude` are checked the same way.
