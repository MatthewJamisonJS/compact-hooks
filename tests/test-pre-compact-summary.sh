#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/pre-compact-summary.sh"
PASS=0; FAIL=0

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
    printf '  ✗ %s\n    expected to contain: %s\n' "$3" "$1"; ((FAIL++)) || true
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
