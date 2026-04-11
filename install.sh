#!/usr/bin/env bash
# compact-hooks installer — self-contained, works via curl or local run
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.sh)
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
PRE_SCRIPT="${SCRIPTS_DIR}/pre-compact-summary.sh"
POST_SCRIPT="${SCRIPTS_DIR}/post-compact-capture.sh"
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

# ── bash-native settings.json hook merger (no Python required) ───────────────
# Injects PreCompact and/or PostCompact entries into settings.json using awk.
# Handles: no file, empty file, no hooks section, hooks section missing entries.
_merge_hooks_bash() {
  local path="$1"
  mkdir -p "$(dirname "$path")"

  # Idempotency: skip entries that are already present
  local need_pre=1 need_post=1
  if [[ -f "$path" ]]; then
    grep -qF '"PreCompact"'  "$path" 2>/dev/null && need_pre=0  || true
    grep -qF '"PostCompact"' "$path" 2>/dev/null && need_post=0 || true
  fi
  [[ $need_pre -eq 0 && $need_post -eq 0 ]] && return 0

  # No file, empty file, or effectively-empty {} — write from scratch
  local _stripped=""
  [[ -f "$path" ]] && _stripped=$(tr -d '[:space:]' < "$path")
  if [[ ! -f "$path" ]] || [[ -z "$_stripped" ]] || [[ "$_stripped" == "{}" ]]; then
    {
      printf '{\n  "hooks": {\n'
      if [[ $need_pre -eq 1 ]]; then
        printf '    "PreCompact": [{"hooks": [{"type": "command", "command": "bash ~/.claude/scripts/pre-compact-summary.sh", "timeout": 15, "statusMessage": "Capturing task context before compaction..."}]}]'
        [[ $need_post -eq 1 ]] && printf ','
        printf '\n'
      fi
      [[ $need_post -eq 1 ]] && printf '    "PostCompact": [{"hooks": [{"type": "command", "command": "bash ~/.claude/scripts/post-compact-capture.sh", "timeout": 15, "async": true, "statusMessage": "Saving compaction summary..."}]}]\n'
      printf '  }\n}\n'
    } > "$path"
    return 0
  fi

  # Validate: must start with {
  local _fc
  _fc=$(sed 's/^[[:space:]]*//' "$path" | head -c1)
  [[ "$_fc" != "{" ]] && return 1

  # Inject via awk: buffer all lines, track brace depth, inject at the right spot.
  #   (a) hooks section exists but missing entries → inject before hooks closing }
  #   (b) no hooks section → inject entire hooks block before root closing }
  local _tmp="${path}.tmp.$$"
  awk -v need_pre="$need_pre" -v need_post="$need_post" '
  BEGIN {
    PRE  = "\"PreCompact\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"bash ~/.claude/scripts/pre-compact-summary.sh\", \"timeout\": 15, \"statusMessage\": \"Capturing task context before compaction...\"}]}]"
    POST = "\"PostCompact\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"bash ~/.claude/scripts/post-compact-capture.sh\", \"timeout\": 15, \"async\": true, \"statusMessage\": \"Saving compaction summary...\"}]}]"
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
      if (need_pre)  inject_str = inject_str "    " PRE  (need_post ? "," : "") "\n"
      if (need_post) inject_str = inject_str "    " POST "\n"
    } else if (!hooks_found && root_close_line>0) {
      inject_at = root_close_line
      for (j=root_close_line-1; j>=1; j--) {
        if (lines[j] ~ /[^[:space:]]/) {
          t=lines[j]; gsub(/[[:space:]]*$/,"",t)
          if (substr(t,length(t),1) != "{") comma_at=j
          break
        }
      }
      inject_str  = "  \"hooks\": {\n"
      if (need_pre)  inject_str = inject_str "    " PRE  (need_post ? "," : "") "\n"
      if (need_post) inject_str = inject_str "    " POST "\n"
      inject_str  = inject_str "  }\n"
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
printf "  ✦ 2 shell hook scripts  → Claude Code hook execution engines\n"
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

  printf "\n${B}pre-compact-summary.sh${R}  ${D}(PreCompact hook)${R}\n"
  printf "  Runs before each compaction. Outputs a JSON payload that injects structured\n"
  printf "  instructions into the compaction context, telling Claude to preserve:\n"
  printf "  overall task, decision chain, current state, and open blockers.\n"

  printf "\n${B}post-compact-capture.sh${R}  ${D}(PostCompact hook, async)${R}\n"
  printf "  Runs after compaction. Reads the session transcript JSONL, locates the\n"
  printf "  compact_boundary entry, extracts Claude's summary, and writes it to:\n"
  printf "    %s\n" "${HOME}/.claude/last-compact-summary.md"

  printf "\n${B}settings.json — hooks to be merged:${R}\n"
  printf '  "PreCompact":  bash ~/.claude/scripts/pre-compact-summary.sh\n'
  printf '  "PostCompact": bash ~/.claude/scripts/post-compact-capture.sh  (async)\n'

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
#  STEP 1 — Shell scripts
# ═══════════════════════════════════════════════════════════════════════════════
step 1 "Shell scripts → ${SCRIPTS_DIR}/"
info "pre-compact-summary.sh  — inject context instructions before compaction"
info "post-compact-capture.sh — save compaction summary to disk"

if _prompt; then
  mkdir -p "$SCRIPTS_DIR"

  # Locate the scripts/ directory relative to this installer.
  # Works for local runs; curl | bash runs from a temp location so we embed inline.
  _SCRIPT_DIR=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  fi

  if [[ -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/scripts/pre-compact-summary.sh" ]]; then
    cp "${_SCRIPT_DIR}/scripts/pre-compact-summary.sh" "$PRE_SCRIPT"
    cp "${_SCRIPT_DIR}/scripts/post-compact-capture.sh" "$POST_SCRIPT"
  else
    cat > "$PRE_SCRIPT" << 'SHEOF'
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
SHEOF
    cat > "$POST_SCRIPT" << 'SHEOF'
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

# Allow tests to override output paths via env vars so the test suite never
# touches the user's real ~/.claude/ files.
OUTPUT_PATH="${COMPACT_OUTPUT_PATH:-${HOME}/.claude/last-compact-summary.md}"
BACKUP_PATH="${COMPACT_BACKUP_PATH:-${HOME}/.claude/last-compact-summary.bak.md}"

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
FALLBACK_USED=0

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
    FALLBACK_USED=1
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
  # When fallback was used, prepend a note so the next session knows the source.
  _FALLBACK_NOTE=""
  [[ $FALLBACK_USED -eq 1 ]] && _FALLBACK_NOTE=$'<!-- Note: primary extraction failed — using last assistant message as fallback -->\n\n'
  cat > "$OUTPUT_PATH" << EOF
<!-- auto-generated by post-compact-capture.sh — do not edit -->
# Last Compaction Summary

**Captured:** ${TIMESTAMP}
**Trigger:** ${TRIGGER}
**Session:** ${SESSION_ID}

---

${_FALLBACK_NOTE}${SUMMARY}
EOF
fi
SHEOF
  fi
  chmod +x "$PRE_SCRIPT" "$POST_SCRIPT"
  ok "pre-compact-summary.sh"
  ok "post-compact-capture.sh"
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
  if _merge_hooks_bash "$SETTINGS_PATH"; then
    ok "PreCompact hook registered"
    ok "PostCompact hook registered"
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
  # Compute line counts from source scripts if this is a local run; fall back to
  # a plain note when piped via curl (BASH_SOURCE[0] is "bash" or unset).
  _SRC_DIR=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    _SRC_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  fi
  _pre_note="chmod +x"
  _post_note="chmod +x"
  if [[ -n "$_SRC_DIR" && -f "${_SRC_DIR}/scripts/pre-compact-summary.sh" ]]; then
    _pre_note="$(_wc "${_SRC_DIR}/scripts/pre-compact-summary.sh") lines · chmod +x"
    _post_note="$(_wc "${_SRC_DIR}/scripts/post-compact-capture.sh") lines · chmod +x"
  fi
  _N_OK=3; _N_SKIP=1; _N_ERR=0
  {
    printf '%s\tCREATED\t%s\n'                              "$PRE_SCRIPT"    "$_pre_note"
    printf '%s\tCREATED\t%s\n'                              "$POST_SCRIPT"   "$_post_note"
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
