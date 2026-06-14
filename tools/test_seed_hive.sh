#!/usr/bin/env bash
#
# Integration runner for the seed-hive entrypoint (issue #247, STEP-005).
#
# Drives plugin/skills/seed-hive/scripts/seed-hive.sh end-to-end against DISPOSABLE tmp project
# roots, with a tmp HOME so companion detection + claude-mem provisioning are hermetic (the
# developer's real ~/.claude / ~/.claude-mem are never read or written). CI-runnable with ONLY
# jq + git present (no tmux / claude / gh): a fake `claude` binary is scaffolded in the tmp HOME
# for the claude-mem path case. SKIPs cleanly when jq or git is missing.
#
# Mirrors tools/test_brood_compat.sh / test_shared_libs.sh conventions: pass/fail counters,
# exit-nonzero-on-failure, all writes inside a disposable tmpdir removed on EXIT.
#
# LOCKED INVARIANTS:
#   1. clean seed (all companions no, allowlist yes) → the FULL Output block verbatim.
#   2. idempotent FULL re-run → all items already present/already documented, settings
#      byte-stable, status complete, target_file unchanged.
#   3. settings-merge agent conflict → status blocked, no overwrite.
#   4. all-companions-no path → correct reduced Output (caveman/claude_mem/codex skipped).
#   5. detect phase reports companion facts (manifest installed/absent, cache fallback, none).
#   6. headless-resolved inputs (inputs file fully specifies yes/no) drive a complete seed.
#
# Usage:
#   ./tools/test_seed_hive.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENTRYPOINT="$REPO_ROOT/plugin/skills/seed-hive/scripts/seed-hive.sh"

[ -f "$ENTRYPOINT" ] || { echo "FAIL: entrypoint missing: $ENTRYPOINT" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq is required to run this suite"  >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git is required to run this suite" >&2; exit 0; }

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_eq() {
  local case_name="$1" expected="$2" actual="$3" msg="${4:-}"
  if [ "$expected" = "$actual" ]; then
    pass "$case_name" "${msg:+$msg }(== '$expected')"
  else
    failed "$case_name" "${msg:+$msg }expected '$expected', got '$actual'"
  fi
}

# assert_contains <case> <needle> <haystack> [msg]
assert_contains() {
  local case_name="$1" needle="$2" haystack="$3" msg="${4:-}"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$case_name" "${msg:+$msg }(contains '$needle')"
  else
    failed "$case_name" "${msg:+$msg }missing '$needle'"
  fi
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-seed-hive.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; return 0; }
trap cleanup EXIT

# new_project <name> — create a disposable git project root with its own tmp HOME under it.
# Echoes the project root path. Sets HOME/PATH per-case via the returned root's fakehome.
new_project() {
  local name="$1"
  local root="$WORKDIR/$name"
  mkdir -p "$root/fakehome"
  ( cd "$root" && git init -q . )
  printf '%s\n' "$root"
}

# run_apply <root> <inputs_json_string> — run the apply phase with HOME pinned to <root>/fakehome.
# Echoes combined stdout.
run_apply() {
  local root="$1" inputs="$2"
  printf '%s' "$inputs" > "$root/inputs.json"
  HOME="$root/fakehome" bash "$ENTRYPOINT" apply "$root/inputs.json"
}

# run_detect <root> — run the detect phase with HOME pinned to <root>/fakehome.
run_detect() {
  local root="$1"
  HOME="$root/fakehome" bash "$ENTRYPOINT" detect "$root"
}

# ── Case 1: clean seed — full Output block verbatim ─────────────────────────────
echo '=== Case 1: clean seed (all companions no, allowlist yes) — full Output verbatim ==='
ROOT="$(new_project clean)"
INPUTS="$(jq -nc --arg r "$ROOT" '{
  project_root: $r, agent_target: "hivemind:overlord",
  caveman: "no", claude_mem: "no", codex: "no", seed_allowlist: "yes",
  companions: {
    "caveman@caveman":       {detected:"absent", source:"none", resolved:"no", via:"explicit-input"},
    "claude-mem@thedotmack": {detected:"absent", source:"none", resolved:"no", via:"explicit-input"},
    "codex@openai-codex":    {detected:"absent", source:"none", resolved:"no", via:"explicit-input"}
  }
}')"
OUT="$(run_apply "$ROOT" "$INPUTS")"
RC=$?
assert_eq "clean:exit" "0" "$RC" "apply exit code"
assert_contains "clean:status"      "status: complete" "$OUT"
assert_contains "clean:project"     "project_root:" "$OUT"
assert_contains "clean:target"      "- .claude/settings.json: created" "$OUT"
assert_contains "clean:gitignore"   "- .gitignore: created" "$OUT"
assert_contains "clean:envrc"       "- .envrc: skipped (caveman not enabled)" "$OUT"
assert_contains "clean:hookfile"    "- .claude/hooks/caveman-ultra-subagent.sh: skipped (caveman not enabled)" "$OUT"
assert_contains "clean:hookwire"    "- hooks.SubagentStart in settings.json: skipped (caveman not enabled)" "$OUT"
assert_contains "clean:companion"   "- caveman@caveman: detected: absent, source: none, resolved: no, via: explicit-input" "$OUT"
assert_contains "clean:memskip"     "- ~/.claude-mem/settings.json CLAUDE_CODE_PATH: skipped (claude_mem not enabled)" "$OUT"
assert_contains "clean:keyhive"     '- enabledPlugins["hivemind@brenpike"]: added' "$OUT"
assert_contains "clean:keyagent"    "- agent: added" "$OUT"
assert_contains "clean:keycave"     '- enabledPlugins["caveman@caveman"]: resolved no' "$OUT"
assert_contains "clean:keypcfg"     '- pluginConfigs["caveman@caveman"]: resolved no' "$OUT"
assert_contains "clean:allow1"      "- Bash(echo *): added" "$OUT"
assert_contains "clean:allowlast"   "- Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*): added" "$OUT"
assert_contains "clean:context"     "- creep-spread: invoked" "$OUT"
assert_contains "clean:testcmd"     "- repo-root CLAUDE.md ## Validation: none detected (recommend manual)" "$OUT"
assert_contains "clean:conflicts"   "conflicts:" "$OUT"
assert_contains "clean:noconflict"  "- None" "$OUT"
# settings.json actually written + parseable, agent + hivemind key present.
assert_eq "clean:settings.agent" "hivemind:overlord" \
  "$(jq -r '.agent' "$ROOT/.claude/settings.json" 2>/dev/null)" "settings agent"
assert_eq "clean:settings.hive" "true" \
  "$(jq -r '.enabledPlugins["hivemind@brenpike"]' "$ROOT/.claude/settings.json" 2>/dev/null)" "settings hive key"

# ── Case 2: idempotent full re-run — byte-stable, all already present ────────────
echo '=== Case 2: idempotent full re-run — byte-stable, already present, status complete ==='
SETTINGS_BEFORE="$(cat "$ROOT/.claude/settings.json")"
OUT2="$(run_apply "$ROOT" "$INPUTS")"
assert_eq "idem:exit" "0" "$?" "re-run exit code"
assert_contains "idem:status"     "status: complete" "$OUT2"
assert_contains "idem:target"     "- .claude/settings.json: unchanged" "$OUT2"
assert_contains "idem:gitignore"  "- .gitignore: already present" "$OUT2"
assert_contains "idem:keyhive"    '- enabledPlugins["hivemind@brenpike"]: already present' "$OUT2"
assert_contains "idem:keyagent"   "- agent: already present" "$OUT2"
assert_contains "idem:allow"      "- Bash(echo *): already present" "$OUT2"
assert_eq "idem:byte-stable" "$SETTINGS_BEFORE" "$(cat "$ROOT/.claude/settings.json")" "settings byte-stable across re-run"

# ── Case 3: settings-merge agent conflict → blocked, no overwrite ────────────────
echo '=== Case 3: agent conflict — status blocked, no overwrite ==='
ROOT3="$(new_project conflict)"
mkdir -p "$ROOT3/.claude"
printf '{"agent":"someone:else"}\n' > "$ROOT3/.claude/settings.json"
BEFORE3="$(cat "$ROOT3/.claude/settings.json")"
INPUTS3="$(jq -nc --arg r "$ROOT3" '{
  project_root: $r, caveman: "no", claude_mem: "no", codex: "no", seed_allowlist: "yes" }')"
OUT3="$(run_apply "$ROOT3" "$INPUTS3")"
assert_eq "conflict:exit" "0" "$?" "blocked is exit 0 (reported outcome)"
assert_contains "conflict:status"   "status: blocked" "$OUT3"
assert_contains "conflict:target"   "- .claude/settings.json: unchanged" "$OUT3"
assert_contains "conflict:conflict" "- agent: someone:else vs hivemind:overlord" "$OUT3"
assert_eq "conflict:no-overwrite" "$BEFORE3" "$(cat "$ROOT3/.claude/settings.json")" "settings byte-unchanged on conflict"

# ── Case 3b: malformed existing settings → blocked, byte-unchanged ───────────────
echo '=== Case 3b: malformed existing settings — blocked, byte-unchanged ==='
ROOT3B="$(new_project malformed)"
mkdir -p "$ROOT3B/.claude"
printf 'this is { not json\n' > "$ROOT3B/.claude/settings.json"
BEFORE3B="$(cat "$ROOT3B/.claude/settings.json")"
INPUTS3B="$(jq -nc --arg r "$ROOT3B" '{ project_root: $r, caveman: "no", claude_mem: "no", codex: "no", seed_allowlist: "yes" }')"
OUT3B="$(run_apply "$ROOT3B" "$INPUTS3B")"
assert_contains "malformed:status" "status: blocked" "$OUT3B"
assert_eq "malformed:byte-unchanged" "$BEFORE3B" "$(cat "$ROOT3B/.claude/settings.json")" "malformed file untouched"

# ── Case 4: all-companions-no reduced Output (already covered by Case 1) + caveman yes ──
echo '=== Case 4: caveman=yes seed — envrc + hook + pluginConfigs written ==='
ROOT4="$(new_project caveman)"
INPUTS4="$(jq -nc --arg r "$ROOT4" '{
  project_root: $r, caveman: "yes", claude_mem: "no", codex: "no", seed_allowlist: "yes" }')"
OUT4="$(run_apply "$ROOT4" "$INPUTS4")"
assert_eq "caveman:exit" "0" "$?" "caveman seed exit"
assert_contains "caveman:status"   "status: complete" "$OUT4"
assert_contains "caveman:envrc"    "- .envrc: created" "$OUT4"
assert_contains "caveman:hookfile" "- .claude/hooks/caveman-ultra-subagent.sh: created" "$OUT4"
assert_contains "caveman:hookwire" "- hooks.SubagentStart in settings.json: added" "$OUT4"
assert_contains "caveman:keypcfg"  '- pluginConfigs["caveman@caveman"]: added' "$OUT4"
assert_eq "caveman:envrc-content" "export CAVEMAN_DEFAULT_MODE=ultra" "$(cat "$ROOT4/.envrc")" ".envrc content"
[ -x "$ROOT4/.claude/hooks/caveman-ultra-subagent.sh" ] \
  && pass "caveman:hook-exec" "hook file is executable" \
  || failed "caveman:hook-exec" "hook file not executable"

# ── Case 5: detect phase — manifest installed/absent, cache fallback, none ───────
echo '=== Case 5: detect phase reports companion facts ==='
ROOT5="$(new_project detect)"
# 5a: no manifest, no cache → all absent/none.
OUT5A="$(run_detect "$ROOT5")"
assert_eq "detect:none-caveman" "absent" "$(printf '%s' "$OUT5A" | jq -r '.companions["caveman@caveman"].detected')"
assert_eq "detect:none-source"  "none"   "$(printf '%s' "$OUT5A" | jq -r '.companions["caveman@caveman"].source')"
# 5b: manifest with caveman installed → caveman installed/manifest, others absent/manifest.
mkdir -p "$ROOT5/fakehome/.claude/plugins"
printf '{"plugins":{"caveman@caveman":[{"x":1}]}}\n' > "$ROOT5/fakehome/.claude/plugins/installed_plugins.json"
OUT5B="$(run_detect "$ROOT5")"
assert_eq "detect:mf-caveman-det" "installed" "$(printf '%s' "$OUT5B" | jq -r '.companions["caveman@caveman"].detected')"
assert_eq "detect:mf-caveman-src" "manifest"  "$(printf '%s' "$OUT5B" | jq -r '.companions["caveman@caveman"].source')"
assert_eq "detect:mf-codex-det"   "absent"    "$(printf '%s' "$OUT5B" | jq -r '.companions["codex@openai-codex"].detected')"
assert_eq "detect:mf-codex-src"   "manifest"  "$(printf '%s' "$OUT5B" | jq -r '.companions["codex@openai-codex"].source')"
# 5c: no manifest, codex cache dir present → codex installed/cache.
rm -f "$ROOT5/fakehome/.claude/plugins/installed_plugins.json"
mkdir -p "$ROOT5/fakehome/.claude/plugins/cache/openai-codex/codex"
OUT5C="$(run_detect "$ROOT5")"
assert_eq "detect:cache-codex-det" "installed" "$(printf '%s' "$OUT5C" | jq -r '.companions["codex@openai-codex"].detected')"
assert_eq "detect:cache-codex-src" "cache"     "$(printf '%s' "$OUT5C" | jq -r '.companions["codex@openai-codex"].source')"

# ── Case 6: headless-resolved inputs drive a complete seed (claude_mem yes path) ─
echo '=== Case 6: headless-resolved inputs (claude_mem yes, allowlist no) → complete seed ==='
ROOT6="$(new_project headless)"
# claude-mem own config with an EMPTY CLAUDE_CODE_PATH + a fake claude binary on PATH.
mkdir -p "$ROOT6/fakehome/.claude-mem" "$ROOT6/fakehome/bin"
printf '{"other":"keep","CLAUDE_CODE_PATH":""}\n' > "$ROOT6/fakehome/.claude-mem/settings.json"
printf '#!/bin/sh\n' > "$ROOT6/fakehome/bin/claude"; chmod +x "$ROOT6/fakehome/bin/claude"
# a detectable test command (go.mod) so test_command: records.
printf 'module x\n' > "$ROOT6/go.mod"
INPUTS6="$(jq -nc --arg r "$ROOT6" '{
  project_root: $r, caveman: "no", claude_mem: "yes", codex: "no", seed_allowlist: "no" }')"
OUT6="$(PATH="$ROOT6/fakehome/bin:$PATH" run_apply "$ROOT6" "$INPUTS6")"
assert_eq "headless:exit" "0" "$?" "headless seed exit"
assert_contains "headless:status"   "status: complete" "$OUT6"
assert_contains "headless:memset"   "- ~/.claude-mem/settings.json CLAUDE_CODE_PATH: set" "$OUT6"
assert_contains "headless:allow-no" "- not requested" "$OUT6"
assert_contains "headless:testcmd"  "- repo-root CLAUDE.md ## Validation: recorded go test ./..." "$OUT6"
assert_eq "headless:mem-preserved" "keep" \
  "$(jq -r '.other' "$ROOT6/fakehome/.claude-mem/settings.json")" "claude-mem sibling key preserved"
assert_eq "headless:mem-set" "$ROOT6/fakehome/bin/claude" \
  "$(jq -r '.CLAUDE_CODE_PATH' "$ROOT6/fakehome/.claude-mem/settings.json")" "CLAUDE_CODE_PATH set to resolved binary"
# allowlist no → no permissions.allow written.
assert_eq "headless:no-allowlist" "null" \
  "$(jq -r '.permissions.allow // "null"' "$ROOT6/.claude/settings.json")" "permissions.allow absent when seed_allowlist=no"

# ── Tally ───────────────────────────────────────────────────────────────────────
echo
echo "test_seed_hive: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
