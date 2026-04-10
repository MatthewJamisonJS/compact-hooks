$Script:Pass = 0; $Script:Fail = 0

function Assert-Eq {
    param([string]$Expected, [string]$Actual, [string]$Label)
    if ($Expected -eq $Actual) { Write-Host "  ✓ $Label" -ForegroundColor Green; $Script:Pass++ }
    else { Write-Host "  ✗ $Label`n    expected: [$Expected]`n    got: [$Actual]" -ForegroundColor Red; $Script:Fail++ }
}

function Assert-Contains {
    param([string]$Needle, [string]$Haystack, [string]$Label)
    if ($Haystack -match [regex]::Escape($Needle)) { Write-Host "  ✓ $Label" -ForegroundColor Green; $Script:Pass++ }
    else { Write-Host "  ✗ $Label`n    expected to contain: [$Needle]" -ForegroundColor Red; $Script:Fail++ }
}

$SCRIPT = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts/pre-compact-summary.ps1"

# Test 1: auto trigger → hookEventName=PreCompact
$output = '{"trigger":"auto"}' | & pwsh $SCRIPT 2>$null
$parsed = $output | ConvertFrom-Json
Assert-Eq "PreCompact" $parsed.hookSpecificOutput.hookEventName "auto trigger: hookEventName=PreCompact"

# Test 2: auto trigger → systemMessage contains [Auto]
$output = '{"trigger":"auto"}' | & pwsh $SCRIPT 2>$null
Assert-Contains "[Auto]" $output "auto trigger: systemMessage contains [Auto]"

# Test 3: manual trigger → systemMessage contains [Manual]
$output = '{"trigger":"manual"}' | & pwsh $SCRIPT 2>$null
Assert-Contains "[Manual]" $output "manual trigger: systemMessage contains [Manual]"

# Test 4: unknown trigger falls back to auto
$output = '{"trigger":"bogus"}' | & pwsh $SCRIPT 2>$null
Assert-Contains "[Auto]" $output "unknown trigger falls back to auto"

# Test 5: malformed input → script exits 0 (fail open)
'not json at all' | & pwsh $SCRIPT 2>$null
Assert-Eq "0" "$LASTEXITCODE" "malformed input: script exits 0"

# Tests 6–11: additionalContext contains all 6 required sections
$output = '{"trigger":"auto"}' | & pwsh $SCRIPT 2>$null
Assert-Contains "OVERALL TASK"    $output "additionalContext contains 'OVERALL TASK'"
Assert-Contains "DECISION CHAIN"  $output "additionalContext contains 'DECISION CHAIN'"
Assert-Contains "CURRENT STATE"   $output "additionalContext contains 'CURRENT STATE'"
Assert-Contains "ACTIVE FILES"    $output "additionalContext contains 'ACTIVE FILES'"
Assert-Contains "LAST ERROR"      $output "additionalContext contains 'LAST ERROR'"
Assert-Contains "OPEN QUESTIONS"  $output "additionalContext contains 'OPEN QUESTIONS'"

Write-Host ""
Write-Host "$($Script:Pass) passed · $($Script:Fail) failed"
if ($Script:Fail -gt 0) { exit 1 }
