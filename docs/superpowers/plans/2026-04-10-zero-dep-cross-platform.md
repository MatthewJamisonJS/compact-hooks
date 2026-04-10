# Zero-Dependency Cross-Platform Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Python hook scripts with platform-native equivalents (bash + PowerShell), add a Windows installer, and improve resilience and preservation quality — zero runtime dependencies on any platform.

**Architecture:** Two script variants per hook (`.sh` for macOS/Linux, `.ps1` for Windows) installed by the corresponding platform installer. The bash versions use `grep`/`awk` for JSON I/O; the PowerShell versions use `ConvertFrom-Json`/`ConvertTo-Json`. Both share the same resilience design: fallback extraction, summary rotation, and diagnostic output on failure.

**Tech Stack:** bash 3.2+ (macOS ships 3.2), PowerShell 5.1+ (built into Windows), `grep -oE`, `awk`, `sed`, `[System.IO.File]`, `ConvertFrom-Json`

---

## File map

| Action | Path | Responsibility |
|---|---|---|
| Create | `scripts/pre-compact-summary.sh` | bash PreCompact hook |
| Create | `scripts/pre-compact-summary.ps1` | PowerShell PreCompact hook |
| Create | `scripts/post-compact-capture.sh` | bash PostCompact hook (with resilience) |
| Create | `scripts/post-compact-capture.ps1` | PowerShell PostCompact hook (with resilience) |
| Create | `install.ps1` | Windows installer, mirrors `install.sh` |
| Create | `doctor.ps1` | Windows doctor, mirrors `doctor.sh` |
| Create | `tests/test-pre-compact-summary.sh` | bash tests for pre-compact hook |
| Create | `tests/test-post-compact-capture.sh` | bash tests for post-compact hook |
| Create | `tests/Compact-Hooks.Tests.ps1` | Pester tests for both PS hooks |
| Create | `tests/fixtures/transcript-valid.jsonl` | mock transcript with compact_boundary |
| Create | `tests/fixtures/transcript-no-boundary.jsonl` | mock transcript missing boundary |
| Create | `tests/fixtures/transcript-empty.jsonl` | empty transcript |
| Modify | `install.sh` | install `.sh` scripts; write `bash ...` hook commands; drop Python preflight |
| Modify | `doctor.sh` | check `.sh` filenames; dry-run `.sh`; remove Python checks |
| Modify | `settings-hooks-snippet.json` | update hook commands to `bash ...` |
| Modify | `README.md` | add Windows section; update tables; remove Python row |
| Delete | `pre-compact-summary.py` | replaced by shell variants |
| Delete | `post-compact-capture.py` | replaced by shell variants |

---

## Task 1: Test fixtures

**Files:**
- Create: `tests/fixtures/transcript-valid.jsonl`
- Create: `tests/fixtures/transcript-no-boundary.jsonl`
- Create: `tests/fixtures/transcript-empty.jsonl`

- [ ] **Step 1: Create the fixtures directory**

```bash
mkdir -p tests/fixtures
```

- [ ] **Step 2: Write the valid transcript fixture**

Create `tests/fixtures/transcript-valid.jsonl` with these exact lines (one JSON object per line):

```
{"uuid":"msg-001","type":"user","parentUuid":null,"message":{"role":"user","content":"Help me build a feature"}}
{"uuid":"msg-002","type":"assistant","parentUuid":"msg-001","message":{"role":"assistant","content":"Sure, let me help."}}
{"uuid":"boundary-001","type":"system","subtype":"compact_boundary"}
{"uuid":"msg-003","type":"user","parentUuid":"boundary-001","message":{"role":"user","content":"Overall task: build a login feature.\n\nDecision chain: chose JWT over sessions.\n\nCurrent state: in progress.\n\nActive files: src/auth.ts\n\nLast error: none.\n\nOpen questions: none."}}
```

- [ ] **Step 3: Write the no-boundary transcript fixture**

Create `tests/fixtures/transcript-no-boundary.jsonl`:

```
{"uuid":"msg-001","type":"user","parentUuid":null,"message":{"role":"user","content":"Hello"}}
{"uuid":"msg-002","type":"assistant","parentUuid":"msg-001","message":{"role":"assistant","content":"Hi there, how can I help?"}}
```

- [ ] **Step 4: Write the empty transcript fixture**

Create `tests/fixtures/transcript-empty.jsonl` as an empty file:

```bash
touch tests/fixtures/transcript-empty.jsonl
```

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/
git commit -m "test: add mock transcript fixtures for hook script tests"
```

---

## Task 2: pre-compact-summary.sh

**Files:**
- Create: `tests/test-pre-compact-summary.sh`
- Create: `scripts/pre-compact-summary.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-pre-compact-summary.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/pre-compact-summary.sh"
PASS=0; FAIL=0

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    printf '  ✓ %s\n' "$3"; ((PASS++))
  else
    printf '  ✗ %s\n    expected: [%s]\n    got:      [%s]\n' "$3" "$1" "$2"; ((FAIL++))
  fi
}

assert_contains() {
  if printf '%s' "$2" | grep -qF "$1"; then
    printf '  ✓ %s\n' "$3"; ((PASS++))
  else
    printf '  ✗ %s\n    expected to contain: %s\n' "$3" "$1"; ((FAIL++))
  fi
}

# Test 1: outputs hookEventName=PreCompact for auto trigger
OUTPUT=$(printf '{"trigger":"auto"}' | bash "$SCRIPT")
HOOK=$(printf '%s' "$OUTPUT" | grep -o '"hookEventName":"[^"]*"' | cut -d'"' -f4)
assert_eq "PreCompact" "$HOOK" "auto trigger: hookEventName=PreCompact"

# Test 2: systemMessage contains [Auto] for auto trigger
OUTPUT=$(printf '{"trigger":"auto"}' | bash "$SCRIPT")
assert_contains "[Auto]" "$OUTPUT" "auto trigger: systemMessage contains [Auto]"

# Test 3: systemMessage contains [Manual] for manual trigger
OUTPUT=$(printf '{"trigger":"manual"}' | bash "$SCRIPT")
assert_contains "[Manual]" "$OUTPUT" "manual trigger: systemMessage contains [Manual]"

# Test 4: unknown trigger defaults to auto
OUTPUT=$(printf '{"trigger":"bogus"}' | bash "$SCRIPT")
assert_contains "[Auto]" "$OUTPUT" "unknown trigger falls back to auto"

# Test 5: malformed input does not crash (fail open)
OUTPUT=$(printf 'not json at all' | bash "$SCRIPT" 2>/dev/null && echo "exited_ok" || echo "crashed")
assert_eq "exited_ok" "$OUTPUT" "malformed input: script exits 0"

# Test 6: additionalContext contains all 6 required sections
OUTPUT=$(printf '{"trigger":"auto"}' | bash "$SCRIPT")
for SECTION in "OVERALL TASK" "DECISION CHAIN" "CURRENT STATE" "ACTIVE FILES" "LAST ERROR" "OPEN QUESTIONS"; do
  assert_contains "$SECTION" "$OUTPUT" "additionalContext contains '$SECTION'"
done

printf '\n%d passed · %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run the test — verify it fails**

```bash
bash tests/test-pre-compact-summary.sh
```

Expected: error because `scripts/pre-compact-summary.sh` does not exist yet.

- [ ] **Step 3: Create the scripts directory and write the implementation**

```bash
mkdir -p scripts
```

Create `scripts/pre-compact-summary.sh`:

```bash
#!/usr/bin/env bash
# PreCompact hook — injects context preservation instructions into compaction.
#
# Input (stdin):  {"trigger":"auto"|"manual"}
# Output (stdout): JSON payload with hookSpecificOutput and systemMessage
#
# Security: reads stdin only; no shell interpolation of external values into commands;
# CONTEXT is a literal constant — not derived from user input.

set -euo pipefail

INPUT=$(cat)

# Extract trigger; default to "auto" for any unknown or missing value.
# || true prevents grep's exit-1-on-no-match from aborting under set -e.
TRIGGER=$(printf '%s' "$INPUT" | grep -oE '"trigger":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
case "$TRIGGER" in
  auto|manual) ;;
  *) TRIGGER="auto" ;;
esac

# Capitalize first letter for display (bash 3.2 compatible — no ${var^})
LABEL=$(printf '%s' "$TRIGGER" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')

# \n in single-quoted strings are literal backslash-n — correct for JSON string embedding.
# A JSON parser receiving this output will interpret \n as newline.
# The em dash is valid UTF-8 in a JSON string.
CONTEXT='COMPACTION IMMINENT \u2014 your summary MUST preserve ALL of the following:\n\n1. OVERALL TASK\n   What is the user ultimately trying to accomplish? Include the acceptance criteria for done.\n\n2. DECISION CHAIN\n   Key decisions made this session: what was chosen, why X over Y, what constraint or discovery drove it.\n\n3. CURRENT STATE\n   Done / in-progress (specific function names or line numbers) / remaining.\n\n4. ACTIVE FILES\n   Exact paths of every file read, written, or edited this session.\n\n5. LAST ERROR\n   Most recent error message, quoted verbatim. State whether it was resolved.\n\n6. OPEN QUESTIONS\n   Unresolved questions or blockers. Quote error messages directly \u2014 do not paraphrase.\n\nThis structured context must survive compaction intact so work can resume without losing the logical thread.'

# Escape any double quotes in CONTEXT for safe JSON string embedding.
ESCAPED=$(printf '%s' "$CONTEXT" | sed 's/"/\\"/g')

printf '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":"%s"},"systemMessage":"[%s] compaction triggered. Capturing task context..."}\n' \
  "$ESCAPED" \
  "$LABEL"
```

- [ ] **Step 4: Run the test — verify it passes**

```bash
bash tests/test-pre-compact-summary.sh
```

Expected: `11 passed · 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/pre-compact-summary.sh tests/test-pre-compact-summary.sh
git commit -m "feat: add pre-compact-summary.sh — bash PreCompact hook, no Python required"
```

---

## Task 3: post-compact-capture.sh

**Files:**
- Create: `tests/test-post-compact-capture.sh`
- Create: `scripts/post-compact-capture.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-post-compact-capture.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/post-compact-capture.sh"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
OUTPUT_PATH="${HOME}/.claude/last-compact-summary.md"
BACKUP_PATH="${HOME}/.claude/last-compact-summary.bak.md"
PASS=0; FAIL=0

cleanup() { rm -f "$OUTPUT_PATH" "$BACKUP_PATH"; }
trap cleanup EXIT

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    printf '  ✓ %s\n' "$3"; ((PASS++))
  else
    printf '  ✗ %s\n    expected: [%s]\n    got:      [%s]\n' "$3" "$1" "$2"; ((FAIL++))
  fi
}

assert_contains() {
  if printf '%s' "$2" | grep -qF "$1"; then
    printf '  ✓ %s\n' "$3"; ((PASS++))
  else
    printf '  ✗ %s\n    expected to contain: [%s]\n    in: [%s]\n' "$3" "$1" "$2"; ((FAIL++))
  fi
}

# Test 1: valid transcript writes summary file
cleanup
INPUT=$(printf '{"transcript_path":"%s","trigger":"auto","session_id":"test-session-1"}' \
  "${FIXTURES}/transcript-valid.jsonl")
printf '%s' "$INPUT" | bash "$SCRIPT"
WROTE=$([[ -f "$OUTPUT_PATH" ]] && echo "yes" || echo "no")
assert_eq "yes" "$WROTE" "valid transcript: summary file written"

# Test 2: summary file contains the extracted content
CONTENT=$(cat "$OUTPUT_PATH" 2>/dev/null || echo "")
assert_contains "Overall task" "$CONTENT" "valid transcript: content contains task text"

# Test 3: summary file contains metadata header
assert_contains "Captured:" "$CONTENT" "valid transcript: metadata header present"
assert_contains "test-session-1" "$CONTENT" "valid transcript: session_id in header"

# Test 4: no-boundary transcript still writes a file (fallback to last assistant message)
cleanup
INPUT=$(printf '{"transcript_path":"%s","trigger":"auto","session_id":"test-session-2"}' \
  "${FIXTURES}/transcript-no-boundary.jsonl")
printf '%s' "$INPUT" | bash "$SCRIPT"
WROTE=$([[ -f "$OUTPUT_PATH" ]] && echo "yes" || echo "no")
assert_eq "yes" "$WROTE" "no-boundary transcript: file still written (fallback)"

# Test 4b: empty transcript (no content at all) writes diagnostic file
cleanup
INPUT=$(printf '{"transcript_path":"%s","trigger":"auto","session_id":"test-session-2b"}' \
  "${FIXTURES}/transcript-empty.jsonl")
printf '%s' "$INPUT" | bash "$SCRIPT"
WROTE=$([[ -f "$OUTPUT_PATH" ]] && echo "yes" || echo "no")
assert_eq "yes" "$WROTE" "empty transcript: diagnostic file still written"
CONTENT=$(cat "$OUTPUT_PATH" 2>/dev/null || echo "")
assert_contains "EXTRACTION FAILED" "$CONTENT" "empty transcript: diagnostic header present"

# Test 5: previous summary is rotated to .bak.md before overwrite
cleanup
printf 'old summary content' > "$OUTPUT_PATH"
INPUT=$(printf '{"transcript_path":"%s","trigger":"auto","session_id":"test-session-3"}' \
  "${FIXTURES}/transcript-valid.jsonl")
printf '%s' "$INPUT" | bash "$SCRIPT"
BACKED=$([[ -f "$BACKUP_PATH" ]] && echo "yes" || echo "no")
assert_eq "yes" "$BACKED" "previous summary rotated to .bak.md"
BAK_CONTENT=$(cat "$BACKUP_PATH" 2>/dev/null || echo "")
assert_contains "old summary content" "$BAK_CONTENT" "backup contains original content"

# Test 6: malformed input exits cleanly without writing
cleanup
printf 'not json' | bash "$SCRIPT" 2>/dev/null
WROTE=$([[ -f "$OUTPUT_PATH" ]] && echo "yes" || echo "no")
assert_eq "no" "$WROTE" "malformed input: no file written, exits 0"

# Test 7: relative path in transcript_path is rejected
cleanup
INPUT='{"transcript_path":"relative/path.jsonl","trigger":"auto","session_id":"x"}'
printf '%s' "$INPUT" | bash "$SCRIPT" 2>/dev/null
WROTE=$([[ -f "$OUTPUT_PATH" ]] && echo "yes" || echo "no")
assert_eq "no" "$WROTE" "relative transcript_path: rejected, no file written"

printf '\n%d passed · %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run the test — verify it fails**

```bash
bash tests/test-post-compact-capture.sh
```

Expected: error because `scripts/post-compact-capture.sh` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `scripts/post-compact-capture.sh`:

```bash
#!/usr/bin/env bash
# PostCompact hook — extracts compaction summary from transcript and saves it.
#
# Input (stdin):  {"transcript_path":"/abs/path","trigger":"auto","session_id":"..."}
# Output:         writes ~/.claude/last-compact-summary.md
#
# Resilience:
#   - Fallback extraction if primary (parentUuid match) finds nothing
#   - Rotates existing summary to .bak.md before overwriting
#   - Writes a diagnostic file on failure so the next session knows not to trust it
#
# Security: transcript_path validated as absolute before use; no eval or shell interpolation.

set -euo pipefail

OUTPUT_PATH="${HOME}/.claude/last-compact-summary.md"
BACKUP_PATH="${HOME}/.claude/last-compact-summary.bak.md"

INPUT=$(cat)

# Extract fields; || true prevents grep exit-1 from aborting under set -e
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | grep -oE '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
TRIGGER=$(printf '%s' "$INPUT" | grep -oE '"trigger":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
SESSION_ID=$(printf '%s' "$INPUT" | grep -oE '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

[[ -z "$TRANSCRIPT_PATH" ]] && exit 0
# Reject relative paths (path traversal guard)
[[ "${TRANSCRIPT_PATH:0:1}" != "/" ]] && exit 0
[[ ! -f "$TRANSCRIPT_PATH" ]] && exit 0

[[ -z "$TRIGGER" ]]    && TRIGGER="auto"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

# ── extraction ────────────────────────────────────────────────────────────────

SUMMARY=""
FAILURE_REASON=""

# Step 1: find the compact_boundary UUID (last occurrence wins)
BOUNDARY_UUID=""
while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  if printf '%s' "$LINE" | grep -qF '"subtype":"compact_boundary"'; then
    BOUNDARY_UUID=$(printf '%s' "$LINE" | grep -oE '"uuid":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  fi
done < "$TRANSCRIPT_PATH"

# Step 2 (primary): find user entry whose parentUuid matches the boundary
if [[ -n "$BOUNDARY_UUID" ]]; then
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    if printf '%s' "$LINE" | grep -qF "\"parentUuid\":\"${BOUNDARY_UUID}\""; then
      # Extract JSON string value — handles escape sequences via [^"\\]*(\\.[^"\\]*)*
      SUMMARY=$(printf '%s' "$LINE" | grep -oE '"content":"([^"\\]|\\.)*"' | head -1 \
        | sed 's/^"content":"//; s/"$//' \
        | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g' \
        || true)
      if [[ -z "$SUMMARY" ]]; then
        # Array content block: {"type":"text","text":"..."}
        SUMMARY=$(printf '%s' "$LINE" | grep -oE '"text":"([^"\\]|\\.)*"' | head -1 \
          | sed 's/^"text":"//; s/"$//' \
          | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g' \
          || true)
      fi
      break
    fi
  done < "$TRANSCRIPT_PATH"
fi

# Step 3 (fallback): scan for the last substantial assistant message
if [[ -z "$SUMMARY" ]]; then
  FALLBACK=""
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    if printf '%s' "$LINE" | grep -qF '"role":"assistant"'; then
      CANDIDATE=$(printf '%s' "$LINE" | grep -oE '"content":"([^"\\]|\\.)*"' | head -1 \
        | sed 's/^"content":"//; s/"$//' \
        | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g' \
        || true)
      [[ -n "$CANDIDATE" ]] && FALLBACK="$CANDIDATE"
    fi
  done < "$TRANSCRIPT_PATH"

  if [[ -n "$FALLBACK" ]]; then
    SUMMARY="$FALLBACK"
    FAILURE_REASON="primary extraction failed — using last assistant message as fallback"
  else
    FAILURE_REASON="no compact_boundary found and no assistant content in transcript"
  fi
fi

# ── rotate existing summary before writing ────────────────────────────────────
if [[ -f "$OUTPUT_PATH" ]]; then
  cp "$OUTPUT_PATH" "$BACKUP_PATH"
fi

# ── write output ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M UTC" 2>/dev/null || date "+%Y-%m-%d %H:%M UTC")
mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ -z "$SUMMARY" ]]; then
  # Write diagnostic so the next session knows the summary is not trustworthy
  cat > "$OUTPUT_PATH" << EOF
<!-- auto-generated by post-compact-capture.sh — do not edit -->
# Last Compaction Summary

**Captured:** ${TIMESTAMP}
**Trigger:** ${TRIGGER}
**Session:** ${SESSION_ID}

---

[EXTRACTION FAILED: ${FAILURE_REASON}]

The previous session's context could not be recovered from this compaction.
Start fresh or check ~/.claude/last-compact-summary.bak.md for the prior summary.
EOF
else
  cat > "$OUTPUT_PATH" << EOF
<!-- auto-generated by post-compact-capture.sh — do not edit -->
# Last Compaction Summary

**Captured:** ${TIMESTAMP}
**Trigger:** ${TRIGGER}
**Session:** ${SESSION_ID}

---

${SUMMARY}
EOF
fi
```

- [ ] **Step 4: Make the script executable**

```bash
chmod +x scripts/post-compact-capture.sh
```

- [ ] **Step 5: Run the test — verify it passes**

```bash
bash tests/test-post-compact-capture.sh
```

Expected: `7 passed · 0 failed`

- [ ] **Step 6: Commit**

```bash
git add scripts/post-compact-capture.sh tests/test-post-compact-capture.sh
git commit -m "feat: add post-compact-capture.sh — bash PostCompact hook with fallback extraction and diagnostic output"
```

---

## Task 4: pre-compact-summary.ps1

**Files:**
- Create: `scripts/pre-compact-summary.ps1`
- Create: `tests/Compact-Hooks.Tests.ps1` (initial — pre-compact tests only)

- [ ] **Step 1: Write the failing Pester test**

Create `tests/Compact-Hooks.Tests.ps1`:

```powershell
#Requires -Version 5.1

BeforeAll {
    $ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts'
    $PreScript  = Join-Path $ScriptsDir 'pre-compact-summary.ps1'
    $PostScript = Join-Path $ScriptsDir 'post-compact-capture.ps1'
    $FixturesDir = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'pre-compact-summary.ps1' {
    It 'outputs hookEventName=PreCompact for auto trigger' {
        $Output = '{"trigger":"auto"}' | & $PreScript | ConvertFrom-Json
        $Output.hookSpecificOutput.hookEventName | Should -Be 'PreCompact'
    }

    It 'systemMessage contains [Auto] for auto trigger' {
        $Output = '{"trigger":"auto"}' | & $PreScript
        $Output | Should -Match '\[Auto\]'
    }

    It 'systemMessage contains [Manual] for manual trigger' {
        $Output = '{"trigger":"manual"}' | & $PreScript
        $Output | Should -Match '\[Manual\]'
    }

    It 'unknown trigger falls back to auto' {
        $Output = '{"trigger":"bogus"}' | & $PreScript
        $Output | Should -Match '\[Auto\]'
    }

    It 'malformed input does not throw' {
        { 'not json' | & $PreScript } | Should -Not -Throw
    }

    It 'additionalContext contains all 6 required sections' {
        $Output = '{"trigger":"auto"}' | & $PreScript | ConvertFrom-Json
        $Context = $Output.hookSpecificOutput.additionalContext
        $Context | Should -Match 'OVERALL TASK'
        $Context | Should -Match 'DECISION CHAIN'
        $Context | Should -Match 'CURRENT STATE'
        $Context | Should -Match 'ACTIVE FILES'
        $Context | Should -Match 'LAST ERROR'
        $Context | Should -Match 'OPEN QUESTIONS'
    }
}
```

- [ ] **Step 2: Run the test — verify it fails**

```powershell
Invoke-Pester -Path tests/Compact-Hooks.Tests.ps1 -Output Detailed
```

Expected: errors because `scripts/pre-compact-summary.ps1` does not exist.

- [ ] **Step 3: Write the implementation**

Create `scripts/pre-compact-summary.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    PreCompact hook — injects context preservation instructions into compaction.
.DESCRIPTION
    Input (stdin):  {"trigger":"auto"|"manual"}
    Output (stdout): JSON payload with hookSpecificOutput and systemMessage
#>
[CmdletBinding()]
Param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read and parse stdin
$RawInput = $Input | Out-String
try {
    $Data = $RawInput | ConvertFrom-Json
    $Trigger = $Data.trigger
} catch {
    $Trigger = $null
}

# Validate trigger against allowlist
$ValidTriggers = @('auto', 'manual')
if ($Trigger -notin $ValidTriggers) {
    $Trigger = 'auto'
}

$Label = (Get-Culture).TextInfo.ToTitleCase($Trigger)

$Context = @'
COMPACTION IMMINENT — your summary MUST preserve ALL of the following:

1. OVERALL TASK
   What is the user ultimately trying to accomplish? Include the acceptance criteria for done.

2. DECISION CHAIN
   Key decisions made this session: what was chosen, why X over Y, what constraint or discovery drove it.

3. CURRENT STATE
   Done / in-progress (specific function names or line numbers) / remaining.

4. ACTIVE FILES
   Exact paths of every file read, written, or edited this session.

5. LAST ERROR
   Most recent error message, quoted verbatim. State whether it was resolved.

6. OPEN QUESTIONS
   Unresolved questions or blockers. Quote error messages directly — do not paraphrase.

This structured context must survive compaction intact so work can resume without losing the logical thread.
'@

$Output = [PSCustomObject]@{
    hookSpecificOutput = [PSCustomObject]@{
        hookEventName   = 'PreCompact'
        additionalContext = $Context
    }
    systemMessage = "[$Label] compaction triggered. Capturing task context..."
}

$Output | ConvertTo-Json -Depth 3 -Compress
```

- [ ] **Step 4: Run the test — verify it passes**

```powershell
Invoke-Pester -Path tests/Compact-Hooks.Tests.ps1 -Output Detailed
```

Expected: all `pre-compact-summary.ps1` tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/pre-compact-summary.ps1 tests/Compact-Hooks.Tests.ps1
git commit -m "feat: add pre-compact-summary.ps1 — PowerShell PreCompact hook"
```

---

## Task 5: post-compact-capture.ps1

**Files:**
- Modify: `tests/Compact-Hooks.Tests.ps1` (add post-compact tests)
- Create: `scripts/post-compact-capture.ps1`

- [ ] **Step 1: Append Pester tests for the post-compact script**

Add this `Describe` block to the end of `tests/Compact-Hooks.Tests.ps1`:

```powershell
Describe 'post-compact-capture.ps1' {
    BeforeEach {
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        $BackupPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.bak.md'
        Remove-Item -Path $OutputPath, $BackupPath -Force -ErrorAction SilentlyContinue
    }

    AfterEach {
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        $BackupPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.bak.md'
        Remove-Item -Path $OutputPath, $BackupPath -Force -ErrorAction SilentlyContinue
    }

    It 'writes summary file for valid transcript' {
        $JsonInput = [PSCustomObject]@{
            transcript_path = Join-Path $FixturesDir 'transcript-valid.jsonl'
            trigger         = 'auto'
            session_id      = 'test-ps-1'
        } | ConvertTo-Json -Compress
        $JsonInput | & $PostScript
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        (Test-Path -Path $OutputPath) | Should -BeTrue
    }

    It 'extracted content appears in summary file' {
        $Input = [PSCustomObject]@{
            transcript_path = Join-Path $FixturesDir 'transcript-valid.jsonl'
            trigger         = 'auto'
            session_id      = 'test-ps-2'
        } | ConvertTo-Json -Compress
        $Input | & $PostScript
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        $Content = Get-Content -Path $OutputPath -Raw
        $Content | Should -Match 'Overall task'
    }

    It 'writes diagnostic file when transcript has no boundary' {
        $Input = [PSCustomObject]@{
            transcript_path = Join-Path $FixturesDir 'transcript-no-boundary.jsonl'
            trigger         = 'auto'
            session_id      = 'test-ps-3'
        } | ConvertTo-Json -Compress
        $Input | & $PostScript
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        (Test-Path -Path $OutputPath) | Should -BeTrue
        $Content = Get-Content -Path $OutputPath -Raw
        $Content | Should -Match 'EXTRACTION'
    }

    It 'rotates existing summary to .bak.md before overwriting' {
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        $BackupPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.bak.md'
        Set-Content -Path $OutputPath -Value 'old summary'
        $Input = [PSCustomObject]@{
            transcript_path = Join-Path $FixturesDir 'transcript-valid.jsonl'
            trigger         = 'auto'
            session_id      = 'test-ps-4'
        } | ConvertTo-Json -Compress
        $Input | & $PostScript
        (Test-Path -Path $BackupPath) | Should -BeTrue
        Get-Content -Path $BackupPath -Raw | Should -Match 'old summary'
    }

    It 'rejects relative transcript paths' {
        $Input = '{"transcript_path":"relative/path.jsonl","trigger":"auto","session_id":"x"}'
        $Input | & $PostScript
        $OutputPath = Join-Path $env:USERPROFILE '.claude' 'last-compact-summary.md'
        (Test-Path -Path $OutputPath) | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run the test — verify the new tests fail**

```powershell
Invoke-Pester -Path tests/Compact-Hooks.Tests.ps1 -Output Detailed
```

Expected: `post-compact-capture.ps1` tests fail, existing tests still pass.

- [ ] **Step 3: Write the implementation**

Create `scripts/post-compact-capture.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    PostCompact hook — extracts compaction summary from transcript and saves it.
.DESCRIPTION
    Input (stdin):  {"transcript_path":"/abs/path","trigger":"auto","session_id":"..."}
    Output:         writes ~/.claude/last-compact-summary.md (or $env:USERPROFILE\.claude\)

    Resilience:
      - Fallback extraction if primary parentUuid match finds nothing
      - Rotates existing summary to .bak.md before overwriting
      - Writes a diagnostic file on failure so the next session knows not to trust it
#>
[CmdletBinding()]
Param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClaudeDir  = [System.IO.Path]::Combine($env:USERPROFILE, '.claude')
$OutputPath = [System.IO.Path]::Combine($ClaudeDir, 'last-compact-summary.md')
$BackupPath = [System.IO.Path]::Combine($ClaudeDir, 'last-compact-summary.bak.md')

# ── parse stdin ───────────────────────────────────────────────────────────────
$RawInput = $Input | Out-String
try {
    $Data = $RawInput | ConvertFrom-Json
} catch {
    exit 0
}

$TranscriptPath = $Data.transcript_path
$Trigger        = if ($Data.trigger)    { $Data.trigger }    else { 'auto' }
$SessionId      = if ($Data.session_id) { $Data.session_id } else { 'unknown' }

# Validate path
if ([string]::IsNullOrWhiteSpace($TranscriptPath)) { exit 0 }
if (-not [System.IO.Path]::IsPathRooted($TranscriptPath)) { exit 0 }
if (-not [System.IO.File]::Exists($TranscriptPath)) { exit 0 }

# ── parse transcript ──────────────────────────────────────────────────────────

function Get-SummaryText {
    [CmdletBinding()]
    Param([string]$Path)

    $Lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    $Entries = foreach ($Line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        try { $Line | ConvertFrom-Json } catch { continue }
    }

    # Primary: find compact_boundary (last occurrence), then the user entry whose parentUuid matches
    $BoundaryUuid = $null
    for ($i = $Entries.Count - 1; $i -ge 0; $i--) {
        $Entry = $Entries[$i]
        if ($Entry.type -eq 'system' -and $Entry.subtype -eq 'compact_boundary') {
            $BoundaryUuid = $Entry.uuid
            break
        }
    }

    if ($BoundaryUuid) {
        foreach ($Entry in $Entries) {
            if ($Entry.parentUuid -eq $BoundaryUuid -and $Entry.type -eq 'user') {
                $Msg = if ($Entry.message) { $Entry.message } else { $Entry }
                $Content = $Msg.content
                if ($Content -is [string] -and $Content.Length -gt 0) {
                    return [PSCustomObject]@{ Text = $Content; FailureReason = $null }
                }
                if ($Content -is [array]) {
                    $TextBlock = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                    if ($TextBlock -and $TextBlock.text.Length -gt 0) {
                        return [PSCustomObject]@{ Text = $TextBlock.text; FailureReason = $null }
                    }
                }
            }
        }
    }

    # Fallback: last assistant message with content
    $LastContent = $null
    foreach ($Entry in $Entries) {
        $Role = if ($Entry.message) { $Entry.message.role } else { $Entry.role }
        if ($Role -eq 'assistant') {
            $Content = if ($Entry.message) { $Entry.message.content } else { $Entry.content }
            if ($Content -is [string] -and $Content.Length -gt 0) {
                $LastContent = $Content
            }
        }
    }

    if ($LastContent) {
        return [PSCustomObject]@{
            Text          = $LastContent
            FailureReason = 'primary extraction failed — using last assistant message as fallback'
        }
    }

    return [PSCustomObject]@{
        Text          = $null
        FailureReason = 'no compact_boundary found and no assistant content in transcript'
    }
}

$Result    = Get-SummaryText -Path $TranscriptPath
$Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')

# ── rotate existing summary ───────────────────────────────────────────────────
if (-not (Test-Path -Path $ClaudeDir)) {
    [System.IO.Directory]::CreateDirectory($ClaudeDir) | Out-Null
}
if (Test-Path -Path $OutputPath) {
    Copy-Item -Path $OutputPath -Destination $BackupPath -Force
}

# ── write output ──────────────────────────────────────────────────────────────
$Header = @"
<!-- auto-generated by post-compact-capture.ps1 — do not edit -->
# Last Compaction Summary

**Captured:** $Timestamp
**Trigger:** $Trigger
**Session:** $SessionId

---

"@

if ($Result.Text) {
    $Body = if ($Result.FailureReason) {
        "<!-- Note: $($Result.FailureReason) -->`n`n$($Result.Text)"
    } else {
        $Result.Text
    }
} else {
    $Body = @"
[EXTRACTION FAILED: $($Result.FailureReason)]

The previous session's context could not be recovered from this compaction.
Start fresh or check $BackupPath for the prior summary.
"@
}

[System.IO.File]::WriteAllText($OutputPath, $Header + $Body, [System.Text.Encoding]::UTF8)
```

- [ ] **Step 4: Run all Pester tests — verify they all pass**

```powershell
Invoke-Pester -Path tests/Compact-Hooks.Tests.ps1 -Output Detailed
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/post-compact-capture.ps1 tests/Compact-Hooks.Tests.ps1
git commit -m "feat: add post-compact-capture.ps1 — PowerShell PostCompact hook with resilience"
```

---

## Task 6: Update install.sh

**Files:**
- Modify: `install.sh`

The changes to `install.sh` are:
1. Remove the Python pre-flight check
2. Change `PRE_SCRIPT` and `POST_SCRIPT` paths from `.py` to `.sh`
3. Replace the Python heredocs in Step 1 with `cat` from the repo `scripts/` directory
4. Update the Step 1 display text from "Python scripts" to "Shell scripts"
5. Update the Step 2 Python subprocess to use bash commands for JSON merging
6. Update the hook commands in Step 2 from `python3 ~/.claude/scripts/...py` to `bash ~/.claude/scripts/...sh`
7. Update the verbose details display text

- [ ] **Step 1: Remove the Python pre-flight check**

In `install.sh`, delete these 3 lines:

```bash
# ── pre-flight: python3 required ────────────────────────────────────────────
command -v python3 &>/dev/null \
  || fail "python3 not found. Install via: brew install python3"
```

- [ ] **Step 2: Update script path variables**

In `install.sh`, change:

```bash
PRE_SCRIPT="${SCRIPTS_DIR}/pre-compact-summary.py"
POST_SCRIPT="${SCRIPTS_DIR}/post-compact-capture.py"
```

To:

```bash
PRE_SCRIPT="${SCRIPTS_DIR}/pre-compact-summary.sh"
POST_SCRIPT="${SCRIPTS_DIR}/post-compact-capture.sh"
```

- [ ] **Step 3: Replace Step 1 body — copy scripts from repo instead of heredoc**

In `install.sh`, replace the block that starts with:

```bash
  cat > "$PRE_SCRIPT" << 'PYEOF'
```

and ends after the second `PYEOF` and `chmod +x` line, up to (but not including) the `ok "pre-compact-summary.py"` lines, with:

```bash
  # Locate the scripts/ directory relative to this installer
  # Works for local runs; curl | bash runs from a temp location so we fetch inline.
  _SCRIPT_DIR=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  fi

  if [[ -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/scripts/pre-compact-summary.sh" ]]; then
    cp "${_SCRIPT_DIR}/scripts/pre-compact-summary.sh" "$PRE_SCRIPT"
    cp "${_SCRIPT_DIR}/scripts/post-compact-capture.sh" "$POST_SCRIPT"
  else
    # Running via curl | bash — embed scripts inline
    cat > "$PRE_SCRIPT" << 'SHEOF'
#!/usr/bin/env bash
INSTALL_PLACEHOLDER_PRE
SHEOF
    cat > "$POST_SCRIPT" << 'SHEOF'
#!/usr/bin/env bash
INSTALL_PLACEHOLDER_POST
SHEOF
  fi
```

> **Note:** The `INSTALL_PLACEHOLDER_PRE` and `INSTALL_PLACEHOLDER_POST` lines are where the full content of `pre-compact-summary.sh` and `post-compact-capture.sh` must be embedded verbatim in the heredoc. Copy the full file contents from `scripts/pre-compact-summary.sh` and `scripts/post-compact-capture.sh` here. This is done last (Task 6, Step 5) once both scripts are finalized.

- [ ] **Step 4: Update hook commands in Step 2**

In `install.sh`, in the Step 2 Python subprocess that merges settings.json, update the `"command"` values from:

```python
"command": "python3 ~/.claude/scripts/pre-compact-summary.py",
```
to:
```python
"command": "bash ~/.claude/scripts/pre-compact-summary.sh",
```

And:

```python
"command": "python3 ~/.claude/scripts/post-compact-capture.py",
```
to:
```python
"command": "bash ~/.claude/scripts/post-compact-capture.sh",
```

And in the doctor auto-fix embedded in doctor.sh (same pattern): update both commands. (Defer this to Task 7.)

- [ ] **Step 5: Update verbose detail text**

In `install.sh`, change the verbose display from:

```bash
  printf "\n${B}pre-compact-summary.py${R}  ${D}(PreCompact hook)${R}\n"
```

to:

```bash
  printf "\n${B}pre-compact-summary.sh${R}  ${D}(PreCompact hook)${R}\n"
```

And:

```bash
  printf "\n${B}post-compact-capture.py${R}  ${D}(PostCompact hook, async)${R}\n"
```

to:

```bash
  printf "\n${B}post-compact-capture.sh${R}  ${D}(PostCompact hook, async)${R}\n"
```

And update the hooks display:

```bash
  printf '  "PreCompact":  python3 ~/.claude/scripts/pre-compact-summary.py\n'
  printf '  "PostCompact": python3 ~/.claude/scripts/post-compact-capture.py  (async)\n'
```

to:

```bash
  printf '  "PreCompact":  bash ~/.claude/scripts/pre-compact-summary.sh\n'
  printf '  "PostCompact": bash ~/.claude/scripts/post-compact-capture.sh  (async)\n'
```

- [ ] **Step 6: Update the ok/rec lines**

Change:

```bash
  ok "pre-compact-summary.py"
  ok "post-compact-capture.py"
  _rec_ok "$PRE_SCRIPT"  "CREATED" "$(_wc "$PRE_SCRIPT") lines · chmod +x"
  _rec_ok "$POST_SCRIPT" "CREATED" "$(_wc "$POST_SCRIPT") lines · chmod +x"
```

to:

```bash
  ok "pre-compact-summary.sh"
  ok "post-compact-capture.sh"
  _rec_ok "$PRE_SCRIPT"  "CREATED" "$(_wc "$PRE_SCRIPT") lines · chmod +x"
  _rec_ok "$POST_SCRIPT" "CREATED" "$(_wc "$POST_SCRIPT") lines · chmod +x"
```

- [ ] **Step 7: Also update the preview sample data block**

Change the preview lines:

```bash
  printf '%s\tCREATED\t59 lines · chmod +x\n'           "$PRE_SCRIPT"
  printf '%s\tCREATED\t93 lines · chmod +x\n'           "$POST_SCRIPT"
```

The line counts should reflect the actual `.sh` file sizes; update them to match `wc -l scripts/pre-compact-summary.sh` and `wc -l scripts/post-compact-capture.sh`.

- [ ] **Step 8: Embed script contents into the curl-path heredocs**

Replace `INSTALL_PLACEHOLDER_PRE` in the heredoc with the full content of `scripts/pre-compact-summary.sh`, and `INSTALL_PLACEHOLDER_POST` with the full content of `scripts/post-compact-capture.sh`.

The cleanest way: after finalizing both scripts, run:

```bash
# Preview what the embedded heredoc will look like (do not run the install):
bash install.sh --preview
```

Confirm no errors.

- [ ] **Step 9: Run install.sh --preview to verify output**

```bash
bash install.sh --preview
```

Expected: completion screen renders cleanly showing `.sh` filenames, no Python references.

- [ ] **Step 10: Commit**

```bash
git add install.sh
git commit -m "feat: update install.sh to install bash hook scripts — drops Python dependency"
```

---

## Task 7: Update doctor.sh

**Files:**
- Modify: `doctor.sh`

Changes:
1. Remove the `python3 in PATH` check
2. Update `PRE_SCRIPT`/`POST_SCRIPT` paths from `.py` to `.sh`
3. Replace the `python3` JSON validation calls with a bash equivalent
4. Update hook registration auto-fix to use `bash ...sh` commands
5. Update the dry-run check to run `.sh` script directly

- [ ] **Step 1: Update the script path variables**

In `doctor.sh`, change:

```bash
PRE_SCRIPT="${HOME}/.claude/scripts/pre-compact-summary.py"
POST_SCRIPT="${HOME}/.claude/scripts/post-compact-capture.py"
```

To:

```bash
PRE_SCRIPT="${HOME}/.claude/scripts/pre-compact-summary.sh"
POST_SCRIPT="${HOME}/.claude/scripts/post-compact-capture.sh"
```

- [ ] **Step 2: Remove the Python check block**

Delete:

```bash
# 1. python3
if command -v python3 &>/dev/null; then
  _PY=$(python3 --version 2>&1)
  _chk "python3 in PATH" "PASS" "$_PY"
else
  _chk "python3 in PATH" "FAIL" "install via: brew install python3"
fi
```

Renumber remaining checks so they start at 1.

- [ ] **Step 3: Replace the Python-based JSON validation in the settings check**

The existing settings.json validation uses:

```bash
elif python3 -c "import json; json.load(open('$SETTINGS_PATH'))" 2>/dev/null; then
```

Replace with a bash-native check:

```bash
elif bash -c "
  content=\$(cat '$SETTINGS_PATH')
  # Valid JSON must start with { or [ after optional whitespace
  trimmed=\$(printf '%s' \"\$content\" | sed 's/^[[:space:]]*//')
  [[ \"\${trimmed:0:1}\" == '{' || \"\${trimmed:0:1}\" == '[' ]]
" 2>/dev/null; then
```

> **Note:** This is a structural check (starts with `{`), not a full JSON validator. It catches the most common corruption (empty file, truncated file) without requiring Python. If full validation is needed, the install step already ensures valid JSON was written.

- [ ] **Step 4: Update the hook presence check**

The hook check currently uses:

```bash
  _present=$(python3 -c "
import json
s = json.load(open('$SETTINGS_PATH'))
print('yes' if '$_hook' in s.get('hooks', {}) else 'no')
")
```

Replace with:

```bash
  _present=$(grep -qF "\"$_hook\"" "$SETTINGS_PATH" && echo "yes" || echo "no")
```

- [ ] **Step 5: Update hook auto-fix to use bash commands**

The hook registration auto-fix currently runs a Python heredoc. Replace it with a simpler bash approach that uses `sed` to insert the hook entry. Since the settings.json was written by `install.sh` with a known structure, we can target the insertion point:

Replace the Python heredoc auto-fix block for each hook with:

```bash
      # Auto-fix: append the missing hook entry using python3 if available, else note manual fix
      if command -v python3 &>/dev/null; then
        python3 - << PYEOF
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_name = "$_hook"

new_entry = {
    "PreCompact": [{"hooks": [{"type": "command",
        "command": "bash ~/.claude/scripts/pre-compact-summary.sh",
        "timeout": 15, "statusMessage": "Capturing task context..."}]}],
    "PostCompact": [{"hooks": [{"type": "command",
        "command": "bash ~/.claude/scripts/post-compact-capture.sh",
        "timeout": 15, "async": True, "statusMessage": "Saving summary..."}]}],
}[hook_name]

with open(settings_path) as f:
    settings = json.load(f)

settings.setdefault("hooks", {})[hook_name] = new_entry

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
PYEOF
        _chk "${_hook} hook registered" "FIXED" "hook entry added to settings.json"
      else
        _chk "${_hook} hook registered" "FAIL" "add hook manually — see settings-hooks-snippet.json"
      fi
```

> **Note:** doctor.sh's auto-fix falls back to Python3 if available (it's an optional enhancement, not a hard dependency). If Python3 is absent, it tells the user to add the hook manually. The core install path has no Python dependency.

- [ ] **Step 6: Update the dry-run check**

The dry-run check currently runs:

```bash
  _dry=$(echo '{"trigger":"auto"}' | python3 "$PRE_SCRIPT" 2>/dev/null || echo "ERROR")
  if echo "$_dry" | python3 -c "..."
```

Replace with:

```bash
if [[ -f "$PRE_SCRIPT" && -x "$PRE_SCRIPT" ]]; then
  _dry=$(printf '{"trigger":"auto"}' | bash "$PRE_SCRIPT" 2>/dev/null || echo "ERROR")
  if printf '%s' "$_dry" | grep -qF '"hookEventName":"PreCompact"'; then
    _chk "pre-compact-summary.sh dry-run" "PASS" "JSON output valid"
  else
    _chk "pre-compact-summary.sh dry-run" "FAIL" "script produced unexpected output — re-run install.sh"
  fi
else
  _chk "pre-compact-summary.sh dry-run" "WARN" "skipped (script missing or not executable)"
fi
```

- [ ] **Step 7: Update the script name labels in check descriptions**

Change `"pre-compact-summary.py exists"` → `"pre-compact-summary.sh exists"`, `"post-compact-capture.py exists"` → `"post-compact-capture.sh exists"`, and the executable checks to match.

- [ ] **Step 8: Verify doctor.sh runs cleanly after a local install**

```bash
bash install.sh
bash doctor.sh
```

Expected: all checks PASS or FIXED; no FAIL on a fresh install.

- [ ] **Step 9: Commit**

```bash
git add doctor.sh
git commit -m "feat: update doctor.sh — check bash hooks, drop Python dependency"
```

---

## Task 8: Update settings-hooks-snippet.json

**Files:**
- Modify: `settings-hooks-snippet.json`

- [ ] **Step 1: Update hook commands**

Replace the full contents of `settings-hooks-snippet.json` with:

```json
{
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/scripts/pre-compact-summary.sh",
            "timeout": 15,
            "statusMessage": "Capturing task context before compaction..."
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/scripts/post-compact-capture.sh",
            "timeout": 15,
            "async": true,
            "statusMessage": "Saving compaction summary..."
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add settings-hooks-snippet.json
git commit -m "chore: update settings-hooks-snippet.json to use bash hook commands"
```

---

## Task 9: install.ps1

**Files:**
- Create: `install.ps1`

This is the Windows installer. It mirrors `install.sh` step-for-step. Full idiomatic PowerShell — see the PowerShell code standards section in the spec.

- [ ] **Step 1: Verify the output path on Windows**

Claude `.claude` directory on Windows is `$env:USERPROFILE\.claude`. Confirm this is where Claude Code stores its config on Windows before writing the installer. Claude Code for Windows uses `%USERPROFILE%\.claude\` to match the Unix `~/.claude` convention.

- [ ] **Step 2: Write install.ps1**

Create `install.ps1`:

```powershell
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

.PARAMETER Verbose
    Shows full details before beginning installation.

.EXAMPLE
    irm https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.ps1 | iex
#>
[CmdletBinding()]
Param(
    [Parameter()][switch]$Preview,
    [Parameter()][switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── paths ─────────────────────────────────────────────────────────────────────
$ClaudeDir    = [System.IO.Path]::Combine($env:USERPROFILE, '.claude')
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

    if ($Verbose) {
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
        Write-Host "  PreCompact:  powershell -NoProfile -File $PreScript"
        Write-Host "  PostCompact: powershell -NoProfile -File $PostScript  (async)"
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
            'd' { $Verbose = $true; & $PSCommandPath @PSBoundParameters; exit }
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

            # Idempotent: only add if the command is not already registered
            $ExistingPre = $Settings.hooks.PSObject.Properties['PreCompact']
            if (-not $ExistingPre) {
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

            $ExistingPost = $Settings.hooks.PSObject.Properties['PostCompact']
            if (-not $ExistingPost) {
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
```

- [ ] **Step 3: Run --preview to verify the output**

On a Windows machine (or PowerShell 5.1+):

```powershell
.\install.ps1 -Preview
```

Expected: completion screen renders with `.ps1` filenames, MERGED/CREATED actions shown.

- [ ] **Step 4: Commit**

```bash
git add install.ps1
git commit -m "feat: add install.ps1 — Windows PowerShell installer, zero dependencies"
```

---

## Task 10: doctor.ps1

**Files:**
- Create: `doctor.ps1`

- [ ] **Step 1: Write doctor.ps1**

Create `doctor.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    compact-hooks doctor for Windows — checks installation health and auto-fixes what it can.
.DESCRIPTION
    Runs 8 checks. Auto-fixes: missing executable policy, missing hook entries,
    missing CLAUDE.md Session Resume block. Reports what it cannot fix.
#>
[CmdletBinding()]
Param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClaudeDir    = [System.IO.Path]::Combine($env:USERPROFILE, '.claude')
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
        Add-Check -Label 'Execution policy allows scripts' -Result 'FAIL' -Action "Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
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
                    $Settings.hooks | Add-Member -MemberType NoteProperty -Name $HookName -Value $NewEntry -Force
                    $Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath -Encoding UTF8
                    Add-Check -Label "$HookName hook registered" -Result 'FIXED' -Action 'hook entry added'
                } catch {
                    Add-Check -Label "$HookName hook registered" -Result 'FAIL' -Action "add manually — see settings-hooks-snippet.json"
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
        Add-Check -Label 'CLAUDE.md has Session Resume' -Result 'FAIL' -Action "re-run install.ps1"
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
    $Icon, $Color = switch ($Check.Result) {
        'PASS'  { '✓', 'Green' }
        'FIXED' { '✦', 'Cyan' }
        'WARN'  { '!', 'Yellow' }
        'FAIL'  { '✗', 'Red' }
        default { '?', 'White' }
    }
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
```

- [ ] **Step 2: Run doctor.ps1 after a local install to verify**

On Windows (after running install.ps1):

```powershell
.\doctor.ps1
```

Expected: all 8 checks PASS (or FIXED on first run if execution policy needed adjusting).

- [ ] **Step 3: Commit**

```bash
git add doctor.ps1
git commit -m "feat: add doctor.ps1 — Windows health check with auto-fix"
```

---

## Task 11: Remove old Python scripts

**Files:**
- Delete: `pre-compact-summary.py`
- Delete: `post-compact-capture.py`

- [ ] **Step 1: Delete the Python scripts**

```bash
git rm pre-compact-summary.py post-compact-capture.py
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove Python hook scripts — replaced by bash and PowerShell variants"
```

---

## Task 12: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the install section**

Replace the existing install block with a platform-split version:

```markdown
## Install

**You'll need:** Claude Code (recent version with `PreCompact`/`PostCompact` hook support).

No other dependencies — Python, Node, or any runtime.

**macOS / Linux:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.sh)
```

**Windows (PowerShell 5.1+):**

```powershell
irm https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.ps1 | iex
```

> **macOS / Linux:** Use `bash <(...)` rather than `curl ... | bash`. The `<(...)` form keeps your terminal's stdin connected so the interactive prompts work correctly.
>
> **Windows:** If you see a security prompt about running remote scripts, run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` first, then retry.

Both installers show you what they're going to do before doing it, and ask to confirm each step. Running either installer again is safe.
```

- [ ] **Step 2: Update the "What it installs" table**

Replace the existing table with:

```markdown
## What it installs

| File | Where | What it does |
|---|---|---|
| `pre-compact-summary.sh` (macOS/Linux) | `~/.claude/scripts/` | Runs before compaction — tells Claude what to preserve |
| `pre-compact-summary.ps1` (Windows) | `~/.claude/scripts/` | Same, PowerShell variant |
| `post-compact-capture.sh` (macOS/Linux) | `~/.claude/scripts/` | Runs after compaction — saves the summary to disk |
| `post-compact-capture.ps1` (Windows) | `~/.claude/scripts/` | Same, PowerShell variant |
| Hook entries | `~/.claude/settings.json` | Wires the scripts into Claude Code's lifecycle |
| Session Resume block | `~/.claude/CLAUDE.md` | Tells Claude to load the saved summary at session start |
```

- [ ] **Step 3: Update the "Something's broken" section**

Replace:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.sh)
```

With:

```markdown
**macOS / Linux:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.sh)
```

**Windows:**

```powershell
irm https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.ps1 | iex
```
```

- [ ] **Step 4: Update the "Files in this repo" section**

Replace with:

```markdown
## Files in this repo

```
compact-hooks/
├── install.sh                   # macOS / Linux installer
├── install.ps1                  # Windows installer
├── doctor.sh                    # macOS / Linux health check
├── doctor.ps1                   # Windows health check
├── scripts/
│   ├── pre-compact-summary.sh   # bash PreCompact hook
│   ├── pre-compact-summary.ps1  # PowerShell PreCompact hook
│   ├── post-compact-capture.sh  # bash PostCompact hook
│   └── post-compact-capture.ps1 # PowerShell PostCompact hook
├── settings-hooks-snippet.json  # hook config reference (macOS/Linux format)
└── CLAUDE-md-addition.md        # the Session Resume block added to CLAUDE.md
```

The `scripts/` files are what the installers write to `~/.claude/scripts/`. If you change them, re-run the installer to push your changes to the active location.
```

- [ ] **Step 5: Update the Requirements table**

Replace the existing requirements table with:

```markdown
## Requirements

| | Minimum | Notes |
|---|---|---|
| Claude Code | recent | needs `PreCompact` / `PostCompact` hook support |
| bash | 3.2 | macOS ships 3.2; all Linux distros include it |
| PowerShell | 5.1 | built into Windows 10+; no install needed |
| OS | macOS / Linux / Windows | all supported natively |
```

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: update README for cross-platform install and no-Python requirement"
```

---

## Verification

After all tasks complete:

1. **macOS/Linux end-to-end**: `bash install.sh` on a machine that has never had compact-hooks. Confirm `.sh` scripts in `~/.claude/scripts/`, hooks in `settings.json`, Session Resume in `CLAUDE.md`.

2. **Windows end-to-end**: `.\install.ps1` on a clean Windows machine. Confirm `.ps1` scripts in `$env:USERPROFILE\.claude\scripts\`, same hook structure.

3. **Hook execution (macOS)**: open Claude Code, run `/compact`. Confirm status messages: `Capturing task context before compaction...` and `Saving compaction summary...`. Check `~/.claude/last-compact-summary.md` was written with all 6 sections.

4. **Hook execution (Windows)**: same as above on Windows.

5. **doctor checks**: `bash doctor.sh` (macOS) and `.\doctor.ps1` (Windows) — all checks PASS.

6. **Idempotency**: run each installer twice. Confirm no duplicate hook entries, no duplicate CLAUDE.md blocks.

7. **Resilience**: feed `transcript-no-boundary.jsonl` as the transcript path to the post-compact script. Confirm `[EXTRACTION FAILED]` is written, not silence.

8. **Summary rotation**: run the post-compact script twice with a valid transcript. Confirm `.bak.md` contains the first run's output.

9. **Bash tests**: `bash tests/test-pre-compact-summary.sh && bash tests/test-post-compact-capture.sh` — all pass.

10. **Pester tests**: `Invoke-Pester tests/Compact-Hooks.Tests.ps1` — all pass.
