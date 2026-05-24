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
done < <(find "$PLUGIN_ROOT/skills" -name 'SKILL.md' -type f -print0 2>/dev/null | grep -zv '/_shared/')
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
        [[ "$ref_name" == "_shared" ]] && continue

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
    # INVARIANT: _shared is not a skill directory.
    if echo "$skill_file" | grep -q '/_shared/'; then
        continue
    fi
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
            # INVARIANT: skills/_shared/ refs are an allowed bare exception per CLAUDE.md.
            if [[ "$bare_ref" == skills/_shared/* ]]; then
                continue
            fi
            check8_found=true
            add_finding 'CHECK8' "$md_file" "$line_num" \
                "Bare path ref (missing \${CLAUDE_PLUGIN_ROOT}/ prefix): $bare_ref"
        done < <(echo "$stripped" | grep -oP '(^|[^A-Za-z0-9_./-])\K(agents|skills|governance)/[A-Za-z0-9_-]+\.(md|sh|json)' || true)
    done < "$md_file"
done < <(find "$PLUGIN_ROOT" -name '*.md' -type f -print0)

if [[ "$check8_found" == false ]]; then
    echo '[PASS] Check 8: No bare governance/agents/skills path refs'
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
