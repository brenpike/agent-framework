<#
.SYNOPSIS
    Validates agent report text against the REL-4 report contracts
    (worker, blocked, planner, PR output, address-pr-feedback,
    watch-pr-feedback) from agent-system-policy.md and skill SKILL.md files.

.DESCRIPTION
    Parses a report file and checks structural compliance:
    - Detects report type via ordered heuristics
    - For worker (complete/partial): required sections and no standalone prose
    - For blocked: required fields with value constraints
    - For planner (compact/full): required fields and list sections
    - For PR output (open-plan-pr): required fields including PR URL
    - For address-pr-feedback: required fields with sub-field groups
    - For watch-pr-feedback: required fields with sub-field groups
    - Unknown type: diagnostic and fail

    Run against a single file or in batch mode against all .txt files in
    tests/reports/.

.PARAMETER ReportFile
    Path to a single report file to validate. When omitted, validates all
    .txt files in tests/reports/ and reports pass/fail per file.

.PARAMETER Batch
    Path to a directory of .txt fixture files. Overrides the default
    tests/reports/ directory for batch mode.

.EXAMPLE
    ./tools/validate_reports.ps1 -ReportFile tests/reports/valid-worker-complete.txt

.EXAMPLE
    ./tools/validate_reports.ps1

.EXAMPLE
    ./tools/validate_reports.ps1 -Batch tests/reports/
#>
param(
    [string]$ReportFile,
    [string]$Batch
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

$validStageValues = @(
    'planning', 'implementation', 'validation', 'git workflow',
    'versioning', 'review remediation', 'monitoring',
    'skill selection', 'fetch', 'parse', 'route'
)

$validRetryStatusValues = @('not attempted', 'retried once', 'exhausted')

$optionalWorkerFields = @(
    'Refs',
    'States handled',
    'Commit',
    'Version',
    'Review item',
    'Git issue',
    'Ready to resolve'
)

# ── Planner Constants ──────────────────────────────────────────────────────

$plannerCompactInlineFields = @('Summary')

$plannerCompactListSections = @('Memory reused', 'Steps', 'Open questions')

$plannerCompactSubFields = @{
    'Versioning' = @('Impact', 'Artifact(s)')
}

$plannerFullExtraListSections = @('Edge cases', 'Shared-file risks')

$plannerFullExtraSubFields = @{
    'Delivery' = @('Shape', 'Branch/PR', 'Worktrees')
}

# ── PR Output Constants ────────────────────────────────────────────────────

$prOutputInlineFields = @(
    'Status', 'Base', 'Head', 'Local HEAD', 'Pushed',
    'Push remote', 'PR head SHA', 'Head verified', 'PR title', 'PR URL'
)

$prOutputListSections = @('Warnings')

# ── address-pr-feedback Constants ──────────────────────────────────────────

$addressFeedbackSubFields = @{
    'PR'       = @('Number', 'Branch', 'Target')
    'Feedback' = @('Source', 'Author', 'URL', 'Classification')
    'Git'      = @('Commit', 'Pushed')
    'Reply'    = @('Posted')
}

$addressFeedbackListSections = @('Changed', 'Validated', 'Issues')

# ── watch-pr-feedback Constants ────────────────────────────────────────────

$watchFeedbackSubFields = @{
    'PR'    = @('Number', 'State', 'Branch', 'Target')
    'Watch' = @('Mode', 'Monitoring', 'Parser', 'Cycles', 'Seen comments', 'New actionable comments')
}

$watchFeedbackListSections = @('Routed', 'Stopped because', 'Next action', 'Issues')

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

    # ── Detect report type ─────────────────────────────────────────────

    $reportType = Get-ReportType -Lines $lines -StatusValue $statusValue

    # ── Route by detected type ─────────────────────────────────────────

    switch ($reportType) {
        'blocked' {
            if ($null -eq $statusValue) {
                $diagnostics.Add('Missing required Status: line')
                return $diagnostics.ToArray()
            }
            if ($statusValue -cnotin $validStatusValues) {
                $diagnostics.Add("Invalid Status value '$statusValue' (must be one of: $($validStatusValues -join ', '))")
                return $diagnostics.ToArray()
            }
            Test-BlockedReport -Lines $lines -Diagnostics $diagnostics
        }
        'worker' {
            if ($null -eq $statusValue) {
                $diagnostics.Add('Missing required Status: line')
                return $diagnostics.ToArray()
            }
            if ($statusValue -cnotin $validStatusValues) {
                $diagnostics.Add("Invalid Status value '$statusValue' (must be one of: $($validStatusValues -join ', '))")
                return $diagnostics.ToArray()
            }
            Test-WorkerReport -Lines $lines -Diagnostics $diagnostics
        }
        'planner' {
            Test-PlannerReport -Lines $lines -Diagnostics $diagnostics
        }
        'pr-output' {
            Test-PrOutputReport -Lines $lines -Diagnostics $diagnostics
        }
        'address-pr-feedback' {
            if ($null -eq $statusValue) {
                $diagnostics.Add('Missing required Status: line')
                return $diagnostics.ToArray()
            }
            if ($statusValue -cnotin $validStatusValues) {
                $diagnostics.Add("Invalid Status value '$statusValue' (must be one of: $($validStatusValues -join ', '))")
                return $diagnostics.ToArray()
            }
            Test-AddressFeedbackReport -Lines $lines -Diagnostics $diagnostics
        }
        'watch-pr-feedback' {
            if ($null -eq $statusValue) {
                $diagnostics.Add('Missing required Status: line')
                return $diagnostics.ToArray()
            }
            if ($statusValue -cnotin $validStatusValues) {
                $diagnostics.Add("Invalid Status value '$statusValue' (must be one of: $($validStatusValues -join ', '))")
                return $diagnostics.ToArray()
            }
            Test-WatchFeedbackReport -Lines $lines -Diagnostics $diagnostics
        }
        default {
            $diagnostics.Add('Unknown report type')
        }
    }

    return $diagnostics.ToArray()
}

# ── Report Type Detection ──────────────────────────────────────────────────

function Get-ReportType {
    <#
    .DESCRIPTION
        Detects the report type using ordered heuristics. Returns one of:
        blocked, worker, planner, pr-output, address-pr-feedback,
        watch-pr-feedback, or unknown.
    #>
    param(
        [string[]]$Lines,
        [AllowNull()][string]$StatusValue
    )

    # 1. PR output: contains any PR-output-exclusive field (check before blocked/worker
    #    so blocked PR-output reports route to Test-PrOutputReport)
    foreach ($line in $Lines) {
        if ($line -match '^(PR head SHA|PR title|Head verified|Local HEAD|Push remote):\s*') {
            return 'pr-output'
        }
    }

    # 2. address-pr-feedback: Feedback: section with Classification: sub-field
    #    (check before blocked/worker so blocked feedback reports route correctly)
    $inFeedback = $false
    foreach ($line in $Lines) {
        if ($line -match '^Feedback:\s*') {
            $inFeedback = $true
            continue
        }
        if ($inFeedback -and $line -match '^\s*-\s*Classification:\s*') {
            return 'address-pr-feedback'
        }
        if ($inFeedback -and $line -match '^[A-Z][^:]*:\s*' -and $line -notmatch '^\s*-') {
            $inFeedback = $false
        }
    }

    # 3. watch-pr-feedback: Watch: section with Monitoring: sub-field
    #    (check before blocked/worker so blocked watch reports route correctly)
    $inWatch = $false
    foreach ($line in $Lines) {
        if ($line -match '^Watch:\s*') {
            $inWatch = $true
            continue
        }
        if ($inWatch -and $line -match '^\s*-\s*Monitoring:\s*') {
            return 'watch-pr-feedback'
        }
        if ($inWatch -and $line -match '^[A-Z][^:]*:\s*' -and $line -notmatch '^\s*-') {
            $inWatch = $false
        }
    }

    # 4. Blocked: first Status value is "blocked"
    if ($StatusValue -eq 'blocked') {
        return 'blocked'
    }

    # 5. Worker: Status is complete/partial AND no Watch: AND no Feedback:
    if ($StatusValue -in @('complete', 'partial')) {
        $hasWatch = $false
        $hasFeedback = $false
        foreach ($line in $Lines) {
            if ($line -match '^Watch:\s*') { $hasWatch = $true }
            if ($line -match '^Feedback:\s*') { $hasFeedback = $true }
        }
        if (-not $hasWatch -and -not $hasFeedback) {
            return 'worker'
        }
    }

    # 6. Worker (statusless fallback): worker-exclusive section headers present
    #    but no Status: line — route to worker so Test-WorkerReport emits the
    #    precise "Missing required Status: line" diagnostic.
    if ($null -eq $StatusValue) {
        $hasNeedScope = $false
        $hasChanged = $false
        $hasValidated = $false
        $hasIssues = $false
        foreach ($line in $Lines) {
            if ($line -match '^Need scope change:\s*') { $hasNeedScope = $true }
            if ($line -match '^Changed:\s*') { $hasChanged = $true }
            if ($line -match '^Validated:\s*') { $hasValidated = $true }
            if ($line -match '^Issues:\s*') { $hasIssues = $true }
        }
        if ($hasNeedScope -or ($hasChanged -and $hasValidated -and $hasIssues)) {
            return 'worker'
        }
    }

    # 7. Planner: first non-blank line is exactly "Plan"
    foreach ($line in $Lines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            if ($line.Trim() -eq 'Plan') {
                return 'planner'
            }
            break
        }
    }

    return 'unknown'
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
        $hasListItem = $false
        for ($j = $startIdx; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j] -match '^([^:]+):\s*') {
                $nextLabel = $Matches[1].Trim()
                if ($allLabelPrefixes.Contains($nextLabel)) {
                    break
                }
            }
            if ($Lines[$j] -match '^\s*-\s') {
                $hasListItem = $true
                break
            }
        }
        if (-not $hasListItem) {
            $Diagnostics.Add("Required section '$section' must contain at least one list item (- entry or - None)")
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
                elseif ($label -eq 'Stage' -and $value -cnotin $validStageValues) {
                    $Diagnostics.Add("Invalid Stage value '$value' (must be one of: $($validStageValues -join ', '))")
                }
                elseif ($label -eq 'Retry status' -and $value -cnotin $validRetryStatusValues) {
                    $Diagnostics.Add("Invalid Retry status value '$value' (must be one of: $($validRetryStatusValues -join ', '))")
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

# ── Planner Report Validation ──────────────────────────────────────────────

function Test-PlannerReport {
    param(
        [string[]]$Lines,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    # INVARIANT: Planner reports start with "Plan" on the first non-blank line (already verified by detection).

    # Determine compact vs full by presence of Delivery: line
    $isFullPlan = $false
    foreach ($line in $Lines) {
        if ($line -match '^Delivery:\s*') {
            $isFullPlan = $true
            break
        }
    }

    # Build recognized label set
    $allLabelPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($field in $plannerCompactInlineFields) {
        [void]$allLabelPrefixes.Add($field)
    }
    foreach ($section in $plannerCompactListSections) {
        [void]$allLabelPrefixes.Add($section)
    }
    foreach ($parent in $plannerCompactSubFields.Keys) {
        [void]$allLabelPrefixes.Add($parent)
    }
    [void]$allLabelPrefixes.Add('Owner')
    [void]$allLabelPrefixes.Add('Files')
    [void]$allLabelPrefixes.Add('Outcome')
    [void]$allLabelPrefixes.Add('Depends on')
    if ($isFullPlan) {
        foreach ($section in $plannerFullExtraListSections) {
            [void]$allLabelPrefixes.Add($section)
        }
        foreach ($parent in $plannerFullExtraSubFields.Keys) {
            [void]$allLabelPrefixes.Add($parent)
        }
        [void]$allLabelPrefixes.Add('Likely bump')
        [void]$allLabelPrefixes.Add('Release files likely needed')
        [void]$allLabelPrefixes.Add('Item(s)')
        [void]$allLabelPrefixes.Add('Classification')
        [void]$allLabelPrefixes.Add('User decision needed')
    }

    # Check required inline fields
    foreach ($field in $plannerCompactInlineFields) {
        $fieldFound = $false
        foreach ($line in $Lines) {
            if ($line -match "^${field}:\s*.+$") {
                $fieldFound = $true
                break
            }
        }
        if (-not $fieldFound) {
            $Diagnostics.Add("Missing required field: $field")
        }
    }

    # Check required list sections
    $requiredListSections = [System.Collections.Generic.List[string]]::new()
    foreach ($section in $plannerCompactListSections) {
        $requiredListSections.Add($section)
    }
    if ($isFullPlan) {
        foreach ($section in $plannerFullExtraListSections) {
            $requiredListSections.Add($section)
        }
    }
    Test-RequiredListSections -Lines $Lines -RequiredSections $requiredListSections.ToArray() -AllLabelPrefixes $allLabelPrefixes -Diagnostics $Diagnostics

    # Check required sub-field groups
    Test-RequiredSubFields -Lines $Lines -SubFieldMap $plannerCompactSubFields -Diagnostics $Diagnostics
    if ($isFullPlan) {
        Test-RequiredSubFields -Lines $Lines -SubFieldMap $plannerFullExtraSubFields -Diagnostics $Diagnostics
    }

    # Check per-step required sub-fields within Steps section
    Test-PlannerStepSubFields -Lines $Lines -IsFullPlan $isFullPlan -AllLabelPrefixes $allLabelPrefixes -Diagnostics $Diagnostics

    # ── Check for standalone prose lines ────────────────────────────────

    $fieldActive = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $lineNum = $i + 1

        # INVARIANT: "Plan" on the first non-blank line is the report heading, not prose.
        if ($line.Trim() -eq 'Plan') {
            $fieldActive = $false
            continue
        }

        if (Test-ValidLine -Line $line -AllLabelPrefixes $allLabelPrefixes -FieldActive ([ref]$fieldActive)) {
            continue
        }

        $Diagnostics.Add("Line $lineNum`: standalone prose: $line")
    }
}

# ── PR Output Report Validation ───────────────────────────────────────────

function Test-PrOutputReport {
    param(
        [string[]]$Lines,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    $allLabelPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($field in $prOutputInlineFields) {
        [void]$allLabelPrefixes.Add($field)
    }
    foreach ($section in $prOutputListSections) {
        [void]$allLabelPrefixes.Add($section)
    }

    # Check required inline fields
    foreach ($field in $prOutputInlineFields) {
        $fieldFound = $false
        foreach ($line in $Lines) {
            if ($line -match "^$([regex]::Escape($field)):\s*") {
                $fieldFound = $true
                break
            }
        }
        if (-not $fieldFound) {
            $Diagnostics.Add("Missing required field: $field")
        }
    }

    # Check Status value against open-plan-pr contract (complete | blocked)
    $validPrOutputStatusValues = @('complete', 'blocked')
    foreach ($line in $Lines) {
        if ($line -match '^Status:\s*(.+)$') {
            $prStatusValue = $Matches[1].Trim()
            if ($prStatusValue -cnotin $validPrOutputStatusValues) {
                $Diagnostics.Add("Invalid PR output Status value '$prStatusValue' (must be one of: $($validPrOutputStatusValues -join ', '))")
            }
            break
        }
    }

    # Check required list sections
    Test-RequiredListSections -Lines $Lines -RequiredSections $prOutputListSections -AllLabelPrefixes $allLabelPrefixes -Diagnostics $Diagnostics

    # Check for standalone prose
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

# ── address-pr-feedback Report Validation ──────────────────────────────────

function Test-AddressFeedbackReport {
    param(
        [string[]]$Lines,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    $allLabelPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    [void]$allLabelPrefixes.Add('Status')
    foreach ($parent in $addressFeedbackSubFields.Keys) {
        [void]$allLabelPrefixes.Add($parent)
    }
    foreach ($section in $addressFeedbackListSections) {
        [void]$allLabelPrefixes.Add($section)
    }

    # Check Status present (already validated by caller, but check presence)
    $hasStatus = $false
    foreach ($line in $Lines) {
        if ($line -match '^Status:\s*') {
            $hasStatus = $true
            break
        }
    }
    if (-not $hasStatus) {
        $Diagnostics.Add('Missing required field: Status')
    }

    # Check required sub-field groups
    Test-RequiredSubFields -Lines $Lines -SubFieldMap $addressFeedbackSubFields -Diagnostics $Diagnostics

    # Check required list sections
    Test-RequiredListSections -Lines $Lines -RequiredSections $addressFeedbackListSections -AllLabelPrefixes $allLabelPrefixes -Diagnostics $Diagnostics

    # Check for standalone prose
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

# ── watch-pr-feedback Report Validation ────────────────────────────────────

function Test-WatchFeedbackReport {
    param(
        [string[]]$Lines,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    $allLabelPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    [void]$allLabelPrefixes.Add('Status')
    foreach ($parent in $watchFeedbackSubFields.Keys) {
        [void]$allLabelPrefixes.Add($parent)
    }
    foreach ($section in $watchFeedbackListSections) {
        [void]$allLabelPrefixes.Add($section)
    }

    # Check Status present
    $hasStatus = $false
    foreach ($line in $Lines) {
        if ($line -match '^Status:\s*') {
            $hasStatus = $true
            break
        }
    }
    if (-not $hasStatus) {
        $Diagnostics.Add('Missing required field: Status')
    }

    # Check required sub-field groups
    Test-RequiredSubFields -Lines $Lines -SubFieldMap $watchFeedbackSubFields -Diagnostics $Diagnostics

    # Check required list sections
    Test-RequiredListSections -Lines $Lines -RequiredSections $watchFeedbackListSections -AllLabelPrefixes $allLabelPrefixes -Diagnostics $Diagnostics

    # Check for standalone prose
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

# ── Shared Validation Helpers ──────────────────────────────────────────────

function Test-RequiredListSections {
    <#
    .DESCRIPTION
        Checks that each named section exists and contains at least one list item.
    #>
    param(
        [string[]]$Lines,
        [string[]]$RequiredSections,
        [System.Collections.Generic.HashSet[string]]$AllLabelPrefixes,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    foreach ($section in $RequiredSections) {
        $sectionIdx = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match "^$([regex]::Escape($section)):\s*") {
                $sectionIdx = $i
                break
            }
        }
        if ($sectionIdx -eq -1) {
            $Diagnostics.Add("Missing required section: $section")
            continue
        }

        $hasListItem = $false
        for ($j = $sectionIdx + 1; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j] -match '^([^:]+):\s*') {
                $nextLabel = $Matches[1].Trim()
                if ($AllLabelPrefixes.Contains($nextLabel)) {
                    break
                }
            }
            if ($Lines[$j] -match '^\s*(-|\d+\.)\s') {
                $hasListItem = $true
                break
            }
        }
        if (-not $hasListItem) {
            $Diagnostics.Add("Required section '$section' must contain at least one list item")
        }
    }
}

function Test-RequiredSubFields {
    <#
    .DESCRIPTION
        Checks that each parent field exists and contains all required
        sub-fields as indented list items (- SubField: value).
    #>
    param(
        [string[]]$Lines,
        [hashtable]$SubFieldMap,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    foreach ($parent in $SubFieldMap.Keys) {
        $parentIdx = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match "^$([regex]::Escape($parent)):\s*") {
                $parentIdx = $i
                break
            }
        }
        if ($parentIdx -eq -1) {
            $Diagnostics.Add("Missing required field group: $parent")
            continue
        }

        $requiredSubs = $SubFieldMap[$parent]
        $foundSubs = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        for ($j = $parentIdx + 1; $j -lt $Lines.Count; $j++) {
            # Stop at the next top-level field (non-indented label)
            if ($Lines[$j] -match '^[A-Za-z]' -and $Lines[$j] -match '^([^:]+):\s*') {
                break
            }
            if ($Lines[$j] -match '^\s*-\s*([^:]+):\s*') {
                $subLabel = $Matches[1].Trim()
                [void]$foundSubs.Add($subLabel)
            }
        }

        foreach ($sub in $requiredSubs) {
            if (-not $foundSubs.Contains($sub)) {
                $Diagnostics.Add("Missing required sub-field '$sub' under '$parent'")
            }
        }
    }
}

# ── Planner Step Sub-field Validation ─────────────────────────────────────

function Test-PlannerStepSubFields {
    <#
    .DESCRIPTION
        Parses each numbered step block within the Steps section and checks
        for required sub-fields. Compact mode requires Owner, Files, Outcome.
        Full mode additionally requires Depends on.
    #>
    param(
        [string[]]$Lines,
        [bool]$IsFullPlan,
        [System.Collections.Generic.HashSet[string]]$AllLabelPrefixes,
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    # Locate Steps: section
    $stepsIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^Steps:\s*') {
            $stepsIdx = $i
            break
        }
    }
    if ($stepsIdx -eq -1) {
        return
    }

    # Find the end of the Steps section (next top-level labeled field at column 0)
    $stepsEndIdx = $Lines.Count
    for ($j = $stepsIdx + 1; $j -lt $Lines.Count; $j++) {
        if ($Lines[$j] -match '^[A-Za-z]' -and $Lines[$j] -match '^([^:]+):\s*') {
            $candidateLabel = $Matches[1].Trim()
            if ($AllLabelPrefixes.Contains($candidateLabel)) {
                $stepsEndIdx = $j
                break
            }
        }
    }

    # Collect step block start indices within the Steps section.
    # A step starts at a line matching "- S<N>" or "<N>. " (numbered list item).
    $stepStarts = [System.Collections.Generic.List[int]]::new()
    $stepLabels = [System.Collections.Generic.List[string]]::new()
    for ($i = $stepsIdx + 1; $i -lt $stepsEndIdx; $i++) {
        if ($Lines[$i] -match '^\s*-\s+S(\d+)\b') {
            $stepStarts.Add($i)
            $stepLabels.Add("S$($Matches[1])")
        }
        elseif ($Lines[$i] -match '^\s*(\d+)\.\s') {
            $stepStarts.Add($i)
            $stepLabels.Add("Step $($Matches[1])")
        }
    }

    if ($stepStarts.Count -eq 0) {
        return
    }

    $requiredSubFields = @('Owner', 'Files', 'Outcome')
    if ($IsFullPlan) {
        $requiredSubFields = @('Owner', 'Files', 'Outcome', 'Depends on')
    }

    for ($s = 0; $s -lt $stepStarts.Count; $s++) {
        $blockStart = $stepStarts[$s]
        if ($s -lt $stepStarts.Count - 1) {
            $blockEnd = $stepStarts[$s + 1]
        }
        else {
            $blockEnd = $stepsEndIdx
        }
        $stepLabel = $stepLabels[$s]

        $foundFields = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        # Check the step header line for inline Owner (e.g., "- S1 Owner: coder")
        if ($Lines[$blockStart] -match '\bOwner:\s*\S') {
            [void]$foundFields.Add('Owner')
        }

        # Scan continuation lines for sub-fields
        for ($k = $blockStart + 1; $k -lt $blockEnd; $k++) {
            if ($Lines[$k] -match '^\s+([^:]+):\s*') {
                $subLabel = $Matches[1].Trim()
                [void]$foundFields.Add($subLabel)
            }
        }

        foreach ($requiredField in $requiredSubFields) {
            if (-not $foundFields.Contains($requiredField)) {
                $Diagnostics.Add("$stepLabel missing required field: $requiredField")
            }
        }
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
    if ($Line -match '^\s*(-|\d+\.)\s') {
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
    if ($Batch) {
        if ([System.IO.Path]::IsPathRooted($Batch)) {
            $fixtureDir = $Batch
        }
        else {
            $fixtureDir = Join-Path $repoRoot $Batch
        }
    }
    else {
        $fixtureDir = Join-Path (Join-Path $repoRoot 'tests') 'reports'
    }
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
