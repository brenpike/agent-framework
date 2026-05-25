#!/usr/bin/env bash
#
# Dev-container provisioning for the hivemind plugin source repo.
#
# Goal: a CI-parity toolchain. The three smoke-test gates at the end run the
# same three checks as .github/workflows/policy-check.yml, so a green run here
# is a strong best-effort signal that the branch will pass CI. It is not an
# absolute guarantee: CI runs on `ubuntu-latest` while this container pins
# `ubuntu-20.04`, so coreutils/grep/perl/python versions can differ between the
# two. The gates also act as a CRLF tripwire — the linters break on CRLF line
# endings.
#
# Structure:
#   (1) verify the validation toolchain is present (hard fail if missing)
#   (2) install required + optional dependencies (soft fail — warn, continue)
#   (3) run the three CI gates as a smoke test (hard fail on failure)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Soft-failure accounting for optional installs. The validation gates are the
# must-pass part; a single failed optional install warns but does not abort.
declare -a INSTALL_OK=()
declare -a INSTALL_WARN=()

note_ok()   { INSTALL_OK+=("$1"); echo "[ok]   $1"; }
note_warn() { INSTALL_WARN+=("$1"); echo "[warn] $1" >&2; }

# Run an optional install step. On failure, record a warning and continue.
try_step() {
    local label="$1"
    shift
    if "$@"; then
        note_ok "$label"
    else
        note_warn "$label (install failed — see output above)"
    fi
}

# ── (0) Ensure hard-required apt tools ──────────────────────────────────────
# jq and perl are HARD-REQUIRED: gate (1) below hard-fails if either is absent,
# and seed_codex_grant also calls jq directly.  Install them before the gate so
# a fresh container never aborts on a missing-tool that apt can supply.
#
# Idempotency: skip the apt round-trip when both tools are already on PATH.
# Failure handling: if apt fails the script aborts here (set -euo pipefail);
# gate (1) would catch a truly-missing tool anyway, but failing early is
# clearer.  Do NOT suppress apt errors — a silent failure masks the root cause.
if ! command -v jq > /dev/null 2>&1 || ! command -v perl > /dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y jq perl
fi

# ── (1) Verify validation toolchain ─────────────────────────────────────────

echo ''
echo '=== (1) Verifying validation toolchain ==='

declare -a MISSING_TOOLS=()
for tool in bash grep perl sed realpath find jq python3 git gh node npm; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

# The policy linter relies on GNU grep PCRE (grep -P). BusyBox/BSD grep lack it.
if command -v grep > /dev/null 2>&1; then
    if ! echo "test" | grep -qP 'te\Kst' 2>/dev/null; then
        MISSING_TOOLS+=("grep(-P/PCRE support)")
    fi
fi

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    echo "[FAIL] Required tooling missing: ${MISSING_TOOLS[*]}" >&2
    echo "       The base image must be Debian/Ubuntu family (GNU grep + perl)." >&2
    exit 1
fi
echo '[ok]   All required validation tools present (incl. GNU grep -P)'

# ── (2) Install dependencies (soft fail) ─────────────────────────────────────

echo ''
echo '=== (2) Installing dependencies ==='

# npm globals — guard so a re-run does not error. `npm install -g` is itself
# idempotent (it upgrades in place), so a check-then-install keeps logs quiet.
install_npm_global() {
    local pkg="$1"
    local bin="$2"
    if command -v "$bin" > /dev/null 2>&1; then
        echo "  $bin already present, skipping $pkg"
        return 0
    fi
    npm install -g "$pkg"
}

# Claude Code CLI. npm global is still supported (Node 18+); the package name
# is @anthropic-ai/claude-code. Anthropic also ships a native installer, but
# npm keeps this script self-contained alongside the other npm tools.
try_step "Claude Code CLI (@anthropic-ai/claude-code)" \
    install_npm_global "@anthropic-ai/claude-code" "claude"

# Codex CLI. The scoped package @openai/codex is the cross-platform npm path;
# the unscoped `codex` package is unrelated to OpenAI — do not use it.
try_step "Codex CLI (@openai/codex)" \
    install_npm_global "@openai/codex" "codex"

# claude-mem. npm global installs the binary; plugin hooks/worker register
# separately via the plugin install (handled in step 3's guidance, not here).
try_step "claude-mem (npm)" \
    install_npm_global "claude-mem" "claude-mem"

# uv / uvx (Astral) — official install script. Idempotent: re-running replaces
# the existing install. uvx is claude-mem's optional vector-search backend.
install_uv() {
    if command -v uvx > /dev/null 2>&1 || command -v uv > /dev/null 2>&1; then
        echo "  uv/uvx already present, skipping"
        return 0
    fi
    curl -LsSf https://astral.sh/uv/install.sh | sh
}
try_step "uv / uvx (Astral)" install_uv

# tmux — terminal multiplexer used by the hivemind brood skill (spawn-brood /
# brood-status open per-strain tmux sessions). Installed via apt; idempotent.
install_tmux() {
    if command -v tmux > /dev/null 2>&1; then
        echo "  tmux already present, skipping"
        return 0
    fi
    sudo apt-get update -qq
    sudo apt-get install -y tmux
}
try_step "tmux" install_tmux

# bun — fast JS runtime / package manager; a claude-mem dependency. Installed
# via the official installer. Idempotent: skipped if bun is already on PATH.
# The bin dir ($HOME/.bun/bin) is added to PATH for this shell session so any
# subsequent steps in postCreate can invoke bun if needed.
install_bun() {
    if command -v bun > /dev/null 2>&1; then
        echo "  bun already present, skipping"
        return 0
    fi
    curl -fsSL https://bun.sh/install | bash
    # Make bun available for the remainder of this script.
    export PATH="${HOME}/.bun/bin:${PATH}"
}
try_step "bun (claude-mem dependency)" install_bun

# ── Codex cache permission grant ─────────────────────────────────────────────
# Seed the GITIGNORED .claude/settings.local.json (never the tracked
# settings.json) with the Codex cache Bash grant for THIS container's $HOME,
# so the local Codex review flow runs prompt-free. Merge without clobbering.
seed_codex_grant() {
    local grant="Bash(node ${HOME}/.claude/plugins/cache/openai-codex/codex/*)"
    local settings='.claude/settings.local.json'

    mkdir -p .claude
    if [[ ! -f "$settings" ]]; then
        echo '{"permissions":{"allow":[]}}' > "$settings"
    fi

    # Already present (for this exact grant) → nothing to do.
    if jq -e --arg g "$grant" \
        '(.permissions.allow // []) | index($g) != null' \
        "$settings" > /dev/null 2>&1; then
        echo "  Codex cache grant already present, skipping"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    jq --arg g "$grant" \
        '.permissions = (.permissions // {}) | .permissions.allow = ((.permissions.allow // []) + [$g])' \
        "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "  Seeded Codex cache grant for HOME=${HOME}"
}
try_step "Codex cache permission grant (.claude/settings.local.json)" seed_codex_grant

# ── Claude Code plugin installs (non-interactive) ────────────────────────────
# `claude plugin install <plugin>@<marketplace>` is a real non-interactive
# command. `claude plugin marketplace add <url-or-repo>` registers a
# marketplace. Both require an authenticated `claude` CLI; in a fresh container
# the CLI is not yet logged in, so these are documented as guidance rather than
# forced — running them unauthenticated would fail noisily. We attempt the
# marketplace adds (which do not require auth) and print the install commands.
install_plugins() {
    if ! command -v claude > /dev/null 2>&1; then
        echo "  claude CLI not installed; skipping plugin setup"
        return 1
    fi

    # Marketplace registration is local metadata and does not require login.
    claude plugin marketplace add https://github.com/brenpike/hivemind.git || true
    claude plugin marketplace add https://github.com/openai/codex-plugin-cc.git || true
    claude plugin marketplace add thedotmack/claude-mem || true
    claude plugin marketplace add https://github.com/caveman/caveman || true

    cat <<'EOF'
  Marketplaces registered. To finish plugin setup, run these inside Claude Code
  (the CLI must be authenticated first — `claude` then sign in):

    claude plugin install hivemind@brenpike
    claude plugin install codex@openai-codex
    claude plugin install claude-mem@claude-mem
    /codex:setup
EOF
}
try_step "Claude Code plugin marketplaces + install guidance" install_plugins

# ── Caveman plugin enable ─────────────────────────────────────────────────────
# caveman@caveman is enabled by default in this container. Marketplace add
# (above) requires no auth. Enabling via enabledPlugins in the GITIGNORED
# settings.local.json also requires no auth — it is purely local config.
# pluginConfigs sets the default output level to ultra to match framework
# agent expectations. Merge without clobbering existing entries.
seed_caveman_enable() {
    local settings='.claude/settings.local.json'

    mkdir -p .claude
    if [[ ! -f "$settings" ]]; then
        echo '{"permissions":{"allow":[]}}' > "$settings"
    fi

    # Idempotent: skip if caveman@caveman is already in enabledPlugins.
    if jq -e '(.enabledPlugins // {}) | has("caveman@caveman")' \
        "$settings" > /dev/null 2>&1; then
        echo "  caveman@caveman already enabled, skipping"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    jq '
      .enabledPlugins = ((.enabledPlugins // {}) + {"caveman@caveman": true}) |
      .pluginConfigs  = ((.pluginConfigs  // {}) + {"caveman@caveman": {"options": {"defaultLevel": "ultra"}}})
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "  Enabled caveman@caveman (ultra) in .claude/settings.local.json"
}
try_step "Caveman plugin enable (.claude/settings.local.json)" seed_caveman_enable

# ── (3) CI-parity smoke test (hard fail) ─────────────────────────────────────
# These three steps mirror .github/workflows/policy-check.yml exactly. The
# JSON gate uses the python3 form to match CI (CLAUDE.md documents jq as the
# local equivalent; both interpreters are present in this container).

echo ''
echo '=== (3) CI-parity smoke test ==='

echo '--- JSON manifests parse (python3, matches CI) ---'
python3 -c "import json; json.load(open('plugin/.claude-plugin/plugin.json'))"
python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))"
echo '[ok]   Both JSON manifests parse'

echo '--- policy_check.sh --strict ---'
bash ./tools/policy_check.sh --strict

echo '--- validate_reports.sh --batch tests/reports/ ---'
bash ./tools/validate_reports.sh --batch tests/reports/

# ── Summary ──────────────────────────────────────────────────────────────────

echo ''
echo '=== Summary ==='
echo "Installs succeeded: ${#INSTALL_OK[@]}"
for item in "${INSTALL_OK[@]+"${INSTALL_OK[@]}"}"; do
    echo "  [ok]   $item"
done
if [[ ${#INSTALL_WARN[@]} -gt 0 ]]; then
    echo "Installs with warnings: ${#INSTALL_WARN[@]}"
    for item in "${INSTALL_WARN[@]}"; do
        echo "  [warn] $item"
    done
    echo ''
    echo 'Optional installs warned but the CI-parity gates passed.'
    echo 'Re-run: bash .devcontainer/postCreate.sh (installs are idempotent).'
fi
echo ''
echo 'Dev container ready. CI-parity validation gates passed.'
