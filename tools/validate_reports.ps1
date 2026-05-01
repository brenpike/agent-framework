<#
.SYNOPSIS
    Validates agent report text against the Shared Worker Report Contract and
    Blocked Report Contract from agent-system-policy.md.

.DESCRIPTION
    Parses a report file and checks structural compliance:
    - Status: line exists with a valid value (complete, partial, blocked)
    - For complete/partial reports: required sections (Changed, Validated,
      Need scope change, Issues) and no standalone prose lines
    - For blocked reports: required fields (Stage, Blocker, Retry status,
      Fallback used, Impact, Next action)
    - Optional worker fields (Refs, States handled, Commit, Version,
      Review item, Git issue, Ready to resolve) are recognized as valid
      labeled fields

    Run against a single file or in batch mode against all .txt files in
    tests/reports/.

.PARAMETER ReportFile
    Path to a single report file to validate. When omitted, validates all
    .txt files in tests/reports/ and reports pass/fail per file.

.EXAMPLE
    ./tools/validate_reports.ps1 -ReportFile tests/reports/valid-worker-complete.txt

.EXAMPLE
    ./tools/validate_reports.ps1
#>
param(
    [string]$ReportFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $repoRoot) {
    $repoRoot = (Get-Location).Path
}

# ── Constants ───────────────────────────────────────────────────────────────

$validStatusValues = @('complete', 'partial', 'blocked')

$workerRequiredSections = @('Changed', 'Validated', 'Need scope change', 'Issues')

$blockedRequiredFields = @('Stage', 'Blocker', 'Retry status', 'Fallback used', 'Impact', 'Next action')

$optionalWorkerFields = @(
    'Refs',
    'States handled',
    'Commit',
    'Version',
    'Review item',
    'Git issue',
    'Ready to resolve'
)

# ── Validation Function ────────────────────────────────────────────────────

function Test-Report {
    <#
    .DESCRIPTION
        Validates a single report file. Returns an array of diagnostic strings.
        An empty array means the report is valid.
    #>
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @("File not found: $Path")
    }

    $lines = Get-Content -Path $Path -Encoding UTF8
    $diagnostics = [System.Collections.Generic.List[string]]::new()

    # ── Check 1: Status line ────────────────────────────────────────────

    $statusValue = $null
    $statusLineIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Status:\s*(.+)$') {
            $statusValue = $Matches[1].Trim()
            $statusLineIndex = $i
            break
        }
    }

    if ($null -eq $statusValue) {
        $diagnostics.Add('Missing required Status: line')
        return $diagnostics.ToArray()
    }

    if ($statusValue -cnotin $validStatusValues) {
        $diagnostics.Add("Invalid Status value '$statusValue' (must be one of: $($validStatusValues -join ', '))")
        return $diagnostics.ToArray()
    }

    # ── Route by status type ────────────────────────────────────────────

    if ($statusValue -eq 'blocked') {
        Test-BlockedReport -Lines $lines -Diagnostics $diagnostics
    }
    else {
        Test-WorkerReport -Lines $lines -Diagnostics $diagnostics
    }

    return $diagnostics.ToArray()
}

# ── Worker Report Validation (complete | partial) ──────────────────────────

function Test-WorkerReport {
    param(
        [string[]]$Lines,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    # INVARIANT: Build a set of all recognized labeled-field prefixes for prose detection.
    $allLabelPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($section in $workerRequiredSections) {
        [void]$allLabelPrefixes.Add($section)
    }
    foreach ($field in $optionalWorkerFields) {
        [void]$allLabelPrefixes.Add($field)
    }
    [void]$allLabelPrefixes.Add('Status')

    # ── Check required sections ─────────────────────────────────────────

    $foundSections = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($line in $Lines) {
        if ($line -match '^([^:]+):\s*') {
            $label = $Matches[1].Trim()
            foreach ($section in $workerRequiredSections) {
                if ($label -eq $section) {
                    [void]$foundSections.Add($section)
                }
            }
        }
    }

    foreach ($section in $workerRequiredSections) {
        if (-not $foundSections.Contains($section)) {
            $Diagnostics.Add("Missing required section: $section")
        }
    }

    # ── Check required sections are non-empty ──────────────────────────

    $sectionLineIndices = @{}
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^([^:]+):\s*') {
            $label = $Matches[1].Trim()
            foreach ($section in $workerRequiredSections) {
                if ($label -eq $section) {
                    $sectionLineIndices[$section] = $i
                }
            }
        }
    }

    foreach ($section in $workerRequiredSections) {
        if (-not $sectionLineIndices.ContainsKey($section)) {
            continue
        }
        $startIdx = $sectionLineIndices[$section] + 1
        $hasContent = $false
        for ($j = $startIdx; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j] -match '^([^:]+):\s*') {
                $nextLabel = $Matches[1].Trim()
                if ($allLabelPrefixes.Contains($nextLabel)) {
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($Lines[$j])) {
                $hasContent = $true
                break
            }
        }
        if (-not $hasContent) {
            $Diagnostics.Add("Required section '$section' is empty (must have at least one entry)")
        }
    }

    # ── Check for standalone prose lines ────────────────────────────────

    $fieldActive = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $lineNum = $i + 1

        if (Test-ValidLine -Line $line -AllLabelPrefixes $allLabelPrefixes -FieldActive ([ref]$fieldActive)) {
            continue
        }

        $Diagnostics.Add("Line $lineNum`: standalone prose: $line")
    }
}

# ── Blocked Report Validation ──────────────────────────────────────────────

function Test-BlockedReport {
    param(
        [string[]]$Lines,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    # INVARIANT: Build a set of all recognized labeled-field prefixes for prose detection.
    $allLabelPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($field in $blockedRequiredFields) {
        [void]$allLabelPrefixes.Add($field)
    }
    foreach ($field in $optionalWorkerFields) {
        [void]$allLabelPrefixes.Add($field)
    }
    [void]$allLabelPrefixes.Add('Status')

    # ── Check required fields ───────────────────────────────────────────

    $foundFields = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($line in $Lines) {
        if ($line -match '^([^:]+):\s*') {
            $label = $Matches[1].Trim()
            foreach ($field in $blockedRequiredFields) {
                if ($label -eq $field) {
                    [void]$foundFields.Add($field)
                }
            }
        }
    }

    foreach ($field in $blockedRequiredFields) {
        if (-not $foundFields.Contains($field)) {
            $Diagnostics.Add("Missing required blocked field: $field")
        }
    }

    # ── Check blocked required fields have non-empty values ────────────

    $inlineFields = @('Stage', 'Blocker', 'Retry status', 'Fallback used', 'Impact')
    $listFields = @('Next action')

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^([^:]+):\s*(.*)$') {
            $label = $Matches[1].Trim()
            $value = $Matches[2].Trim()

            if ($label -in $inlineFields) {
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $Diagnostics.Add("Required blocked field '$label' has no value (must not be empty)")
                }
            }

            if ($label -in $listFields) {
                $hasListItem = $false
                for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                    if ($Lines[$j] -match '^\s*-\s') {
                        $hasListItem = $true
                        break
                    }
                    if ([string]::IsNullOrWhiteSpace($Lines[$j])) {
                        continue
                    }
                    break
                }
                if (-not $hasListItem) {
                    $Diagnostics.Add("Required blocked field '$label' has no list items (must have at least one)")
                }
            }
        }
    }

    # ── Check for standalone prose lines ────────────────────────────────

    $fieldActive = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $lineNum = $i + 1

        if (Test-ValidLine -Line $line -AllLabelPrefixes $allLabelPrefixes -FieldActive ([ref]$fieldActive)) {
            continue
        }

        $Diagnostics.Add("Line $lineNum`: standalone prose: $line")
    }
}

# ── Line Classification ────────────────────────────────────────────────────

function Test-ValidLine {
    <#
    .DESCRIPTION
        Returns $true if the line is structurally valid (not standalone prose).
        Valid lines: blank, heading (#), labeled field (Field: value),
        or list item (- ) that appears under an active labeled field.
        FieldActive tracks whether a labeled field has been seen; list items
        are only valid when a field is active. Headings reset the active-field
        context so that list items after a heading require a new labeled field.
    #>
    param(
        [string]$Line,
        [System.Collections.Generic.HashSet[string]]$AllLabelPrefixes,
        [ref]$FieldActive
    )

    # Blank line
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $true
    }

    # Heading — resets active-field context
    if ($Line -match '^\s*#+\s') {
        $FieldActive.Value = $false
        return $true
    }

    # Labeled field: "SomeLabel: value" where label is a known prefix
    if ($Line -match '^([^:]+):\s*') {
        $label = $Matches[1].Trim()
        if ($AllLabelPrefixes.Contains($label)) {
            $FieldActive.Value = $true
            return $true
        }
    }

    # List item (with optional leading whitespace) — only valid under a field
    if ($Line -match '^\s*-\s') {
        return $FieldActive.Value
    }

    return $false
}

# ── Entry Point ─────────────────────────────────────────────────────────────

if ($ReportFile) {
    $resolvedPath = $ReportFile
    if (-not [System.IO.Path]::IsPathRooted($ReportFile)) {
        $resolvedPath = Join-Path $repoRoot $ReportFile
    }

    $results = @(Test-Report -Path $resolvedPath)
    if ($results.Count -eq 0) {
        Write-Host "[PASS] $ReportFile"
        exit 0
    }
    else {
        Write-Host "[FAIL] $ReportFile"
        foreach ($diag in $results) {
            Write-Host "  $diag"
        }
        exit 1
    }
}
else {
    $fixtureDir = Join-Path (Join-Path $repoRoot 'tests') 'reports'
    if (-not (Test-Path $fixtureDir)) {
        Write-Host "Fixture directory not found: $fixtureDir"
        exit 1
    }

    $fixtures = Get-ChildItem -Path $fixtureDir -Filter '*.txt' -File
    if ($fixtures.Count -eq 0) {
        Write-Host "No .txt fixtures found in $fixtureDir"
        exit 1
    }

    $totalPassed = 0
    $totalFailed = 0
    $batchFailed = $false

    foreach ($fixture in $fixtures) {
        $relPath = 'tests/reports/' + $fixture.Name
        $expectValid = $fixture.Name -match '^valid-'

        $results = @(Test-Report -Path $fixture.FullName)
        $reportIsValid = ($results.Count -eq 0)

        if ($expectValid -and $reportIsValid) {
            Write-Host "[PASS] $relPath"
            $totalPassed++
        }
        elseif ($expectValid -and -not $reportIsValid) {
            Write-Host "[FAIL] $relPath (expected valid, got diagnostics)"
            foreach ($diag in $results) {
                Write-Host "  $diag"
            }
            $totalFailed++
            $batchFailed = $true
        }
        elseif (-not $expectValid -and -not $reportIsValid) {
            Write-Host "[PASS] $relPath (correctly rejected)"
            foreach ($diag in $results) {
                Write-Host "  $diag"
            }
            $totalPassed++
        }
        elseif (-not $expectValid -and $reportIsValid) {
            Write-Host "[FAIL] $relPath (expected invalid, but passed validation)"
            $totalFailed++
            $batchFailed = $true
        }
    }

    Write-Host ''
    Write-Host "Results: $totalPassed passed, $totalFailed failed out of $($fixtures.Count) fixtures"

    if ($batchFailed) {
        exit 1
    }
    exit 0
}
