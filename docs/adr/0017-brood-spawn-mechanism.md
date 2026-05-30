# Brood spawn uses detached tmux sessions, explicit worktree creation, and two-pass injection

**Status:** accepted — 2026-05-30

ADR-0007 deferred the brood SPAWN MECHANISM. The first real launch exposed that `claude --worktree --tmux` is unusable from a non-TTY Bash tool context and mangles branch names; this ADR records the mechanism that replaced it.

## Context

Five root-cause failures emerged at first launch:

1. `claude --tmux` requires a real terminal; the Bash tool provides none → "open terminal failed: not a terminal".
2. `claude --worktree <NAME>` derives `worktree-<NAME>` as the branch name and mangles slash-separated names — never the intended strain branch.
3. Foreground `claude --tmux` never returns; a sequential spawn loop hung on strain #1.
4. Detached children have no human to approve Claude Code permission prompts.
5. `printf '%q' | tmux send-keys` mangled multi-line task strings.

## Decision

1. **Worktree creation:** `git worktree add -b <exact-strain-branch> <path> <base>`. The `base` input (resolved trunk SHA/ref) is passed by the hatchery and recorded in the brood manifest; worktrees branch off it exactly.
2. **Session launch:** `tmux new-session -d` (detached) running `claude --dangerously-skip-permissions --settings '{"skipDangerousModePermissionPrompt":true}'`. The detached session supplies a PTY. The settings injection pre-accepts the one-time "Bypass Permissions mode" trust gate non-interactively, avoiding screen-scraping.
3. **Spawn topology:** two-pass — pass 1 launches all strain sessions in parallel; pass 2 polls each session for readiness then injects its task.
4. **Task injection:** each strain task is written to a temp file; delivered via `tmux load-buffer <file>` + `paste-buffer` + Enter. Bypasses send-keys quoting entirely.
5. **Readiness detection:** `tmux capture-pane` polled until the pane contains the string `hivemind:overlord` (READY_TIMEOUT=90 s, POLL_INTERVAL=2 s).
6. **Cleanup split:** hard failures before launch → kill session + remove worktree; post-launch timeout/inject failures → leave session alive, mark strain `failed` in manifest (recoverable by user).

## Considered Options

| Option | Rejected because |
|---|---|
| `claude --worktree <NAME> --tmux` directly | Requires a TTY the Bash tool cannot provide; mangles branch names |
| Foreground serial spawn | Blocks on strain #1 indefinitely; no parallel boot |
| Screen-scrape the bypass-permissions gate + keystroke injection | Brittle TUI coupling; the settings key `skipDangerousModePermissionPrompt` is a stable contract |
| `tmux send-keys` with `printf '%q'` escaping | Mangled multi-line prompts; quoting complexity grows with prompt content |

## Consequences

- ONE remaining TUI coupling: the `hivemind:overlord` ready-detection substring. If the overlord prompt changes, READY_TIMEOUT exhausts before injection. This is a documented maintenance point.
- `--dangerously-skip-permissions` widens child blast radius (consistent with ADR-0007: unattended children run the full standard pipeline with no human in the loop).
- New `base` input on `spawn-brood` and top-level `base` field in the brood manifest.
- Naming is now deterministic: tmux session `brood-<short-id>`, worktree `.claude/worktrees/<short-id>`.

## Amendment — 2026-05-30 (PR #154)

The bypass-mode blast radius above interacts with untrusted input: a strain task description may be sourced from a GitHub issue body and pasted into the child prompt, while the detached child has no interactive permission gate. Two compensating controls now mitigate the brood injection surface (defense-in-depth), plus a structural backstop:

1. **Data-boundary preamble in `task.md`** — `hivemind:spawn-brood` prepends the canonical external-content data-boundary preamble above the description payload (inside the same heredoc), so it is injected ahead of every strain description.
2. **Pre-spawn human approval of normalized task text** — the overlord brood gate (`overlord.md` steps 3a/3b) surfaces the normalized `{name, description}` task text to the human for explicit approval before spawn; with no downstream permission prompt, this approval is the injection gate.

Partial structural backstop (scoped to product-file mutation): the child is itself a delegating overlord whose `tools:` carry no `Write`/`Edit`, so embedded instructions that would mutate product files still route through branch → checkpoint → review → PR rather than direct file writes (Write-Capable Skill Containment, `plugin/governance/security-policy.md`). It does NOT contain all execution — the child holds `Bash` and runs `--dangerously-skip-permissions`, so a surviving injected instruction could drive Bash directly; the three compensating controls (preamble, human approval, allowlist) remain the real boundary. Status remains accepted.

## Amendment — 2026-05-30 (PR #154, I/O-primitive change)

The brood file writes (`task.md` and `manifest.yaml`) migrate from shell heredoc to the **Write tool**. Embedding untrusted text in heredoc syntax was the wrong primitive: `cat > file <<"$DELIM"` does NOT parameter-expand the delimiter word `$DELIM` (a quoted heredoc word is taken literally), so the "per-call random delimiter" scheme never actually randomized — the literal token `$DELIM` was the real delimiter on every spawn, and a payload line equal to the literal `$DELIM` would terminate the heredoc early and execute the subsequent lines in the hatchery shell. This is the same injection class the random-delimiter scheme was meant to close.

Decision:

1. **Write tool for both files.** `task.md` and `manifest.yaml` are each written with a single Write tool call. Write performs no shell parsing of untrusted bytes, eliminating the heredoc-delimiter injection class entirely (no delimiter to collide with, no path to hatchery-shell execution). The Write tool emits no chat text, so Silence Discipline is preserved (it is a permitted non-final tool call; the final routing/exit Bash call still follows).
2. **YAML validity is assured by the block-scalar discipline, not the removed delimiter.** Every manifest scalar derived from planner output, issue text, or a filesystem path is emitted as a YAML literal block scalar (`|`); only fixed-shape trusted literals stay inline. The sole residual YAML-authoring rule: an embedded newline inside an untrusted value must be reproduced indented to the block scalar's content indent. Refinement (2.17.5): exact-value fields (`name`, `branch`, `base`, `worktree_path`) use `|-` (strip chomping) so the parsed value has no trailing newline, and `hivemind:brood-status` double-quotes every manifest value it interpolates into a shell command — block scalars give YAML-injection safety, `|-` gives exact values, consumer quoting gives shell safety.
3. **P1 linked-worktree exclude-path fix.** Pre-flight 1f's repo-local exclude path is now resolved via `git rev-parse --git-path info/exclude` instead of a hardcoded `<repo_root>/.git/info/exclude`, which is wrong in a linked git worktree (`<repo_root>/.git` is a gitdir-pointer FILE, not a directory) — a supported context under recursive brood (a spawned child overlord spawning from a worktree).

Considered and rejected: a TRUE YAML serializer (`python3 -c 'import yaml; yaml.safe_dump(...)'` or `yq`). Rejected because (a) it adds a runtime dependency not guaranteed on consumers, and (b) passing untrusted input into a `-c` program reintroduces the same injection class unless the values are first written to files — which is the Write-tool primitive again. The Write tool is therefore the correct and sufficient primitive; the serializer fallback is recorded here only and is NOT placed in the SKILL body.

The prior amendment's "inside the same heredoc" phrasing for the `task.md` preamble is superseded by the Write-tool primitive (recorded here as an append; prior text is left intact). Status remains accepted.

## Amendment — 2026-05-30 (PR #154, shell-injection class closure)

Prior fixes leaned on "double-quote every dynamic token" as the shell-safety story. That is wrong: **double-quoting is not a shell-safety encoding.** When untrusted LITERAL bytes appear in the SOURCE of a command the agent hands to the Bash tool, bash command substitution `$(...)`, backticks, and `${}` STILL expand even inside double quotes. `git check-ref-format --branch` ACCEPTS branches like `feat/x$(touch${IFS}/tmp/pwn)`, so emitting `git check-ref-format --branch "feat/x$(touch...)"` runs `touch` before git ever validates the ref. Quoting stops only word-splitting and globbing.

Decision (closes the entire shell-injection class on `branch`/`base`):

1. **Agent-reasoning allowlist gate (primary).** `hivemind:spawn-brood` adds an **Input Validation Gate** applied by the agent in its OWN reasoning — the model matches each `branch`/`base` value against the literal rule `^[A-Za-z0-9._/-]+$` (non-empty, not starting with `-`, no `..`) BEFORE any Bash call, so raw untrusted bytes NEVER enter generated shell source. Only an already-clean value is ever placed into a (still double-quoted) shell token. The charset excludes every shell-special byte while keeping real branches valid (`feat/x.y`, `release/1.2.3`, `bugfix/foo-bar`).
2. **Derived values safe-by-construction.** `short` (sanitized `[a-z0-9-]`), `worktree_path` (`<repo_root>/.claude/worktrees/<short>`), and `tmux_session` (`brood-<short>`) carry no untrusted bytes and need no gate; they are quoted as defense-in-depth only.
3. **brood-status re-gates the manifest branch.** `hivemind:brood-status` re-applies the SAME allowlist (in agent reasoning) to every manifest value before its first shell use, skipping a strain's probes and reporting `blocked (branch failed safety allowlist)` on failure while continuing other strains. Defense in depth — the consumer does not trust the manifest file even though spawn-brood's gate should have prevented an unsafe value.
4. **`check-ref-format` demoted to defense-in-depth.** It runs AFTER the gate as ref-SHAPE validation on an already-safe value; it is never the shell-safety boundary (it accepts injection-bearing names).

Considered and rejected as PRIMARY: the out-of-band approach (Write-then-`cat`, or read into a shell variable referenced only as `"$var"`, which is inert because bash does not re-evaluate command substitution from variable contents). Recorded as a documented fallback only — rejected as primary because no real branch needs a forbidden byte, and clean rejection of a hostile name beats faithful execution of it. Status remains accepted.

## Amendment — 2026-05-30 (PR #154, behavior-preserving structural refactor)

The deterministic shell that `hivemind:spawn-brood` previously hand-templated in
its SKILL.md body is extracted into one committed script,
`plugin/skills/spawn-brood/scripts/spawn-brood.sh`. Same inputs produce identical
worktrees, sessions, manifest, and exit codes — no observable-behavior change.

Decision:

1. **File-based Write-tool inputs parsed by jq into inert variables.** The agent
   authors a single JSON inputs file (`.hivemind/brood/inputs.json`) with the
   Write tool; the script parses it with `jq` into shell variables referenced only
   as `"$var"`. This makes the command-substitution injection class STRUCTURALLY
   closed by architecture rather than per-snippet quoting: untrusted bytes never
   enter generated command source, and bash does not re-evaluate command
   substitution from variable contents. The round-7 allowlist gate is retained in
   the script as defense-in-depth ref-shape validation, no longer load-bearing.
2. **`jq` is now a required runtime dependency** (READ-only, for inputs parsing).
   The script blocks with a verbose `blocker: jq is required …` + exit 1 if
   absent, alongside the existing `tmux`/`claude` checks. ADR-0017's earlier
   rejection of a true YAML serializer for manifest WRITING still holds — manifest
   emission stays `printf` block-scalar.
3. **SKILL.md slimmed to a navigator; rationale relocated to `reference.md`.** The
   skill body is now ~4 imperative steps (build inputs → Write file → run script →
   interpret exit). The security WHY, three-layer manifest model, block-scalar
   chomping reasoning, ready-substring maintenance point, and inputs schema move to
   `plugin/skills/spawn-brood/reference.md`. The broad `allowed-tools` Bash grants
   collapse to the single precise
   `Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/spawn-brood/scripts/spawn-brood.sh *)`
   grant plus `Read`/`Write`, matching the `github-review-loop` precedent.

Status remains accepted.

## Amendment — 2026-05-30 (PR #154, filesystem-path out-of-band + tmux paste/buffer hardening)

The round-7 shell-injection closure (allowlist gate) covered `branch`/`base` but left filesystem PATHS treated as "safe-by-construction because `repo_root` came from `git rev-parse`" / "the user's own filesystem path, not in the threat model." That carve-out is SUPERSEDED and was wrong: the checkout DIRECTORY NAME is filesystem-controlled and can legally contain shell metacharacters (a repo cloned under `repo$(touch${IFS}PWNED)`), and command substitution `$(...)`/backticks expand even inside double quotes when those literal bytes appear in command source. Paths cannot be charset-allowlisted (legit paths contain spaces).

Decision (extends the round-7 closure to filesystem paths):

1. **Out-of-band path variables.** `repo_root` and the derived `worktree_path` are NEVER emitted as literal path text into command source. Each shell command derives the path INLINE via command substitution — `rr="$(git rev-parse --show-toplevel)"`, `wt="$rr/.claude/worktrees/<short>"` — whose output is captured into a variable and is then inert (bash does not re-evaluate command substitution from variable contents); the path is referenced only as `"$rr"`/`"$wt"`. The only literal interpolated is `<short>` (already sanitized to `[a-z0-9-]`). Because each Bash tool call runs in a fresh shell, the variable is re-derived within every command that needs it. Applied to every path-bearing shell site (`git worktree add`, the `task.md` parent `mkdir`, Pass-2 `load-buffer`, config-copy `mkdir`/`cp`, HARD-failure `git worktree remove --force`, and the pre-flight worktree-existence test). `worktree_path` is still recorded in the manifest as an absolute path via the Write tool — a tool parameter, no shell, so inert there.
2. **tmux bracketed paste (`paste-buffer -p`).** The task is always multiline (data-boundary preamble + blank line + description); `paste-buffer` without `-p` replaces linefeeds with carriage returns, so the TUI could receive the preamble and each description line as separate Enter-terminated submissions instead of one bounded prompt. `-p` (bracketed paste) injects the whole multiline issue-sourced payload as a single bounded prompt; the explicit `send-keys Enter` still submits it once.
3. **Best-effort named-buffer deletion on inject-failure.** `paste-buffer -d` deletes the per-strain named buffer (`brood-<short>`) only on a SUCCESSFUL paste. A `load-buffer` success followed by a `paste-buffer` failure (child pane exits between readiness and paste) leaves the untrusted issue-sourced task resident on the shared tmux server. Every inject-failure path now best-effort deletes the buffer (`tmux delete-buffer -b "brood-<short>" 2>/dev/null || true`), so an untrusted task never persists in the shared tmux buffer regardless of outcome.

Status remains accepted.
