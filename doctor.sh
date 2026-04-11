#!/usr/bin/env bash
# compact-hooks doctor — checks installation health and auto-fixes what it can
#
# Usage:
#   bash doctor.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.sh)

set -euo pipefail

PRE_SCRIPT="${HOME}/.claude/scripts/pre-compact-summary.sh"
POST_SCRIPT="${HOME}/.claude/scripts/post-compact-capture.sh"
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

# ── bash-native single-hook injector (no Python required) ─────────────────────
# Adds one missing hook entry (PreCompact or PostCompact) to settings.json.
# Assumes settings.json exists and is valid JSON (callers have already verified).
_fix_missing_hook() {
  local path="$1" hook="$2"
  local _tmp="${path}.tmp.$$"
  awk -v target_hook="$hook" '
  BEGIN {
    ENTRY["PreCompact"]  = "    \"PreCompact\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"bash ~/.claude/scripts/pre-compact-summary.sh\", \"timeout\": 15, \"statusMessage\": \"Capturing task context...\"}]}]"
    ENTRY["PostCompact"] = "    \"PostCompact\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"bash ~/.claude/scripts/post-compact-capture.sh\", \"timeout\": 15, \"async\": true, \"statusMessage\": \"Saving summary...\"}]}]"
    entry = ENTRY[target_hook]
    n=0; depth=0; hooks_found=0; hooks_open_line=0; hooks_close_line=0
    root_close_line=0; in_hooks_val=0
  }
  {
    lines[++n] = $0
    prev_d = depth
    ll = length($0)
    for (k=1; k<=ll; k++) {
      c = substr($0, k, 1)
      if (c=="{" || c=="[") depth++
      else if (c=="}" || c=="]") {
        depth--
        if (depth==0) root_close_line=n
        if (in_hooks_val && depth==1) { hooks_close_line=n; in_hooks_val=0 }
      }
    }
    if (prev_d==1 && !hooks_found && $0 ~ /"hooks"/) {
      hooks_found=1; hooks_open_line=n; in_hooks_val=1
    }
  }
  END {
    inject_at=0; inject_str=""; comma_at=0
    if (hooks_found && hooks_close_line>0) {
      inject_at = hooks_close_line
      if (hooks_close_line > hooks_open_line+1) {
        for (j=hooks_close_line-1; j>hooks_open_line; j--) {
          if (lines[j] ~ /[^[:space:]]/) { comma_at=j; break }
        }
      }
      inject_str = entry "\n"
    } else if (!hooks_found && root_close_line>0) {
      inject_at = root_close_line
      for (j=root_close_line-1; j>=1; j--) {
        if (lines[j] ~ /[^[:space:]]/) {
          t=lines[j]; gsub(/[[:space:]]*$/,"",t)
          if (substr(t,length(t),1) != "{") comma_at=j
          break
        }
      }
      inject_str = "  \"hooks\": {\n" entry "\n  }\n"
    }
    if (comma_at>0) {
      t=lines[comma_at]; gsub(/[[:space:]]*$/,"",t)
      lc=substr(t,length(t),1)
      if (lc!="," && lc!="{" && lc!="[") lines[comma_at]=t","
    }
    for (i=1; i<=n; i++) {
      if (i==inject_at && inject_str!="") printf "%s", inject_str
      print lines[i]
    }
  }
  ' "$path" > "$_tmp" && mv "$_tmp" "$path" || { rm -f "$_tmp"; return 1; }
}

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

# 1-2. Scripts exist + executable
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

# 3. settings.json valid JSON
if [[ ! -f "$SETTINGS_PATH" ]]; then
  _chk "settings.json exists" "FAIL" "re-run install.sh"
elif bash -c "
  content=\$(cat '$SETTINGS_PATH')
  trimmed=\$(printf '%s' \"\$content\" | sed 's/^[[:space:]]*//')
  [[ \"\${trimmed:0:1}\" == '{' || \"\${trimmed:0:1}\" == '[' ]]
" 2>/dev/null; then
  _chk "settings.json valid JSON" "PASS" ""

  # 4-5. Hook entries present
  for _hook in PreCompact PostCompact; do
    _present=$(grep -qF "\"$_hook\"" "$SETTINGS_PATH" && echo "yes" || echo "no")
    if [[ "$_present" == "yes" ]]; then
      _chk "${_hook} hook registered" "PASS" ""
    else
      if _fix_missing_hook "$SETTINGS_PATH" "$_hook"; then
        _chk "${_hook} hook registered" "FIXED" "hook entry added to settings.json"
      else
        _chk "${_hook} hook registered" "FAIL" "add hook manually — see settings-hooks-snippet.json"
      fi
    fi
  done
else
  _chk "settings.json valid JSON" "FAIL" "file is malformed — re-run install.sh"
fi

# 6. CLAUDE.md Session Resume
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

# 7. Dry-run pre-compact-summary.sh
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
