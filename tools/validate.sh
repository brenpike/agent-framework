#!/usr/bin/env bash
# Path-selective validation dispatcher for the hivemind repo (issue #164, STEP-001).
#
# Runs the repo's validation suite ONCE pre-PR. Two run shapes:
#   --all       Full suite, identical to .github/workflows/policy-check.yml (CI parity).
#   --changed   Map the changed-file set to the minimal set of suites that exercise
#               those paths, then run only those. FAIL-CLOSED: any ambiguity runs MORE.
#
# This script gates correctness. A mis-mapped path that skips a relevant heavy suite is a
# false-green. Every unmapped/unknown path therefore escalates to the FULL suite — never a
# silent skip. The mapping globs below were derived by reading each tool to confirm the exact
# inputs it exercises (test_engine.sh, test_brood_compat.sh, test_shared_libs.sh,
# validate_reports.sh, validate_workflows.sh, policy_check.sh).
#
# Usage:
#   bash tools/validate.sh [--all]
#   bash tools/validate.sh --changed [--base <ref>]
#   bash tools/validate.sh --self-test
#   bash tools/validate.sh -h | --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# ── Suite invocations (CI parity — see .github/workflows/policy-check.yml) ────────
# Each constant is the exact command CI runs, in CI order. --all replays them verbatim.
SUITE_JSON_MANIFESTS='json-manifests'   # special: two python3 json.load parses
SUITE_POLICY_CHECK='policy_check.sh --strict'
SUITE_VALIDATE_REPORTS='validate_reports.sh --batch tests/reports/'
SUITE_WORKFLOWS_STRICT='validate_workflows.sh --strict'
SUITE_WORKFLOWS_SELFTEST='validate_workflows.sh --self-test'
SUITE_TEST_ENGINE='test_engine.sh'
SUITE_TEST_SHARED='test_shared_libs.sh'
SUITE_TEST_BROOD='test_brood_compat.sh'
SUITE_TEST_FIX_HISTORY='test_fix_history_classify.sh'
SUITE_TEST_FETCH_NORMALIZE='test_fetch_normalize.sh'

# Full suite, in CI order. Used by --all and by every FAIL-CLOSED escalation.
ALL_SUITES=(
  "$SUITE_JSON_MANIFESTS"
  "$SUITE_POLICY_CHECK"
  "$SUITE_VALIDATE_REPORTS"
  "$SUITE_WORKFLOWS_STRICT"
  "$SUITE_WORKFLOWS_SELFTEST"
  "$SUITE_TEST_ENGINE"
  "$SUITE_TEST_SHARED"
  "$SUITE_TEST_BROOD"
  "$SUITE_TEST_FIX_HISTORY"
  "$SUITE_TEST_FETCH_NORMALIZE"
)

# KNOWN_SUITES: the tools/*.sh validation suites this dispatcher knows about. --self-test
# cross-checks this list against the actual tools/*.sh glob: a new suite that is neither here
# nor in NON_SUITE_TOOLS is a coverage gap and fails --self-test.
KNOWN_SUITES=(
  policy_check.sh
  validate_reports.sh
  validate_workflows.sh
  test_engine.sh
  test_shared_libs.sh
  test_brood_compat.sh
  test_fix_history_classify.sh
  test_fetch_normalize.sh
)

# NON_SUITE_TOOLS: tools/*.sh files that are NOT validation suites (so --self-test does not
# demand a mapping rule for them). This dispatcher is itself excluded.
NON_SUITE_TOOLS=(
  validate.sh
)

# ── Suite execution ──────────────────────────────────────────────────────────────
# run_suite: execute one suite token against the real repo. Returns the suite's exit status.
run_suite() {
  local suite="$1"
  case "$suite" in
    "$SUITE_JSON_MANIFESTS")
      python3 -c "import json; json.load(open('plugin/.claude-plugin/plugin.json'))" \
        && python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))"
      ;;
    *)
      # shellcheck disable=SC2086 # word-splitting of "script.sh --flag arg" is intentional
      bash "$SCRIPT_DIR"/$suite
      ;;
  esac
}

# run_suites: run a de-duped, CI-ordered subset. Prints a header per suite. Exits non-zero if
# any suite fails, after attempting every selected suite (no early abort — full signal).
run_suites() {
  local -a requested=("$@")
  local -a ordered=()
  local s w
  # Reorder the requested set into canonical CI order so output is stable and the cheap
  # policy_check/json parse run first.
  for s in "${ALL_SUITES[@]}"; do
    for w in "${requested[@]}"; do
      if [[ "$s" == "$w" ]]; then
        ordered+=("$s")
        break
      fi
    done
  done

  if [[ ${#ordered[@]} -eq 0 ]]; then
    echo "no impacted files — running nothing, exit 0"
    return 0
  fi

  local rc=0
  for s in "${ordered[@]}"; do
    echo
    echo "=== validate.sh: running [$s] ==="
    if run_suite "$s"; then
      echo "--- [$s] PASS ---"
    else
      echo "--- [$s] FAIL ---" >&2
      rc=1
    fi
  done
  return "$rc"
}

# ── Path → suite mapping (FAIL-CLOSED) ─────────────────────────────────────────────
# map_path: append to the global SELECTED array (suite\tpath) every suite a single changed
# path triggers, plus a reason. Composes by UNION — one path may hit several rules. A path
# matching NO rule (and not classified as docs-only) escalates to the FULL suite via the
# FULLSUITE sentinel.
#
# Globs verified against each tool:
#   plugin/workflows/*.json            -> validate_workflows --strict + --self-test
#   plugin/skills/record-state-result/scripts/**, init-run-ledger/scripts/**, tests/engine/**,
#     plugin/skills/_shared/containment.sh
#                                      -> test_engine  (also validate_workflows reads tests/engine;
#                                         containment.sh is copied into test_engine's fake plugin)
#   plugin/skills/spawn-brood/**, brood-status/**, init-run-ledger/scripts/**,
#     plugin/skills/_shared/containment.sh, tests/brood/**
#                                      -> test_brood_compat
#   plugin/skills/_shared/*.sh, tests/brood/**          -> test_shared_libs
#   tests/reports/**                                    -> validate_reports
#   plugin/agents/{cerebrate,local-reviewer,github-reviewer}.md,
#     plugin/skills/github-review-loop/SKILL.md         -> validate_workflows (exit_reason contracts)
#   tests/workflow-defs/**                              -> validate_workflows
#   plugin/**, .claude-plugin/**, tests/policy/**, tests/plugin/**, tests/workflows/**, *.md under plugin
#                                      -> policy_check
#   plugin/.claude-plugin/plugin.json or .claude-plugin/marketplace.json -> json-manifests parse
#   tools/**                           -> FULL suite (validator bootstrap)
#   .github/**                         -> FULL suite (CI bootstrap — the gate harness itself)
#   outside plugin|.claude-plugin|tools|tests|.github (docs: README.md, docs/**) -> no code suites
#   anything matching no rule          -> FULL suite

SELECTED=()      # lines of "suite<TAB>reason"
FORCE_FULL=0     # set to 1 by any FAIL-CLOSED escalation
FORCE_FULL_REASON=''
FORCE_FULL_SELFTEST=0  # set to 1 when the escalation is a validator-bootstrap change (tools/**,
                       # .github/**): the full suite must ALSO run this dispatcher's --self-test,
                       # since a broken path->suite mapping in validate.sh itself would otherwise
                       # green a --changed run without the mapping-coverage assertions executing.

add_selected() {
  SELECTED+=("$1"$'\t'"$2")
}

force_full() {
  FORCE_FULL=1
  FORCE_FULL_REASON="$1"
}

# force_full_bootstrap: a FAIL-CLOSED escalation triggered by a change to the validator harness
# itself (tools/**, .github/**). In addition to the full suite, the dispatcher's own --self-test
# must run so a broken mapping rule cannot merge behind a green --changed.
force_full_bootstrap() {
  force_full "$1"
  FORCE_FULL_SELFTEST=1
}

map_path() {
  local p="$1"
  local matched=0

  # tools/** -> validator bootstrap: re-run everything (including this script's --self-test).
  if [[ "$p" == tools/* ]]; then
    force_full_bootstrap "tools change ($p) — validator bootstrap, full suite + self-test"
    return 0
  fi

  # .github/** -> CI bootstrap: the workflow that runs this dispatcher is itself the gate
  # harness. A change there (e.g. rewiring dispatch, dropping the --all branch) is the other
  # half of the validator-bootstrap surface, so fail-closed to the FULL suite — same posture
  # as tools/**. Never docs-only: an unguarded workflow edit could green a --changed run with
  # zero suites executed.
  if [[ "$p" == .github/* ]]; then
    force_full_bootstrap "CI/workflow change ($p) — validator bootstrap, full suite + self-test"
    return 0
  fi

  # JSON manifests.
  if [[ "$p" == "plugin/.claude-plugin/plugin.json" || "$p" == ".claude-plugin/marketplace.json" ]]; then
    add_selected "$SUITE_JSON_MANIFESTS" "$p (JSON manifest)"
    matched=1
  fi

  # validate_workflows: workflow defs.
  if [[ "$p" == plugin/workflows/*.json ]]; then
    add_selected "$SUITE_WORKFLOWS_STRICT" "$p (workflow definition)"
    add_selected "$SUITE_WORKFLOWS_SELFTEST" "$p (workflow definition)"
    matched=1
  fi
  # validate_workflows: exit_reason contract documents.
  case "$p" in
    plugin/agents/cerebrate.md|plugin/agents/local-reviewer.md|plugin/agents/github-reviewer.md|plugin/skills/github-review-loop/SKILL.md)
      add_selected "$SUITE_WORKFLOWS_STRICT" "$p (exit_reason / state contract source)"
      add_selected "$SUITE_WORKFLOWS_SELFTEST" "$p (exit_reason / state contract source)"
      matched=1
      ;;
  esac
  # validate_workflows: workflow-def fixtures.
  if [[ "$p" == tests/workflow-defs/* ]]; then
    add_selected "$SUITE_WORKFLOWS_STRICT" "$p (workflow-def fixture)"
    add_selected "$SUITE_WORKFLOWS_SELFTEST" "$p (workflow-def fixture)"
    matched=1
  fi

  # test_engine: engine scripts + engine fixtures (validate_workflows also reads tests/engine).
  # Also containment.sh: test_engine.sh copies the shared containment guard into its fake plugin
  # and exercises engine symlink/external-path containment cases, so a containment.sh change must
  # trigger test_engine or record/init engine containment regressions go untested under --changed.
  if [[ "$p" == plugin/skills/record-state-result/scripts/* \
     || "$p" == plugin/skills/init-run-ledger/scripts/* \
     || "$p" == plugin/skills/_shared/containment.sh \
     || "$p" == tests/engine/* ]]; then
    add_selected "$SUITE_TEST_ENGINE" "$p (engine script/fixture)"
    matched=1
  fi
  if [[ "$p" == tests/engine/* ]]; then
    add_selected "$SUITE_WORKFLOWS_STRICT" "$p (run-ledger fixture, validate_workflows)"
    add_selected "$SUITE_WORKFLOWS_SELFTEST" "$p (run-ledger fixture, validate_workflows)"
  fi

  # test_brood_compat: spawn-brood / brood-status scripts + init engine + brood fixtures.
  # Also containment.sh: the shared containment guard's regressions are exercised ONLY by
  # test_brood_compat (via spawn-brood.sh / brood-status guards), not test_shared_libs — so a
  # containment.sh change must trigger this suite or its only relevant coverage is skipped.
  if [[ "$p" == plugin/skills/spawn-brood/* \
     || "$p" == plugin/skills/brood-status/* \
     || "$p" == plugin/skills/init-run-ledger/scripts/* \
     || "$p" == plugin/skills/_shared/containment.sh \
     || "$p" == tests/brood/* ]]; then
    add_selected "$SUITE_TEST_BROOD" "$p (brood script/fixture)"
    matched=1
  fi

  # test_shared_libs: shared libs + brood fixtures.
  if [[ "$p" == plugin/skills/_shared/*.sh || "$p" == tests/brood/* ]]; then
    add_selected "$SUITE_TEST_SHARED" "$p (shared lib / brood fixture)"
    matched=1
  fi

  # validate_reports: report fixtures.
  if [[ "$p" == tests/reports/* ]]; then
    add_selected "$SUITE_VALIDATE_REPORTS" "$p (report fixture)"
    matched=1
  fi

  # test_fix_history_classify: the pure jq classification filter + its payload fixtures. The .jq
  # filter is ALSO a plugin/* file (policy_check prose-lints it via the wholesale rule below), but
  # policy_check NEVER EXECUTES jq — so without this rule a filter edit would only be prose-linted,
  # never behaviorally exercised. Route both the filter glob and the fixture dir to the behavioral
  # suite. (tools/test_fix_history_classify.sh itself is covered by the tools/** full-suite leg.)
  if [[ "$p" == plugin/skills/github-review-loop/scripts/*.jq \
     || "$p" == tests/fix-history/* ]]; then
    add_selected "$SUITE_TEST_FIX_HISTORY" "$p (fix-history classify filter/fixture)"
    matched=1
  fi

  # test_fetch_normalize: the fetch + normalize candidate-set builder (.sh) + its payload/expected
  # fixtures. The script is ALSO a plugin/* file (policy_check prose-lints it via the wholesale rule
  # below), but policy_check NEVER EXECUTES bash — so without this rule a fetch-normalize edit would
  # only be prose-linted, never behaviorally exercised. Route both the script and its fixture dir to
  # the behavioral suite. (tools/test_fetch_normalize.sh itself is covered by the tools/** leg.)
  if [[ "$p" == plugin/skills/github-review-loop/scripts/fetch-normalize.sh \
     || "$p" == tests/fetch-normalize/* ]]; then
    add_selected "$SUITE_TEST_FETCH_NORMALIZE" "$p (fetch-normalize builder/fixture)"
    matched=1
  fi

  # policy_check: all plugin/.claude-plugin runtime + policy/plugin/workflows fixtures.
  if [[ "$p" == plugin/* \
     || "$p" == .claude-plugin/* \
     || "$p" == tests/policy/* \
     || "$p" == tests/plugin/* \
     || "$p" == tests/workflows/* ]]; then
    add_selected "$SUITE_POLICY_CHECK" "$p (policy/contract surface)"
    matched=1
  fi

  # policy_check: README.md. Although README.md lives outside every code tree (docs-only by
  # location), policy_check's compatibility fixtures tests/plugin/readme-agent-names-match.json
  # and tests/plugin/readme-skill-names-match.json READ README.md. A README-only PR would
  # otherwise select no suite and merge with PR CI green, only for the push-to-main full suite
  # to fail if an agent/skill name drifted. Route README.md through policy_check --strict so the
  # README compatibility contract is exercised pre-PR.
  if [[ "$p" == "README.md" ]]; then
    add_selected "$SUITE_POLICY_CHECK" "$p (README compatibility fixtures in policy_check)"
    matched=1
  fi

  if [[ "$matched" -eq 1 ]]; then
    return 0
  fi

  # Docs-only: outside every code-bearing tree -> no code suites.
  case "$p" in
    plugin/*|.claude-plugin/*|tools/*|tests/*)
      # Inside a code tree but matched nothing above -> FAIL-CLOSED.
      force_full "unmapped path inside code tree ($p) — full suite"
      ;;
    *)
      echo "  docs-only (no code suite): $p"
      ;;
  esac
}

# ── --changed plumbing ─────────────────────────────────────────────────────────────
# resolve_base: echo a resolved base ref (a commit-ish usable in `git diff <base>...HEAD`),
# or empty string if none resolves. For each candidate it requires a successful merge-base
# with HEAD.
#
# FAIL-CLOSED on explicit base: when the caller supplies an explicit --base (e.g. the PR
# workflow's `--base origin/main`), that ref is the ONLY candidate. If it cannot be verified
# (detached/shallow checkout where the explicit ref is missing), we return empty rather than
# silently narrowing to origin/main/main/HEAD~1 — a narrower fallback would map only the last
# commit and skip earlier runtime-file changes in a multi-commit PR, defeating the advertised
# fail-closed posture. An empty return drives run_changed to escalate to the FULL suite. The
# origin/main → main → HEAD~1 fallback chain applies ONLY when no explicit base was supplied.
resolve_base() {
  local explicit="$1"
  local cand
  local -a candidates=()
  if [[ -n "$explicit" ]]; then
    candidates+=("$explicit")
  else
    candidates+=(origin/main main HEAD~1)
  fi

  for cand in "${candidates[@]}"; do
    if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      local mb
      if mb="$(git merge-base "$cand" HEAD 2>/dev/null)" && [[ -n "$mb" ]]; then
        echo "$mb"
        return 0
      fi
    fi
  done
  echo ""
  return 0
}

# changed_files: print the de-duped changed-file set: committed diff base...HEAD UNION
# unstaged/working diff UNION porcelain status paths (uncommitted/in-progress edits).
changed_files() {
  local base="$1"
  {
    # --no-renames: when Git detects a rename, --name-only reports ONLY the destination, so a
    # PR that moves a runtime file (e.g. plugin/governance/foo.md -> docs/foo.md) would be
    # classified docs-only and skip every suite even though the plugin payload lost a runtime
    # file. Disabling rename detection emits the original (deleted) path AND the new path as
    # separate entries, so the source code-tree path still triggers the fail-closed/policy leg.
    git diff --no-renames --name-only "$base...HEAD" 2>/dev/null || true
    git diff --no-renames --name-only HEAD 2>/dev/null || true
    # Porcelain: strip the 2-char XY status + space; handle "old -> new" renames (both paths).
    git status --porcelain 2>/dev/null | while IFS= read -r line; do
      local rest="${line:3}"
      if [[ "$rest" == *' -> '* ]]; then
        printf '%s\n' "${rest%% -> *}" "${rest##* -> }"
      else
        printf '%s\n' "$rest"
      fi
    done
  } | sed '/^$/d' | sort -u
}

run_changed() {
  local base_arg="$1"
  local base
  base="$(resolve_base "$base_arg")"

  if [[ -z "$base" ]]; then
    echo "validate.sh --changed: NO base ref resolved (tried '${base_arg:-<none>}', origin/main, main, HEAD~1)." >&2
    echo "FAIL-CLOSED: running FULL suite." >&2
    run_suites "${ALL_SUITES[@]}"
    return $?
  fi

  echo "validate.sh --changed"
  echo "resolved base: $base"

  local -a files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(changed_files "$base")

  echo "changed-file set (${#files[@]}):"
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "  (none)"
    echo "no impacted files — exit 0"
    return 0
  fi
  local f
  for f in "${files[@]}"; do
    echo "  $f"
  done

  echo "mapping:"
  for f in "${files[@]}"; do
    map_path "$f"
  done

  if [[ "$FORCE_FULL" -eq 1 ]]; then
    echo "FAIL-CLOSED escalation: $FORCE_FULL_REASON"
    local full_rc=0
    if [[ "$FORCE_FULL_SELFTEST" -eq 1 ]]; then
      echo "validator-bootstrap change — running --self-test (mapping-coverage gate) first."
      echo
      echo "=== validate.sh: running [self-test] ==="
      if self_test; then
        echo "--- [self-test] PASS ---"
      else
        echo "--- [self-test] FAIL ---" >&2
        full_rc=1
      fi
    fi
    echo "running FULL suite."
    run_suites "${ALL_SUITES[@]}" || full_rc=1
    return "$full_rc"
  fi

  # De-dupe SELECTED into a unique suite list, printing WHY each suite was selected.
  local -a suites=()
  local entry suite reason seen
  declare -A reasons_seen=()
  for entry in "${SELECTED[@]}"; do
    suite="${entry%%$'\t'*}"
    reason="${entry#*$'\t'}"
    echo "  select [$suite] <- $reason"
    seen=0
    for s in "${suites[@]:-}"; do
      [[ "$s" == "$suite" ]] && seen=1 && break
    done
    [[ "$seen" -eq 0 ]] && suites+=("$suite")
  done

  echo
  echo "selected ${#suites[@]} suite(s)."
  run_suites "${suites[@]}"
  return $?
}

# ── --self-test (mapping-coverage assertion) ────────────────────────────────────────
self_test() {
  local fails=0
  echo "validate.sh --self-test: mapping coverage"

  # 1. Every KNOWN_SUITES entry must be referenced by at least one mapping rule. We probe by
  #    feeding a representative path per suite and asserting map_path selects it.
  declare -A probe=(
    ["policy_check.sh"]="plugin/agents/overlord.md"
    ["validate_reports.sh"]="tests/reports/some-fixture.txt"
    ["validate_workflows.sh"]="plugin/workflows/main.json"
    ["test_engine.sh"]="tests/engine/ledger-x.json"
    ["test_shared_libs.sh"]="plugin/skills/_shared/allowlist.sh"
    ["test_brood_compat.sh"]="tests/brood/manifest-x.json"
    ["test_fix_history_classify.sh"]="tests/fix-history/case01-x.json"
    ["test_fetch_normalize.sh"]="tests/fetch-normalize/case-x.json"
  )
  local script_name expected_suite suite_path probe_path hit
  for script_name in "${KNOWN_SUITES[@]}"; do
    probe_path="${probe[$script_name]:-}"
    if [[ -z "$probe_path" ]]; then
      echo "FAIL: KNOWN_SUITES entry '$script_name' has no --self-test probe path"
      fails=$((fails + 1))
      continue
    fi
    SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
    map_path "$probe_path" >/dev/null
    hit=0
    for entry in "${SELECTED[@]:-}"; do
      suite_path="${entry%%$'\t'*}"
      # suite_path is like "validate_workflows.sh --strict" or "json-manifests"; match prefix.
      if [[ "$suite_path" == "$script_name"* ]]; then hit=1; break; fi
    done
    if [[ "$hit" -eq 1 ]]; then
      echo "PASS: suite $script_name reachable via $probe_path"
    else
      echo "FAIL: suite $script_name NOT reachable from probe $probe_path"
      fails=$((fails + 1))
    fi
  done

  # 2. Every tools/*.sh validation suite must be in KNOWN_SUITES or NON_SUITE_TOOLS.
  local tool base in_known in_non
  while IFS= read -r tool; do
    base="$(basename "$tool")"
    in_known=0; in_non=0
    for s in "${KNOWN_SUITES[@]}"; do [[ "$s" == "$base" ]] && in_known=1 && break; done
    for s in "${NON_SUITE_TOOLS[@]}"; do [[ "$s" == "$base" ]] && in_non=1 && break; done
    if [[ "$in_known" -eq 1 || "$in_non" -eq 1 ]]; then
      echo "PASS: tools/$base classified (known=$in_known non-suite=$in_non)"
    else
      echo "FAIL: tools/$base is unclassified — add to KNOWN_SUITES (with a mapping rule) or NON_SUITE_TOOLS"
      fails=$((fails + 1))
    fi
  done < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*.sh' -type f | sort)

  # 3. Every top-level tests/<dir>/ must map to some suite (a sentinel path under it must
  #    either select a suite or FAIL-CLOSED to full — never docs-only/no-suite).
  local d dname sentinel
  if [[ -d "$REPO_ROOT/tests" ]]; then
    while IFS= read -r d; do
      dname="$(basename "$d")"
      sentinel="tests/$dname/__selftest_probe__"
      SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
      map_path "$sentinel" >/dev/null
      if [[ ${#SELECTED[@]} -gt 0 || "$FORCE_FULL" -eq 1 ]]; then
        echo "PASS: tests/$dname maps (suites=${#SELECTED[@]} full=$FORCE_FULL)"
      else
        echo "FAIL: tests/$dname maps to NO suite and does not FAIL-CLOSED"
        fails=$((fails + 1))
      fi
    done < <(find "$REPO_ROOT/tests" -maxdepth 1 -mindepth 1 -type d | sort)
  fi

  # 4. An unmapped sentinel inside a code tree must FAIL-CLOSED to full suite. Use a path
  #    under tests/ whose subdir matches no mapping rule (plugin/* and .claude-plugin/* are
  #    wholesale policy_check surfaces, so they can never be "unmapped").
  SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
  map_path "tests/__no_such_dir__/unmapped.xyz" >/dev/null
  if [[ "$FORCE_FULL" -eq 1 ]]; then
    echo "PASS: unmapped code-tree sentinel -> FULL suite"
  else
    echo "FAIL: unmapped code-tree sentinel did NOT FAIL-CLOSED"
    fails=$((fails + 1))
  fi

  # 5. tools/** sentinel must FAIL-CLOSED to full suite.
  SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
  map_path "tools/some_new_thing.sh" >/dev/null
  if [[ "$FORCE_FULL" -eq 1 ]]; then
    echo "PASS: tools/** sentinel -> FULL suite"
  else
    echo "FAIL: tools/** sentinel did NOT FAIL-CLOSED"
    fails=$((fails + 1))
  fi

  # 6. A docs-only sentinel must select NO code suite and NOT escalate. README.md is NOT a
  #    valid docs-only probe — it is routed through policy_check (its compatibility fixtures
  #    read README.md), so use a docs/ path that no rule maps.
  SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
  map_path "docs/some-doc.md" >/dev/null
  if [[ ${#SELECTED[@]} -eq 0 && "$FORCE_FULL" -eq 0 ]]; then
    echo "PASS: docs/some-doc.md -> no code suites"
  else
    echo "FAIL: docs/some-doc.md selected suites (${#SELECTED[@]}) or escalated (full=$FORCE_FULL)"
    fails=$((fails + 1))
  fi

  # 6b. README.md must route through policy_check (its compatibility fixtures read README.md),
  #     NOT classify as docs-only/no-suite.
  SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
  map_path "README.md" >/dev/null
  hit=0
  for entry in "${SELECTED[@]:-}"; do
    [[ "${entry%%$'\t'*}" == "$SUITE_POLICY_CHECK" ]] && hit=1 && break
  done
  if [[ "$hit" -eq 1 ]]; then
    echo "PASS: README.md -> policy_check (README compatibility fixtures)"
  else
    echo "FAIL: README.md did NOT route through policy_check (selected ${#SELECTED[@]} suites, full=$FORCE_FULL)"
    fails=$((fails + 1))
  fi

  # 7. The CI workflow that runs this dispatcher must FAIL-CLOSED to full suite, never
  #    docs-only — otherwise a workflow-only edit could green a --changed run with no suites.
  SELECTED=(); FORCE_FULL=0; FORCE_FULL_REASON=''
  map_path ".github/workflows/policy-check.yml" >/dev/null
  if [[ "$FORCE_FULL" -eq 1 ]]; then
    echo "PASS: .github/workflows/** -> FULL suite"
  else
    echo "FAIL: .github/workflows/** did NOT FAIL-CLOSED (selected ${#SELECTED[@]} suites)"
    fails=$((fails + 1))
  fi

  echo
  if [[ "$fails" -eq 0 ]]; then
    echo "--self-test: ALL PASS"
    return 0
  fi
  echo "--self-test: $fails FAILURE(S)"
  return 1
}

# ── Usage ─────────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage:
  bash tools/validate.sh [--all]              Run the full CI-parity validation suite.
  bash tools/validate.sh --changed [--base R] Run only suites impacted by changed files.
  bash tools/validate.sh --self-test          Assert mapping coverage; no suites run.
  bash tools/validate.sh -h | --help          Show this help.
EOF
}

# ── Arg parsing ─────────────────────────────────────────────────────────────────────
main() {
  local mode='all'
  local base_arg=''

  if [[ $# -eq 0 ]]; then
    mode='all'
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) mode='all'; shift ;;
      --changed) mode='changed'; shift ;;
      --self-test) mode='self-test'; shift ;;
      --base)
        if [[ $# -lt 2 ]]; then
          echo "error: --base requires a ref argument" >&2
          usage >&2
          exit 2
        fi
        base_arg="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "error: unknown flag '$1'" >&2
        usage >&2
        exit 2 ;;
    esac
  done

  case "$mode" in
    all)
      echo "validate.sh --all (CI-parity full suite)"
      run_suites "${ALL_SUITES[@]}"
      ;;
    changed)
      run_changed "$base_arg"
      ;;
    self-test)
      self_test
      ;;
  esac
}

main "$@"
