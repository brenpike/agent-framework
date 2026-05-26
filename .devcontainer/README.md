# Dev Container

This dev container provisions a **CI-parity toolchain** so contributors can run the full validation suite and dogfood the hivemind plugin — in GitHub Codespaces or in VS Code Dev Containers.

## What it provides

- The exact validation toolchain used by `.github/workflows/policy-check.yml`, so a green local run is a strong signal the branch will pass CI.
- All CLI dependencies for hivemind plugin development: Claude Code CLI, Codex CLI, claude-mem, bun, uv/uvx, tmux.
- Plugin marketplaces registered (no auth required): hivemind, codex, claude-mem, caveman.
- A seeded `.claude/settings.local.json` with the Codex cache permission grant for this container's `$HOME`.

Plugin **enablement** (caveman, codex, claude-mem) and plugin **configuration** (SubagentStart hook, pluginConfigs, .envrc, permissions allowlist) are handled by `hivemind:setup-project` — the canonical path — not by postCreate. See [Configure the plugins](#configure-the-plugins-one-time-in-claude-code) below.

The base image is Ubuntu 20.04. A Debian/Ubuntu family image is mandatory: the policy linter requires GNU `grep -P` and `perl`, which Alpine/BusyBox lack. CI runs on `ubuntu-latest`, so minor coreutils/grep/perl/python version differences between the two are possible — the smoke test is a best-effort signal, not an absolute guarantee.

## How to launch

### GitHub Codespaces

In the browser:

1. Go to the repository on GitHub.
2. Click **Code** > **Codespaces** > **Create codespace on `<branch>`**.

Via the CLI:

```bash
gh codespace create --repo brenpike/hivemind --branch <branch>
```

GitHub pre-authenticates the `gh` CLI inside Codespaces via `GITHUB_TOKEN`. No manual `gh auth login` is needed.

### Local VS Code Dev Containers

Prerequisites:
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine on Linux)
- VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension installed

Steps:
1. Clone the repo and open it in VS Code.
2. Open the command palette (`Ctrl+Shift+P` / `Cmd+Shift+P`) and run **Dev Containers: Reopen in Container** (or **Dev Containers: Rebuild and Reopen in Container** if the container already exists).

> Note: In a local Dev Container the `gh` CLI is not pre-authenticated. Run `gh auth login` inside the container terminal before using `gh` commands.

## What happens automatically on first build

`postCreateCommand` runs `bash .devcontainer/postCreate.sh`, which does the following in order:

**Step 0 — apt hard requirements (hard fail if apt fails)**

Installs `jq` and `perl` via apt if not already present. These are required by the validation gates and by the settings-seeding steps below.

**Step 1 — Toolchain verification (hard fail if any tool is missing)**

Verifies that `bash`, `grep` (with PCRE `-P` support), `perl`, `sed`, `realpath`, `find`, `jq`, `python3`, `git`, `gh`, `node`, and `npm` are all on `PATH`. The script aborts immediately if any are missing.

**Step 2 — Dependency installs (soft fail — warns and continues)**

Each install is idempotent (skipped if already present) and wrapped so a single failure prints a warning but does not abort the build:

| Dependency | Install method |
|---|---|
| Claude Code CLI (`@anthropic-ai/claude-code`) | `npm install -g` |
| Codex CLI (`@openai/codex`) | `npm install -g` |
| `claude-mem` | `npm install -g` |
| `uv` / `uvx` (Astral) | Official install script (`astral.sh/uv/install.sh`) |
| `tmux` | `apt-get install -y tmux` |
| `bun` | Official install script (`bun.sh/install`) |

**Step 2 — Plugin marketplaces registered (soft fail)**

Registers the following marketplaces via `claude plugin marketplace add` (no auth required):

- `https://github.com/brenpike/hivemind.git`
- `https://github.com/openai/codex-plugin-cc.git`
- `thedotmack/claude-mem`
- `https://github.com/juliusbrussee/caveman`

**Step 2 — Codex cache permission grant seeded (soft fail)**

Writes the Codex cache Bash grant for the container's `$HOME` into `.claude/settings.local.json` so the local Codex review flow (`hivemind:adaptation-cycle`) runs prompt-free. Merged without clobbering existing entries.

**Step 3 — CI-parity smoke test (hard fail if any gate fails)**

Runs the same three gates as `.github/workflows/policy-check.yml`:

```bash
python3 -c "import json; json.load(open('plugin/.claude-plugin/plugin.json'))"
python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))"
bash ./tools/policy_check.sh --strict
bash ./tools/validate_reports.sh --batch tests/reports/
```

A green run here is a strong best-effort signal the branch will pass CI.

## Configure the plugins (one-time, in Claude Code)

Plugin enablement and configuration require an authenticated `claude` CLI session. postCreate handles OS/CLI tooling, marketplace registration, and the container-real-path Codex grant; everything below is done once inside Claude Code.

**Division of labor:**
- `postCreate.sh` — OS tooling, npm CLIs, marketplace registration, container-real-path Codex grant in `.claude/settings.local.json` (gitignored)
- `hivemind:setup-project` — plugin enablement (`enabledPlugins`), plugin config (`pluginConfigs`), SubagentStart hook, `.envrc`, permissions allowlist; writes to `.claude/settings.json` (tracked in this repo)

### Bootstrap order

**1. Authenticate and launch Claude Code**

```bash
claude
```

Follow the login prompt. In a **local Dev Container**, also run `gh auth login` in the container terminal before this step (Codespaces pre-auths `gh` via `GITHUB_TOKEN`).

**2. Enable the hivemind plugin**

This is the one prerequisite `setup-project` cannot do for itself — it is a skill that runs inside hivemind:

```text
claude plugin install hivemind@brenpike
claude plugin install codex@openai-codex
claude plugin install claude-mem@thedotmack
claude plugin install caveman@caveman
```

> When developing from a local source checkout, you can also install hivemind from the local path instead of the registry. See the Install section of the root README.

**3. Run setup-project**

This is the canonical step that writes all plugin configuration — caveman enablement, the caveman ultra SubagentStart hook, `pluginConfigs`, `.envrc`, and the recommended permissions allowlist:

```text
/hivemind:setup-project caveman=yes codex=yes claude_mem=yes seed_allowlist=yes
```

What it writes to `.claude/settings.json` (tracked):
- `enabledPlugins["hivemind@brenpike"]`, `enabledPlugins["caveman@caveman"]`, `enabledPlugins["codex@openai-codex"]`, `enabledPlugins["claude-mem@thedotmack"]`
- `pluginConfigs["caveman@caveman"].options.defaultLevel = "ultra"`
- `hooks.SubagentStart` entry pointing to `.claude/hooks/caveman-ultra-subagent.sh`
- `permissions.allow` — merged recommended least-privilege allowlist (read/output helpers + scoped git reads)

What it writes outside `.claude/settings.json`:
- `.envrc` — `export CAVEMAN_DEFAULT_MODE=ultra`
- `.claude/hooks/caveman-ultra-subagent.sh` — the SubagentStart hook script

All merges are append-if-absent: existing entries are never overwritten.

**4. Wire up Codex review**

```text
/codex:setup
```

## Running the validation suite manually

The three CI gates can be run at any time inside the container:

```bash
# Gate 1: JSON manifests parse
python3 -c "import json; json.load(open('plugin/.claude-plugin/plugin.json'))"
python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))"

# Gate 2: prose/contract linter
bash ./tools/policy_check.sh --strict

# Gate 3: report-format linter
bash ./tools/validate_reports.sh --batch tests/reports/
```

All three must pass before opening a PR.

## `.claude/settings.local.json`

This file is gitignored and per-contributor. `postCreate.sh` seeds one entry into it:

- **Codex cache Bash grant** — allows the local Codex review flow to run without permission prompts, scoped to the container's `$HOME`.

The seed is a jq-merge: it appends entries that are absent and never overwrites entries that are already present. Re-running the script is safe.

Note: caveman enablement (`enabledPlugins`, `pluginConfigs`) is no longer seeded here by postCreate. It is written to the tracked `.claude/settings.json` by `hivemind:setup-project caveman=yes`.

## Troubleshooting

**Re-run postCreate manually:**

```bash
bash .devcontainer/postCreate.sh
```

All install steps are idempotent. Re-running is safe and will skip already-installed tools.

**Soft-fail install warnings:**

Optional installs (npm globals, uv, bun, tmux, marketplace registration, Codex grant) print `[warn]` on failure but do not abort. The CI-parity smoke test gates are the must-pass part. Common causes in offline or locked-down Codespaces:

- Network access blocked — npm/curl installs fail silently; the toolchain verification and JSON/linter gates still run.
- `claude` CLI not yet installed — marketplace-add and Codex grant steps are skipped; the smoke test still runs.

**Ubuntu-20.04 vs CI `ubuntu-latest` caveat:**

CI runs on `ubuntu-latest`; this container pins `ubuntu-20.04`. Minor coreutils, grep, perl, and python version differences are possible. If a gate passes locally but fails in CI, check for version-sensitive behavior in `tools/policy_check.sh` or `tools/validate_reports.sh`.

**Caveman not active after build:**

The caveman marketplace is registered automatically, but caveman enablement requires running `hivemind:setup-project caveman=yes` inside an authenticated Claude Code session (see [Configure the plugins](#configure-the-plugins-one-time-in-claude-code) above). The `claude plugin install` step is also required.
