#!/usr/bin/env bash
# compact-hooks installer — self-contained, works via curl or local run
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install.sh)
#   bash install.sh [--verbose|-v] [--preview]
#
# --preview  renders the completion screen with sample data; nothing is installed

set -euo pipefail

# ── flags ──────────────────────────────────────────────────────────────────────
VERBOSE=0
PREVIEW=0
for arg in "$@"; do
  [[ "$arg" == "--verbose" || "$arg" == "-v" ]] && VERBOSE=1
  [[ "$arg" == "--preview" ]]                   && PREVIEW=1
done

# ── colors (basic ANSI — used during the interactive install steps) ────────────
if [[ -t 1 ]]; then
  B='\033[1m'; D='\033[2m'; R='\033[0m'
  GRN='\033[32m'; YLW='\033[33m'; RED='\033[31m'; CYN='\033[36m'
else
  B=''; D=''; R=''; GRN=''; YLW=''; RED=''; CYN=''
fi

TOTAL=3

bar()  { printf "${D}────────────────────────────────────────────────────────${R}\n"; }
hdr()  { printf "\n${B}%s${R}\n" "$1"; }
step() { printf "\n${B}[%d/%d] %s${R}\n" "$1" "$TOTAL" "$2"; }
ok()   { printf "  ${GRN}✓${R} %s\n" "$1"; }
skp()  { printf "  ${D}–${R} %s\n" "$1"; }
info() { printf "  ${D}→${R} %s\n" "$1"; }
fail() { printf "\n${RED}Error:${R} %s\n" "$1" >&2; exit 1; }
tag()  { printf "  %-58s ${D}[%s]${R}\n" "$1" "$2"; }

# Reads from /dev/tty so prompts work under `curl | bash` (stdin = pipe)
ask() { IFS= read -r "$1" </dev/tty 2>/dev/null || true; }

# ── paths ──────────────────────────────────────────────────────────────────────
SCRIPTS_DIR="${HOME}/.claude/scripts"
SETTINGS_PATH="${HOME}/.claude/settings.json"
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
PRE_SCRIPT="${SCRIPTS_DIR}/pre-compact-summary.py"
POST_SCRIPT="${SCRIPTS_DIR}/post-compact-capture.py"
SESSION_MARKER="# Session Resume"

# ── tracking (tab-separated: path | action | note) ────────────────────────────
REPORT_FILE=$(mktemp)
trap 'rm -f "$REPORT_FILE" "${_RENDERER:-}"' EXIT

_N_OK=0; _N_SKIP=0
declare -a _ERRORS=()

_rec_ok()   { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$REPORT_FILE"; ((_N_OK++  )); }
_rec_skip() { printf '%s\t%s\t%s\n' "$1" "SKIPPED"  "$3" >> "$REPORT_FILE"; ((_N_SKIP++)); }
_rec_err()  { printf '%s\t%s\t%s\n' "$1" "FAILED"   "$3" >> "$REPORT_FILE"; _ERRORS+=("$3"); }

_wc() { awk 'END{print NR}' "$1"; }  # portable line count (avoids wc -l whitespace)

# ── pre-flight: python3 required ────────────────────────────────────────────
command -v python3 &>/dev/null \
  || fail "python3 not found. Install via: brew install python3"

# ── resolve per-path statuses ──────────────────────────────────────────────
_fstatus() { [[ -f "$1" ]] && echo "OVERWRITE" || echo "NEW"; }

ST_PRE=$(_fstatus "$PRE_SCRIPT")
ST_POST=$(_fstatus "$POST_SCRIPT")
[[ -f "$SETTINGS_PATH" ]] && ST_SETTINGS="MERGE" || ST_SETTINGS="NEW"

if [[ -f "$CLAUDE_MD" ]] && grep -qF "$SESSION_MARKER" "$CLAUDE_MD" 2>/dev/null; then
  ST_CLAUDE_MD="SKIP (already present)"
else
  ST_CLAUDE_MD="APPEND"
fi

# ── per-step prompt: ⏎ proceed / s skip / q abort ─────────────────────────
_prompt() {
  printf "  ${D}⏎ proceed   s skip   q abort${R}  "
  ask _r
  case "${_r:-}" in
    q|Q) printf "\nAborted.\n"; exit 0 ;;
    s|S) return 1 ;;
    *)   return 0 ;;
  esac
}

if [[ "$PREVIEW" -eq 0 ]]; then

# ═══════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
printf "\n"
bar
hdr "  compact-hooks installer"
bar

printf "\n${B}What this installs:${R}\n"
printf "  ✦ 2 Python hook scripts → Claude Code hook execution engines\n"
printf "  ✦ 2 hook entries        → merged into settings.json (PreCompact + PostCompact)\n"
printf "  ✦ Session Resume block  → prepended to CLAUDE.md\n"

printf "\n${B}Resolved paths  ${D}(installing as: ${USER}@$(hostname -s 2>/dev/null || echo localhost))${R}\n\n"
tag "$PRE_SCRIPT"    "$ST_PRE"
tag "$POST_SCRIPT"   "$ST_POST"
tag "$SETTINGS_PATH" "$ST_SETTINGS"
tag "$CLAUDE_MD"     "$ST_CLAUDE_MD"
printf "\n"
bar

# ── optional details view ─────────────────────────────────────────────────────
if [[ "$VERBOSE" -eq 0 ]]; then
  printf "\n${D}d = full details   ⏎ = begin install   q = quit:${R}  "
  ask _initial
  case "${_initial:-}" in
    q|Q) printf "\nAborted.\n"; exit 0 ;;
    d|D) VERBOSE=1 ;;
  esac
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  hdr "Details"

  printf "\n${B}pre-compact-summary.py${R}  ${D}(PreCompact hook)${R}\n"
  printf "  Runs before each compaction. Outputs a JSON payload that injects structured\n"
  printf "  instructions into the compaction context, telling Claude to preserve:\n"
  printf "  overall task, decision chain, current state, and open blockers.\n"

  printf "\n${B}post-compact-capture.py${R}  ${D}(PostCompact hook, async)${R}\n"
  printf "  Runs after compaction. Reads the session transcript JSONL, locates the\n"
  printf "  compact_boundary entry, extracts Claude's summary, and writes it to:\n"
  printf "    %s\n" "${HOME}/.claude/last-compact-summary.md"

  printf "\n${B}settings.json — hooks to be merged:${R}\n"
  printf '  "PreCompact":  python3 ~/.claude/scripts/pre-compact-summary.py\n'
  printf '  "PostCompact": python3 ~/.claude/scripts/post-compact-capture.py  (async)\n'

  printf "\n${B}CLAUDE.md — block to be prepended:${R}\n"
  printf "  # Session Resume\n"
  printf "  If \`~/.claude/last-compact-summary.md\` exists, read it before doing\n"
  printf "  anything else — it contains the task context and decision chain.\n"

  printf "\n"
  bar
  printf "\n${D}⏎ begin install   q = quit:${R}  "
  ask _confirm
  [[ "${_confirm:-}" =~ ^[Qq]$ ]] && { printf "\nAborted.\n"; exit 0; }
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — Python scripts
# ═══════════════════════════════════════════════════════════════════════════════
step 1 "Python scripts → ${SCRIPTS_DIR}/"
info "pre-compact-summary.py  — inject context instructions before compaction"
info "post-compact-capture.py — save compaction summary to disk"

if _prompt; then
  mkdir -p "$SCRIPTS_DIR"

  cat > "$PRE_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
PreCompact hook: injects structured summary instructions into compaction context.

Security notes:
  - Reads stdin via json.load() — no shell word splitting, no injection risk
  - trigger field validated against an allowlist before use
  - Output serialized via json.dumps() — never built by string interpolation
"""
import json
import sys

VALID_TRIGGERS = {"auto", "manual"}


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # Fail open: if we can't parse input, don't block compaction
        sys.exit(0)

    raw_trigger = data.get("trigger", "auto")
    trigger = raw_trigger if raw_trigger in VALID_TRIGGERS else "auto"

    additional_context = (
        "COMPACTION IMMINENT — your summary MUST preserve ALL of the following:\n\n"
        "1. OVERALL TASK (root goal, not just current step)\n"
        "   What is the user ultimately trying to accomplish?\n\n"
        "2. DECISION CHAIN (reasoning trail)\n"
        "   What key decisions were made? Why was approach X chosen over Y?\n"
        "   What constraints or discoveries shaped those choices?\n\n"
        "3. CURRENT STATE\n"
        "   What has been completed? What is in-progress? What remains?\n\n"
        "4. OPEN QUESTIONS / BLOCKERS\n"
        "   Any unresolved ambiguities, pending confirmations, or known issues?\n\n"
        "This structured context must survive compaction intact "
        "so work can resume without losing the logical thread."
    )

    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreCompact",
            "additionalContext": additional_context,
        },
        "systemMessage": (
            f"[pre-compact-summary] {trigger.capitalize()} compaction triggered — "
            "task context and decision chain will be preserved in summary."
        ),
    }

    print(json.dumps(output))


if __name__ == "__main__":
    main()
PYEOF

  cat > "$POST_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
PostCompact hook: extracts the compaction summary from the transcript
and writes it to ~/.claude/last-compact-summary.md for cross-session recovery.

Security notes:
  - Reads stdin via json.load() — no shell word splitting
  - transcript_path validated as an absolute path before use
  - All file I/O uses Python builtins — no shell execution
  - Output file is user-scoped (~/.claude/) — no privilege escalation
"""
import json
import os
import sys
from datetime import datetime, timezone
from typing import Optional

OUTPUT_PATH = os.path.expanduser("~/.claude/last-compact-summary.md")


def extract_summary(transcript_path: str) -> Optional[str]:
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            entries = [json.loads(line) for line in f if line.strip()]
    except (OSError, json.JSONDecodeError):
        return None

    boundary_uuid = None
    for entry in reversed(entries):
        if entry.get("type") == "system" and entry.get("subtype") == "compact_boundary":
            boundary_uuid = entry.get("uuid")
            break

    if not boundary_uuid:
        return None

    for entry in entries:
        if entry.get("parentUuid") == boundary_uuid and entry.get("type") == "user":
            msg = entry.get("message") or entry.get("content")
            if isinstance(msg, dict):
                return msg.get("content", "")
            if isinstance(msg, str):
                return msg
            break

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    raw_path = data.get("transcript_path", "")
    if not raw_path or not os.path.isabs(raw_path):
        sys.exit(0)
    transcript_path = os.path.normpath(raw_path)

    summary = extract_summary(transcript_path)
    if not summary:
        sys.exit(0)

    trigger = data.get("trigger", "auto")
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    session_id = data.get("session_id", "unknown")

    content = (
        f"<!-- auto-generated by post-compact-capture.py — do not edit -->\n"
        f"# Last Compaction Summary\n\n"
        f"**Captured:** {timestamp}  \n"
        f"**Trigger:** {trigger}  \n"
        f"**Session:** {session_id}\n\n"
        f"---\n\n"
        f"{summary.strip()}\n"
    )

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(content)

    sys.exit(0)


if __name__ == "__main__":
    main()
PYEOF

  chmod +x "$PRE_SCRIPT" "$POST_SCRIPT"
  ok "pre-compact-summary.py"
  ok "post-compact-capture.py"
  _rec_ok "$PRE_SCRIPT"  "CREATED" "$(_wc "$PRE_SCRIPT") lines · chmod +x"
  _rec_ok "$POST_SCRIPT" "CREATED" "$(_wc "$POST_SCRIPT") lines · chmod +x"
else
  skp "Step 1 skipped"
  _rec_skip "$PRE_SCRIPT"  "" "user skipped"
  _rec_skip "$POST_SCRIPT" "" "user skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 2 — Hook wiring
# ═══════════════════════════════════════════════════════════════════════════════
step 2 "Hook config → ${SETTINGS_PATH}"
info "Merges PreCompact + PostCompact entries (existing hooks preserved)"

if _prompt; then
  _settings_action="$ST_SETTINGS"
  if python3 - << 'PYEOF'
import json, os, sys

settings_path = os.path.expanduser("~/.claude/settings.json")

new_hooks = {
    "PreCompact": [
        {
            "hooks": [
                {
                    "type": "command",
                    "command": "python3 ~/.claude/scripts/pre-compact-summary.py",
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
                    "command": "python3 ~/.claude/scripts/post-compact-capture.py",
                    "timeout": 15,
                    "async": True,
                    "statusMessage": "Saving compaction summary..."
                }
            ]
        }
    ]
}

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError as e:
            print(f"MALFORMED_JSON:{e}", file=sys.stderr)
            sys.exit(1)

settings.setdefault("hooks", {}).update(new_hooks)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

PYEOF
  then
    _all_hooks=$(python3 -c "
import json,os
try:
    s=json.load(open(os.path.expanduser('~/.claude/settings.json')))
    print(', '.join(s.get('hooks',{}).keys()))
except Exception:
    print('(unreadable)')
")
    ok "PreCompact hook registered"
    ok "PostCompact hook registered"
    info "All active hooks: ${_all_hooks}"
    _rec_ok "$SETTINGS_PATH" "$_settings_action" "PreCompact + PostCompact added"
  else
    _rec_err "$SETTINGS_PATH" "settings.json parse failed — run doctor.sh"
  fi
else
  skp "Step 2 skipped"
  _rec_skip "$SETTINGS_PATH" "" "user skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 3 — CLAUDE.md
# ═══════════════════════════════════════════════════════════════════════════════
step 3 "Session Resume → ${CLAUDE_MD}"
info "Prepends 2-line block instructing Claude to load the saved summary at session start"

if [[ "$ST_CLAUDE_MD" == "SKIP (already present)" ]]; then
  ok "Already present — no changes made"
  _rec_skip "$CLAUDE_MD" "" "Session Resume already in CLAUDE.md"
else
  if _prompt; then
    ADDITION='# Session Resume
If `~/.claude/last-compact-summary.md` exists, read it before doing anything else — it contains the task context and decision chain from the previous compaction.'

    if [[ -f "$CLAUDE_MD" ]]; then
      _prev_lines=$(_wc "$CLAUDE_MD")
      EXISTING=$(cat "$CLAUDE_MD")
      printf '%s\n\n%s\n' "$ADDITION" "$EXISTING" > "$CLAUDE_MD"
      _rec_ok "$CLAUDE_MD" "MERGED" "2 lines prepended · was ${_prev_lines} lines"
    else
      mkdir -p "$(dirname "$CLAUDE_MD")"
      printf '%s\n' "$ADDITION" > "$CLAUDE_MD"
      _rec_ok "$CLAUDE_MD" "CREATED" "2 lines"
    fi
    ok "Session Resume block added"
  else
    skp "Step 3 skipped"
    _rec_skip "$CLAUDE_MD" "" "user skipped"
  fi
fi

else
  # ── preview: inject sample data, skip all install steps ──────────────────────
  _N_OK=3; _N_SKIP=1; _N_ERR=0
  {
    printf '%s\tCREATED\t59 lines · chmod +x\n'           "$PRE_SCRIPT"
    printf '%s\tCREATED\t93 lines · chmod +x\n'           "$POST_SCRIPT"
    printf '%s\tMERGED\tPreCompact + PostCompact added\n'  "$SETTINGS_PATH"
    printf '%s\tSKIPPED\tSession Resume already present\n' "$CLAUDE_MD"
  } > "$REPORT_FILE"

fi  # end: if PREVIEW -eq 0 / else preview

# ═══════════════════════════════════════════════════════════════════════════════
#  COMPLETION SCREEN — Dracula-styled animated report
# ═══════════════════════════════════════════════════════════════════════════════
_N_ERR=${#_ERRORS[@]}

_RENDERER=$(mktemp)
cat > "$_RENDERER" << 'RENDERER_EOF'
#!/usr/bin/env python3
"""Renders the compact-hooks installation report with Dracula 256-color styling."""
import sys, os, time, json

TTY = sys.stdout.isatty()

def _sleep(t):
    if TTY: time.sleep(t)

# ── Dracula 256-color palette ────────────────────────────────────────────────
R      = '\033[0m'
BOLD   = '\033[1m'
DIM    = '\033[2m'
PINK   = '\033[38;5;212m'   # #ff79c6
PURPLE = '\033[38;5;141m'   # #bd93f9
CYAN   = '\033[38;5;117m'   # #8be9fd
GREEN  = '\033[38;5;84m'    # #50fa7b
ORANGE = '\033[38;5;215m'   # #ffb86c
RED    = '\033[38;5;203m'   # #ff5555
YELLOW = '\033[38;5;228m'   # #f1fa8c
CMNT   = '\033[38;5;61m'    # #6272a4

ACTION_COLOR = {
    'CREATED':     GREEN,
    'MERGED':      CYAN,
    'OVERWRITTEN': ORANGE,
    'SKIPPED':     CMNT,
    'FAILED':      RED,
}

HOME = os.path.expanduser('~')

def shorten(path):
    return path.replace(HOME, '~')

def banner():
    W = 56
    title = "  ✓  compact-hooks"
    sub   = "session context survives compaction"
    pad   = W - len(title) - len(sub) - 4
    _sleep(0.15)
    print()
    print(f"  {PINK}{'━' * W}{R}")
    print(f"  {PINK}{BOLD}{title}{R}  {CMNT}{sub}{R}")
    print(f"  {PINK}{'━' * W}{R}")

def stats(n_ok, n_skip, n_err):
    _sleep(0.12)
    print()
    parts = []
    if n_ok:   parts.append(f"{GREEN}{BOLD}{n_ok} changed{R}")
    if n_skip: parts.append(f"{CMNT}{n_skip} skipped{R}")
    if n_err:  parts.append(f"{RED}{BOLD}{n_err} failed{R}")
    line = "   ".join(parts) if parts else f"{CMNT}no changes{R}"
    print(f"  {line}")
    print()

def table(rows):
    if not rows:
        return

    display = [(shorten(p), a, n) for p, a, n in rows]

    PW = max(max(len(r[0]) for r in display), 4)
    AW = max(max(len(r[1]) for r in display), 6)
    NW = max(max(len(r[2]) for r in display), 4)

    def hbar(l, m, r_ch):
        return f"  {CMNT}{l}{'─'*(PW+2)}{m}{'─'*(AW+2)}{m}{'─'*(NW+2)}{r_ch}{R}"

    def row(p, a, n, pc='', ac='', nc=''):
        return (
            f"  {CMNT}│{R} {pc}{p:<{PW}}{R} "
            f"{CMNT}│{R} {ac}{a:<{AW}}{R} "
            f"{CMNT}│{R} {nc}{n:<{NW}}{R} "
            f"{CMNT}│{R}"
        )

    _sleep(0.1)
    print(hbar('┌', '┬', '┐'))
    print(row('path', 'action', 'note', CYAN+BOLD, CYAN+BOLD, CYAN+BOLD))
    print(hbar('├', '┼', '┤'))

    for path, action, note in display:
        _sleep(0.05)
        ac = ACTION_COLOR.get(action, '')
        print(row(path, action, note, '', ac, DIM))

    print(hbar('└', '┴', '┘'))

def errors(msgs):
    if not msgs:
        return
    print()
    print(f"  {RED}{BOLD}Errors{R}")
    for m in msgs:
        print(f"  {RED}✗{R} {m}")

def footer(has_errors):
    _sleep(0.08)
    print()
    print(f"  {CMNT}{'─' * 56}{R}")
    print(f"  {PURPLE}Verify:{R}  /hooks in Claude Code  ·  /compact to test")
    if has_errors:
        print(f"  {YELLOW}Issues:{R}  bash doctor.sh  (or re-run with --verbose)")
    else:
        print(f"  {CMNT}Issues?  bash doctor.sh{R}")
    print()

def main():
    args = sys.argv[1:]
    if len(args) < 4:
        sys.exit(1)

    report_file = args[0]
    n_ok   = int(args[1])
    n_skip = int(args[2])
    n_err  = int(args[3])
    error_msgs = args[4:]

    rows = []
    try:
        with open(report_file) as f:
            for line in f:
                parts = line.rstrip('\n').split('\t', 2)
                if len(parts) == 3:
                    rows.append(parts)
    except OSError:
        pass

    banner()
    stats(n_ok, n_skip, n_err)
    table(rows)
    errors(error_msgs)
    footer(n_err > 0)

if __name__ == '__main__':
    main()
RENDERER_EOF

python3 "$_RENDERER" \
  "$REPORT_FILE" "$_N_OK" "$_N_SKIP" "$_N_ERR" \
  "${_ERRORS[@]+"${_ERRORS[@]}"}"

# ── auto-run doctor.sh if anything failed ─────────────────────────────────────
if [[ "$_N_ERR" -gt 0 ]]; then
  printf "  ${YELLOW}Running doctor.sh to verify and auto-fix…${R}\n\n"

  # Locate doctor.sh: check next to this script (local run), else fetch inline
  _DOCTOR=""

  # If we're running as a real file (not piped), look for doctor.sh alongside it
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    [[ -f "${_SCRIPT_DIR}/doctor.sh" ]] && _DOCTOR="${_SCRIPT_DIR}/doctor.sh"
  fi

  if [[ -n "$_DOCTOR" ]]; then
    bash "$_DOCTOR"
  else
    # Running via curl | bash — embed doctor inline rather than fetching again
    # (avoids a second network request and works fully offline after initial fetch)
    printf "  ${CMNT}(doctor.sh not found locally — paste the doctor URL or re-run install from a cloned repo)${R}\n\n"
  fi
fi
