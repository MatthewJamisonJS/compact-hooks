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

# Extract trigger field; || true prevents grep's exit-1-on-no-match from aborting under set -e.
RAW_TRIGGER=$(printf '%s' "$INPUT" | grep -oE '"trigger":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

# If input contains no "trigger" key at all (e.g. not valid JSON), fail open: exit 0 silently.
# This lets Claude proceed normally rather than injecting a malformed hook payload.
if [[ -z "$RAW_TRIGGER" ]]; then
  exit 0
fi

# Normalise unknown trigger values to "auto" (e.g. trigger="bogus").
TRIGGER="$RAW_TRIGGER"
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
