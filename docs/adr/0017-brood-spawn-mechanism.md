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
