<#
.SYNOPSIS
    Policy linter for the agent-framework plugin.

.DESCRIPTION
    Runs structural and content checks against plugin/ files, plus safety
    regression fixtures (tests/policy/) and compatibility fixtures (tests/plugin/).
    Advisory mode (default): reports findings, exits 0 unless the harness itself fails.
    Strict mode (-Strict): exits non-zero when findings exist that are not in the allowlist.

.PARAMETER Strict
    When set, exit non-zero for findings not covered by the allowlist.

.EXAMPLE
    ./tools/policy_check.ps1
    ./tools/policy_check.ps1 -Strict
#>
param(
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is tools/ — one level up is repo root.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $repoRoot) {
    $repoRoot = (Get-Location).Path
}
$pluginRoot = Join-Path $repoRoot 'plugin'
$allowlistPath = Join-Path (Join-Path (Join-Path $repoRoot 'tests') 'policy') 'policy-lint-allowlist.json'

function Resolve-RepoPath {
    param([string]$SlashPath)
    $segments = $SlashPath -split '/'
    $result = $repoRoot
    foreach ($seg in $segments) {
        $result = Join-Path $result $seg
    }
    return $result
}

# ── Helpers ──────────────────────────────────────────────────────────────────

function Load-Allowlist {
    if (Test-Path $allowlistPath) {
        $raw = Get-Content -Path $allowlistPath -Raw -Encoding UTF8
        return ($raw | ConvertFrom-Json)
    }
    return @()
}

function Test-Allowlisted {
    param(
        [string]$Rule,
        [string]$Path,
        [int]$Line
    )
    foreach ($entry in $script:allowlist) {
        if ($entry.rule -ne $Rule) { continue }
        $entryPath = $entry.path -replace '/', '\'
        $normalizedPath = $Path -replace '/', '\'
        if ($entryPath -ne $normalizedPath) { continue }
        $hasLine = $entry.PSObject.Properties.Name -contains 'line'
        if ($hasLine -and $entry.line -ne 0 -and $entry.line -ne $Line) { continue }
        return $true
    }
    return $false
}

function Add-Finding {
    param(
        [string]$Rule,
        [string]$FilePath,
        [int]$Line,
        [string]$Description
    )
    $relPath = $FilePath
    if ($FilePath.StartsWith($repoRoot)) {
        $relPath = $FilePath.Substring($repoRoot.Length).TrimStart('\', '/')
    }
    $relPath = $relPath -replace '\\', '/'

    $isAllowlisted = Test-Allowlisted -Rule $Rule -Path $relPath -Line $Line
    $finding = [PSCustomObject]@{
        Rule        = $Rule
        Path        = $relPath
        Line        = $Line
        Description = $Description
        Allowlisted = $isAllowlisted
    }
    $script:findings.Add($finding)

    $lineLabel = if ($Line -gt 0) { ":$Line" } else { '' }
    $prefix = if ($isAllowlisted) { '[ALLOW]' } else { '[FIND]' }
    Write-Host "$prefix [$Rule] ${relPath}${lineLabel} -- $Description"
}

# ── State ────────────────────────────────────────────────────────────────────

$script:allowlist = Load-Allowlist
$script:findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$checksPassed = 0
$checksFailed = 0

# ── CHECK 1: Forbidden hedge ────────────────────────────────────────────────

Write-Host ''
Write-Host '=== CHECK 1: Forbidden hedge ==='

$mdFiles = Get-ChildItem -Path $pluginRoot -Filter '*.md' -Recurse -File
$check1Found = $false

foreach ($mdFile in $mdFiles) {
    $lineNum = 0
    $lines = Get-Content -Path $mdFile.FullName -Encoding UTF8
    foreach ($textLine in $lines) {
        $lineNum++

        # INVARIANT: The rule definition itself in agent-system-policy.md is not a violation.
        if ($textLine -match 'Do not use the word.*ambiguous.*as a hedge') { continue }

        if (-not ($textLine -match '\bambiguous\b')) { continue }

        $isHedge = $false

        # Pattern: "unsafe or ambiguous" — gate-level uncertainty
        if ($textLine -match '\bunsafe\s+or\s+ambiguous\b') { $isHedge = $true }

        # Pattern: "is ambiguous" — gate on state being ambiguous
        if ($textLine -match '\bis\s+ambiguous\b') { $isHedge = $true }

        # Pattern: "or ambiguous" preceded by a stop/gate word (not in classification/routing)
        # But skip "non-human or ambiguous" (descriptive) and "human/ambiguous" (classification)
        if ($textLine -match '\bor\s+ambiguous\b' -and $textLine -notmatch 'non-human\s+or\s+ambiguous' -and $textLine -notmatch '/ambiguous') {
            if ($textLine -match '\b(continue|proceed|stop|when|if)\b.*\bor\s+ambiguous\b') { $isHedge = $true }
            if ($textLine -match '\bor\s+ambiguous\b.*\b(continue|proceed|stop|when|if)\b') { $isHedge = $true }
        }

        # Pattern: "proceed if ... ambiguous" or "continue ... ambiguous" as gate
        if ($textLine -match '\b(proceed|continue|stop)\b.*\bambiguous\b') {
            if ($textLine -notmatch '/ambiguous' -and $textLine -notmatch 'non-human') {
                $isHedge = $true
            }
        }

        if (-not $isHedge) { continue }

        $check1Found = $true
        Add-Finding -Rule 'CHECK1' -FilePath $mdFile.FullName -Line $lineNum `
            -Description "Forbidden hedge: 'ambiguous' used as gate-level uncertainty"
    }
}

if (-not $check1Found) {
    Write-Host '[PASS] Check 1: No forbidden hedge violations found'
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 2: Required files exist ───────────────────────────────────────────

Write-Host ''
Write-Host '=== CHECK 2: Required files exist ==='

$requiredFiles = @(
    'plugin/governance/agent-system-policy.md',
    'plugin/governance/branching-pr-workflow.md',
    'plugin/governance/versioning.md',
    'plugin/governance/pr-review-remediation-loop.md',
    'plugin/governance/AGENTS.template.md',
    'plugin/agents/orchestrator.md',
    'plugin/agents/planner.md',
    'plugin/agents/coder.md',
    'plugin/agents/designer.md'
)

$check2Found = $false
foreach ($relFile in $requiredFiles) {
    $absPath = Resolve-RepoPath $relFile
    if (-not (Test-Path $absPath)) {
        $check2Found = $true
        Add-Finding -Rule 'CHECK2' -FilePath $relFile -Line 0 `
            -Description "Required file missing: $relFile"
    }
}

if (-not $check2Found) {
    Write-Host '[PASS] Check 2: All required files exist'
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 3: Skill names exist ──────────────────────────────────────────────

Write-Host ''
Write-Host '=== CHECK 3: Skill names exist ==='

$skillPattern = [regex]'agent-framework:([a-zA-Z0-9_-]+)'
$agentNames = @('orchestrator', 'planner', 'coder', 'designer')

# Collect scan sources: all plugin/agents/*.md, plugin/skills/**/SKILL.md (excluding _shared/), and plugin/governance/*.md.
$scanFiles = @()
$agentsDir = Join-Path $pluginRoot 'agents'
$skillsDir = Join-Path $pluginRoot 'skills'
$governanceDir = Join-Path $pluginRoot 'governance'
$scanFiles += Get-ChildItem -Path $agentsDir -Filter '*.md' -File
$scanFiles += Get-ChildItem -Path $skillsDir -Filter 'SKILL.md' -Recurse -File |
    Where-Object { $_.FullName -notmatch '[/\\]_shared[/\\]' }
$scanFiles += Get-ChildItem -Path $governanceDir -Filter '*.md' -File

# Extract all agent-framework:* references with their source file.
# Keys: ref name. Values: list of source file paths that contain the reference.
$skillRefSources = @{}
$agentRefSources = @{}

foreach ($scanFile in $scanFiles) {
    $scanContent = Get-Content -Path $scanFile.FullName -Raw -Encoding UTF8
    $scanMatches = $skillPattern.Matches($scanContent)
    foreach ($matchItem in $scanMatches) {
        $refName = $matchItem.Groups[1].Value
        if ($refName -eq '_shared') { continue }
        if ($agentNames -contains $refName) {
            if ($refName -eq 'orchestrator') { continue }
            if (-not $agentRefSources.ContainsKey($refName)) {
                $agentRefSources[$refName] = [System.Collections.Generic.List[string]]::new()
            }
            if (-not $agentRefSources[$refName].Contains($scanFile.FullName)) {
                $agentRefSources[$refName].Add($scanFile.FullName)
            }
        } else {
            if (-not $skillRefSources.ContainsKey($refName)) {
                $skillRefSources[$refName] = [System.Collections.Generic.List[string]]::new()
            }
            if (-not $skillRefSources[$refName].Contains($scanFile.FullName)) {
                $skillRefSources[$refName].Add($scanFile.FullName)
            }
        }
    }
}

$check3Found = $false
foreach ($skillName in $skillRefSources.Keys) {
    $skillMdPath = Join-Path (Join-Path (Join-Path $pluginRoot 'skills') $skillName) 'SKILL.md'
    if (-not (Test-Path $skillMdPath)) {
        $check3Found = $true
        foreach ($sourceFile in $skillRefSources[$skillName]) {
            Add-Finding -Rule 'CHECK3' -FilePath $sourceFile -Line 0 `
                -Description "Skill referenced but SKILL.md missing: plugin/skills/$skillName/SKILL.md"
        }
    }
}

if (-not $check3Found) {
    Write-Host "[PASS] Check 3: All $($skillRefSources.Count) skill references resolve to SKILL.md files"
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 4: Agent names exist ──────────────────────────────────────────────

Write-Host ''
Write-Host '=== CHECK 4: Agent names exist ==='

$check4Found = $false
foreach ($agentRefName in $agentRefSources.Keys) {
    $agentMdPath = Join-Path (Join-Path $pluginRoot 'agents') "$agentRefName.md"
    if (-not (Test-Path $agentMdPath)) {
        $check4Found = $true
        foreach ($sourceFile in $agentRefSources[$agentRefName]) {
            Add-Finding -Rule 'CHECK4' -FilePath $sourceFile -Line 0 `
                -Description "Agent referenced but file missing: plugin/agents/$agentRefName.md"
        }
    }
}

if (-not $check4Found) {
    Write-Host "[PASS] Check 4: All $($agentRefSources.Count) agent references resolve to .md files"
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 5: Unsupported frontmatter fields ─────────────────────────────────

Write-Host ''
Write-Host '=== CHECK 5: Unsupported frontmatter fields ==='

$agentDir = Join-Path $pluginRoot 'agents'
$agentFiles = Get-ChildItem -Path $agentDir -Filter '*.md' -File

$check5Found = $false
foreach ($agentFile in $agentFiles) {
    $content = Get-Content -Path $agentFile.FullName -Encoding UTF8
    $inFrontmatter = $false
    $frontmatterStarted = $false
    $lineNum = 0

    foreach ($textLine in $content) {
        $lineNum++
        if ($textLine.Trim() -eq '---') {
            if (-not $frontmatterStarted) {
                $frontmatterStarted = $true
                $inFrontmatter = $true
                continue
            } else {
                break
            }
        }
        if (-not $inFrontmatter) { continue }

        if ($textLine -match '^\s*mcpServers\s*:') {
            $check5Found = $true
            Add-Finding -Rule 'CHECK5' -FilePath $agentFile.FullName -Line $lineNum `
                -Description 'Unsupported frontmatter field: mcpServers'
        }
        if ($textLine -match '^\s*permissionMode\s*:') {
            $check5Found = $true
            Add-Finding -Rule 'CHECK5' -FilePath $agentFile.FullName -Line $lineNum `
                -Description 'Unsupported frontmatter field: permissionMode'
        }
    }
}

if (-not $check5Found) {
    Write-Host '[PASS] Check 5: No unsupported frontmatter fields found'
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 6: Governance reference paths resolve ─────────────────────────────

Write-Host ''
Write-Host '=== CHECK 6: Governance reference paths resolve ==='

$pathPattern = [regex]'\$\{CLAUDE_PLUGIN_ROOT\}/([^\s`\)]+)'
$check6Found = $false

foreach ($mdFile in $mdFiles) {
    $content = Get-Content -Path $mdFile.FullName -Encoding UTF8
    $lineNum = 0
    foreach ($textLine in $content) {
        $lineNum++
        $lineMatches = $pathPattern.Matches($textLine)
        foreach ($matchItem in $lineMatches) {
            $refRelPath = $matchItem.Groups[1].Value
            # Strip trailing punctuation that is not part of file paths.
            $refRelPath = $refRelPath.TrimEnd('.', ',', ';', ':', ')')
            $resolvedPath = Join-Path $pluginRoot ($refRelPath -replace '/', '\')
            $normalizedResolved = [System.IO.Path]::GetFullPath($resolvedPath)
            $normalizedPluginRoot = [System.IO.Path]::GetFullPath($pluginRoot)

            $pluginRootWithSep = $normalizedPluginRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
            if (-not ($normalizedResolved.StartsWith($pluginRootWithSep, [System.StringComparison]::OrdinalIgnoreCase) -or
                      $normalizedResolved -eq $normalizedPluginRoot)) {
                $check6Found = $true
                Add-Finding -Rule 'CHECK6' -FilePath $mdFile.FullName -Line $lineNum `
                    -Description "Path escapes plugin root: `${CLAUDE_PLUGIN_ROOT}/$refRelPath"
            } else {
                $pathExists = (Test-Path $resolvedPath -PathType Leaf) -or (Test-Path $resolvedPath -PathType Container)
                if (-not $pathExists) {
                    $check6Found = $true
                    Add-Finding -Rule 'CHECK6' -FilePath $mdFile.FullName -Line $lineNum `
                        -Description "Path does not resolve: `${CLAUDE_PLUGIN_ROOT}/$refRelPath"
                }
            }
        }
    }
}

if (-not $check6Found) {
    Write-Host '[PASS] Check 6: All governance reference paths resolve'
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 7: Skill frontmatter completeness ─────────────────────────────────

Write-Host ''
Write-Host '=== CHECK 7: Skill frontmatter completeness ==='

$skillsDir = Join-Path $pluginRoot 'skills'
$skillMdFiles = Get-ChildItem -Path $skillsDir -Filter 'SKILL.md' -Recurse -File

$requiredFrontmatterFields = @('name', 'description', 'allowed-tools', 'shell')
$check7Found = $false

foreach ($skillFile in $skillMdFiles) {
    # INVARIANT: _shared is not a skill directory.
    if ($skillFile.FullName -match '[/\\]_shared[/\\]') { continue }

    $content = Get-Content -Path $skillFile.FullName -Encoding UTF8
    $inFrontmatter = $false
    $frontmatterStarted = $false
    $foundFields = @{}

    foreach ($textLine in $content) {
        if ($textLine.Trim() -eq '---') {
            if (-not $frontmatterStarted) {
                $frontmatterStarted = $true
                $inFrontmatter = $true
                continue
            } else {
                break
            }
        }
        if (-not $inFrontmatter) { continue }

        foreach ($fieldName in $requiredFrontmatterFields) {
            if ($textLine -match "^\s*${fieldName}\s*:") {
                $foundFields[$fieldName] = $true
            }
        }
    }

    foreach ($fieldName in $requiredFrontmatterFields) {
        if (-not $foundFields.ContainsKey($fieldName)) {
            $check7Found = $true
            Add-Finding -Rule 'CHECK7' -FilePath $skillFile.FullName -Line 0 `
                -Description "Missing required frontmatter field: $fieldName"
        }
    }
}

if (-not $check7Found) {
    $skillCount = ($skillMdFiles | Where-Object { $_.FullName -notmatch '[/\\]_shared[/\\]' }).Count
    Write-Host "[PASS] Check 7: All $skillCount skill files have complete frontmatter"
    $checksPassed++
} else {
    $checksFailed++
}

# ── CHECK 8: AGENTS.template.md referenced in README ────────────────────────

Write-Host ''
Write-Host '=== CHECK 8: AGENTS.template.md referenced in README ==='

$readmePath = Join-Path $repoRoot 'README.md'
$check8Found = $false

if (Test-Path $readmePath) {
    $readmeContent = Get-Content -Path $readmePath -Raw -Encoding UTF8
    if ($readmeContent -match 'AGENTS\.template\.md') {
        Write-Host '[PASS] Check 8: README.md references AGENTS.template.md'
        $checksPassed++
    } else {
        $check8Found = $true
        Add-Finding -Rule 'CHECK8' -FilePath 'README.md' -Line 0 `
            -Description 'README.md does not reference AGENTS.template.md'
        $checksFailed++
    }
} else {
    $check8Found = $true
    Add-Finding -Rule 'CHECK8' -FilePath 'README.md' -Line 0 `
        -Description 'README.md does not exist'
    $checksFailed++
}

# ── SAFETY REGRESSION TESTS ─────────────────────────────────────────────────

Write-Host ''
Write-Host '=== SAFETY: Regression fixture tests ==='

$safetyDir = Join-Path (Join-Path $repoRoot 'tests') 'policy'
$safetyFixtures = @()
if (Test-Path $safetyDir) {
    $safetyFixtures = Get-ChildItem -Path $safetyDir -Filter 'safety-*.json' -File
}

$safetyPassed = 0
$safetyFailed = 0

function Get-Frontmatter {
    param([string]$FilePath)
    $lines = Get-Content -Path $FilePath -Encoding UTF8
    $inFrontmatter = $false
    $frontmatterStarted = $false
    $frontmatterLines = @()
    foreach ($textLine in $lines) {
        if ($textLine.Trim() -eq '---') {
            if (-not $frontmatterStarted) {
                $frontmatterStarted = $true
                $inFrontmatter = $true
                continue
            } else {
                break
            }
        }
        if ($inFrontmatter) {
            $frontmatterLines += $textLine
        }
    }
    return ($frontmatterLines -join "`n")
}

function Test-SetCheck {
    param(
        [Parameter(Mandatory)] [string]$RuleName,
        [Parameter(Mandatory)] $SetCheck
    )
    # Returns $true on pass, $false on fail. Adds findings on fail.
    $passed = $true

    $regexText = [string]$SetCheck.extract_regex
    if ([string]::IsNullOrEmpty($regexText)) {
        Add-Finding -Rule 'SAFETY' -FilePath '<fixture>' -Line 0 `
            -Description "[$RuleName] set_check.extract_regex is required"
        return $false
    }
    try {
        $regex = [regex]::new($regexText)
    } catch {
        Add-Finding -Rule 'SAFETY' -FilePath '<fixture>' -Line 0 `
            -Description "[$RuleName] set_check.extract_regex did not compile: $($_.Exception.Message)"
        return $false
    }

    $expected = @()
    if ($SetCheck.PSObject.Properties.Name -contains 'expected_set') {
        $expected = @($SetCheck.expected_set)
    }
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$expected,
        [System.StringComparer]::Ordinal
    )

    foreach ($entry in $SetCheck.files) {
        $relPath = [string]$entry.path
        $mode = if ($entry.PSObject.Properties.Name -contains 'mode') { [string]$entry.mode } else { 'equal' }
        $absPath = Resolve-RepoPath $relPath
        if (-not (Test-Path $absPath)) {
            $passed = $false
            Add-Finding -Rule 'SAFETY' -FilePath $relPath -Line 0 `
                -Description "[$RuleName] set_check file missing: $relPath"
            continue
        }
        $content = Get-Content -Path $absPath -Raw -Encoding UTF8
        $matchCollection = $regex.Matches($content)
        $captured = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        $counts = @{}
        foreach ($m in $matchCollection) {
            if ($m.Groups.Count -lt 2) { continue }
            $val = $m.Groups[1].Value
            [void]$captured.Add($val)
            if (-not $counts.ContainsKey($val)) { $counts[$val] = 0 }
            $counts[$val] = $counts[$val] + 1
        }

        # Compute extras (captured \ expected) and missing (expected \ captured).
        $extras = @($captured | Where-Object { -not $expectedSet.Contains($_) })
        $missing = @($expected | Where-Object { -not $captured.Contains($_) })

        switch ($mode) {
            'equal' {
                if ($extras.Count -gt 0 -or $missing.Count -gt 0) {
                    $passed = $false
                    $detail = @()
                    if ($missing.Count -gt 0) { $detail += "missing: $($missing -join ', ')" }
                    if ($extras.Count -gt 0) { $detail += "extras: $($extras -join ', ')" }
                    Add-Finding -Rule 'SAFETY' -FilePath $relPath -Line 0 `
                        -Description "[$RuleName] set_check (equal) failed for ${relPath}: $($detail -join '; ')"
                }
            }
            'subset' {
                if ($extras.Count -gt 0) {
                    $passed = $false
                    Add-Finding -Rule 'SAFETY' -FilePath $relPath -Line 0 `
                        -Description "[$RuleName] set_check (subset) failed for ${relPath}: extras: $($extras -join ', ')"
                }
            }
            'superset' {
                if ($missing.Count -gt 0) {
                    $passed = $false
                    Add-Finding -Rule 'SAFETY' -FilePath $relPath -Line 0 `
                        -Description "[$RuleName] set_check (superset) failed for ${relPath}: missing: $($missing -join ', ')"
                }
            }
            default {
                $passed = $false
                Add-Finding -Rule 'SAFETY' -FilePath $relPath -Line 0 `
                    -Description "[$RuleName] set_check unknown mode '$mode' (expected equal|subset|superset)"
            }
        }

        # Optional per-element occurrence-count assertion. Catches intra-file
        # drift that distinct-set checks miss (e.g., one of two mirrored
        # tables drops an element while the other still contains it).
        if ($SetCheck.PSObject.Properties.Name -contains 'expected_counts') {
            $expectedCounts = $SetCheck.expected_counts
            foreach ($prop in $expectedCounts.PSObject.Properties) {
                $key = $prop.Name
                $want = [int]$prop.Value
                $got = if ($counts.ContainsKey($key)) { [int]$counts[$key] } else { 0 }
                if ($got -ne $want) {
                    $passed = $false
                    Add-Finding -Rule 'SAFETY' -FilePath $relPath -Line 0 `
                        -Description "[$RuleName] set_check expected_counts mismatch in ${relPath}: '$key' has $got occurrence(s), expected $want"
                }
            }
        }
    }

    return $passed
}

foreach ($fixtureFile in $safetyFixtures) {
    $fixtureRaw = Get-Content -Path $fixtureFile.FullName -Raw -Encoding UTF8
    $fixture = $fixtureRaw | ConvertFrom-Json
    $ruleName = $fixture.rule
    $fixturePassed = $true

    $hasLegacy = $fixture.PSObject.Properties.Name -contains 'source'
    $hasSetCheck = $fixture.PSObject.Properties.Name -contains 'set_check'

    if (-not $hasLegacy -and -not $hasSetCheck) {
        $fixturePassed = $false
        Add-Finding -Rule 'SAFETY' -FilePath $fixtureFile.Name -Line 0 `
            -Description "[$ruleName] fixture has neither source/consumers nor set_check"
    }

    # Set-check assertion (regex extraction + set comparison across files).
    if ($hasSetCheck) {
        $setOk = Test-SetCheck -RuleName $ruleName -SetCheck $fixture.set_check
        if (-not $setOk) { $fixturePassed = $false }
    }

    # Legacy source/consumers presence check (skipped when fixture omits source).
    if ($hasLegacy) {
    # Check source pattern exists in source file.
    $sourceAbsPath = Resolve-RepoPath $fixture.source.file
    if (-not (Test-Path $sourceAbsPath)) {
        $fixturePassed = $false
        Add-Finding -Rule 'SAFETY' -FilePath $fixture.source.file -Line 0 `
            -Description "[$ruleName] Source file missing: $($fixture.source.file)"
    } else {
        $sourceContent = Get-Content -Path $sourceAbsPath -Raw -Encoding UTF8
        if (-not $sourceContent.Contains($fixture.source.pattern)) {
            $fixturePassed = $false
            Add-Finding -Rule 'SAFETY' -FilePath $fixture.source.file -Line 0 `
                -Description "[$ruleName] Source pattern not found: $($fixture.source.pattern)"
        }
    }

    # Check each consumer.
    foreach ($consumer in $fixture.consumers) {
        $consumerAbsPath = Resolve-RepoPath $consumer.file
        if (-not (Test-Path $consumerAbsPath)) {
            $fixturePassed = $false
            Add-Finding -Rule 'SAFETY' -FilePath $consumer.file -Line 0 `
                -Description "[$ruleName] Consumer file missing: $($consumer.file)"
            continue
        }

        $isAbsent = $false
        if (($consumer.PSObject.Properties.Name -contains 'absent') -and $consumer.absent -eq $true) {
            $isAbsent = $true
        }

        if ($isAbsent) {
            # INVARIANT: absent checks scope to YAML frontmatter only.
            $frontmatterContent = Get-Frontmatter -FilePath $consumerAbsPath
            if ($frontmatterContent.Contains($consumer.pattern)) {
                $fixturePassed = $false
                Add-Finding -Rule 'SAFETY' -FilePath $consumer.file -Line 0 `
                    -Description "[$ruleName] Consumer frontmatter must NOT contain: $($consumer.pattern)"
            }
        } else {
            $consumerContent = Get-Content -Path $consumerAbsPath -Raw -Encoding UTF8
            if (-not $consumerContent.Contains($consumer.pattern)) {
                $fixturePassed = $false
                Add-Finding -Rule 'SAFETY' -FilePath $consumer.file -Line 0 `
                    -Description "[$ruleName] Consumer pattern not found: $($consumer.pattern)"
            }
        }
    }
    }  # end if ($hasLegacy)

    if ($fixturePassed) {
        Write-Host "[PASS] SAFETY: $ruleName"
        $safetyPassed++
    } else {
        Write-Host "[FAIL] SAFETY: $ruleName"
        $safetyFailed++
    }
}

if ($safetyFixtures.Count -eq 0) {
    Write-Host '[SKIP] No safety fixture files found'
} else {
    Write-Host "Safety fixtures: $safetyPassed passed, $safetyFailed failed out of $($safetyFixtures.Count)"
    $checksPassed += $safetyPassed
    $checksFailed += $safetyFailed
}

# ── COMPATIBILITY TESTS ─────────────────────────────────────────────────────

Write-Host ''
Write-Host '=== COMPAT: Plugin compatibility fixture tests ==='

$compatDir = Join-Path (Join-Path $repoRoot 'tests') 'plugin'
$compatFixtures = @()
if (Test-Path $compatDir) {
    $compatFixtures = Get-ChildItem -Path $compatDir -Filter '*.json' -File
}

$compatPassed = 0
$compatFailed = 0

foreach ($fixtureFile in $compatFixtures) {
    $fixtureRaw = Get-Content -Path $fixtureFile.FullName -Raw -Encoding UTF8
    $fixture = $fixtureRaw | ConvertFrom-Json
    $checkDesc = $fixture.check
    $checkType = $fixture.type
    $fixturePassed = $true

    switch ($checkType) {

        'json-fields' {
            $targetPath = Resolve-RepoPath $fixture.file
            if (-not (Test-Path $targetPath)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                    -Description "[$checkDesc] File missing: $($fixture.file)"
            } else {
                $jsonRaw = Get-Content -Path $targetPath -Raw -Encoding UTF8
                $jsonObj = $jsonRaw | ConvertFrom-Json
                foreach ($reqField in $fixture.required) {
                    if (-not ($jsonObj.PSObject.Properties.Name -contains $reqField)) {
                        $fixturePassed = $false
                        Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                            -Description "[$checkDesc] Missing required JSON field: $reqField"
                    }
                }
            }
        }

        'json-field-value' {
            $targetPath = Resolve-RepoPath $fixture.file
            if (-not (Test-Path $targetPath)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                    -Description "[$checkDesc] File missing: $($fixture.file)"
            } else {
                $jsonRaw = Get-Content -Path $targetPath -Raw -Encoding UTF8
                $jsonObj = $jsonRaw | ConvertFrom-Json

                # Check required arrays if specified.
                if ($fixture.PSObject.Properties.Name -contains 'required-arrays') {
                    foreach ($arrName in $fixture.'required-arrays') {
                        if (-not ($jsonObj.PSObject.Properties.Name -contains $arrName)) {
                            $fixturePassed = $false
                            Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                                -Description "[$checkDesc] Missing required array: $arrName"
                        } elseif ($jsonObj.$arrName -isnot [System.Array] -or $jsonObj.$arrName.Count -eq 0) {
                            $fixturePassed = $false
                            Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                                -Description "[$checkDesc] Field is not a non-empty array: $arrName"
                        }
                    }
                }

                # Check field value in first plugins entry (for marketplace) or top-level.
                $fieldName = $fixture.field
                $expectedValue = $fixture.expected
                $fieldFound = $false

                if ($jsonObj.PSObject.Properties.Name -contains 'plugins' -and $jsonObj.plugins.Count -gt 0) {
                    $fieldFound = $true
                    foreach ($pluginEntry in $jsonObj.plugins) {
                        if (-not ($pluginEntry.PSObject.Properties.Name -contains $fieldName)) {
                            $fixturePassed = $false
                            Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                                -Description "[$checkDesc] plugins[] entry missing required field '$fieldName'"
                        } elseif ($pluginEntry.$fieldName -ne $expectedValue) {
                            $fixturePassed = $false
                            Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                                -Description "[$checkDesc] plugins[].$fieldName = '$($pluginEntry.$fieldName)', expected '$expectedValue'"
                        }
                    }
                } elseif ($jsonObj.PSObject.Properties.Name -contains $fieldName) {
                    $fieldFound = $true
                    if ($jsonObj.$fieldName -ne $expectedValue) {
                        $fixturePassed = $false
                        Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                            -Description "[$checkDesc] $fieldName = '$($jsonObj.$fieldName)', expected '$expectedValue'"
                    }
                }

                if (-not $fieldFound) {
                    $fixturePassed = $false
                    Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                        -Description "[$checkDesc] Field '$fieldName' not found"
                }
            }
        }

        'frontmatter-all-files' {
            $targetDir = Resolve-RepoPath $fixture.dir
            if (-not (Test-Path $targetDir)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.dir -Line 0 `
                    -Description "[$checkDesc] Directory missing: $($fixture.dir)"
            } else {
                $globPattern = if ($fixture.PSObject.Properties.Name -contains 'glob') { $fixture.glob } else { '*.md' }
                $excludePattern = if ($fixture.PSObject.Properties.Name -contains 'exclude') { $fixture.exclude } else { $null }

                $targetFiles = @()
                if ($globPattern -match '/') {
                    # Glob with subdirectory (e.g. */SKILL.md) — recurse and filter.
                    $targetFiles = Get-ChildItem -Path $targetDir -Filter ($globPattern -split '/')[-1] -Recurse -File
                } else {
                    $targetFiles = Get-ChildItem -Path $targetDir -Filter $globPattern -File
                }

                if ($excludePattern) {
                    $targetFiles = $targetFiles | Where-Object { $_.FullName -notmatch "[/\\]$excludePattern[/\\]" }
                }

                if ($targetFiles.Count -eq 0) {
                    $fixturePassed = $false
                    Add-Finding -Rule 'COMPAT' -FilePath $fixture.dir -Line 0 `
                        -Description "[$checkDesc] No files matched glob '$globPattern' in $($fixture.dir)"
                }

                foreach ($targetFile in $targetFiles) {
                    $fmContent = Get-Frontmatter -FilePath $targetFile.FullName
                    foreach ($reqField in $fixture.required) {
                        if ($fmContent -notmatch "(?m)^\s*${reqField}\s*:") {
                            $fixturePassed = $false
                            $relFile = $targetFile.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                            Add-Finding -Rule 'COMPAT' -FilePath $relFile -Line 0 `
                                -Description "[$checkDesc] Missing frontmatter field: $reqField"
                        }
                    }
                }
            }
        }

        'frontmatter-field-absent' {
            $targetDir = Resolve-RepoPath $fixture.dir
            if (-not (Test-Path $targetDir)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.dir -Line 0 `
                    -Description "[$checkDesc] Directory missing: $($fixture.dir)"
            } else {
                $targetFiles = Get-ChildItem -Path $targetDir -Filter '*.md' -File
                foreach ($targetFile in $targetFiles) {
                    $fmContent = Get-Frontmatter -FilePath $targetFile.FullName
                    foreach ($absentField in $fixture.absent) {
                        if ($fmContent -match "(?m)^\s*${absentField}\s*:") {
                            $fixturePassed = $false
                            $relFile = $targetFile.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                            Add-Finding -Rule 'COMPAT' -FilePath $relFile -Line 0 `
                                -Description "[$checkDesc] Forbidden frontmatter field present: $absentField"
                        }
                    }
                }
            }
        }

        'dir-names-in-file' {
            $targetDir = Resolve-RepoPath $fixture.dir
            $refFilePath = Resolve-RepoPath $fixture.file
            $excludePattern = if ($fixture.PSObject.Properties.Name -contains 'exclude') { $fixture.exclude } else { $null }

            if (-not (Test-Path $targetDir)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.dir -Line 0 `
                    -Description "[$checkDesc] Directory missing: $($fixture.dir)"
            } elseif (-not (Test-Path $refFilePath)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                    -Description "[$checkDesc] Reference file missing: $($fixture.file)"
            } else {
                $refContent = Get-Content -Path $refFilePath -Raw -Encoding UTF8
                $subdirs = Get-ChildItem -Path $targetDir -Directory
                if ($excludePattern) {
                    $subdirs = $subdirs | Where-Object { $_.Name -ne $excludePattern }
                }
                foreach ($subdir in $subdirs) {
                    if ($refContent -notmatch [regex]::Escape($subdir.Name)) {
                        $fixturePassed = $false
                        Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                            -Description "[$checkDesc] Directory name not found in $($fixture.file): $($subdir.Name)"
                    }
                }
            }
        }

        'file-names-in-file' {
            $targetDir = Resolve-RepoPath $fixture.dir
            $refFilePath = Resolve-RepoPath $fixture.file

            if (-not (Test-Path $targetDir)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.dir -Line 0 `
                    -Description "[$checkDesc] Directory missing: $($fixture.dir)"
            } elseif (-not (Test-Path $refFilePath)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                    -Description "[$checkDesc] Reference file missing: $($fixture.file)"
            } else {
                $refContent = Get-Content -Path $refFilePath -Raw -Encoding UTF8
                $filesInDir = Get-ChildItem -Path $targetDir -Filter '*.md' -File
                foreach ($fileInDir in $filesInDir) {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileInDir.Name)
                    if ($refContent -notmatch [regex]::Escape($baseName)) {
                        $fixturePassed = $false
                        Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                            -Description "[$checkDesc] Filename not found in $($fixture.file): $baseName"
                    }
                }
            }
        }

        'file-exists-and-referenced' {
            $targetPath = Resolve-RepoPath $fixture.file
            $refFilePath = Resolve-RepoPath $fixture.'referenced-in'

            if (-not (Test-Path $targetPath)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.file -Line 0 `
                    -Description "[$checkDesc] File missing: $($fixture.file)"
            }

            if (-not (Test-Path $refFilePath)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.'referenced-in' -Line 0 `
                    -Description "[$checkDesc] Reference file missing: $($fixture.'referenced-in')"
            } elseif (Test-Path $targetPath) {
                $refContent = Get-Content -Path $refFilePath -Raw -Encoding UTF8
                $fileBaseName = [System.IO.Path]::GetFileName($fixture.file)
                if ($refContent -notmatch [regex]::Escape($fileBaseName)) {
                    $fixturePassed = $false
                    Add-Finding -Rule 'COMPAT' -FilePath $fixture.'referenced-in' -Line 0 `
                        -Description "[$checkDesc] $($fixture.'referenced-in') does not reference $fileBaseName"
                }
            }
        }

        'pattern-absent-in-dir' {
            $targetDir = Resolve-RepoPath $fixture.dir
            $searchPattern = $fixture.pattern

            if (-not (Test-Path $targetDir)) {
                $fixturePassed = $false
                Add-Finding -Rule 'COMPAT' -FilePath $fixture.dir -Line 0 `
                    -Description "[$checkDesc] Directory missing: $($fixture.dir)"
            } else {
                $allFiles = Get-ChildItem -Path $targetDir -File -Recurse
                foreach ($scanFile in $allFiles) {
                    $scanContent = Get-Content -Path $scanFile.FullName -Raw -Encoding UTF8
                    if ($scanContent -match [regex]::Escape($searchPattern)) {
                        $fixturePassed = $false
                        $relFile = $scanFile.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                        Add-Finding -Rule 'COMPAT' -FilePath $relFile -Line 0 `
                            -Description "[$checkDesc] Forbidden pattern found: $searchPattern"
                    }
                }
            }
        }

        default {
            $fixturePassed = $false
            Add-Finding -Rule 'COMPAT' -FilePath $fixtureFile.Name -Line 0 `
                -Description "[$checkDesc] Unknown fixture type: $checkType"
        }
    }

    if ($fixturePassed) {
        Write-Host "[PASS] COMPAT: $checkDesc"
        $compatPassed++
    } else {
        Write-Host "[FAIL] COMPAT: $checkDesc"
        $compatFailed++
    }
}

if ($compatFixtures.Count -eq 0) {
    Write-Host '[SKIP] No compatibility fixture files found'
} else {
    Write-Host "Compatibility fixtures: $compatPassed passed, $compatFailed failed out of $($compatFixtures.Count)"
    $checksPassed += $compatPassed
    $checksFailed += $compatFailed
}

# ── WORKFLOW FIXTURE TESTS ──────────────────────────────────────────────────

Write-Host ''
Write-Host '=== WORKFLOW-FIXTURES: Golden-path workflow tests ==='

function Test-WorkflowFixtures {
    $fixturesDir = Join-Path (Join-Path $repoRoot 'tests') 'workflows'
    $fixtures = @()
    if (Test-Path $fixturesDir) {
        $fixtures = Get-ChildItem -Path $fixturesDir -Filter 'golden-*.json' -File
    }
    if ($fixtures.Count -eq 0) {
        Write-Host "FAIL [WORKFLOW-FIXTURES] No golden-*.json fixtures found in tests/workflows/"
        Add-Finding -Rule 'WORKFLOW-FIXTURES' -FilePath $fixturesDir -Line 0 `
            -Description 'No golden-*.json fixtures found in tests/workflows/'
        return @{ Passed = 0; Failed = 1 }
    }
    $wfPassed = 0
    $wfFailed = 0
    $expectedFixtures = @(
        'golden-feature.json',
        'golden-monitor-request.json',
        'golden-pr-open.json',
        'golden-review-remediation.json',
        'golden-trivial-edit.json'
    )
    foreach ($expected in $expectedFixtures) {
        $expectedPath = Join-Path $fixturesDir $expected
        if (-not (Test-Path $expectedPath)) {
            Write-Host "FAIL [WORKFLOW-FIXTURES] Missing required fixture: $expected"
            Add-Finding -Rule 'WORKFLOW-FIXTURES' -FilePath (Join-Path $fixturesDir $expected) -Line 0 `
                -Description "Missing required fixture: $expected"
            $wfFailed++
        }
    }
    foreach ($f in $fixtures) {
        try { $data = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            Write-Host "FAIL [WORKFLOW-FIXTURES] $($f.Name): JSON parse error"
            Add-Finding -Rule 'WORKFLOW-FIXTURES' -FilePath $f.FullName -Line 0 `
                -Description "Fixture JSON parse error: $($f.Name)"
            $wfFailed++
            continue
        }
        $filePassed = $true
        if (-not $data.steps -or @($data.steps).Count -eq 0) {
            Write-Host "FAIL [WORKFLOW-FIXTURES] $($f.Name): fixture has no steps"
            Add-Finding -Rule 'WORKFLOW-FIXTURES' -FilePath $f.FullName -Line 0 `
                -Description "Fixture has no steps: $($f.Name)"
            $wfFailed++
            continue
        }
        foreach ($step in $data.steps) {
            $srcPath = Resolve-RepoPath $step.source.file
            if (-not (Test-Path $srcPath)) {
                Write-Host "FAIL [WORKFLOW-FIXTURES] $($f.Name) state=$($step.state): source file not found: $($step.source.file)"
                Add-Finding -Rule 'WORKFLOW-FIXTURES' -FilePath $step.source.file -Line 0 `
                    -Description "Workflow fixture source file not found: $($step.source.file)"
                $filePassed = $false
                continue
            }
            $content = Get-Content $srcPath -Raw -Encoding UTF8
            if ($content.Contains($step.source.pattern)) {
                Write-Host "PASS [WORKFLOW-FIXTURES] $($f.Name) state=$($step.state)"
            } else {
                Write-Host "FAIL [WORKFLOW-FIXTURES] $($f.Name) state=$($step.state): pattern not found: $($step.source.pattern)"
                Add-Finding -Rule 'WORKFLOW-FIXTURES' -FilePath $step.source.file -Line 0 `
                    -Description "Workflow fixture pattern not found in $($step.source.file): $($step.source.pattern)"
                $filePassed = $false
            }
        }
        if ($filePassed) { $wfPassed++ } else { $wfFailed++ }
    }
    return @{ Passed = $wfPassed; Failed = $wfFailed }
}

$wfResult = Test-WorkflowFixtures
$checksPassed += $wfResult.Passed
$checksFailed += $wfResult.Failed

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '=== Summary ==='

$totalFindings = $script:findings.Count
$allowlistedCount = @($script:findings | Where-Object { $_.Allowlisted }).Count
$nonAllowlistedCount = $totalFindings - $allowlistedCount

Write-Host "Checks passed: $checksPassed / $($checksPassed + $checksFailed)"
Write-Host "Total findings: $totalFindings"
Write-Host "Allowlisted:    $allowlistedCount"
Write-Host "New findings:   $nonAllowlistedCount"

if ($Strict -and $nonAllowlistedCount -gt 0) {
    Write-Host ''
    Write-Host "STRICT MODE: $nonAllowlistedCount finding(s) not in allowlist. Exiting with error."
    exit 1
}

exit 0
