[CmdletBinding()]
param()

# PreCompact hook — injects context preservation instructions into compaction.
#
# Input (stdin):  {"trigger":"auto"|"manual"}
# Output (stdout): JSON payload with hookSpecificOutput and systemMessage
#
# Security: reads stdin only; no shell interpolation of external values into commands;
# CONTEXT is a literal constant — not derived from user input.

$StdinContent = [Console]::In.ReadToEnd()

# Try to parse JSON; fail open if malformed (let Claude proceed normally).
try {
    $Parsed = $StdinContent | ConvertFrom-Json
} catch {
    exit 0
}

# If no trigger key present, fail open.
if (-not $Parsed.trigger) {
    exit 0
}

$Trigger = $Parsed.trigger

# Normalize unknown trigger values to "auto".
if ($Trigger -ne 'auto' -and $Trigger -ne 'manual') {
    $Trigger = 'auto'
}

# Capitalize first letter for display.
$Label = $Trigger.Substring(0, 1).ToUpper() + $Trigger.Substring(1)

# Build context as a here-string with actual newlines.
# ConvertTo-Json will serialize newlines as \n in the JSON string, which is correct.
# The em dash (U+2014) is valid UTF-8 in a JSON string.
$Context = @"
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
"@

$HookOutput = [PSCustomObject]@{
    hookSpecificOutput = [PSCustomObject]@{
        hookEventName     = 'PreCompact'
        additionalContext = $Context
    }
    systemMessage = "[$Label] compaction triggered. Capturing task context..."
}

Write-Output ($HookOutput | ConvertTo-Json -Depth 5 -Compress)
