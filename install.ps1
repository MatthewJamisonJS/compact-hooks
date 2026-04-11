#Requires -Version 5.1
<#
.SYNOPSIS
    compact-hooks installer for Windows — installs PowerShell hook scripts.
.DESCRIPTION
    Installs pre-compact-summary.ps1 and post-compact-capture.ps1 into
    $env:USERPROFILE\.claude\scripts\, registers PreCompact and PostCompact
    hooks in settings.json, and prepends the Session Resume block to CLAUDE.md.

    Safe to re-run. Existing config is preserved; hooks are not duplicated.

.PARAMETER Preview
    Renders the completion screen with sample data. Nothing is installed.

.PARAMETER Details
    Shows full details before beginning installation.

.EXAMPLE
    irm https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.ps1 | iex
#>
[CmdletBinding()]
Param(
    [Parameter()][switch]$Preview,
    [Parameter()][switch]$Details
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── paths ─────────────────────────────────────────────────────────────────────
$UserHome     = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$ClaudeDir    = [System.IO.Path]::Combine($UserHome, '.claude')
$ScriptsDir   = [System.IO.Path]::Combine($ClaudeDir, 'scripts')
$SettingsPath = [System.IO.Path]::Combine($ClaudeDir, 'settings.json')
$ClaudeMdPath = [System.IO.Path]::Combine($ClaudeDir, 'CLAUDE.md')
$PreScript    = [System.IO.Path]::Combine($ScriptsDir, 'pre-compact-summary.ps1')
$PostScript   = [System.IO.Path]::Combine($ScriptsDir, 'post-compact-capture.ps1')
$SessionMarker = '# Session Resume'
$Total = 3

# ── helpers ───────────────────────────────────────────────────────────────────
function Write-Bar  { Write-Host ('─' * 56) -ForegroundColor DarkGray }
function Write-Hdr  { param([string]$Text) Write-Host "`n$Text" -ForegroundColor White }
function Write-Step { param([int]$N, [string]$Text) Write-Host "`n[$N/$Total] $Text" -ForegroundColor White }
function Write-Ok   { param([string]$Text) Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Skip { param([string]$Text) Write-Host "  – $Text" -ForegroundColor DarkGray }
function Write-Info { param([string]$Text) Write-Host "  → $Text" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Text) Write-Error "Error: $Text"; exit 1 }

function Get-FileStatus {
    [CmdletBinding()]
    Param([string]$Path)
    if ([System.IO.File]::Exists($Path)) { 'OVERWRITE' } else { 'NEW' }
}

function Invoke-Prompt {
    # Returns $true to proceed, $false to skip
    Write-Host '  ⏎ proceed   s skip   q abort  ' -NoNewline -ForegroundColor DarkGray
    $Response = Read-Host
    switch ($Response.ToLower()) {
        'q' { Write-Host "`nAborted."; exit 0 }
        's' { return $false }
        default { return $true }
    }
}

# ── resolve statuses ──────────────────────────────────────────────────────────
$StPre      = Get-FileStatus -Path $PreScript
$StPost     = Get-FileStatus -Path $PostScript
$StSettings = if ([System.IO.File]::Exists($SettingsPath)) { 'MERGE' } else { 'NEW' }
$StClaudeMd = if (
    [System.IO.File]::Exists($ClaudeMdPath) -and
    ([System.IO.File]::ReadAllText($ClaudeMdPath) -match [regex]::Escape($SessionMarker))
) { 'SKIP (already present)' } else { 'APPEND' }

# ── tracking ──────────────────────────────────────────────────────────────────
$Report = [System.Collections.Generic.List[PSCustomObject]]::new()
$Errors = [System.Collections.Generic.List[string]]::new()

function Add-ReportRow {
    [CmdletBinding()]
    Param([string]$Path, [string]$Action, [string]$Note)
    $Report.Add([PSCustomObject]@{ Path = $Path; Action = $Action; Note = $Note })
}

if (-not $Preview) {

    # ── pre-flight summary ────────────────────────────────────────────────────
    Write-Host ''
    Write-Bar
    Write-Hdr '  compact-hooks installer'
    Write-Bar
    Write-Host ''
    Write-Host 'What this installs:' -ForegroundColor White
    Write-Host '  ✦ 2 PowerShell hook scripts  → Claude Code hook execution engines'
    Write-Host '  ✦ 2 hook entries              → merged into settings.json (PreCompact + PostCompact)'
    Write-Host '  ✦ Session Resume block        → prepended to CLAUDE.md'
    Write-Host ''
    Write-Host 'Resolved paths:' -ForegroundColor White
    Write-Host ''
    Write-Host "  $PreScript" -NoNewline; Write-Host "  [$StPre]" -ForegroundColor DarkGray
    Write-Host "  $PostScript" -NoNewline; Write-Host "  [$StPost]" -ForegroundColor DarkGray
    Write-Host "  $SettingsPath" -NoNewline; Write-Host "  [$StSettings]" -ForegroundColor DarkGray
    Write-Host "  $ClaudeMdPath" -NoNewline; Write-Host "  [$StClaudeMd]" -ForegroundColor DarkGray
    Write-Host ''
    Write-Bar

    if ($Details) {
        Write-Hdr 'Details'
        Write-Host ''
        Write-Host 'pre-compact-summary.ps1  (PreCompact hook)' -ForegroundColor White
        Write-Host '  Runs before each compaction. Outputs a JSON payload that injects structured'
        Write-Host '  instructions into the compaction context, telling Claude to preserve:'
        Write-Host '  overall task, decision chain, current state, active files, last error, blockers.'
        Write-Host ''
        Write-Host 'post-compact-capture.ps1  (PostCompact hook, async)' -ForegroundColor White
        Write-Host "  Runs after compaction. Reads the session transcript, finds the compact_boundary,"
        Write-Host "  extracts Claude's summary, and writes it to:"
        Write-Host "    $([System.IO.Path]::Combine($ClaudeDir, 'last-compact-summary.md'))"
        Write-Host ''
        Write-Host 'settings.json — hooks to be merged:' -ForegroundColor White
        Write-Host "  PreCompact:  powershell -NoProfile -File `"$PreScript`""
        Write-Host "  PostCompact: powershell -NoProfile -File `"$PostScript`"  (async)"
        Write-Host ''
        Write-Bar
        Write-Host ''
        Write-Host '⏎ begin install   q = quit:  ' -NoNewline -ForegroundColor DarkGray
        $Confirm = Read-Host
        if ($Confirm -match '^[Qq]$') { Write-Host "`nAborted."; exit 0 }
    } else {
        Write-Host ''
        Write-Host 'd = full details   ⏎ = begin install   q = quit:  ' -NoNewline -ForegroundColor DarkGray
        $Initial = Read-Host
        switch ($Initial.ToLower()) {
            'q' { Write-Host "`nAborted."; exit 0 }
            'd' { & $PSCommandPath -Details; exit }
        }
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 1 — PowerShell scripts
    # ═══════════════════════════════════════════════════════════════════════════
    Write-Step -N 1 -Text "PowerShell scripts → $ScriptsDir"
    Write-Info 'pre-compact-summary.ps1  — inject context instructions before compaction'
    Write-Info 'post-compact-capture.ps1 — save compaction summary to disk'

    if (Invoke-Prompt) {
        try {
            [System.IO.Directory]::CreateDirectory($ScriptsDir) | Out-Null

            # Locate scripts/ relative to this installer (local run)
            $InstallerDir = $PSScriptRoot
            $LocalPre  = if ($InstallerDir) { [System.IO.Path]::Combine($InstallerDir, 'scripts', 'pre-compact-summary.ps1') } else { $null }
            $LocalPost = if ($InstallerDir) { [System.IO.Path]::Combine($InstallerDir, 'scripts', 'post-compact-capture.ps1') } else { $null }

            if ($LocalPre -and [System.IO.File]::Exists($LocalPre)) {
                [System.IO.File]::Copy($LocalPre,  $PreScript,  $true)
                [System.IO.File]::Copy($LocalPost, $PostScript, $true)
            } else {
                # Running via iex — fetch from GitHub
                # Enforce TLS 1.2+ for PowerShell 5.1 (defaults to TLS 1.0 on older Windows)
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
                $BaseUrl = 'https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/scripts'
                [System.Net.WebClient]::new().DownloadFile("$BaseUrl/pre-compact-summary.ps1",  $PreScript)
                [System.Net.WebClient]::new().DownloadFile("$BaseUrl/post-compact-capture.ps1", $PostScript)
            }

            Write-Ok 'pre-compact-summary.ps1'
            Write-Ok 'post-compact-capture.ps1'
            Add-ReportRow -Path $PreScript  -Action $StPre  -Note 'written'
            Add-ReportRow -Path $PostScript -Action $StPost -Note 'written'
        } catch {
            $Errors.Add("Step 1 failed: $_")
            Add-ReportRow -Path $PreScript -Action 'FAILED' -Note $_.ToString()
        }
    } else {
        Write-Skip 'Step 1 skipped'
        Add-ReportRow -Path $PreScript  -Action 'SKIPPED' -Note 'user skipped'
        Add-ReportRow -Path $PostScript -Action 'SKIPPED' -Note 'user skipped'
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 2 — Hook wiring
    # ═══════════════════════════════════════════════════════════════════════════
    Write-Step -N 2 -Text "Hook config → $SettingsPath"
    Write-Info 'Merges PreCompact + PostCompact entries (existing hooks preserved)'

    if (Invoke-Prompt) {
        try {
            $Settings = if ([System.IO.File]::Exists($SettingsPath)) {
                try {
                    [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
                } catch {
                    Write-Fail "settings.json is malformed — fix or delete it, then re-run. Error: $_"
                }
            } else {
                [PSCustomObject]@{}
            }

            if (-not $Settings.PSObject.Properties['hooks']) {
                $Settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([PSCustomObject]@{})
            }

            $PreHookCmd  = "powershell -NoProfile -File `"$PreScript`""
            $PostHookCmd = "powershell -NoProfile -File `"$PostScript`""

            # Idempotent: only add if not already registered
            if (-not $Settings.hooks.PSObject.Properties['PreCompact']) {
                $Settings.hooks | Add-Member -MemberType NoteProperty -Name 'PreCompact' -Value @(
                    [PSCustomObject]@{
                        hooks = @([PSCustomObject]@{
                            type          = 'command'
                            command       = $PreHookCmd
                            timeout       = 15
                            statusMessage = 'Capturing task context before compaction...'
                        })
                    }
                )
            }

            if (-not $Settings.hooks.PSObject.Properties['PostCompact']) {
                $Settings.hooks | Add-Member -MemberType NoteProperty -Name 'PostCompact' -Value @(
                    [PSCustomObject]@{
                        hooks = @([PSCustomObject]@{
                            type          = 'command'
                            command       = $PostHookCmd
                            timeout       = 15
                            async         = $true
                            statusMessage = 'Saving compaction summary...'
                        })
                    }
                )
            }

            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($SettingsPath)) | Out-Null
            $Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath -Encoding UTF8

            Write-Ok 'PreCompact hook registered'
            Write-Ok 'PostCompact hook registered'
            Add-ReportRow -Path $SettingsPath -Action $StSettings -Note 'PreCompact + PostCompact added'
        } catch {
            $Errors.Add("Step 2 failed: $_")
            Add-ReportRow -Path $SettingsPath -Action 'FAILED' -Note $_.ToString()
        }
    } else {
        Write-Skip 'Step 2 skipped'
        Add-ReportRow -Path $SettingsPath -Action 'SKIPPED' -Note 'user skipped'
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 3 — CLAUDE.md
    # ═══════════════════════════════════════════════════════════════════════════
    Write-Step -N 3 -Text "Session Resume → $ClaudeMdPath"
    Write-Info 'Prepends 2-line block instructing Claude to load the saved summary at session start'

    if ($StClaudeMd -eq 'SKIP (already present)') {
        Write-Ok 'Already present — no changes made'
        Add-ReportRow -Path $ClaudeMdPath -Action 'SKIPPED' -Note 'Session Resume already present'
    } elseif (Invoke-Prompt) {
        try {
            $Addition = @"
# Session Resume
If ``~/.claude/last-compact-summary.md`` exists, read it before doing anything else — it contains the task context and decision chain from the previous compaction.
"@
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($ClaudeMdPath)) | Out-Null

            $Existing = if ([System.IO.File]::Exists($ClaudeMdPath)) {
                [System.IO.File]::ReadAllText($ClaudeMdPath, [System.Text.Encoding]::UTF8)
            } else { '' }

            $NewContent = if ($Existing) { "$Addition`n`n$Existing" } else { $Addition }
            [System.IO.File]::WriteAllText($ClaudeMdPath, $NewContent, [System.Text.Encoding]::UTF8)

            Write-Ok 'Session Resume block added'
            Add-ReportRow -Path $ClaudeMdPath -Action $StClaudeMd -Note '2 lines prepended'
        } catch {
            $Errors.Add("Step 3 failed: $_")
            Add-ReportRow -Path $ClaudeMdPath -Action 'FAILED' -Note $_.ToString()
        }
    } else {
        Write-Skip 'Step 3 skipped'
        Add-ReportRow -Path $ClaudeMdPath -Action 'SKIPPED' -Note 'user skipped'
    }

} else {
    # ── preview ───────────────────────────────────────────────────────────────
    Add-ReportRow -Path $PreScript    -Action 'CREATED' -Note 'written'
    Add-ReportRow -Path $PostScript   -Action 'CREATED' -Note 'written'
    Add-ReportRow -Path $SettingsPath -Action 'MERGED'  -Note 'PreCompact + PostCompact added'
    Add-ReportRow -Path $ClaudeMdPath -Action 'SKIPPED' -Note 'Session Resume already present'
}

# ── completion screen ─────────────────────────────────────────────────────────
$NOk   = ($Report | Where-Object { $_.Action -notin @('SKIPPED','FAILED') }).Count
$NSkip = ($Report | Where-Object { $_.Action -eq 'SKIPPED' }).Count
$NFail = $Errors.Count

Write-Host ''
Write-Host ('━' * 56) -ForegroundColor Magenta
Write-Host '  ✓  compact-hooks' -NoNewline -ForegroundColor Magenta
Write-Host '  session context survives compaction' -ForegroundColor DarkGray
Write-Host ('━' * 56) -ForegroundColor Magenta
Write-Host ''

$Parts = @()
if ($NOk)   { $Parts += "$NOk changed" }
if ($NSkip) { $Parts += "$NSkip skipped" }
if ($NFail) { $Parts += "$NFail failed" }
Write-Host ('  ' + ($Parts -join '   '))
Write-Host ''

foreach ($Row in $Report) {
    $Color = switch ($Row.Action) {
        'CREATED'     { 'Green' }
        'MERGED'      { 'Cyan' }
        'OVERWRITTEN' { 'Yellow' }
        'SKIPPED'     { 'DarkGray' }
        'FAILED'      { 'Red' }
        default       { 'White' }
    }
    Write-Host "  $($Row.Path)" -NoNewline
    Write-Host "  [$($Row.Action)]" -ForegroundColor $Color
    if ($Row.Note) { Write-Host "    $($Row.Note)" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('─' * 56) -ForegroundColor DarkGray
Write-Host '  Verify:  /hooks in Claude Code  ·  /compact to test' -ForegroundColor Cyan
if ($NFail -gt 0) {
    Write-Host '  Issues:  .\doctor.ps1' -ForegroundColor Yellow
    foreach ($E in $Errors) { Write-Host "  ✗ $E" -ForegroundColor Red }
    & "$PSScriptRoot\doctor.ps1"
} else {
    Write-Host '  Issues?  .\doctor.ps1' -ForegroundColor DarkGray
}
Write-Host ''
