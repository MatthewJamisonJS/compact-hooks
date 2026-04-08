#!/usr/bin/env bash
# compact-hooks doctor — checks installation health and auto-fixes what it can
#
# Usage:
#   bash doctor.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/doctor.sh)

set -euo pipefail

PRE_SCRIPT="${HOME}/.claude/scripts/pre-compact-summary.py"
POST_SCRIPT="${HOME}/.claude/scripts/post-compact-capture.py"
SETTINGS_PATH="${HOME}/.claude/settings.json"
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
SESSION_MARKER="# Session Resume"

# ── Dracula palette ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
  PINK='\033[38;5;212m'; PURPLE='\033[38;5;141m'; CYAN='\033[38;5;117m'
  GREEN='\033[38;5;84m'; YELLOW='\033[38;5;228m'; RED='\033[38;5;203m'
  CMNT='\033[38;5;61m'
else
  R=''; BOLD=''; DIM=''; PINK=''; PURPLE=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; CMNT=''
fi

# ── state tracking ─────────────────────────────────────────────────────────────
declare -a _LABELS=()
declare -a _RESULTS=()    # PASS | FAIL | FIXED | WARN
declare -a _ACTIONS=()    # what was done (or empty)

_chk() {
  _LABELS+=("$1")
  _RESULTS+=("$2")
  _ACTIONS+=("${3:-}")
}

# ── run checks ─────────────────────────────────────────────────────────────────

# 1. python3
if command -v python3 &>/dev/null; then
  _PY=$(python3 --version 2>&1)
  _chk "python3 in PATH" "PASS" "$_PY"
else
  _chk "python3 in PATH" "FAIL" "install via: brew install python3"
fi

# 2-3. Scripts exist + executable
for _f in "$PRE_SCRIPT" "$POST_SCRIPT"; do
  _name=$(basename "$_f")
  if [[ ! -f "$_f" ]]; then
    _chk "$_name exists"     "FAIL" "re-run install.sh to restore"
    _chk "$_name executable" "FAIL" "re-run install.sh to restore"
  else
    _chk "$_name exists" "PASS" ""
    if [[ -x "$_f" ]]; then
      _chk "$_name executable" "PASS" ""
    else
      chmod +x "$_f"
      _chk "$_name executable" "FIXED" "chmod +x applied"
    fi
  fi
done

# 4. settings.json valid JSON
if [[ ! -f "$SETTINGS_PATH" ]]; then
  _chk "settings.json exists" "FAIL" "re-run install.sh"
elif python3 -c "import json; json.load(open('$SETTINGS_PATH'))" 2>/dev/null; then
  _chk "settings.json valid JSON" "PASS" ""

  # 5-6. Hook entries present
  for _hook in PreCompact PostCompact; do
    _present=$(python3 -c "
import json
s = json.load(open('$SETTINGS_PATH'))
print('yes' if '$_hook' in s.get('hooks', {}) else 'no')
")
    if [[ "$_present" == "yes" ]]; then
      _chk "${_hook} hook registered" "PASS" ""
    else
      # Auto-fix: merge the missing hook
      python3 - << PYEOF
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_name = "$_hook"

new_entry = {
    "PreCompact": [{"hooks": [{"type": "command",
        "command": "python3 ~/.claude/scripts/pre-compact-summary.py",
        "timeout": 15, "statusMessage": "Capturing task context..."}]}],
    "PostCompact": [{"hooks": [{"type": "command",
        "command": "python3 ~/.claude/scripts/post-compact-capture.py",
        "timeout": 15, "async": True, "statusMessage": "Saving summary..."}]}],
}[hook_name]

with open(settings_path) as f:
    settings = json.load(f)

settings.setdefault("hooks", {})[hook_name] = new_entry

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
PYEOF
      _chk "${_hook} hook registered" "FIXED" "hook entry added to settings.json"
    fi
  done
else
  _chk "settings.json valid JSON" "FAIL" "file is malformed — re-run install.sh"
fi

# 7. CLAUDE.md Session Resume
if [[ -f "$CLAUDE_MD" ]] && grep -qF "$SESSION_MARKER" "$CLAUDE_MD" 2>/dev/null; then
  _chk "CLAUDE.md has Session Resume" "PASS" ""
else
  ADDITION='# Session Resume
If `~/.claude/last-compact-summary.md` exists, read it before doing anything else — it contains the task context and decision chain from the previous compaction.'
  if [[ -f "$CLAUDE_MD" ]]; then
    EXISTING=$(cat "$CLAUDE_MD")
    printf '%s\n\n%s\n' "$ADDITION" "$EXISTING" > "$CLAUDE_MD"
  else
    mkdir -p "$(dirname "$CLAUDE_MD")"
    printf '%s\n' "$ADDITION" > "$CLAUDE_MD"
  fi
  _chk "CLAUDE.md has Session Resume" "FIXED" "block prepended"
fi

# 8. Dry-run pre-compact-summary.py
if [[ -f "$PRE_SCRIPT" && -x "$PRE_SCRIPT" ]] && command -v python3 &>/dev/null; then
  _dry=$(echo '{"trigger":"auto"}' | python3 "$PRE_SCRIPT" 2>/dev/null || echo "ERROR")
  if echo "$_dry" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'hookSpecificOutput' in d
assert d['hookSpecificOutput'].get('hookEventName') == 'PreCompact'
" 2>/dev/null; then
    _chk "pre-compact-summary.py dry-run" "PASS" "JSON output valid"
  else
    _chk "pre-compact-summary.py dry-run" "FAIL" "script produced unexpected output — re-run install.sh"
  fi
else
  _chk "pre-compact-summary.py dry-run" "WARN" "skipped (script missing or no python3)"
fi

# ── render report ──────────────────────────────────────────────────────────────
_RENDERER=$(mktemp)
trap 'rm -f "$_RENDERER"' EXIT

cat > "$_RENDERER" << 'RENDERER_EOF'
#!/usr/bin/env python3
import sys, os, time

TTY = sys.stdout.isatty()
def _sleep(t):
    if TTY: time.sleep(t)

R='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
PINK='\033[38;5;212m'; PURPLE='\033[38;5;141m'; CYAN='\033[38;5;117m'
GREEN='\033[38;5;84m'; YELLOW='\033[38;5;228m'; RED='\033[38;5;203m'
ORANGE='\033[38;5;215m'; CMNT='\033[38;5;61m'

RESULT_STYLE = {
    'PASS':  (GREEN,  '✓'),
    'FIXED': (CYAN,   '✦'),
    'WARN':  (YELLOW, '!'),
    'FAIL':  (RED,    '✗'),
}

def main():
    args = sys.argv[1:]  # interleaved: label, result, action ...
    rows = []
    for i in range(0, len(args) - 2, 3):
        rows.append((args[i], args[i+1], args[i+2]))

    n_pass  = sum(1 for _, r, _ in rows if r == 'PASS')
    n_fixed = sum(1 for _, r, _ in rows if r == 'FIXED')
    n_fail  = sum(1 for _, r, _ in rows if r == 'FAIL')
    n_warn  = sum(1 for _, r, _ in rows if r == 'WARN')

    W = 56
    _sleep(0.1)
    print()
    print(f"  {PINK}{'━' * W}{R}")
    print(f"  {PINK}{BOLD}  compact-hooks doctor{R}")
    print(f"  {PINK}{'━' * W}{R}")
    print()

    parts = []
    if n_pass:  parts.append(f"{GREEN}{BOLD}{n_pass} pass{R}")
    if n_fixed: parts.append(f"{CYAN}{BOLD}{n_fixed} fixed{R}")
    if n_warn:  parts.append(f"{YELLOW}{n_warn} warn{R}")
    if n_fail:  parts.append(f"{RED}{BOLD}{n_fail} fail{R}")
    print("  " + "   ".join(parts))
    print()
    _sleep(0.1)

    LW = max(len(r[0]) for r in rows)
    RW = 5
    AW = max((len(r[2]) for r in rows), default=0)
    AW = max(AW, 6)

    def hbar(l, m, r_ch):
        return f"  {CMNT}{l}{'─'*(LW+2)}{m}{'─'*(RW+2)}{m}{'─'*(AW+2)}{r_ch}{R}"

    def row(label, result, action, lc='', rc='', ac=''):
        return (
            f"  {CMNT}│{R} {lc}{label:<{LW}}{R} "
            f"{CMNT}│{R} {rc}{result:<{RW}}{R} "
            f"{CMNT}│{R} {ac}{action:<{AW}}{R} "
            f"{CMNT}│{R}"
        )

    print(hbar('┌', '┬', '┐'))
    print(row('check', 'result', 'action', CYAN+BOLD, CYAN+BOLD, CYAN+BOLD))
    print(hbar('├', '┼', '┤'))

    for label, result, action in rows:
        _sleep(0.05)
        color, icon = RESULT_STYLE.get(result, ('', '?'))
        print(row(label, f"{color}{icon} {result}{R}", action or '—', '', '', DIM))

    print(hbar('└', '┴', '┘'))
    print()
    _sleep(0.08)
    print(f"  {CMNT}{'─' * W}{R}")

    if n_fail == 0 and n_fixed == 0:
        print(f"  {GREEN}{BOLD}All checks pass.{R}  {CMNT}No action needed.{R}")
    elif n_fail == 0:
        print(f"  {CYAN}{BOLD}{n_fixed} issue(s) auto-fixed.{R}  Restart Claude Code to pick up changes.")
    else:
        print(f"  {RED}{BOLD}{n_fail} issue(s) require manual action.{R}  Re-run install.sh.")

    print()

if __name__ == '__main__':
    main()
RENDERER_EOF

# Build flat args list: label result action label result action ...
_ARGS=()
for i in "${!_LABELS[@]}"; do
  _ARGS+=("${_LABELS[$i]}" "${_RESULTS[$i]}" "${_ACTIONS[$i]}")
done

python3 "$_RENDERER" "${_ARGS[@]}"
