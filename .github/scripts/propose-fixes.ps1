<#
.SYNOPSIS
    Parses UiPath CI failures, applies safe auto-fixes, and generates a PR report.

.PARAMETERS
    -ProjectFile    Path to project.json
    -ArtifactsDir   Directory containing downloaded CI artifacts (analysis-output.txt, analysis-report.json)
    -ValidateResult Result string from the validate job ('success'|'failure'|'skipped')
    -PackageResult  Result string from the package job ('success'|'failure'|'skipped')
    -OutputReport   Path to write the markdown fix-proposal report
    -OutputProject  Path to write the (possibly patched) project.json
#>
param(
    [string]$ProjectFile    = "project.json",
    [string]$ArtifactsDir  = "./ci-artifacts",
    [string]$ValidateResult = "success",
    [string]$PackageResult  = "success",
    [string]$OutputReport   = "fix-proposals.md",
    [string]$OutputProject  = "project-fixed.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Section([string]$title) { Write-Host "`n=== $title ===" }

$fixes      = [System.Collections.Generic.List[hashtable]]::new()
$warnings   = [System.Collections.Generic.List[string]]::new()
$autoFixed  = $false

# ── Load project.json ─────────────────────────────────────────────────────────
Write-Section "Loading project.json"
if (-not (Test-Path $ProjectFile)) {
    Write-Warning "project.json not found at: $ProjectFile"
    exit 0
}

$proj    = Get-Content $ProjectFile -Raw | ConvertFrom-Json
$changed = $false

# ── Known-good minimum versions per Studio 25.10 ─────────────────────────────
$minimumVersions = @{
    "UiPath.System.Activities"      = "25.10.5"
    "UiPath.UIAutomation.Activities"= "25.10.33"
    "UiPath.Excel.Activities"       = "3.5.2"
    "UiPath.Mail.Activities"        = "2.9.10"
    "UiPath.Testing.Activities"     = "25.10.2"
}

# ── Fix 1: Typo in projectProfile ("Developement" → "Development") ───────────
Write-Section "Fix 1 – projectProfile typo"
if ($proj.designOptions.projectProfile -eq "Developement") {
    $proj.designOptions.projectProfile = "Development"
    $changed = $true
    $fixes.Add(@{
        Category = "project.json"
        Rule     = "Schema typo"
        Fix      = "Corrected `projectProfile` value from ``Developement`` to ``Development``"
        Auto     = $true
    })
    Write-Host "Applied: projectProfile typo fix"
}

# ── Fix 2: Dependency version pinning (exact pin → minimum range) ─────────────
Write-Section "Fix 2 – dependency version ranges"
if ($proj.dependencies) {
    $deps = $proj.dependencies | ConvertTo-Json | ConvertFrom-Json  # get as ordered dict
    $newDeps = [ordered]@{}

    foreach ($prop in $proj.dependencies.PSObject.Properties) {
        $pkg  = $prop.Name
        $spec = $prop.Value   # e.g. "[3.5.2]" or "[3.5.2,)"

        # Detect overly-pinned exact versions [x.y.z] and open them to [x.y.z,)
        if ($spec -match '^\[(\d+\.\d+\.\d+)\]$') {
            $ver      = $Matches[1]
            $newSpec  = "[$ver,)"
            $newDeps[$pkg] = $newSpec
            $changed  = $true
            $fixes.Add(@{
                Category = "project.json"
                Rule     = "Locked dependency"
                Fix      = "``$pkg``: changed ``$spec`` → ``$newSpec`` (allows patch updates)"
                Auto     = $true
            })
            Write-Host "Applied: $pkg $spec → $newSpec"
        } else {
            $newDeps[$pkg] = $spec
        }

        # Warn if version is below known minimum
        if ($minimumVersions.ContainsKey($pkg) -and $spec -match '(\d+\.\d+\.\d+)') {
            $current = [version]$Matches[1]
            $minimum = [version]$minimumVersions[$pkg]
            if ($current -lt $minimum) {
                $warnings.Add("``$pkg`` version $current is below the Studio 25.10 minimum ($minimum). Update to at least $minimum.")
                $fixes.Add(@{
                    Category = "project.json"
                    Rule     = "Outdated dependency"
                    Fix      = "Update ``$pkg`` from $current to at least $($minimumVersions[$pkg])"
                    Auto     = $false
                })
            }
        }
    }

    # Rebuild dependencies on the project object
    $proj.dependencies = [PSCustomObject]$newDeps
}

# ── Fix 3: Missing required runtime fields ────────────────────────────────────
Write-Section "Fix 3 – runtime options defaults"
if (-not $proj.runtimeOptions.PSObject.Properties['excludedLoggedData']) {
    $proj.runtimeOptions | Add-Member -MemberType NoteProperty -Name "excludedLoggedData" -Value @("Private:*","*password*")
    $changed = $true
    $fixes.Add(@{
        Category = "project.json"
        Rule     = "Missing field"
        Fix      = "Added default ``excludedLoggedData`` to runtimeOptions (security best-practice)"
        Auto     = $true
    })
    Write-Host "Applied: added excludedLoggedData defaults"
}

# ── Fix 4: Parse Workflow Analyzer report ─────────────────────────────────────
Write-Section "Fix 4 – Workflow Analyzer violations"
$analyzerViolations = @()
$analyzerReportPath = Join-Path $ArtifactsDir "analysis-report.json"
if (Test-Path $analyzerReportPath) {
    try {
        $analyzerViolations = @(Get-Content $analyzerReportPath -Raw | ConvertFrom-Json)
        Write-Host "Loaded $($analyzerViolations.Count) analyzer finding(s)"
    } catch {
        $warnings.Add("Could not parse analysis-report.json: $_")
    }
}

# Analyzer raw text fallback
$analyzerText = ""
$analyzerTextPath = Join-Path $ArtifactsDir "analysis-output.txt"
if (Test-Path $analyzerTextPath) {
    $analyzerText = Get-Content $analyzerTextPath -Raw
}

# Known fixable rule IDs and their guidance
$ruleGuidance = @{
    "ST-NMG-001" = "Rename the workflow file/sequence to match the PascalCase naming convention."
    "ST-NMG-002" = "Rename variables to camelCase (e.g., ``myVar``)."
    "ST-NMG-004" = "Rename arguments to PascalCase prefixed with in_/out_/io_ (e.g., ``in_FilePath``)."
    "ST-USG-001" = "Remove unused variables to keep the workflow clean."
    "ST-USG-009" = "Remove unused imports/namespaces from the workflow."
    "ST-SEC-001" = "Move hardcoded credentials to Orchestrator Assets or environment variables."
    "ST-SEC-009" = "Use secure string types for sensitive data instead of plain strings."
    "ST-DBP-002" = "Add a Try/Catch block around activities that can fail."
    "ST-DBP-004" = "Set a meaningful timeout on all UI interaction activities."
    "ST-DOC-001" = "Add a workflow annotation describing the purpose of this workflow."
    "ST-MRD-007" = "Avoid using Log Message inside loops; buffer and log outside the loop."
}

foreach ($v in $analyzerViolations) {
    $rule    = $v.RuleId
    $guide   = if ($ruleGuidance.ContainsKey($rule)) { $ruleGuidance[$rule] } else { "Review the UiPath Workflow Analyzer documentation for rule $rule." }
    $fixes.Add(@{
        Category = "Workflow Analyzer"
        Rule     = "$rule — $($v.Description)"
        Fix      = $guide
        Auto     = $false
        File     = $v.FilePath
        Line     = $v.Line
    })
}

# ── Write fixed project.json ──────────────────────────────────────────────────
if ($changed) {
    $proj | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputProject -Encoding UTF8
    $autoFixed = $true
    Write-Host "Wrote patched project to: $OutputProject"
} else {
    Write-Host "No project.json changes needed"
}

# ── Generate Markdown report ──────────────────────────────────────────────────
Write-Section "Generating fix-proposals.md"

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine("## CI Failure Analysis & Fix Proposals")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("Automated analysis of the failed CI run. Review each item below.")
$null = $sb.AppendLine("")

# Status table
$null = $sb.AppendLine("### Pipeline Status")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("| Job | Result |")
$null = $sb.AppendLine("|-----|--------|")
$statusEmoji = @{ success = "✅"; failure = "❌"; skipped = "⏭️"; cancelled = "⛔" }
$null = $sb.AppendLine("| Validate & Analyze | $($statusEmoji[$ValidateResult] ?? '❓') $ValidateResult |")
$null = $sb.AppendLine("| Package | $($statusEmoji[$PackageResult] ?? '❓') $PackageResult |")
$null = $sb.AppendLine("")

# Auto-fixed items
$autoFixes = @($fixes | Where-Object { $_.Auto -eq $true })
if ($autoFixes.Count -gt 0) {
    $null = $sb.AppendLine("### ✅ Auto-Applied Fixes (included in this PR)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Category | Issue | Fix Applied |")
    $null = $sb.AppendLine("|----------|-------|-------------|")
    foreach ($f in $autoFixes) {
        $null = $sb.AppendLine("| $($f.Category) | $($f.Rule) | $($f.Fix) |")
    }
    $null = $sb.AppendLine("")
}

# Manual fixes required
$manualFixes = @($fixes | Where-Object { $_.Auto -eq $false })
if ($manualFixes.Count -gt 0) {
    $null = $sb.AppendLine("### 🔧 Manual Fixes Required")
    $null = $sb.AppendLine("")
    foreach ($f in $manualFixes) {
        $location = if ($f.File) { "``$($f.File)``$(if($f.Line){"  line $($f.Line)"})" } else { "" }
        $null = $sb.AppendLine("#### $($f.Rule)")
        if ($location) { $null = $sb.AppendLine("**Location:** $location") }
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine($f.Fix)
        $null = $sb.AppendLine("")
    }
}

# Warnings
if ($warnings.Count -gt 0) {
    $null = $sb.AppendLine("### ⚠️ Warnings")
    $null = $sb.AppendLine("")
    foreach ($w in $warnings) {
        $null = $sb.AppendLine("- $w")
    }
    $null = $sb.AppendLine("")
}

if ($fixes.Count -eq 0 -and $warnings.Count -eq 0) {
    $null = $sb.AppendLine("No specific fixable issues were identified automatically. Check the raw CI logs for details.")
    $null = $sb.AppendLine("")
}

$null = $sb.AppendLine("---")
$null = $sb.AppendLine("*Generated by `.github/scripts/propose-fixes.ps1`. Review before merging.*")

$sb.ToString() | Set-Content -Path $OutputReport -Encoding UTF8
Write-Host "Report written to: $OutputReport"

# Return exit code 0 — failures are reported via the report, not the script exit
exit 0
