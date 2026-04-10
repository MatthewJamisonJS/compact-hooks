#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/post-compact-capture.sh"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
PASS=0; FAIL=0

# Use a temp directory so tests never touch the user's real ~/.claude/ files.
TEST_HOME=$(mktemp -d)
export COMPACT_OUTPUT_PATH="${TEST_HOME}/.claude/last-compact-summary.md"
export COMPACT_BACKUP_PATH="${TEST_HOME}/.claude/last-compact-summary.bak.md"
OUTPUT_PATH="$COMPACT_OUTPUT_PATH"
BACKUP_PATH="$COMPACT_BACKUP_PATH"
mkdir -p "${TEST_HOME}/.claude"

# cleanup removes only the output files between tests; the EXIT trap removes
# the whole temp dir when the test suite finishes.
cleanup() { rm -f "$OUTPUT_PATH" "$BACKUP_PATH"; }
trap 'rm -rf "$TEST_HOME"' EXIT

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    printf '  ✓ %s\n' "$3"; ((PASS++)) || true
  else
    printf '  ✗ %s\n    expected: [%s]\n    got:      [%s]\n' "$3" "$1" "$2"; ((FAIL++)) || true
  fi
}

assert_contains() {
  if printf '%s' "$2" | grep -qF "$1"; then
    printf '  ✓ %s\n' "$3"; ((PASS++)) || true
  else
    printf '  ✗ %s\n    expected to contain: [%s]\n' "$3" "$1"; ((FAIL++)) || true
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
