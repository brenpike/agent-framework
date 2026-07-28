#!/usr/bin/env bash
#
# Policy linter for the hivemind plugin.
#
# Runs structural and content checks against plugin/ files, plus safety
# regression fixtures (tests/policy/) and compatibility fixtures (tests/plugin/).
# Advisory mode (default): reports findings, exits 0 unless the harness itself fails.
# Strict mode (--strict): exits non-zero when findings exist that are not in the allowlist.
#
# Usage:
#   ./tools/policy_check.sh
#   ./tools/policy_check.sh --strict

set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────────────

STRICT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict|-Strict)
            STRICT=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# ── Path setup ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_ROOT="$REPO_ROOT/plugin"
ALLOWLIST_PATH="$REPO_ROOT/tests/policy/policy-lint-allowlist.json"

resolve_repo_path() {
    echo "$REPO_ROOT/$1"
}

# ── Helpers ─────────────────────────────────────────────────────────────────

load_allowlist() {
    if [[ -f "$ALLOWLIST_PATH" ]]; then
        cat "$ALLOWLIST_PATH"
    else
        echo "[]"
    fi
}

ALLOWLIST_JSON="$(load_allowlist)"

# Findings storage: parallel arrays
declare -a FINDING_RULES=()
declare -a FINDING_PATHS=()
declare -a FINDING_LINES=()
declare -a FINDING_DESCS=()
declare -a FINDING_ALLOWED=()

test_allowlisted() {
    local rule="$1"
    local fpath="$2"
    local line="$3"

    local count
    count="$(echo "$ALLOWLIST_JSON" | jq 'length')"
    local i=0
    while [[ $i -lt $count ]]; do
        local entry_rule
        entry_rule="$(echo "$ALLOWLIST_JSON" | jq -r ".[$i].rule")"
        if [[ "$entry_rule" != "$rule" ]]; then
            i=$((i + 1))
            continue
        fi
        local entry_path
        entry_path="$(echo "$ALLOWLIST_JSON" | jq -r ".[$i].path")"
        if [[ "$entry_path" != "$fpath" ]]; then
            i=$((i + 1))
            continue
        fi
        local has_line
        has_line="$(echo "$ALLOWLIST_JSON" | jq ".[$i] | has(\"line\")")"
        if [[ "$has_line" == "true" ]]; then
            local entry_line
            entry_line="$(echo "$ALLOWLIST_JSON" | jq -r ".[$i].line")"
            if [[ "$entry_line" != "0" && "$entry_line" != "$line" ]]; then
                i=$((i + 1))
                continue
            fi
        fi
        echo "true"
        return
    done
    echo "false"
}

add_finding() {
    local rule="$1"
    local filepath="$2"
    local line="$3"
    local description="$4"

    local rel_path="$filepath"
    if [[ "$filepath" == "$REPO_ROOT"* ]]; then
        rel_path="${filepath#"$REPO_ROOT"/}"
    fi
    # Normalize backslashes to forward slashes
    rel_path="${rel_path//\\//}"

    local is_allowlisted
    is_allowlisted="$(test_allowlisted "$rule" "$rel_path" "$line")"

    FINDING_RULES+=("$rule")
    FINDING_PATHS+=("$rel_path")
    FINDING_LINES+=("$line")
    FINDING_DESCS+=("$description")
    FINDING_ALLOWED+=("$is_allowlisted")

    local line_label=""
    if [[ "$line" -gt 0 ]]; then
        line_label=":$line"
    fi
    local prefix="[FIND]"
    if [[ "$is_allowlisted" == "true" ]]; then
        prefix="[ALLOW]"
    fi
    echo "$prefix [$rule] ${rel_path}${line_label} -- $description"
}

get_frontmatter() {
    local filepath="$1"
    local in_frontmatter=false
    local frontmatter_started=false
    local result=""
    while IFS= read -r textline || [[ -n "$textline" ]]; do
        local trimmed
        trimmed="$(echo "$textline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ "$trimmed" == "---" ]]; then
            if [[ "$frontmatter_started" == false ]]; then
                frontmatter_started=true
                in_frontmatter=true
                continue
            else
                break
            fi
        fi
        if [[ "$in_frontmatter" == true ]]; then
            if [[ -n "$result" ]]; then
                result="$result"$'\n'"$textline"
            else
                result="$textline"
            fi
        fi
    done < "$filepath"
    echo "$result"
}

# ── State ───────────────────────────────────────────────────────────────────

CHECKS_PASSED=0
CHECKS_FAILED=0

# ── CHECK 1: Forbidden hedge ───────────────────────────────────────────────

echo ''
echo '=== CHECK 1: Forbidden hedge ==='

check1_found=false

while IFS= read -r -d '' md_file; do
    line_num=0
    while IFS= read -r textline || [[ -n "$textline" ]]; do
        line_num=$((line_num + 1))

        # INVARIANT: The rule definition itself in governance docs is not a violation.
        if echo "$textline" | grep -qP 'Do not use the word.*ambiguous.*as a hedge'; then
            continue
        fi

        if ! echo "$textline" | grep -qP '\bambiguous\b'; then
            continue
        fi

        is_hedge=false

        # Pattern: "unsafe or ambiguous"
        if echo "$textline" | grep -qP '\bunsafe\s+or\s+ambiguous\b'; then
            is_hedge=true
        fi

        # Pattern: "is ambiguous"
        if echo "$textline" | grep -qP '\bis\s+ambiguous\b'; then
            is_hedge=true
        fi

        # Pattern: "or ambiguous" preceded by a stop/gate word
        if echo "$textline" | grep -qP '\bor\s+ambiguous\b'; then
            if ! echo "$textline" | grep -qP 'non-human\s+or\s+ambiguous'; then
                if ! echo "$textline" | grep -qP '/ambiguous'; then
                    if echo "$textline" | grep -qP '\b(continue|proceed|stop|when|if)\b.*\bor\s+ambiguous\b'; then
                        is_hedge=true
                    fi
                    if echo "$textline" | grep -qP '\bor\s+ambiguous\b.*\b(continue|proceed|stop|when|if)\b'; then
                        is_hedge=true
                    fi
                fi
            fi
        fi

        # Pattern: "proceed if ... ambiguous" or "continue ... ambiguous" as gate
        if echo "$textline" | grep -qP '\b(proceed|continue|stop)\b.*\bambiguous\b'; then
            if ! echo "$textline" | grep -qP '/ambiguous'; then
                if ! echo "$textline" | grep -qP 'non-human'; then
                    is_hedge=true
                fi
            fi
        fi

        if [[ "$is_hedge" == false ]]; then
            continue
        fi

        check1_found=true
        add_finding 'CHECK1' "$md_file" "$line_num" \
            "Forbidden hedge: 'ambiguous' used as gate-level uncertainty"
    done < "$md_file"
done < <(find "$PLUGIN_ROOT" -name '*.md' -type f -print0)

if [[ "$check1_found" == false ]]; then
    echo '[PASS] Check 1: No forbidden hedge violations found'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 2: Required files exist ──────────────────────────────────────────

echo ''
echo '=== CHECK 2: Required files exist ==='

REQUIRED_FILES=(
    'plugin/governance/definitions.md'
    'plugin/governance/report-format.md'
    'plugin/governance/safety-rails.md'
    'plugin/governance/security-policy.md'
    'plugin/governance/versioning.md'
    'plugin/governance/workflow.md'
    'plugin/agents/cerebrate.md'
    'plugin/agents/overlord.md'
    'plugin/agents/drone.md'
    'plugin/agents/changeling.md'
)

check2_found=false
for rel_file in "${REQUIRED_FILES[@]}"; do
    abs_path="$(resolve_repo_path "$rel_file")"
    if [[ ! -e "$abs_path" ]]; then
        check2_found=true
        add_finding 'CHECK2' "$rel_file" 0 \
            "Required file missing: $rel_file"
    fi
done

if [[ "$check2_found" == false ]]; then
    echo '[PASS] Check 2: All required files exist'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 3: Skill names exist ─────────────────────────────────────────────

echo ''
echo '=== CHECK 3: Skill names exist ==='

AGENT_NAMES=('cerebrate' 'overlord' 'drone' 'changeling' 'local-reviewer' 'github-reviewer')

# Collect scan sources
declare -a SCAN_FILES=()
while IFS= read -r -d '' f; do
    SCAN_FILES+=("$f")
done < <(find "$PLUGIN_ROOT/agents" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
while IFS= read -r -d '' f; do
    SCAN_FILES+=("$f")
done < <(find "$PLUGIN_ROOT/skills" -name 'SKILL.md' -type f -print0 2>/dev/null)
while IFS= read -r -d '' f; do
    SCAN_FILES+=("$f")
done < <(find "$PLUGIN_ROOT/governance" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)

# Extract all hivemind:* references.
# skill_refs: associative array mapping skill name -> space-separated source file paths
# agent_refs: associative array mapping agent name -> space-separated source file paths
declare -A SKILL_REF_SOURCES=()
declare -A AGENT_REF_SOURCES=()

is_agent_name() {
    local name="$1"
    for aname in "${AGENT_NAMES[@]}"; do
        if [[ "$aname" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

for scan_file in "${SCAN_FILES[@]}"; do
    scan_content="$(<"$scan_file")"
    while IFS= read -r ref_name; do
        [[ -z "$ref_name" ]] && continue

        if is_agent_name "$ref_name"; then
            if [[ -z "${AGENT_REF_SOURCES[$ref_name]:-}" ]]; then
                AGENT_REF_SOURCES[$ref_name]="$scan_file"
            elif [[ "${AGENT_REF_SOURCES[$ref_name]}" != *"$scan_file"* ]]; then
                AGENT_REF_SOURCES[$ref_name]="${AGENT_REF_SOURCES[$ref_name]}"$'\n'"$scan_file"
            fi
        else
            if [[ -z "${SKILL_REF_SOURCES[$ref_name]:-}" ]]; then
                SKILL_REF_SOURCES[$ref_name]="$scan_file"
            elif [[ "${SKILL_REF_SOURCES[$ref_name]}" != *"$scan_file"* ]]; then
                SKILL_REF_SOURCES[$ref_name]="${SKILL_REF_SOURCES[$ref_name]}"$'\n'"$scan_file"
            fi
        fi
    done < <(echo "$scan_content" | grep -oP 'hivemind:\K[a-zA-Z0-9_-]+' | sort -u)
done

check3_found=false
skill_ref_count=${#SKILL_REF_SOURCES[@]}
for skill_name in "${!SKILL_REF_SOURCES[@]}"; do
    skill_md_path="$PLUGIN_ROOT/skills/$skill_name/SKILL.md"
    if [[ ! -f "$skill_md_path" ]]; then
        check3_found=true
        while IFS= read -r source_file; do
            [[ -z "$source_file" ]] && continue
            add_finding 'CHECK3' "$source_file" 0 \
                "Skill referenced but SKILL.md missing: plugin/skills/$skill_name/SKILL.md"
        done <<< "${SKILL_REF_SOURCES[$skill_name]}"
    fi
done

if [[ "$check3_found" == false ]]; then
    echo "[PASS] Check 3: All $skill_ref_count skill references resolve to SKILL.md files"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 4: Agent names exist ─────────────────────────────────────────────

echo ''
echo '=== CHECK 4: Agent names exist ==='

check4_found=false
agent_ref_count=${#AGENT_REF_SOURCES[@]}
for agent_ref_name in "${!AGENT_REF_SOURCES[@]}"; do
    agent_md_path="$PLUGIN_ROOT/agents/$agent_ref_name.md"
    if [[ ! -f "$agent_md_path" ]]; then
        check4_found=true
        while IFS= read -r source_file; do
            [[ -z "$source_file" ]] && continue
            add_finding 'CHECK4' "$source_file" 0 \
                "Agent referenced but file missing: plugin/agents/$agent_ref_name.md"
        done <<< "${AGENT_REF_SOURCES[$agent_ref_name]}"
    fi
done

if [[ "$check4_found" == false ]]; then
    echo "[PASS] Check 4: All $agent_ref_count agent references resolve to .md files"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 5: Unsupported frontmatter fields ────────────────────────────────

echo ''
echo '=== CHECK 5: Unsupported frontmatter fields ==='

check5_found=false
while IFS= read -r -d '' agent_file; do
    in_frontmatter=false
    frontmatter_started=false
    line_num=0
    while IFS= read -r textline || [[ -n "$textline" ]]; do
        line_num=$((line_num + 1))
        trimmed="$(echo "$textline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ "$trimmed" == "---" ]]; then
            if [[ "$frontmatter_started" == false ]]; then
                frontmatter_started=true
                in_frontmatter=true
                continue
            else
                break
            fi
        fi
        if [[ "$in_frontmatter" == false ]]; then
            continue
        fi

        if echo "$textline" | grep -qP '^\s*mcpServers\s*:'; then
            check5_found=true
            add_finding 'CHECK5' "$agent_file" "$line_num" \
                'Unsupported frontmatter field: mcpServers'
        fi
        if echo "$textline" | grep -qP '^\s*permissionMode\s*:'; then
            check5_found=true
            add_finding 'CHECK5' "$agent_file" "$line_num" \
                'Unsupported frontmatter field: permissionMode'
        fi
    done < "$agent_file"
done < <(find "$PLUGIN_ROOT/agents" -maxdepth 1 -name '*.md' -type f -print0)

if [[ "$check5_found" == false ]]; then
    echo '[PASS] Check 5: No unsupported frontmatter fields found'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 6: Governance reference paths resolve ────────────────────────────

echo ''
echo '=== CHECK 6: Governance reference paths resolve ==='

check6_found=false
while IFS= read -r -d '' md_file; do
    line_num=0
    while IFS= read -r textline || [[ -n "$textline" ]]; do
        line_num=$((line_num + 1))
        # Extract all ${CLAUDE_PLUGIN_ROOT}/... references from this line
        while IFS= read -r ref_rel_path; do
            [[ -z "$ref_rel_path" ]] && continue
            # Strip trailing punctuation that is not part of file paths.
            ref_rel_path="$(echo "$ref_rel_path" | sed 's/[.,;:)]*$//')"
            resolved_path="$PLUGIN_ROOT/$ref_rel_path"
            normalized_resolved="$(realpath -m "$resolved_path" 2>/dev/null || echo "$resolved_path")"
            normalized_plugin_root="$(realpath -m "$PLUGIN_ROOT")"

            if [[ "$normalized_resolved" != "$normalized_plugin_root" && "$normalized_resolved" != "$normalized_plugin_root/"* ]]; then
                check6_found=true
                add_finding 'CHECK6' "$md_file" "$line_num" \
                    "Path escapes plugin root: \${CLAUDE_PLUGIN_ROOT}/$ref_rel_path"
            else
                if [[ ! -f "$resolved_path" && ! -d "$resolved_path" ]]; then
                    check6_found=true
                    add_finding 'CHECK6' "$md_file" "$line_num" \
                        "Path does not resolve: \${CLAUDE_PLUGIN_ROOT}/$ref_rel_path"
                fi
            fi
        done < <(echo "$textline" | grep -oP '\$\{CLAUDE_PLUGIN_ROOT\}/\K[^\s`\)]+' || true)
    done < "$md_file"
done < <(find "$PLUGIN_ROOT" -name '*.md' -type f -print0)

if [[ "$check6_found" == false ]]; then
    echo '[PASS] Check 6: All governance reference paths resolve'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 7: Skill frontmatter completeness ────────────────────────────────

echo ''
echo '=== CHECK 7: Skill frontmatter completeness ==='

REQUIRED_FRONTMATTER_FIELDS=('name' 'description' 'allowed-tools' 'shell')
check7_found=false
skill_file_count=0

while IFS= read -r -d '' skill_file; do
    skill_file_count=$((skill_file_count + 1))

    fm_content="$(get_frontmatter "$skill_file")"
    for field_name in "${REQUIRED_FRONTMATTER_FIELDS[@]}"; do
        if ! echo "$fm_content" | grep -qP "^\s*${field_name}\s*:"; then
            check7_found=true
            add_finding 'CHECK7' "$skill_file" 0 \
                "Missing required frontmatter field: $field_name"
        fi
    done
done < <(find "$PLUGIN_ROOT/skills" -name 'SKILL.md' -type f -print0)

if [[ "$check7_found" == false ]]; then
    echo "[PASS] Check 7: All $skill_file_count skill files have complete frontmatter"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 8: No bare governance/agents/skills path refs ────────────────────

echo ''
echo '=== CHECK 8: No bare governance/agents/skills path refs ==='

check8_found=false
while IFS= read -r -d '' md_file; do
    line_num=0
    while IFS= read -r textline || [[ -n "$textline" ]]; do
        line_num=$((line_num + 1))
        # Strip every correct ${CLAUDE_PLUGIN_ROOT}/<path> token first so its
        # inner governance|agents|skills segment cannot trigger a false match.
        stripped="$(echo "$textline" | sed -E 's#\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./{}-]+##g')"
        # Flag any residual bare ref that carries a filename suffix. The suffix
        # requirement keeps generic prose like "the governance/ layer" clean.
        while IFS= read -r bare_ref; do
            [[ -z "$bare_ref" ]] && continue
            check8_found=true
            add_finding 'CHECK8' "$md_file" "$line_num" \
                "Bare path ref (missing \${CLAUDE_PLUGIN_ROOT}/ prefix): $bare_ref"
        done < <(echo "$stripped" | grep -oP '(^|[^A-Za-z0-9_./-])\K(agents|skills|governance|references|workflows)/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(md|sh|json)' || true)
    done < "$md_file"
done < <(find "$PLUGIN_ROOT" -name '*.md' -type f -print0)

if [[ "$check8_found" == false ]]; then
    echo '[PASS] Check 8: No bare governance/agents/skills path refs'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 9: Containment guard precedes guarded read in engine scripts ──────
#
# STRUCTURAL PREVENTION for issue #163: the "containment-guard-before-read"
# defect (a guarded path token READ at a line BEFORE its containment guard)
# recurred because safe ordering was convention, not enforced. This check makes
# the class non-regressable.
#
# Scope: every committed engine script matching plugin/skills/*/scripts/*.sh
# that SOURCES _shared/containment.sh. Scripts that do not source it (e.g.
# brood-discover.sh) are excluded — they have no guard to order against.
#
# For each (script, guarded-token) pair we locate:
#   * the GUARD line (the containment helper invocation for that token), and
#   * the FIRST DANGEROUS READ line (the first jq/cat that actually opens the
#     file, or — for $ledger — the first existence/validity probe on the
#     post-derivation path).
# We FIRE when a token is read but (a) has NO guard at all, or (b) its first
# dangerous read occurs at a line number BEFORE the guard.
#
# The $INPUTS_FILE containment guard may be satisfied EITHER by an inline
# hivemind_assert_inputs_contained call OR by delegation to the
# hivemind_read_inputs_file shared helper, which performs that assertion
# internally (per the ADR-0020 engine-IO extraction, issue #245). Both forms
# are recognized as the guard line. This recognizes a real guard and does NOT
# weaken the check: a script that reads $INPUTS_FILE with NEITHER an inline
# assertion NOR the helper call still fires a missing-guard finding.
#
# Deliberate exclusions to avoid false positives:
#   * the GUARD line itself names the token as an argument — never counted as a read.
#   * `[ -f "$INPUTS_FILE" ]` / `[ -n "$INPUTS_FILE" ]` are pure existence/arg
#     presence probes that legitimately precede the inputs guard; only the first
#     `jq` open of $INPUTS_FILE is the read the guard must gate (the jq validity
#     probe is the canonical read-oracle, per the engine reference script).
#   * `[ -L "$MANIFEST" ]` / `[ -f "$MANIFEST" ]` are leaf/existence probes that
#     precede the manifest guard by design; only `cat`/`jq` opens are reads.
#   * for $ledger the path is DERIVED after the runs-dir guard, so its first
#     `[ -f "$ledger" ]` existence probe IS a real read of the derived path and
#     the guard must precede it.
#
# Two distinct guards are enforced for the ledger, as SEPARATE token rows:
#   * $ledger      — the ANCESTOR/runs-dir ordering guard (hivemind_assert_contained)
#                    must precede the first ledger read. Its guard pattern is anchored
#                    to the EXECUTABLE invocation (^[[:space:]]*[^#]*hivemind_assert_contained
#                    [^#]*\.hivemind/runs/$run_id) so the prose comments that merely NAME
#                    hivemind_assert_contained are not miscounted as the guard line —
#                    otherwise the first match would be an explanatory comment ABOVE the
#                    real call, and a $ledger read moved above the real guard could pass.
#                    The read pattern is likewise line-start anchored (^[[:space:]]*) so a
#                    `[ -f "$ledger" ]` appearing inside a comment is not miscounted as the
#                    first read.
#   * $ledger-leaf — the LEAF symlink guard (hivemind_assert_ledger_contained) must
#                    ALSO precede the first ledger read. This makes the leaf guard
#                    TERMINAL: a containment-sourcing engine that reads "$ledger"
#                    without first calling hivemind_assert_ledger_contained fires a
#                    missing-guard or ordering finding, so a reverted leaf guard or a
#                    new unguarded ledger reader cannot regress silently. The
#                    $ledger-leaf row anchors its read/guard patterns at line start
#                    (^[[:space:]]*) so prose in comments naming the symbols is not
#                    miscounted as a guard or a read.

echo ''
echo '=== CHECK 9: Containment guard precedes guarded read in engine scripts ==='

# first_match_line PATTERN FILE [EXCLUDE_PATTERN]
# Echoes the line number of the first line matching PATTERN. When EXCLUDE_PATTERN
# is supplied, lines also matching it are skipped. Echoes empty when no match.
first_match_line() {
    local pattern="$1"
    local file="$2"
    local exclude="${3:-}"
    local matched
    while IFS= read -r matched; do
        [[ -z "$matched" ]] && continue
        local lineno="${matched%%:*}"
        local body="${matched#*:}"
        if [[ -n "$exclude" ]] && echo "$body" | grep -qE "$exclude"; then
            continue
        fi
        echo "$lineno"
        return
    done < <(grep -nE "$pattern" "$file" 2>/dev/null || true)
    echo ""
}

check9_found=false
check9_script_count=0

while IFS= read -r -d '' engine_script; do
    # Only engine scripts that source the containment helper participate.
    if ! grep -qE '(^|[[:space:]])(\.|source)[[:space:]][^#]*containment\.sh' "$engine_script"; then
        continue
    fi
    check9_script_count=$((check9_script_count + 1))

    # Token table: TOKEN | GUARD_PATTERN | READ_PATTERN | READ_EXCLUDE
    # READ_EXCLUDE removes existence/arg-presence/symlink probes that legitimately
    # precede the guard so they are not mistaken for the gated open. For
    # $INPUTS_FILE the GUARD_PATTERN and READ_EXCLUDE both accept the
    # hivemind_read_inputs_file helper call as the guard (it runs
    # hivemind_assert_inputs_contained internally; ADR-0020 / #245), so the
    # bootstrap helper-call line is neither a missing guard nor a counted read.
    # EVERY GUARD_PATTERN is anchored to an EXECUTABLE line (^[[:space:]]*[^#]*)
    # so a COMMENT that merely NAMES the guard helper (e.g. a `# hivemind_read_inputs_file
    # "$INPUTS_FILE"` doc line above the first real read) is NOT miscounted as the
    # guard — otherwise an engine reading $INPUTS_FILE/$MANIFEST with no real guard
    # could pass on the strength of a comment mention.
    declare -a token_labels=('$INPUTS_FILE' '$MANIFEST' '$ledger' '$ledger-leaf')
    declare -a token_guards=(
        '^[[:space:]]*[^#]*(hivemind_assert_inputs_contained|hivemind_read_inputs_file)[^#]*"\$INPUTS_FILE"'
        '^[[:space:]]*[^#]*(hivemind_assert_inputs_contained|\[ -L )[^#]*"\$MANIFEST"'
        '^[[:space:]]*[^#]*hivemind_assert_contained[^#]*\.hivemind/runs/\$run_id'
        '^[[:space:]]*hivemind_assert_ledger_contained'
    )
    declare -a token_reads=(
        '(jq |cat )[^#]*"\$INPUTS_FILE"'
        '(jq |cat )[^#]*"\$MANIFEST"'
        '^[[:space:]]*(jq |cat |\[ -f )[^#]*"\$ledger"'
        '^[[:space:]]*(jq |cat |\[ -f )[^#]*"\$ledger"'
    )
    declare -a token_read_excludes=(
        'hivemind_assert_inputs_contained|hivemind_read_inputs_file|\[ -[fnL] '
        'hivemind_assert_inputs_contained|\[ -[fnL] '
        'hivemind_assert(_contained|_ledger_contained)'
        'hivemind_assert(_contained|_ledger_contained)'
    )

    ti=0
    while [[ $ti -lt ${#token_labels[@]} ]]; do
        token_label="${token_labels[$ti]}"
        read_line="$(first_match_line "${token_reads[$ti]}" "$engine_script" "${token_read_excludes[$ti]}")"
        ti_next=$((ti + 1))

        # Token not read in this script — nothing to order.
        if [[ -z "$read_line" ]]; then
            ti=$ti_next
            continue
        fi

        guard_line="$(first_match_line "${token_guards[$ti]}" "$engine_script")"

        if [[ -z "$guard_line" ]]; then
            check9_found=true
            add_finding 'CHECK9' "$engine_script" "$read_line" \
                "Containment guard missing: ${token_label} is read here but no containment guard for it exists in this engine script"
            ti=$ti_next
            continue
        fi

        if [[ "$read_line" -lt "$guard_line" ]]; then
            check9_found=true
            add_finding 'CHECK9' "$engine_script" "$read_line" \
                "Containment guard ordering: ${token_label} is read at line $read_line BEFORE its guard at line $guard_line — guard must precede the read"
        fi
        ti=$ti_next
    done

    unset token_labels token_guards token_reads token_read_excludes
done < <(find "$PLUGIN_ROOT/skills" -path '*/scripts/*.sh' -type f -print0)

if [[ "$check9_found" == false ]]; then
    echo "[PASS] Check 9: All $check9_script_count containment-sourcing engine scripts guard each token before its first read"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 10: No literal NUL byte in plugin Markdown payload ───────────────
#
# Packaged plugin .md files (skills, agents, governance, references) are
# runtime-loaded TEXT assets. A literal NUL byte makes a file binary to
# `file`, truncates shell-based validators and Markdown tooling, and may be
# dropped or mistaken for binary by plugin consumers. Forbid it outright; a
# textual escape such as `\u0000` or `<NUL>` represents the byte in prose.
echo ''
echo '=== CHECK 10: No literal NUL byte in plugin Markdown payload ==='

check10_found=false
check10_md_count=0
while IFS= read -r -d '' md_file; do
    check10_md_count=$((check10_md_count + 1))
    if LC_ALL=C grep -qaP '\x00' "$md_file" 2>/dev/null; then
        check10_found=true
        add_finding 'CHECK10' "$md_file" 0 \
            "Literal NUL byte in plugin Markdown payload — replace with a textual escape (e.g. \\u0000 or <NUL>); NUL makes the file binary and breaks Markdown/shell tooling and plugin consumers"
    fi
done < <(find "$PLUGIN_ROOT" -name '*.md' -type f -print0)

if [[ "$check10_found" == false ]]; then
    echo "[PASS] Check 10: All $check10_md_count plugin Markdown payload files are free of literal NUL bytes"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 11: No bare calling-bioform name in skill body prose (P14) ────────
#
# Reusable skills are role-agnostic and may be invoked by any agent. Naming a
# specific calling bioform (overlord/drone/changeling) in skill BODY prose
# couples the skill to one caller and violates engineering-principles.md P14:
# reference the caller by role/intent, not by bioform name. Agents legitimately
# own these names, so scope is skills/ only. Structural exclusions (YAML
# frontmatter, fenced code blocks, table rows) and a KEEP-phrase allowlist for
# legitimate architectural-invariant/topology mentions keep the scan tight.

echo ''
echo '=== CHECK 11: No bare calling-bioform name in skill body prose (P14) ==='

# Denylist of calling-bioform names — single variable for trivial extension.
# cerebrate is intentionally NOT in v1; it is deferred to issue #254.
BIOFORM_DENYLIST='overlord|drone|changeling'
# KEEP-phrase regex: legitimate architectural-invariant/topology mentions that
# must NOT be flagged even though they contain a denylisted word.
CHECK11_KEEP_REGEX='RUN-OWNERSHIP-01|overlord instance|overlord session|overlord-invocable|overlord resume|overlord step|hivemind:overlord|parallel overlord sessions'

check11_found=false
while IFS= read -r -d '' skill_file; do
    # One-pass awk state machine emits surviving BODY lines as "line_num<TAB>line",
    # excluding YAML frontmatter, fenced code blocks, and markdown table rows.
    while IFS=$'\t' read -r line_num textline; do
        [[ -z "$line_num" ]] && continue
        # Strip legitimate KEEP-phrase spans first (mirrors CHECK 8's
        # ${CLAUDE_PLUGIN_ROOT} strip at line ~504), so a real leak sharing a
        # line with a legit mention is still caught instead of the whole line
        # being exempted.
        residual="$(echo "$textline" | sed -E "s/(${CHECK11_KEEP_REGEX})//Ig")"
        if echo "$residual" | grep -qiwE "($BIOFORM_DENYLIST)"; then
            bare_word="$(echo "$residual" | grep -oiwE "($BIOFORM_DENYLIST)" | head -n1)"
            check11_found=true
            add_finding 'CHECK11' "$skill_file" "$line_num" \
                "bare calling-bioform name '$bare_word' in skill body prose -- reference the caller by role/intent (P14); see engineering-principles.md P14"
        fi
    done < <(awk '
        BEGIN { in_fm = 0; fm_done = 0; in_fence = 0 }
        {
            # YAML frontmatter: first line "---" opens, next "---" closes.
            if (!fm_done && NR == 1 && $0 == "---") { in_fm = 1; next }
            if (in_fm) { if ($0 == "---") { in_fm = 0; fm_done = 1 } next }
            # Fenced code blocks toggle on lines starting with ```.
            if ($0 ~ /^```/) { in_fence = !in_fence; next }
            if (in_fence) next
            # Markdown table rows.
            if ($0 ~ /^[ \t]*\|/) next
            print NR "\t" $0
        }
    ' "$skill_file")
done < <(find "$PLUGIN_ROOT/skills" -name 'SKILL.md' -type f -print0)

if [[ "$check11_found" == false ]]; then
    echo '[PASS] Check 11: No bare calling-bioform name in skill body prose (P14)'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 12: No bare validation-tool/manifest token in governance/agents prose ─
#
# Governance and agent docs are runtime-loaded instructions. Naming a concrete
# validation-tool or manifest filename in prose (e.g. a validate script, a
# syntax-check invocation, a language manifest) hard-codes a project-specific
# toolchain detail into role-agnostic doctrine — the same coupling class CHECK 8
# guards for path refs. Scope is governance/ and agents/ only (maxdepth 1, NOT
# skills — skills are covered by their own checks). The denylist names whole
# concrete tool/manifest tokens, never bare generics like jq, json, or version.
#
# Structural exclusions mirror CHECK 11: YAML frontmatter, fenced code blocks,
# and >=4-space indented (code) lines are skipped via a per-file in_fence
# toggle, and backtick inline-code spans are stripped before matching so a
# token shown as inline code is not flagged.

echo ''
echo '=== CHECK 12: No bare validation-tool/manifest token in governance/agents prose ==='

# Denylist of concrete validation-tool / manifest tokens. Whole tokens only —
# deliberately excludes bare generics (jq, json, version) to avoid false hits.
CHECK12_DENYLIST='tools/validate\.sh|bash -n|python3 -m json\.tool|test_[a-z0-9_]+\.sh|package\.json|pyproject\.toml|Cargo\.toml|go\.mod|requirements\.txt|plugin\.json|marketplace\.json'

check12_found=false
while IFS= read -r -d '' doc_file; do
    # One-pass awk state machine emits surviving BODY lines as "line_num<TAB>line",
    # excluding YAML frontmatter, fenced code blocks, and >=4-space indented lines.
    while IFS=$'\t' read -r line_num textline; do
        [[ -z "$line_num" ]] && continue
        # Strip backtick inline-code spans first (mirrors CHECK 11's KEEP-phrase
        # strip at line ~730), so a token shown as inline code is exempt while a
        # real bare occurrence sharing a line with inline code is still caught.
        residual="$(echo "$textline" | sed -E 's/`[^`]*`//g')"
        if echo "$residual" | grep -qE "($CHECK12_DENYLIST)"; then
            bare_token="$(echo "$residual" | grep -oE "($CHECK12_DENYLIST)" | head -n1)"
            check12_found=true
            add_finding 'CHECK12' "$doc_file" "$line_num" \
                "bare validation-tool/manifest token '$bare_token' in governance/agents prose -- reference the toolchain by role/intent, not a concrete tool or manifest filename"
        fi
    done < <(awk '
        BEGIN { in_fm = 0; fm_done = 0; in_fence = 0 }
        {
            # YAML frontmatter: first line "---" opens, next "---" closes.
            if (!fm_done && NR == 1 && $0 == "---") { in_fm = 1; next }
            if (in_fm) { if ($0 == "---") { in_fm = 0; fm_done = 1 } next }
            # Fenced code blocks toggle on lines starting with ```.
            if ($0 ~ /^```/) { in_fence = !in_fence; next }
            if (in_fence) next
            # Indented code lines (>=4 leading spaces).
            if ($0 ~ /^    /) next
            print NR "\t" $0
        }
    ' "$doc_file")
done < <(find "$PLUGIN_ROOT/governance" "$PLUGIN_ROOT/agents" -maxdepth 1 -name '*.md' -type f -print0)

if [[ "$check12_found" == false ]]; then
    echo '[PASS] Check 12: No bare validation-tool/manifest token in governance/agents prose'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 13: P18 fail-closed shell floor ──────────────────────────────────
#
# Every committed plugin runtime shell script (plugin/**/*.sh) MUST enable the
# fail-closed shell floor — errexit, nounset, and pipefail — before its first
# executable statement, OR carry a documented CHECK13 allowlist exception. The
# three options may be set across one or more top-level `set` lines and in any
# spelling (set -euo pipefail, set -e + set -u + set -o pipefail, set -eu +
# set -o pipefail, set -o errexit -o nounset -o pipefail, etc.). Each `set` line
# is parsed by a left-to-right argument tokenizer that mirrors Bash's own
# interpretation: clustered short flags (-euo), long-form `-o name`, the `+`/`+o`
# disable forms, and the `--` end-of-options terminator (after which tokens are
# positional, NOT options) are all handled in one ordered walk. Option state
# persists across lines so a split-line floor and a later disable resolve to the
# final state. Scope is plugin runtime scripts only — tools/ and tests/ are
# intentionally excluded.
#
# Detection reads top-of-file lines, skipping the shebang and comment/blank
# lines, and stops scanning `set` options at the first non-comment executable
# statement. Lines are CRLF-tolerant: a trailing carriage return is stripped
# before matching so an autocrlf checkout does not produce false findings.
#
# SCOPE / LIMITATION: CHECK 13 is a BEST-EFFORT lint. It detects the PRESENCE of
# a floor STATEMENT at the top of a script — a standalone `set -euo pipefail`
# equivalent that runs as a simple command in the main shell. It does NOT prove
# floor EFFECTIVENESS under every pathological construct: a floor `set` reached
# only inside a conditional or function after the scan window, or an eval'd /
# dynamically-built `set`, is outside what this scanner can verify and is a
# documented limitation tracked separately. The scanner DOES fail closed on the
# common ineffective forms — a `set` that is piped, subshelled, backgrounded,
# chained, or `;`-separated is treated as establishing nothing (see the
# effectiveness guard below), so those constructs are flagged rather than
# silently credited.
#
# Finding line: a documented exception script carries a `P18 FLOOR EXCEPTION`
# comment marking the deliberate omission; the marker is recognized by canonical
# normalized match (see the marker branch below) and the finding is anchored to
# that line so the CHECK13 allowlist entry (seeded to that comment line) matches
# via the established test_allowlisted path. A script with no such marker (e.g. a
# new unguarded script) falls back to its first executable line, or line 1.

echo ''
echo '=== CHECK 13: P18 fail-closed shell floor ==='

check13_found=false
while IFS= read -r -d '' shell_script; do
    has_errexit=false
    has_nounset=false
    has_pipefail=false
    first_set_line=0
    exception_line=0
    line_num=0
    while IFS= read -r textline || [[ -n "$textline" ]]; do
        line_num=$((line_num + 1))
        # CRLF tolerance: strip a single trailing carriage return.
        textline="${textline%$'\r'}"
        trimmed="${textline#"${textline%%[![:space:]]*}"}"
        # Skip the shebang, blank lines, and comment lines. The documented
        # P18 FLOOR EXCEPTION marker, when present, anchors the finding line.
        if [[ "$line_num" -eq 1 && "$trimmed" == '#!'* ]]; then
            continue
        fi
        # Recognize the documented P18 FLOOR EXCEPTION marker by CANONICAL
        # NORMALIZED match rather than a brittle contiguous-substring test. All
        # shipped markers are single-sourced to the exact phrase
        # `P18 FLOOR EXCEPTION`; normalizing the candidate line before the
        # contains-test additionally tolerates future whitespace/punctuation
        # drift (extra spaces, ASCII hyphen `-`, em-dash, en-dash) on that same
        # 3-word phrase. Normalization: strip a leading `#` and surrounding
        # whitespace, strip a trailing CR (already stripped above, belt-and-
        # suspenders), collapse internal runs of whitespace AND dash characters
        # to a single space, then uppercase. Recognition is contiguous (the
        # normalized line must CONTAIN the normalized canonical token), NOT a
        # gappy subsequence, so unrelated comments cannot falsely match.
        if [[ "$exception_line" -eq 0 ]]; then
            norm_line="$(printf '%s' "$trimmed" \
                | sed -e 's/\r$//' \
                      -e 's/^#//' \
                      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                      -e 's/[[:space:]–—-]\{1,\}/ /g' \
                | tr '[:lower:]' '[:upper:]')"
            if [[ "$norm_line" == *'P18 FLOOR EXCEPTION'* ]]; then
                exception_line="$line_num"
            fi
        fi
        if [[ -z "$trimmed" || "$trimmed" == '#'* ]]; then
            continue
        fi
        # Parse top-level `set` lines with a left-to-right argument tokenizer
        # that mirrors how Bash itself interprets `set` arguments, rather than a
        # bag of independent per-line regexes. The previous regex approach was
        # FAIL-OPEN for `set -- -e -u -o pipefail`: Bash treats every token after
        # `--` as a POSITIONAL PARAMETER, not an option, so such a line floors
        # NOTHING — but the regexes still counted the trailing -e/-u/-o pipefail
        # and let an unfloored script pass strict validation. Tokenizing in order
        # and stopping at `--` closes that hole and dissolves the whole flag-side
        # edge-case class (clusters, long-form `-o name`, `+`/`+o` disables, and
        # `--` terminator are all one walk).
        if [[ "$trimmed" == 'set '* || "$trimmed" == 'set' ]]; then
            [[ "$first_set_line" -eq 0 ]] && first_set_line="$line_num"
            # Strip a trailing inline comment before tokenizing: a `#` preceded
            # by whitespace begins a shell comment, so flags appearing only after
            # it (e.g. `set -u # TODO add -e -o pipefail`) must NOT count toward
            # the floor. Without this strip, comment text would falsely satisfy
            # errexit/pipefail and skip both the finding and the CHECK13
            # allowlist path.
            set_flags="$trimmed"
            if [[ "$set_flags" =~ ^(.*[[:space:]])#.*$ ]]; then
                set_flags="${BASH_REMATCH[1]}"
            fi
            # Strip a SINGLE optional trailing list terminator before the
            # effectiveness guard below. A standalone `set -euo pipefail;` (or,
            # after the inline-comment strip above, `set -euo pipefail; # note`)
            # is still ONE valid Bash simple command that floors the current
            # shell — the trailing `;` is a list terminator, not a separator
            # introducing a SECOND command. Removing only a `;` that is the last
            # non-whitespace character keeps such a floor effective while leaving
            # a `;` that DOES introduce another command (`set -e; cmd`) intact,
            # so the guard below still marks THAT line inert. Strictness is
            # preserved: this only un-inerts a genuine trailing-terminator floor.
            if [[ "$set_flags" =~ ^(.*[^[:space:];])[[:space:]]*\;[[:space:]]*$ ]]; then
                set_flags="${BASH_REMATCH[1]}"
            fi
            # FAIL-CLOSED effectiveness guard: a `set` only changes the script's
            # main-shell options when it runs as a STANDALONE SIMPLE COMMAND. A
            # `set` that is piped (`set -euo pipefail | cat`), subshelled
            # (`(set -euo pipefail)`), backgrounded (`set ... &`), chained
            # (`set ... && cmd`), command-substituted, or split off with a `;`
            # that introduces another command runs in a subshell or is not the
            # floor statement at all, so its flags do NOT establish the floor.
            # Detecting any of these operator characters in the set statement
            # marks the line INERT: we do not tokenize it and do not credit its
            # flags, so the script is judged on the remaining effective `set`
            # lines (and is flagged if none floor it). This is strictness-only —
            # it can never fail open. The option NAME `pipefail` contains no `|`,
            # so a clean `set -euo pipefail`, `set -o pipefail`, `set -e`,
            # `set -u`, split-line floors, a trailing-`;` floor (stripped above),
            # and `set --` carry NONE of these characters and are unaffected.
            if [[ "$set_flags" == *'|'* || "$set_flags" == *'&'* \
                || "$set_flags" == *'('* || "$set_flags" == *')'* \
                || "$set_flags" == *';'* || "$set_flags" == *'`'* \
                || "$set_flags" == *'$'* ]]; then
                continue
            fi
            # has_errexit/has_nounset/has_pipefail PERSIST across `set` lines and
            # are NOT reset here: a split-line floor (set -e + set -u + set -o
            # pipefail) and a disable-after-floor (set -euo pipefail; set +e)
            # both depend on order across lines, so the FINAL state before the
            # first executable statement decides the floor.
            read -ra set_args <<< "$set_flags"
            arg_count=${#set_args[@]}
            arg_index=1   # set_args[0] is the literal `set`
            while [[ "$arg_index" -lt "$arg_count" ]]; do
                token="${set_args[$arg_index]}"
                if [[ "$token" == '--' ]]; then
                    # Everything after `--` is positional, not options. Stop.
                    break
                elif [[ "$token" == '-o' || "$token" == '+o' ]]; then
                    # Long-form option: the NAME is the next token. Enable for
                    # `-o`, disable for `+o`. Guard the trailing-token case.
                    if [[ "$((arg_index + 1))" -lt "$arg_count" ]]; then
                        opt_name="${set_args[$((arg_index + 1))]}"
                        case "$opt_name" in
                            errexit)  [[ "$token" == '-o' ]] && has_errexit=true  || has_errexit=false ;;
                            nounset)  [[ "$token" == '-o' ]] && has_nounset=true  || has_nounset=false ;;
                            pipefail) [[ "$token" == '-o' ]] && has_pipefail=true || has_pipefail=false ;;
                        esac
                        arg_index=$((arg_index + 1))   # consume the name token
                    fi
                elif [[ "$token" == '-' || "$token" == '+' ]]; then
                    : # bare - / + : ignore safely
                elif [[ "$token" == -[a-zA-Z]* ]]; then
                    # Clustered SHORT enable flags, e.g. -e, -eu, -euo. Walk the
                    # cluster letters; a cluster `o` consumes the NEXT WHOLE TOKEN
                    # as the long option name (the `-euo pipefail` case).
                    cluster="${token#-}"
                    cluster_i=0
                    while [[ "$cluster_i" -lt "${#cluster}" ]]; do
                        letter="${cluster:$cluster_i:1}"
                        case "$letter" in
                            e) has_errexit=true ;;
                            u) has_nounset=true ;;
                            o)
                                if [[ "$((arg_index + 1))" -lt "$arg_count" ]]; then
                                    opt_name="${set_args[$((arg_index + 1))]}"
                                    case "$opt_name" in
                                        errexit)  has_errexit=true ;;
                                        nounset)  has_nounset=true ;;
                                        pipefail) has_pipefail=true ;;
                                    esac
                                    arg_index=$((arg_index + 1))   # consume name
                                fi
                                break   # `o` ends cluster scanning
                                ;;
                        esac
                        cluster_i=$((cluster_i + 1))
                    done
                elif [[ "$token" == +[a-zA-Z]* ]]; then
                    # Clustered SHORT disable flags, e.g. +e, +eu. A cluster `o`
                    # consumes the next token as the name and disables it.
                    cluster="${token#+}"
                    cluster_i=0
                    while [[ "$cluster_i" -lt "${#cluster}" ]]; do
                        letter="${cluster:$cluster_i:1}"
                        case "$letter" in
                            e) has_errexit=false ;;
                            u) has_nounset=false ;;
                            o)
                                if [[ "$((arg_index + 1))" -lt "$arg_count" ]]; then
                                    opt_name="${set_args[$((arg_index + 1))]}"
                                    case "$opt_name" in
                                        errexit)  has_errexit=false ;;
                                        nounset)  has_nounset=false ;;
                                        pipefail) has_pipefail=false ;;
                                    esac
                                    arg_index=$((arg_index + 1))   # consume name
                                fi
                                break
                                ;;
                        esac
                        cluster_i=$((cluster_i + 1))
                    done
                fi
                # anything else (positional-looking / unknown long opt) → ignore
                arg_index=$((arg_index + 1))
            done
            continue
        fi
        # First non-comment, non-set executable statement ends the floor window:
        # `set` options enabled below here would not establish the floor.
        break
    done < "$shell_script"

    if [[ "$has_errexit" == true && "$has_nounset" == true && "$has_pipefail" == true ]]; then
        continue
    fi

    # Anchor the finding to (in precedence order) the documented P18 FLOOR
    # EXCEPTION comment, the first partial `set` line, or line 1 — so a
    # documented-exception script's finding line matches its seeded CHECK13
    # allowlist entry via test_allowlisted (the exception comment for scripts
    # that carry one, the partial-floor `set` line otherwise, line 1 for a
    # bare sourced library). A new unguarded script with none of these still
    # fires on line 1.
    if [[ "$exception_line" -gt 0 ]]; then
        finding_line="$exception_line"
    elif [[ "$first_set_line" -gt 0 ]]; then
        finding_line="$first_set_line"
    else
        finding_line=1
    fi
    # The pass/fail tally counts only NON-allowlisted findings as failures: a
    # script with a documented CHECK13 exception is a clean (allowlisted) state,
    # not a check failure. Resolve allowlist status on the same rel-path
    # normalization add_finding applies so the two agree.
    rel_script="$shell_script"
    if [[ "$shell_script" == "$REPO_ROOT"* ]]; then
        rel_script="${shell_script#"$REPO_ROOT"/}"
    fi
    rel_script="${rel_script//\\//}"
    if [[ "$(test_allowlisted 'CHECK13' "$rel_script" "$finding_line")" != "true" ]]; then
        check13_found=true
    fi
    add_finding 'CHECK13' "$shell_script" "$finding_line" \
        "missing P18 fail-closed shell floor (set -euo pipefail) -- add the floor or document a justified CHECK13 allowlist exception"
done < <(find "$PLUGIN_ROOT" -name '*.sh' -type f -print0)

if [[ "$check13_found" == false ]]; then
    echo '[PASS] Check 13: All plugin shell scripts carry the P18 fail-closed floor or a CHECK13 exception'
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── CHECK 14: No turn-terminating language in sub-step skill body prose ────
#
# A skill body loads into its CALLING AGENT's context. A skill invoked INLINE as
# a mid-procedure sub-step of an agent therefore must carry NO turn-terminating
# language: an agent that reads `Your final action must be ...` obeys it as its
# own terminal directive, ends its turn early, and returns the skill's output as
# its own result — a silent FALSE PASS (a bare `verdict: clean` list reads as
# review-passed, with no error and no non-zero exit). Observed live on 4 of 5
# reviewer dispatches (issue #321). Skill prose must be SKILL-SCOPED ("this
# skill's procedure produces zero chat text of its own"), never caller-scoped.
#
# The sub-step set is DERIVED FROM CALLERS, never declared. Discovery reads two
# INDEPENDENT, position-free signals off each non-overlord agent BODY line — the
# `Skill tool` marker literal, and every resolvable `hivemind:<name>` token — and
# then applies a parity test between those tokens and the raw `hivemind:`
# mentions on the line. No verb, article, ordering, or connective is asserted, so
# a rephrased invocation cannot quietly fall out of the derived set. The property
# this buys is LOUD FAILURE, not omniscience: wherever the two signals DISAGREE
# the check emits a FINDING rather than a silent omission — a marked line with no
# resolvable token fails, and a `hivemind:` mention discovery cannot resolve
# fails.
#
# Two residuals stated honestly, because this predicate does NOT cover everything:
#   - A line that invokes a skill with NO `Skill tool` marker stays UNDERIVED. It
#     is still resolvable, so parity holds and nothing fires. The marker is the
#     inline-invocation signal; prose lacking it is out of the derived set.
#   - A foreign-namespace inline invocation (a marked line whose skill is not in
#     the `hivemind:` namespace) trips the marked-but-unresolvable finding BY
#     DESIGN, forcing an explicit decision about that caller instead of a silent
#     gap.
#
# FAIL-CLOSED: an EMPTY derived set is itself a finding — members are known to
# exist, so an empty set means discovery broke. Workflow-state skills are never
# in the derived set, so their (correct) terminal framing is never scanned.
#
# Structural exclusions (YAML frontmatter, fenced code blocks, table rows) come
# from the shared body-line emitter below and apply to BOTH the agent discovery
# pass and the skill-body scan. `stop-and-merge` is stripped before matching: it
# is a domain term in detect-remediation-signals, not terminal language.

# Emits a Markdown file's surviving BODY lines as "line_num<TAB>line", excluding
# YAML frontmatter, fenced code blocks, and markdown table rows. Defined once and
# consumed by both CHECK 14 passes; one pass per file, no per-line subshell.
emit_body_lines() {
    local markdown_file="$1"
    awk '
        BEGIN { in_fm = 0; fm_done = 0; in_fence = 0 }
        {
            # YAML frontmatter: first line "---" opens, next "---" closes.
            if (!fm_done && NR == 1 && $0 == "---") { in_fm = 1; next }
            if (in_fm) { if ($0 == "---") { in_fm = 0; fm_done = 1 } next }
            # Fenced code blocks toggle on lines starting with ```.
            if ($0 ~ /^```/) { in_fence = !in_fence; next }
            if (in_fence) next
            # Markdown table rows.
            if ($0 ~ /^[ \t]*\|/) next
            print NR "\t" $0
        }
    ' "$markdown_file"
}

echo ''
echo '=== CHECK 14: No turn-terminating language in sub-step skill body prose ==='

# Signal 1: the inline Skill-tool marker literal. Position-free.
CHECK14_SKILLTOOL_MARKER='Skill tool'
# Signal 2: a resolvable sub-step token — a backtick IMMEDIATELY followed by the
# namespace and a name, the name terminated by any character outside the name
# charset. The CLOSING backtick is deliberately NOT required, so a token carrying
# trailing arguments (`hivemind:record-state-result --plan-steps`) still resolves.
CHECK14_TOKEN_REGEX='`hivemind:[a-z0-9-]+'
# Turn-terminating prose patterns that make a caller end its own turn.
CHECK14_TERMINAL_REGEX='Your final action|final action is a|[Pp]roduce zero (text|chat)|^Emit exactly|and stop'
# KEEP-phrase regex: domain terms that must NOT be flagged.
CHECK14_KEEP_REGEX='stop-and-merge'

check14_found=false
declare -a CHECK14_DERIVED_NAMES=()
while IFS= read -r -d '' agent_file; do
    # Each awk record is "kind<TAB>line<TAB>mentions<TAB>tokens<TAB>name"; `name`
    # is populated on `skill` records only.
    while IFS=$'\t' read -r record_kind record_line record_mentions record_tokens record_name; do
        case "$record_kind" in
            skill)
                CHECK14_DERIVED_NAMES+=("$record_name")
                ;;
            unresolvable)
                check14_found=true
                add_finding 'CHECK14' "$agent_file" "$record_line" \
                    "Skill-tool invocation line carries NO resolvable \`hivemind:<name>\` token -- sub-step discovery cannot derive which skill this line invokes; write the invoked skill as a backticked \`hivemind:<name>\` token or drop the Skill-tool marker (fail-closed, never silently pass)"
                ;;
            parity)
                check14_found=true
                add_finding 'CHECK14' "$agent_file" "$record_line" \
                    "line carries $record_mentions 'hivemind:' reference(s) but only $record_tokens resolvable token(s) -- a hivemind: reference sub-step discovery cannot resolve; write every reference as a backticked \`hivemind:<name>\` token (fail-closed, never silently pass)"
                ;;
        esac
    done < <(emit_body_lines "$agent_file" \
        | awk -F'\t' -v marker="$CHECK14_SKILLTOOL_MARKER" -v token_re="$CHECK14_TOKEN_REGEX" '
            {
                line_num = $1
                text = substr($0, index($0, "\t") + 1)
                # Signal 1 — position-free marker presence.
                has_marker = (index(text, marker) > 0)
                # Raw namespace mentions; "&" re-inserts the match, so gsub only counts.
                mention_count = gsub(/hivemind:/, "&", text)
                # Signal 2 — every resolvable token, in order of appearance.
                token_count = 0
                rest = text
                while (match(rest, token_re)) {
                    name = substr(rest, RSTART, RLENGTH)
                    sub(/^[^:]*:/, "", name)
                    token_count++
                    found[token_count] = name
                    rest = substr(rest, RSTART + RLENGTH)
                }
                # R1 DERIVE: marker + tokens enrolls EVERY token on the line.
                if (has_marker && token_count > 0) {
                    for (i = 1; i <= token_count; i++) {
                        print "skill\t" line_num "\t" mention_count "\t" token_count "\t" found[i]
                    }
                }
                # R2 FAIL-CLOSED: marked line discovery cannot resolve at all.
                if (has_marker && token_count == 0) {
                    print "unresolvable\t" line_num "\t" mention_count "\t" token_count "\t"
                }
                # R3 FAIL-CLOSED: a namespace mention that is not a resolvable token.
                if (mention_count != token_count) {
                    print "parity\t" line_num "\t" mention_count "\t" token_count "\t"
                }
            }
        ')
done < <(find "$PLUGIN_ROOT/agents" -maxdepth 1 -name '*.md' -type f ! -name 'overlord.md' -print0)

declare -a CHECK14_SUBSTEP_SKILLS=()
if [[ ${#CHECK14_DERIVED_NAMES[@]} -gt 0 ]]; then
    while IFS= read -r substep_skill; do
        [[ -z "$substep_skill" ]] && continue
        CHECK14_SUBSTEP_SKILLS+=("$substep_skill")
    done < <(printf '%s\n' "${CHECK14_DERIVED_NAMES[@]}" | sort -u)
fi

if [[ ${#CHECK14_SUBSTEP_SKILLS[@]} -eq 0 ]]; then
    check14_found=true
    add_finding 'CHECK14' "$PLUGIN_ROOT/agents" 0 \
        "sub-step skill discovery derived an EMPTY set from non-overlord agent bodies -- Skill-tool sub-step invocations are known to exist, so the discovery regex is broken; repair it (fail-closed, never silently pass)"
else
    for substep_skill in "${CHECK14_SUBSTEP_SKILLS[@]}"; do
        substep_file="$PLUGIN_ROOT/skills/$substep_skill/SKILL.md"
        if [[ ! -f "$substep_file" ]]; then
            check14_found=true
            add_finding 'CHECK14' "$substep_file" 0 \
                "sub-step skill 'hivemind:$substep_skill' is invoked (Skill tool) by a non-overlord agent but its SKILL.md does not exist"
            continue
        fi
        # Shared body-line emitter supplies "line_num<TAB>line" for BODY lines only.
        while IFS=$'\t' read -r line_num textline; do
            [[ -z "$line_num" ]] && continue
            # Strip KEEP-phrase spans first (mirrors CHECK 11's KEEP strip), so a
            # real terminal phrase sharing a line with a domain term is still caught.
            residual="$(echo "$textline" | sed -E "s/(${CHECK14_KEEP_REGEX})//Ig")"
            if echo "$residual" | grep -qE "$CHECK14_TERMINAL_REGEX"; then
                terminal_phrase="$(echo "$residual" | grep -oE "$CHECK14_TERMINAL_REGEX" | head -n1)"
                check14_found=true
                add_finding 'CHECK14' "$substep_file" "$line_num" \
                    "turn-terminating language '$terminal_phrase' in sub-step skill body prose -- this skill is invoked inline (Skill tool) by a non-overlord agent, so the caller obeys it as its own terminal directive and ends its turn early (false PASS, issue #321); rephrase SKILL-SCOPED, not caller-scoped"
            fi
        done < <(emit_body_lines "$substep_file")
    done
fi

if [[ "$check14_found" == false ]]; then
    echo "[PASS] Check 14: No turn-terminating language in ${#CHECK14_SUBSTEP_SKILLS[@]} caller-derived sub-step skill bodies (${CHECK14_SUBSTEP_SKILLS[*]})"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# ── SAFETY REGRESSION TESTS ────────────────────────────────────────────────

echo ''
echo '=== SAFETY: Regression fixture tests ==='

SAFETY_DIR="$REPO_ROOT/tests/policy"
declare -a SAFETY_FIXTURES=()
if [[ -d "$SAFETY_DIR" ]]; then
    while IFS= read -r -d '' f; do
        SAFETY_FIXTURES+=("$f")
    done < <(find "$SAFETY_DIR" -maxdepth 1 -name 'safety-*.json' -type f -print0)
fi

SAFETY_PASSED=0
SAFETY_FAILED=0

test_set_check() {
    local rule_name="$1"
    local set_check_json="$2"
    local passed=true

    local regex_text
    regex_text="$(echo "$set_check_json" | jq -r '.extract_regex // empty')"
    if [[ -z "$regex_text" ]]; then
        add_finding 'SAFETY' '<fixture>' 0 \
            "[$rule_name] set_check.extract_regex is required"
        TEST_SET_CHECK_RESULT="false"
        return
    fi

    # Validate regex compiles
    if ! echo "" | grep -P "$regex_text" > /dev/null 2>&1; then
        # grep -P returns 1 for no match but 2 for bad regex; test specifically
        if echo "" | grep -P "$regex_text" 2>&1 | grep -qi 'error\|invalid\|unknown'; then
            add_finding 'SAFETY' '<fixture>' 0 \
                "[$rule_name] set_check.extract_regex did not compile"
            TEST_SET_CHECK_RESULT="false"
            return
        fi
    fi

    # Build expected set
    local expected_json
    expected_json="$(echo "$set_check_json" | jq -r '.expected_set // []')"

    # Process each file entry
    local file_count
    file_count="$(echo "$set_check_json" | jq '.files | length')"
    local fi_idx=0
    while [[ $fi_idx -lt $file_count ]]; do
        local rel_path
        rel_path="$(echo "$set_check_json" | jq -r ".files[$fi_idx].path")"
        local mode
        mode="$(echo "$set_check_json" | jq -r ".files[$fi_idx].mode // \"equal\"")"
        local abs_path
        abs_path="$(resolve_repo_path "$rel_path")"

        if [[ ! -f "$abs_path" ]]; then
            passed=false
            add_finding 'SAFETY' "$rel_path" 0 \
                "[$rule_name] set_check file missing: $rel_path"
            fi_idx=$((fi_idx + 1))
            continue
        fi

        local content
        content="$(<"$abs_path")"

        # Extract capture group 1 matches; Perl is primary (handles PCRE regexes correctly)
        local captured_json
        captured_json="$(echo "$content" | perl -ne "while (/$regex_text/g) { print \"\$1\n\" }" 2>/dev/null | jq -R . | jq -s 'group_by(.) | map({key: .[0], value: length}) | from_entries' 2>/dev/null || echo '{}')"
        # Fallback: grep -oP + sed-E for environments without Perl
        if [[ "$captured_json" == '{}' ]]; then
            captured_json="$(echo "$content" | grep -oP "$regex_text" 2>/dev/null | sed -E "s/$regex_text/\1/" | jq -R . | jq -s 'group_by(.) | map({key: .[0], value: length}) | from_entries' 2>/dev/null || echo '{}')"
        fi

        local captured_set
        captured_set="$(echo "$captured_json" | jq -r 'keys[]' 2>/dev/null || true)"

        # Compute extras (captured \ expected) and missing (expected \ captured)
        local extras=""
        local missing=""
        while IFS= read -r val; do
            [[ -z "$val" ]] && continue
            if ! echo "$expected_json" | jq -e --arg v "$val" 'index($v) != null' > /dev/null 2>&1; then
                if [[ -n "$extras" ]]; then extras="$extras, $val"; else extras="$val"; fi
            fi
        done <<< "$captured_set"

        local exp_count
        exp_count="$(echo "$expected_json" | jq 'length')"
        local ei=0
        while [[ $ei -lt $exp_count ]]; do
            local exp_val
            exp_val="$(echo "$expected_json" | jq -r ".[$ei]")"
            if ! echo "$captured_set" | grep -qxF "$exp_val"; then
                if [[ -n "$missing" ]]; then missing="$missing, $exp_val"; else missing="$exp_val"; fi
            fi
            ei=$((ei + 1))
        done

        case "$mode" in
            equal)
                if [[ -n "$extras" || -n "$missing" ]]; then
                    passed=false
                    local detail=""
                    if [[ -n "$missing" ]]; then detail="missing: $missing"; fi
                    if [[ -n "$extras" ]]; then
                        if [[ -n "$detail" ]]; then detail="$detail; "; fi
                        detail="${detail}extras: $extras"
                    fi
                    add_finding 'SAFETY' "$rel_path" 0 \
                        "[$rule_name] set_check (equal) failed for ${rel_path}: $detail"
                fi
                ;;
            subset)
                if [[ -n "$extras" ]]; then
                    passed=false
                    add_finding 'SAFETY' "$rel_path" 0 \
                        "[$rule_name] set_check (subset) failed for ${rel_path}: extras: $extras"
                fi
                ;;
            superset)
                if [[ -n "$missing" ]]; then
                    passed=false
                    add_finding 'SAFETY' "$rel_path" 0 \
                        "[$rule_name] set_check (superset) failed for ${rel_path}: missing: $missing"
                fi
                ;;
            *)
                passed=false
                add_finding 'SAFETY' "$rel_path" 0 \
                    "[$rule_name] set_check unknown mode '$mode' (expected equal|subset|superset)"
                ;;
        esac

        # Optional per-element occurrence-count assertion
        local has_expected_counts
        has_expected_counts="$(echo "$set_check_json" | jq 'has("expected_counts")')"
        if [[ "$has_expected_counts" == "true" ]]; then
            local expected_counts_json
            expected_counts_json="$(echo "$set_check_json" | jq '.expected_counts')"
            while IFS= read -r count_key; do
                [[ -z "$count_key" ]] && continue
                local want
                want="$(echo "$expected_counts_json" | jq -r --arg k "$count_key" '.[$k]')"
                local got
                got="$(echo "$captured_json" | jq -r --arg k "$count_key" '.[$k] // 0')"
                if [[ "$got" != "$want" ]]; then
                    passed=false
                    add_finding 'SAFETY' "$rel_path" 0 \
                        "[$rule_name] set_check expected_counts mismatch in ${rel_path}: '$count_key' has $got occurrence(s), expected $want"
                fi
            done < <(echo "$expected_counts_json" | jq -r 'keys[]')
        fi

        fi_idx=$((fi_idx + 1))
    done

    TEST_SET_CHECK_RESULT="$passed"
}

for fixture_file in "${SAFETY_FIXTURES[@]}"; do
    fixture_raw="$(<"$fixture_file")"
    rule_name="$(echo "$fixture_raw" | jq -r '.rule')"
    fixture_passed=true

    has_source="$(echo "$fixture_raw" | jq 'has("source")')"
    has_consumers="$(echo "$fixture_raw" | jq 'has("consumers")')"
    has_set_check="$(echo "$fixture_raw" | jq 'has("set_check")')"

    if [[ "$has_source" != "true" && "$has_consumers" != "true" && "$has_set_check" != "true" ]]; then
        fixture_passed=false
        add_finding 'SAFETY' "$(basename "$fixture_file")" 0 \
            "[$rule_name] fixture has none of source / consumers / set_check"
    fi

    # Set-check assertion
    if [[ "$has_set_check" == "true" ]]; then
        set_check_json="$(echo "$fixture_raw" | jq '.set_check')"
        TEST_SET_CHECK_RESULT=""
        test_set_check "$rule_name" "$set_check_json"
        if [[ "$TEST_SET_CHECK_RESULT" != "true" ]]; then
            fixture_passed=false
        fi
    fi

    # Legacy source presence check
    if [[ "$has_source" == "true" ]]; then
        source_file_rel="$(echo "$fixture_raw" | jq -r '.source.file')"
        source_pattern="$(echo "$fixture_raw" | jq -r '.source.pattern')"
        source_abs_path="$(resolve_repo_path "$source_file_rel")"

        if [[ ! -f "$source_abs_path" ]]; then
            fixture_passed=false
            add_finding 'SAFETY' "$source_file_rel" 0 \
                "[$rule_name] Source file missing: $source_file_rel"
        else
            source_content="$(<"$source_abs_path")"
            if [[ "$source_content" != *"$source_pattern"* ]]; then
                fixture_passed=false
                add_finding 'SAFETY' "$source_file_rel" 0 \
                    "[$rule_name] Source pattern not found: $source_pattern"
            fi
        fi
    fi

    # Legacy consumers presence check
    if [[ "$has_consumers" == "true" ]]; then
        consumer_count="$(echo "$fixture_raw" | jq '.consumers | length')"
        ci=0
        while [[ $ci -lt $consumer_count ]]; do
            consumer_file_rel="$(echo "$fixture_raw" | jq -r ".consumers[$ci].file")"
            consumer_pattern="$(echo "$fixture_raw" | jq -r ".consumers[$ci].pattern")"
            consumer_abs_path="$(resolve_repo_path "$consumer_file_rel")"

            if [[ ! -f "$consumer_abs_path" ]]; then
                fixture_passed=false
                add_finding 'SAFETY' "$consumer_file_rel" 0 \
                    "[$rule_name] Consumer file missing: $consumer_file_rel"
                ci=$((ci + 1))
                continue
            fi

            is_absent="$(echo "$fixture_raw" | jq -r ".consumers[$ci].absent // false")"

            if [[ "$is_absent" == "true" ]]; then
                # INVARIANT: absent checks scope to YAML frontmatter only.
                frontmatter_content="$(get_frontmatter "$consumer_abs_path")"
                if [[ "$frontmatter_content" == *"$consumer_pattern"* ]]; then
                    fixture_passed=false
                    add_finding 'SAFETY' "$consumer_file_rel" 0 \
                        "[$rule_name] Consumer frontmatter must NOT contain: $consumer_pattern"
                fi
            else
                consumer_content="$(<"$consumer_abs_path")"
                if [[ "$consumer_content" != *"$consumer_pattern"* ]]; then
                    fixture_passed=false
                    add_finding 'SAFETY' "$consumer_file_rel" 0 \
                        "[$rule_name] Consumer pattern not found: $consumer_pattern"
                fi
            fi
            ci=$((ci + 1))
        done
    fi

    if [[ "$fixture_passed" == true ]]; then
        echo "[PASS] SAFETY: $rule_name"
        SAFETY_PASSED=$((SAFETY_PASSED + 1))
    else
        echo "[FAIL] SAFETY: $rule_name"
        SAFETY_FAILED=$((SAFETY_FAILED + 1))
    fi
done

if [[ ${#SAFETY_FIXTURES[@]} -eq 0 ]]; then
    echo '[SKIP] No safety fixture files found'
else
    echo "Safety fixtures: $SAFETY_PASSED passed, $SAFETY_FAILED failed out of ${#SAFETY_FIXTURES[@]}"
    CHECKS_PASSED=$((CHECKS_PASSED + SAFETY_PASSED))
    CHECKS_FAILED=$((CHECKS_FAILED + SAFETY_FAILED))
fi

# ── COMPATIBILITY TESTS ────────────────────────────────────────────────────

echo ''
echo '=== COMPAT: Plugin compatibility fixture tests ==='

COMPAT_DIR="$REPO_ROOT/tests/plugin"
declare -a COMPAT_FIXTURES=()
if [[ -d "$COMPAT_DIR" ]]; then
    while IFS= read -r -d '' f; do
        COMPAT_FIXTURES+=("$f")
    done < <(find "$COMPAT_DIR" -maxdepth 1 -name '*.json' -type f -print0)
fi

COMPAT_PASSED=0
COMPAT_FAILED=0

for fixture_file in "${COMPAT_FIXTURES[@]}"; do
    fixture_raw="$(<"$fixture_file")"
    check_desc="$(echo "$fixture_raw" | jq -r '.check')"
    check_type="$(echo "$fixture_raw" | jq -r '.type')"
    fixture_passed=true

    case "$check_type" in

        json-fields)
            target_rel="$(echo "$fixture_raw" | jq -r '.file')"
            target_path="$(resolve_repo_path "$target_rel")"
            if [[ ! -f "$target_path" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_rel" 0 \
                    "[$check_desc] File missing: $target_rel"
            else
                json_obj="$(<"$target_path")"
                req_count="$(echo "$fixture_raw" | jq '.required | length')"
                ri=0
                while [[ $ri -lt $req_count ]]; do
                    req_field="$(echo "$fixture_raw" | jq -r ".required[$ri]")"
                    if ! echo "$json_obj" | jq -e --arg f "$req_field" 'has($f)' > /dev/null 2>&1; then
                        fixture_passed=false
                        add_finding 'COMPAT' "$target_rel" 0 \
                            "[$check_desc] Missing required JSON field: $req_field"
                    fi
                    ri=$((ri + 1))
                done
            fi
            ;;

        json-field-value)
            target_rel="$(echo "$fixture_raw" | jq -r '.file')"
            target_path="$(resolve_repo_path "$target_rel")"
            if [[ ! -f "$target_path" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_rel" 0 \
                    "[$check_desc] File missing: $target_rel"
            else
                json_obj="$(<"$target_path")"

                # Check required arrays if specified
                has_req_arrays="$(echo "$fixture_raw" | jq 'has("required-arrays")')"
                if [[ "$has_req_arrays" == "true" ]]; then
                    ra_count="$(echo "$fixture_raw" | jq '."required-arrays" | length')"
                    rai=0
                    while [[ $rai -lt $ra_count ]]; do
                        arr_name="$(echo "$fixture_raw" | jq -r ".\"required-arrays\"[$rai]")"
                        if ! echo "$json_obj" | jq -e --arg f "$arr_name" 'has($f)' > /dev/null 2>&1; then
                            fixture_passed=false
                            add_finding 'COMPAT' "$target_rel" 0 \
                                "[$check_desc] Missing required array: $arr_name"
                        else
                            arr_len="$(echo "$json_obj" | jq --arg f "$arr_name" '.[$f] | if type == "array" then length else -1 end')"
                            if [[ "$arr_len" -le 0 ]]; then
                                fixture_passed=false
                                add_finding 'COMPAT' "$target_rel" 0 \
                                    "[$check_desc] Field is not a non-empty array: $arr_name"
                            fi
                        fi
                        rai=$((rai + 1))
                    done
                fi

                # Check field value
                field_name="$(echo "$fixture_raw" | jq -r '.field')"
                expected_value="$(echo "$fixture_raw" | jq -r '.expected')"
                field_found=false

                has_plugins="$(echo "$json_obj" | jq 'has("plugins") and (.plugins | length > 0)' 2>/dev/null || echo "false")"
                if [[ "$has_plugins" == "true" ]]; then
                    field_found=true
                    plugin_count="$(echo "$json_obj" | jq '.plugins | length')"
                    pi=0
                    while [[ $pi -lt $plugin_count ]]; do
                        has_field="$(echo "$json_obj" | jq --arg f "$field_name" ".plugins[$pi] | has(\$f)")"
                        if [[ "$has_field" != "true" ]]; then
                            fixture_passed=false
                            add_finding 'COMPAT' "$target_rel" 0 \
                                "[$check_desc] plugins[] entry missing required field '$field_name'"
                        else
                            actual_value="$(echo "$json_obj" | jq -r --arg f "$field_name" ".plugins[$pi][\$f]")"
                            if [[ "$actual_value" != "$expected_value" ]]; then
                                fixture_passed=false
                                add_finding 'COMPAT' "$target_rel" 0 \
                                    "[$check_desc] plugins[].$field_name = '$actual_value', expected '$expected_value'"
                            fi
                        fi
                        pi=$((pi + 1))
                    done
                else
                    has_field="$(echo "$json_obj" | jq --arg f "$field_name" 'has($f)' 2>/dev/null || echo "false")"
                    if [[ "$has_field" == "true" ]]; then
                        field_found=true
                        actual_value="$(echo "$json_obj" | jq -r --arg f "$field_name" '.[$f]')"
                        if [[ "$actual_value" != "$expected_value" ]]; then
                            fixture_passed=false
                            add_finding 'COMPAT' "$target_rel" 0 \
                                "[$check_desc] $field_name = '$actual_value', expected '$expected_value'"
                        fi
                    fi
                fi

                if [[ "$field_found" == false ]]; then
                    fixture_passed=false
                    add_finding 'COMPAT' "$target_rel" 0 \
                        "[$check_desc] Field '$field_name' not found"
                fi
            fi
            ;;

        frontmatter-all-files)
            target_dir_rel="$(echo "$fixture_raw" | jq -r '.dir')"
            target_dir="$(resolve_repo_path "$target_dir_rel")"
            if [[ ! -d "$target_dir" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_dir_rel" 0 \
                    "[$check_desc] Directory missing: $target_dir_rel"
            else
                glob_pattern="$(echo "$fixture_raw" | jq -r '.glob // "*.md"')"
                exclude_pattern="$(echo "$fixture_raw" | jq -r '.exclude // empty')"

                declare -a target_files=()
                if [[ "$glob_pattern" == *"/"* ]]; then
                    # Glob with subdirectory (e.g. */SKILL.md) — recurse and filter
                    local_filter="${glob_pattern##*/}"
                    while IFS= read -r -d '' tf; do
                        target_files+=("$tf")
                    done < <(find "$target_dir" -name "$local_filter" -type f -print0)
                else
                    while IFS= read -r -d '' tf; do
                        target_files+=("$tf")
                    done < <(find "$target_dir" -maxdepth 1 -name "$glob_pattern" -type f -print0)
                fi

                if [[ -n "$exclude_pattern" ]]; then
                    declare -a filtered_files=()
                    for tf in "${target_files[@]}"; do
                        if ! echo "$tf" | grep -q "/$exclude_pattern/"; then
                            filtered_files+=("$tf")
                        fi
                    done
                    target_files=("${filtered_files[@]}")
                fi

                if [[ ${#target_files[@]} -eq 0 ]]; then
                    fixture_passed=false
                    add_finding 'COMPAT' "$target_dir_rel" 0 \
                        "[$check_desc] No files matched glob '$glob_pattern' in $target_dir_rel"
                fi

                req_count="$(echo "$fixture_raw" | jq '.required | length')"
                for target_file in "${target_files[@]}"; do
                    fm_content="$(get_frontmatter "$target_file")"
                    ri=0
                    while [[ $ri -lt $req_count ]]; do
                        req_field="$(echo "$fixture_raw" | jq -r ".required[$ri]")"
                        if ! echo "$fm_content" | grep -qP "^\s*${req_field}\s*:"; then
                            fixture_passed=false
                            rel_file="${target_file#"$REPO_ROOT"/}"
                            rel_file="${rel_file//\\//}"
                            add_finding 'COMPAT' "$rel_file" 0 \
                                "[$check_desc] Missing frontmatter field: $req_field"
                        fi
                        ri=$((ri + 1))
                    done
                done
            fi
            ;;

        frontmatter-field-absent)
            target_dir_rel="$(echo "$fixture_raw" | jq -r '.dir')"
            target_dir="$(resolve_repo_path "$target_dir_rel")"
            if [[ ! -d "$target_dir" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_dir_rel" 0 \
                    "[$check_desc] Directory missing: $target_dir_rel"
            else
                while IFS= read -r -d '' target_file; do
                    fm_content="$(get_frontmatter "$target_file")"
                    absent_count="$(echo "$fixture_raw" | jq '.absent | length')"
                    ai=0
                    while [[ $ai -lt $absent_count ]]; do
                        absent_field="$(echo "$fixture_raw" | jq -r ".absent[$ai]")"
                        if echo "$fm_content" | grep -qP "^\s*${absent_field}\s*:"; then
                            fixture_passed=false
                            rel_file="${target_file#"$REPO_ROOT"/}"
                            rel_file="${rel_file//\\//}"
                            add_finding 'COMPAT' "$rel_file" 0 \
                                "[$check_desc] Forbidden frontmatter field present: $absent_field"
                        fi
                        ai=$((ai + 1))
                    done
                done < <(find "$target_dir" -maxdepth 1 -name '*.md' -type f -print0)
            fi
            ;;

        dir-names-in-file)
            target_dir_rel="$(echo "$fixture_raw" | jq -r '.dir')"
            ref_file_rel="$(echo "$fixture_raw" | jq -r '.file')"
            exclude_pattern="$(echo "$fixture_raw" | jq -r '.exclude // empty')"
            target_dir="$(resolve_repo_path "$target_dir_rel")"
            ref_file_path="$(resolve_repo_path "$ref_file_rel")"

            if [[ ! -d "$target_dir" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_dir_rel" 0 \
                    "[$check_desc] Directory missing: $target_dir_rel"
            elif [[ ! -f "$ref_file_path" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$ref_file_rel" 0 \
                    "[$check_desc] Reference file missing: $ref_file_rel"
            else
                ref_content="$(<"$ref_file_path")"
                while IFS= read -r -d '' subdir; do
                    dir_name="$(basename "$subdir")"
                    if [[ -n "$exclude_pattern" && "$dir_name" == "$exclude_pattern" ]]; then
                        continue
                    fi
                    # Use fixed-string grep to check for the directory name
                    if ! echo "$ref_content" | grep -qF "$dir_name"; then
                        fixture_passed=false
                        add_finding 'COMPAT' "$ref_file_rel" 0 \
                            "[$check_desc] Directory name not found in $ref_file_rel: $dir_name"
                    fi
                done < <(find "$target_dir" -mindepth 1 -maxdepth 1 -type d -print0)
            fi
            ;;

        file-names-in-file)
            target_dir_rel="$(echo "$fixture_raw" | jq -r '.dir')"
            ref_file_rel="$(echo "$fixture_raw" | jq -r '.file')"
            target_dir="$(resolve_repo_path "$target_dir_rel")"
            ref_file_path="$(resolve_repo_path "$ref_file_rel")"

            if [[ ! -d "$target_dir" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_dir_rel" 0 \
                    "[$check_desc] Directory missing: $target_dir_rel"
            elif [[ ! -f "$ref_file_path" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$ref_file_rel" 0 \
                    "[$check_desc] Reference file missing: $ref_file_rel"
            else
                ref_content="$(<"$ref_file_path")"
                while IFS= read -r -d '' file_in_dir; do
                    base_name="$(basename "$file_in_dir" .md)"
                    if ! echo "$ref_content" | grep -qF "$base_name"; then
                        fixture_passed=false
                        add_finding 'COMPAT' "$ref_file_rel" 0 \
                            "[$check_desc] Filename not found in $ref_file_rel: $base_name"
                    fi
                done < <(find "$target_dir" -maxdepth 1 -name '*.md' -type f -print0)
            fi
            ;;

        file-exists-and-referenced)
            target_rel="$(echo "$fixture_raw" | jq -r '.file')"
            ref_file_rel="$(echo "$fixture_raw" | jq -r '.["referenced-in"]')"
            target_path="$(resolve_repo_path "$target_rel")"
            ref_file_path="$(resolve_repo_path "$ref_file_rel")"

            if [[ ! -f "$target_path" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_rel" 0 \
                    "[$check_desc] File missing: $target_rel"
            fi

            if [[ ! -f "$ref_file_path" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$ref_file_rel" 0 \
                    "[$check_desc] Reference file missing: $ref_file_rel"
            elif [[ -f "$target_path" ]]; then
                ref_content="$(<"$ref_file_path")"
                file_base_name="$(basename "$target_rel")"
                if ! echo "$ref_content" | grep -qF "$file_base_name"; then
                    fixture_passed=false
                    add_finding 'COMPAT' "$ref_file_rel" 0 \
                        "[$check_desc] $ref_file_rel does not reference $file_base_name"
                fi
            fi
            ;;

        pattern-absent-in-dir)
            target_dir_rel="$(echo "$fixture_raw" | jq -r '.dir')"
            search_pattern="$(echo "$fixture_raw" | jq -r '.pattern')"
            target_dir="$(resolve_repo_path "$target_dir_rel")"

            if [[ ! -d "$target_dir" ]]; then
                fixture_passed=false
                add_finding 'COMPAT' "$target_dir_rel" 0 \
                    "[$check_desc] Directory missing: $target_dir_rel"
            else
                while IFS= read -r -d '' scan_file; do
                    scan_content="$(<"$scan_file")"
                    if [[ "$scan_content" == *"$search_pattern"* ]]; then
                        fixture_passed=false
                        rel_file="${scan_file#"$REPO_ROOT"/}"
                        rel_file="${rel_file//\\//}"
                        add_finding 'COMPAT' "$rel_file" 0 \
                            "[$check_desc] Forbidden pattern found: $search_pattern"
                    fi
                done < <(find "$target_dir" -type f -print0)
            fi
            ;;

        *)
            fixture_passed=false
            add_finding 'COMPAT' "$(basename "$fixture_file")" 0 \
                "[$check_desc] Unknown fixture type: $check_type"
            ;;
    esac

    if [[ "$fixture_passed" == true ]]; then
        echo "[PASS] COMPAT: $check_desc"
        COMPAT_PASSED=$((COMPAT_PASSED + 1))
    else
        echo "[FAIL] COMPAT: $check_desc"
        COMPAT_FAILED=$((COMPAT_FAILED + 1))
    fi
done

if [[ ${#COMPAT_FIXTURES[@]} -eq 0 ]]; then
    echo '[SKIP] No compatibility fixture files found'
else
    echo "Compatibility fixtures: $COMPAT_PASSED passed, $COMPAT_FAILED failed out of ${#COMPAT_FIXTURES[@]}"
    CHECKS_PASSED=$((CHECKS_PASSED + COMPAT_PASSED))
    CHECKS_FAILED=$((CHECKS_FAILED + COMPAT_FAILED))
fi

# ── WORKFLOW FIXTURE TESTS ─────────────────────────────────────────────────

echo ''
echo '=== WORKFLOW-FIXTURES: Golden-path workflow tests ==='

test_workflow_fixtures() {
    local fixtures_dir="$REPO_ROOT/tests/workflows"
    declare -a fixtures=()
    if [[ -d "$fixtures_dir" ]]; then
        while IFS= read -r -d '' f; do
            fixtures+=("$f")
        done < <(find "$fixtures_dir" -maxdepth 1 -name 'golden-*.json' -type f -print0)
    fi

    WF_PASSED=0
    WF_FAILED=0

    if [[ ${#fixtures[@]} -eq 0 ]]; then
        echo "FAIL [WORKFLOW-FIXTURES] No golden-*.json fixtures found in tests/workflows/"
        add_finding 'WORKFLOW-FIXTURES' "$fixtures_dir" 0 \
            'No golden-*.json fixtures found in tests/workflows/'
        WF_FAILED=1
        return
    fi

    local expected_fixtures=(
        'golden-feature.json'
        'golden-monitor-request.json'
        'golden-pr-open.json'
        'golden-review-remediation.json'
        'golden-trivial-edit.json'
    )

    for expected in "${expected_fixtures[@]}"; do
        local expected_path="$fixtures_dir/$expected"
        if [[ ! -f "$expected_path" ]]; then
            echo "FAIL [WORKFLOW-FIXTURES] Missing required fixture: $expected"
            add_finding 'WORKFLOW-FIXTURES' "$fixtures_dir/$expected" 0 \
                "Missing required fixture: $expected"
            WF_FAILED=$((WF_FAILED + 1))
        fi
    done

    for f in "${fixtures[@]}"; do
        local f_name
        f_name="$(basename "$f")"
        local data
        data="$(<"$f")" || true
        if ! echo "$data" | jq empty 2>/dev/null; then
            echo "FAIL [WORKFLOW-FIXTURES] $f_name: JSON parse error"
            add_finding 'WORKFLOW-FIXTURES' "$f" 0 \
                "Fixture JSON parse error: $f_name"
            WF_FAILED=$((WF_FAILED + 1))
            continue
        fi

        local step_count
        step_count="$(echo "$data" | jq '.steps // [] | length')"
        if [[ "$step_count" -eq 0 ]]; then
            echo "FAIL [WORKFLOW-FIXTURES] $f_name: fixture has no steps"
            add_finding 'WORKFLOW-FIXTURES' "$f" 0 \
                "Fixture has no steps: $f_name"
            WF_FAILED=$((WF_FAILED + 1))
            continue
        fi

        local file_passed=true
        local si=0
        while [[ $si -lt $step_count ]]; do
            local step_state
            step_state="$(echo "$data" | jq -r ".steps[$si].state")"
            local src_file_rel
            src_file_rel="$(echo "$data" | jq -r ".steps[$si].source.file")"
            local src_pattern
            src_pattern="$(echo "$data" | jq -r ".steps[$si].source.pattern")"
            local src_path
            src_path="$(resolve_repo_path "$src_file_rel")"

            if [[ ! -f "$src_path" ]]; then
                echo "FAIL [WORKFLOW-FIXTURES] $f_name state=$step_state: source file not found: $src_file_rel"
                add_finding 'WORKFLOW-FIXTURES' "$src_file_rel" 0 \
                    "Workflow fixture source file not found: $src_file_rel"
                file_passed=false
                si=$((si + 1))
                continue
            fi

            local content
            content="$(<"$src_path")"
            if [[ "$content" == *"$src_pattern"* ]]; then
                echo "PASS [WORKFLOW-FIXTURES] $f_name state=$step_state"
            else
                echo "FAIL [WORKFLOW-FIXTURES] $f_name state=$step_state: pattern not found: $src_pattern"
                add_finding 'WORKFLOW-FIXTURES' "$src_file_rel" 0 \
                    "Workflow fixture pattern not found in $src_file_rel: $src_pattern"
                file_passed=false
            fi
            si=$((si + 1))
        done

        if [[ "$file_passed" == true ]]; then
            WF_PASSED=$((WF_PASSED + 1))
        else
            WF_FAILED=$((WF_FAILED + 1))
        fi
    done
}

WF_PASSED=0
WF_FAILED=0
test_workflow_fixtures
CHECKS_PASSED=$((CHECKS_PASSED + WF_PASSED))
CHECKS_FAILED=$((CHECKS_FAILED + WF_FAILED))

# ── Summary ─────────────────────────────────────────────────────────────────

echo ''
echo '=== Summary ==='

TOTAL_FINDINGS=${#FINDING_RULES[@]}
ALLOWLISTED_COUNT=0
for allowed in "${FINDING_ALLOWED[@]}"; do
    if [[ "$allowed" == "true" ]]; then
        ALLOWLISTED_COUNT=$((ALLOWLISTED_COUNT + 1))
    fi
done
NON_ALLOWLISTED_COUNT=$((TOTAL_FINDINGS - ALLOWLISTED_COUNT))

echo "Checks passed: $CHECKS_PASSED / $((CHECKS_PASSED + CHECKS_FAILED))"
echo "Total findings: $TOTAL_FINDINGS"
echo "Allowlisted:    $ALLOWLISTED_COUNT"
echo "New findings:   $NON_ALLOWLISTED_COUNT"

if [[ "$STRICT" == true && "$NON_ALLOWLISTED_COUNT" -gt 0 ]]; then
    echo ''
    echo "STRICT MODE: $NON_ALLOWLISTED_COUNT finding(s) not in allowlist. Exiting with error."
    exit 1
fi

exit 0
