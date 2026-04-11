#Requires -Version 5.1
<#
.SYNOPSIS
    compact-hooks doctor for Windows — checks installation health and auto-fixes what it can.
.DESCRIPTION
    Runs 8 checks. Auto-fixes: missing execution policy, missing hook entries,
    missing CLAUDE.md Session Resume block. Reports what it cannot fix.
#>
[CmdletBinding()]
Param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UserHome     = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$ClaudeDir    = [System.IO.Path]::Combine($UserHome, '.claude')
$ScriptsDir   = [System.IO.Path]::Combine($ClaudeDir, 'scripts')
$SettingsPath = [System.IO.Path]::Combine($ClaudeDir, 'settings.json')
$ClaudeMdPath = [System.IO.Path]::Combine($ClaudeDir, 'CLAUDE.md')
$PreScript    = [System.IO.Path]::Combine($ScriptsDir, 'pre-compact-summary.ps1')
$PostScript   = [System.IO.Path]::Combine($ScriptsDir, 'post-compact-capture.ps1')
$SessionMarker = '# Session Resume'

$Checks = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Check {
    [CmdletBinding()]
    Param([string]$Label, [string]$Result, [string]$Action = '')
    $Checks.Add([PSCustomObject]@{ Label = $Label; Result = $Result; Action = $Action })
}

# ── 1. PowerShell execution policy ───────────────────────────────────────────
$Policy = Get-ExecutionPolicy -Scope CurrentUser
if ($Policy -in @('Unrestricted', 'RemoteSigned', 'Bypass')) {
    Add-Check -Label 'Execution policy allows scripts' -Result 'PASS' -Action $Policy
} else {
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Add-Check -Label 'Execution policy allows scripts' -Result 'FIXED' -Action 'Set to RemoteSigned'
    } catch {
        Add-Check -Label 'Execution policy allows scripts' -Result 'FAIL' -Action 'Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser'
    }
}

# ── 2-3. Script files exist ───────────────────────────────────────────────────
foreach ($Script in @($PreScript, $PostScript)) {
    $Name = [System.IO.Path]::GetFileName($Script)
    if ([System.IO.File]::Exists($Script)) {
        Add-Check -Label "$Name exists" -Result 'PASS'
    } else {
        Add-Check -Label "$Name exists" -Result 'FAIL' -Action 're-run install.ps1 to restore'
    }
}

# ── 4. settings.json valid ────────────────────────────────────────────────────
if (-not [System.IO.File]::Exists($SettingsPath)) {
    Add-Check -Label 'settings.json exists' -Result 'FAIL' -Action 're-run install.ps1'
} else {
    try {
        $Settings = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
        Add-Check -Label 'settings.json valid JSON' -Result 'PASS'

        # ── 5-6. Hook entries ─────────────────────────────────────────────────
        foreach ($HookName in @('PreCompact', 'PostCompact')) {
            $Existing = $Settings.hooks.PSObject.Properties[$HookName]
            if ($Existing) {
                Add-Check -Label "$HookName hook registered" -Result 'PASS'
            } else {
                try {
                    $PreCmd  = "powershell -NoProfile -File `"$PreScript`""
                    $PostCmd = "powershell -NoProfile -File `"$PostScript`""
                    $NewEntry = if ($HookName -eq 'PreCompact') {
                        @([PSCustomObject]@{ hooks = @([PSCustomObject]@{
                            type = 'command'; command = $PreCmd; timeout = 15
                            statusMessage = 'Capturing task context...'
                        })})
                    } else {
                        @([PSCustomObject]@{ hooks = @([PSCustomObject]@{
                            type = 'command'; command = $PostCmd; timeout = 15
                            async = $true; statusMessage = 'Saving summary...'
                        })})
                    }
                    if (-not $Settings.PSObject.Properties['hooks']) {
                        $Settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([PSCustomObject]@{})
                    }
                    $Settings.hooks | Add-Member -MemberType NoteProperty -Name $HookName -Value $NewEntry -Force
                    $Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath -Encoding UTF8
                    Add-Check -Label "$HookName hook registered" -Result 'FIXED' -Action 'hook entry added'
                } catch {
                    Add-Check -Label "$HookName hook registered" -Result 'FAIL' -Action 'add manually — see settings-hooks-snippet.json'
                }
            }
        }
    } catch {
        Add-Check -Label 'settings.json valid JSON' -Result 'FAIL' -Action 'file is malformed — re-run install.ps1'
    }
}

# ── 7. CLAUDE.md Session Resume ───────────────────────────────────────────────
$HasResume = [System.IO.File]::Exists($ClaudeMdPath) -and
             ([System.IO.File]::ReadAllText($ClaudeMdPath) -match [regex]::Escape($SessionMarker))
if ($HasResume) {
    Add-Check -Label 'CLAUDE.md has Session Resume' -Result 'PASS'
} else {
    try {
        $Addition = "# Session Resume`nIf ``~/.claude/last-compact-summary.md`` exists, read it before doing anything else — it contains the task context and decision chain from the previous compaction."
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($ClaudeMdPath)) | Out-Null
        $Existing = if ([System.IO.File]::Exists($ClaudeMdPath)) {
            [System.IO.File]::ReadAllText($ClaudeMdPath, [System.Text.Encoding]::UTF8)
        } else { '' }
        $New = if ($Existing) { "$Addition`n`n$Existing" } else { $Addition }
        [System.IO.File]::WriteAllText($ClaudeMdPath, $New, [System.Text.Encoding]::UTF8)
        Add-Check -Label 'CLAUDE.md has Session Resume' -Result 'FIXED' -Action 'block prepended'
    } catch {
        Add-Check -Label 'CLAUDE.md has Session Resume' -Result 'FAIL' -Action 're-run install.ps1'
    }
}

# ── 8. Dry-run pre-compact-summary.ps1 ───────────────────────────────────────
if ([System.IO.File]::Exists($PreScript)) {
    try {
        $DryOutput = '{"trigger":"auto"}' | & $PreScript | ConvertFrom-Json
        if ($DryOutput.hookSpecificOutput.hookEventName -eq 'PreCompact') {
            Add-Check -Label 'pre-compact-summary.ps1 dry-run' -Result 'PASS' -Action 'JSON output valid'
        } else {
            Add-Check -Label 'pre-compact-summary.ps1 dry-run' -Result 'FAIL' -Action 're-run install.ps1'
        }
    } catch {
        Add-Check -Label 'pre-compact-summary.ps1 dry-run' -Result 'FAIL' -Action "script error: $_"
    }
} else {
    Add-Check -Label 'pre-compact-summary.ps1 dry-run' -Result 'WARN' -Action 'skipped (script missing)'
}

# ── render report ─────────────────────────────────────────────────────────────
$NPass  = ($Checks | Where-Object { $_.Result -eq 'PASS' }).Count
$NFixed = ($Checks | Where-Object { $_.Result -eq 'FIXED' }).Count
$NWarn  = ($Checks | Where-Object { $_.Result -eq 'WARN' }).Count
$NFail  = ($Checks | Where-Object { $_.Result -eq 'FAIL' }).Count

Write-Host ''
Write-Host ('━' * 56) -ForegroundColor Magenta
Write-Host '  compact-hooks doctor' -ForegroundColor Magenta
Write-Host ('━' * 56) -ForegroundColor Magenta
Write-Host ''

$Parts = @()
if ($NPass)  { $Parts += "$NPass pass" }
if ($NFixed) { $Parts += "$NFixed fixed" }
if ($NWarn)  { $Parts += "$NWarn warn" }
if ($NFail)  { $Parts += "$NFail fail" }
Write-Host ('  ' + ($Parts -join '   '))
Write-Host ''

foreach ($Check in $Checks) {
    $Icon  = switch ($Check.Result) { 'PASS' { '✓' } 'FIXED' { '✦' } 'WARN' { '!' } 'FAIL' { '✗' } default { '?' } }
    $Color = switch ($Check.Result) { 'PASS' { 'Green' } 'FIXED' { 'Cyan' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'White' } }
    Write-Host "  $Icon " -NoNewline -ForegroundColor $Color
    Write-Host "$($Check.Label)" -NoNewline
    if ($Check.Action) { Write-Host "  — $($Check.Action)" -ForegroundColor DarkGray } else { Write-Host '' }
}

Write-Host ''
Write-Host ('─' * 56) -ForegroundColor DarkGray

if ($NFail -eq 0 -and $NFixed -eq 0) {
    Write-Host '  All checks pass. No action needed.' -ForegroundColor Green
} elseif ($NFail -eq 0) {
    Write-Host "  $NFixed issue(s) auto-fixed. Restart Claude Code to pick up changes." -ForegroundColor Cyan
} else {
    Write-Host "  $NFail issue(s) require manual action. Re-run install.ps1." -ForegroundColor Red
}
Write-Host ''
