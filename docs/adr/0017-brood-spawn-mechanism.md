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

Structural backstop: the child is itself a delegating overlord whose `tools:` carry no `Write`/`Edit`, so embedded instructions still route through branch → checkpoint → review → PR rather than direct execution (Write-Capable Skill Containment, `plugin/governance/security-policy.md`). Status remains accepted.

## Amendment — 2026-05-30 (PR #154, I/O-primitive change)

The brood file writes (`task.md` and `manifest.yaml`) migrate from shell heredoc to the **Write tool**. Embedding untrusted text in heredoc syntax was the wrong primitive: `cat > file <<"$DELIM"` does NOT parameter-expand the delimiter word `$DELIM` (a quoted heredoc word is taken literally), so the "per-call random delimiter" scheme never actually randomized — the literal token `$DELIM` was the real delimiter on every spawn, and a payload line equal to the literal `$DELIM` would terminate the heredoc early and execute the subsequent lines in the hatchery shell. This is the same injection class the random-delimiter scheme was meant to close.

Decision:

1. **Write tool for both files.** `task.md` and `manifest.yaml` are each written with a single Write tool call. Write performs no shell parsing of untrusted bytes, eliminating the heredoc-delimiter injection class entirely (no delimiter to collide with, no path to hatchery-shell execution). The Write tool emits no chat text, so Silence Discipline is preserved (it is a permitted non-final tool call; the final routing/exit Bash call still follows).
2. **YAML validity is assured by the block-scalar discipline, not the removed delimiter.** Every manifest scalar derived from planner output, issue text, or a filesystem path is emitted as a YAML literal block scalar (`|`); only fixed-shape trusted literals stay inline. The sole residual YAML-authoring rule: an embedded newline inside an untrusted value must be reproduced indented to the block scalar's content indent.
3. **P1 linked-worktree exclude-path fix.** Pre-flight 1f's repo-local exclude path is now resolved via `git rev-parse --git-path info/exclude` instead of a hardcoded `<repo_root>/.git/info/exclude`, which is wrong in a linked git worktree (`<repo_root>/.git` is a gitdir-pointer FILE, not a directory) — a supported context under recursive brood (a spawned child overlord spawning from a worktree).

Considered and rejected: a TRUE YAML serializer (`python3 -c 'import yaml; yaml.safe_dump(...)'` or `yq`). Rejected because (a) it adds a runtime dependency not guaranteed on consumers, and (b) passing untrusted input into a `-c` program reintroduces the same injection class unless the values are first written to files — which is the Write-tool primitive again. The Write tool is therefore the correct and sufficient primitive; the serializer fallback is recorded here only and is NOT placed in the SKILL body.

The prior amendment's "inside the same heredoc" phrasing for the `task.md` preamble is superseded by the Write-tool primitive (recorded here as an append; prior text is left intact). Status remains accepted.
