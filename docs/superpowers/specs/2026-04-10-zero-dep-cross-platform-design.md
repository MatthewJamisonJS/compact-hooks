# Design: Zero-Dependency Cross-Platform Rewrite

**Date:** 2026-04-10
**Status:** Approved

---

## Context

`compact-hooks` currently requires Python 3.7+ on every machine it runs on. The hook scripts (`pre-compact-summary.py`, `post-compact-capture.py`) use Python purely for JSON I/O and file parsing — nothing that justifies the dependency. The installer (`install.sh`) is Bash-only, making the project entirely inaccessible to Windows users who don't run WSL or Git Bash.

This design covers three coordinated improvements:

1. **Windows installer** — a native PowerShell installer and doctor that mirror their Bash counterparts
2. **Zero-dependency hook scripts** — rewrite both hooks in Bash (macOS/Linux) and PowerShell (Windows), eliminating Python entirely
3. **Silent failure resilience + richer preservation** — fix the post-compact script's silent failure modes and upgrade the pre-compact preservation prompt

---

## PowerShell code standards

The PowerShell scripts must be idiomatic — not bash translated to PowerShell. Required conventions:

- `[CmdletBinding()]` on all scripts and functions
- `Param()` blocks with `[Parameter()]` attributes and explicit type annotations (`[string]`, `[bool]`, `[switch]`)
- `try/catch/finally` for all file I/O and JSON operations
- `Write-Host` for user-facing output, `Write-Error` for errors, `Write-Verbose` for diagnostics (never `echo`)
- PascalCase variables and function names
- `[PSCustomObject]` for structured data
- `.NET` class methods (`[System.IO.File]::ReadAllText()`, `[System.IO.Path]::Combine()`) where cleaner than cmdlets
- `#Requires -Version 5.1` at the top of every script
- Named parameters at all call sites — no positional usage
- Error messages that say what to do, not just what broke

---

## Improvement 1: Windows installer

### Files

| File | Action |
|---|---|
| `install.ps1` | New — mirrors `install.sh` step-for-step |
| `doctor.ps1` | New — mirrors `doctor.sh` check-for-check |

### install.ps1 behavior

- **Pre-flight**: resolves `$env:USERPROFILE\.claude\` paths, detects NEW / OVERWRITE / MERGE state for each target, no dependency checks (none needed)
- **Step 1**: writes `.ps1` hook scripts to `~\.claude\scripts\`
- **Step 2**: merges hook entries into `settings.json` using `ConvertFrom-Json` / `ConvertTo-Json`; idempotent — checks whether the hook command already exists before adding
- **Step 3**: prepends Session Resume block to `CLAUDE.md` if the marker string isn't already present
- **`--preview` flag**: dry-run that prints what would happen without touching anything
- Install one-liner: `irm https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.ps1 | iex`

### doctor.ps1 behavior

Runs the same 8 checks as `doctor.sh` with these differences:

- No executable bit check (not applicable on Windows)
- Adds one check: PowerShell execution policy permits script execution; auto-fixes with `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`
- Same auto-fix logic: re-adds missing hooks to `settings.json`, re-prepends missing CLAUDE.md block
- Same result table format (PASS / FIXED / WARN / FAIL)

---

## Improvement 2: Zero-dependency hook scripts

### Approach: platform-native split

Two script variants per hook. The installer places the correct variant and writes the correct hook command for the detected platform.

**Hook command format:**

| Platform | Command |
|---|---|
| macOS / Linux | `bash ~/.claude/scripts/pre-compact-summary.sh` |
| Windows | `powershell -NoProfile -File ~/.claude/scripts/pre-compact-summary.ps1` |

### New files

| File | Replaces |
|---|---|
| `scripts/pre-compact-summary.sh` | `pre-compact-summary.py` |
| `scripts/pre-compact-summary.ps1` | `pre-compact-summary.py` (Windows) |
| `scripts/post-compact-capture.sh` | `post-compact-capture.py` |
| `scripts/post-compact-capture.ps1` | `post-compact-capture.py` (Windows) |

### Removed files

- `pre-compact-summary.py`
- `post-compact-capture.py`

### JSON handling

- **Bash**: `grep -o` + `cut` for field extraction from known JSON schemas; `printf` + heredoc for output construction
- **PowerShell**: `ConvertFrom-Json` / `ConvertTo-Json` for all JSON I/O

### Updates to existing files

- `install.sh`: installs `.sh` scripts (not `.py`); writes `bash ~/.claude/scripts/...` hook commands
- `doctor.sh`: checks for `.sh` filenames; dry-run executes `.sh` scripts
- `settings-hooks-snippet.json`: updated to show `.sh` hook commands

---

## Improvement 3: Silent failure resilience + richer preservation

### post-compact-capture.sh / .ps1

**Primary extraction** (unchanged): find `compact_boundary` system event, match assistant message by `parentUuid`.

**Fallback extraction** (new): if no boundary event found or UUID match fails, scan backward through the transcript for the last assistant message with non-empty `content`. Something is better than nothing.

**Summary rotation** (new): before writing `last-compact-summary.md`, move the existing file to `last-compact-summary.bak.md`. A bad extraction never destroys a known-good previous summary.

**Diagnostic on failure** (new): if both extraction paths return empty, write `last-compact-summary.md` with an `[EXTRACTION FAILED: <reason>]` header so the next session knows the summary is not trustworthy. Reasons: `no compact_boundary found`, `no content after boundary`, `transcript unreadable`.

### pre-compact-summary.sh / .ps1

The `additional_context` payload gains two new required sections and the existing four get sharper directives:

**New sections:**

- `ACTIVE FILES` — exact paths of files read, written, or edited this session; list them explicitly, not by description
- `LAST ERROR` — most recent error message or exception, quoted verbatim, with whether it was resolved

**Upgraded existing directives:**

- OVERALL TASK: one-sentence goal *and* the acceptance criteria for done
- DECISION CHAIN: "why X over Y" reasoning, not just what was chosen; include constraints or discoveries that changed the approach
- CURRENT STATE: specific function names or line numbers for anything in-progress, not just file names
- OPEN QUESTIONS: unresolved error messages quoted directly, not paraphrased

---

## Updates to existing files

| File | Changes |
|---|---|
| `install.sh` | Install `.sh` scripts instead of `.py`; write `bash ~/.claude/scripts/...` hook commands; remove Python pre-flight check |
| `doctor.sh` | Check for `.sh` filenames; dry-run `.sh` scripts; remove Python checks |
| `settings-hooks-snippet.json` | Update hook commands to `bash ~/.claude/scripts/...` |
| `README.md` | Add Windows install section; update "What it installs" table; update requirements table (remove Python row); update "Files in this repo" section |

---

## Verification

1. **macOS/Linux install**: run `bash install.sh` on a clean machine (or VM); confirm `.sh` scripts appear in `~/.claude/scripts/`, hook entries appear in `settings.json`, Session Resume block appears in `CLAUDE.md`
2. **Windows install**: run `install.ps1` on a Windows machine; confirm `.ps1` scripts appear, hooks registered, CLAUDE.md updated
3. **Hook execution**: open Claude Code, run `/compact`; confirm `Capturing task context...` and `Saving compaction summary...` status messages appear; confirm `~/.claude/last-compact-summary.md` is written
4. **Fallback extraction**: corrupt the transcript boundary in a test run; confirm a summary is still written with fallback content (not a silent failure)
5. **Diagnostic on total failure**: feed an empty transcript; confirm `[EXTRACTION FAILED]` is written rather than silently skipping
6. **Idempotency**: run both installers twice; confirm no duplicate hook entries, no duplicated CLAUDE.md blocks
7. **doctor checks**: after install, run `doctor.sh` (macOS) and `doctor.ps1` (Windows); confirm all checks pass
8. **Richer prompt**: trigger a compaction and read the resulting summary; confirm ACTIVE FILES and LAST ERROR sections are present
