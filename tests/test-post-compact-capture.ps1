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

$SCRIPT   = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts/post-compact-capture.ps1"
$FIXTURES = Join-Path $PSScriptRoot "fixtures"

# Test-isolation temp directory — never touches the user's real ~/.claude/
$TestHome = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()
New-Item -ItemType Directory -Path $TestHome | Out-Null
$env:COMPACT_OUTPUT_PATH = Join-Path $TestHome ".claude/last-compact-summary.md"
$env:COMPACT_BACKUP_PATH = Join-Path $TestHome ".claude/last-compact-summary.bak.md"
$OutputPath = $env:COMPACT_OUTPUT_PATH
$BackupPath = $env:COMPACT_BACKUP_PATH
New-Item -ItemType Directory -Path (Join-Path $TestHome ".claude") | Out-Null

function Cleanup {
    Remove-Item -Path $OutputPath -ErrorAction SilentlyContinue
    Remove-Item -Path $BackupPath -ErrorAction SilentlyContinue
}

# ── Test 1: valid transcript writes summary file ───────────────────────────────
Cleanup
$ValidFixture = (Join-Path $FIXTURES "transcript-valid.jsonl").Replace('\','/')
$JsonInput = '{"transcript_path":"' + $ValidFixture + '","trigger":"auto","session_id":"test-session-1"}'
$JsonInput | & $SCRIPT
$Wrote = if (Test-Path $OutputPath) { "yes" } else { "no" }
Assert-Eq "yes" $Wrote "valid transcript: summary file written"

# ── Test 2: summary file contains extracted content ───────────────────────────
$Content = if (Test-Path $OutputPath) { Get-Content -Path $OutputPath -Raw -Encoding UTF8 } else { "" }
Assert-Contains "Overall task" $Content "valid transcript: content contains task text"

# ── Test 3: metadata header ───────────────────────────────────────────────────
Assert-Contains "Captured:" $Content "valid transcript: metadata header present"
Assert-Contains "test-session-1" $Content "valid transcript: session_id in header"

# ── Test 4: no-boundary transcript uses fallback ──────────────────────────────
Cleanup
$NoBoundaryFixture = (Join-Path $FIXTURES "transcript-no-boundary.jsonl").Replace('\','/')
$JsonInput = '{"transcript_path":"' + $NoBoundaryFixture + '","trigger":"auto","session_id":"test-session-2"}'
$JsonInput | & $SCRIPT
$Wrote = if (Test-Path $OutputPath) { "yes" } else { "no" }
Assert-Eq "yes" $Wrote "no-boundary transcript: file still written (fallback)"

# ── Test 5: empty transcript writes diagnostic file ───────────────────────────
Cleanup
$EmptyFixture = (Join-Path $FIXTURES "transcript-empty.jsonl").Replace('\','/')
$JsonInput = '{"transcript_path":"' + $EmptyFixture + '","trigger":"auto","session_id":"test-session-2b"}'
$JsonInput | & $SCRIPT
$Wrote = if (Test-Path $OutputPath) { "yes" } else { "no" }
Assert-Eq "yes" $Wrote "empty transcript: diagnostic file still written"
$Content = if (Test-Path $OutputPath) { Get-Content -Path $OutputPath -Raw -Encoding UTF8 } else { "" }
Assert-Contains "EXTRACTION FAILED" $Content "empty transcript: diagnostic header present"

# ── Test 6: previous summary is rotated to .bak.md ────────────────────────────
Cleanup
Set-Content -Path $OutputPath -Value "old summary content" -Encoding UTF8
$JsonInput = '{"transcript_path":"' + $ValidFixture + '","trigger":"auto","session_id":"test-session-3"}'
$JsonInput | & $SCRIPT
$Backed = if (Test-Path $BackupPath) { "yes" } else { "no" }
Assert-Eq "yes" $Backed "previous summary rotated to .bak.md"
$BakContent = if (Test-Path $BackupPath) { Get-Content -Path $BackupPath -Raw -Encoding UTF8 } else { "" }
Assert-Contains "old summary content" $BakContent "backup contains original content"

# ── Test 7: malformed input exits cleanly, no file written ────────────────────
Cleanup
"not json" | & $SCRIPT 2>$null
$Wrote = if (Test-Path $OutputPath) { "yes" } else { "no" }
Assert-Eq "no" $Wrote "malformed input: no file written, exits 0"

# ── Test 8: relative transcript_path is rejected ──────────────────────────────
Cleanup
'{"transcript_path":"relative/path.jsonl","trigger":"auto","session_id":"x"}' | & $SCRIPT 2>$null
$Wrote = if (Test-Path $OutputPath) { "yes" } else { "no" }
Assert-Eq "no" $Wrote "relative transcript_path: rejected, no file written"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "$($Script:Pass) passed · $($Script:Fail) failed"
Remove-Item -Recurse -Force -Path $TestHome -ErrorAction SilentlyContinue
if ($Script:Fail -gt 0) { exit 1 }
