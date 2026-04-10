# compact-hooks

A small quality-of-life setup for Claude Code that I put together and wanted to share.

When Claude compacts a long conversation, these hooks make sure the context that matters — what you were working on, the decisions made along the way, what's still left — actually survives into the next session.

It's a starting point. The defaults are mine. Change them to fit how you work.

![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-bd93f9?style=flat-square&labelColor=282a36)
![License](https://img.shields.io/badge/license-MIT-50fa7b?style=flat-square&labelColor=282a36)

---

## Why this exists

Claude Code compacts conversations automatically when they get long. It writes a summary — but that summary doesn't always hold onto the thread of what you were actually doing. The next session starts fresh and you end up re-explaining things.

This is just two small hook scripts and one line in your CLAUDE.md that work together to fix that.

---

## Install

**You'll need:** Claude Code (recent version with `PreCompact`/`PostCompact` hook support).

No other dependencies — no Python, Node, or any runtime.

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

**Just want to see what the finish screen looks like without actually installing?**

```bash
# macOS / Linux
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.sh) --preview
```

```powershell
# Windows
.\install.ps1 -Preview
```

---

## What it installs

| File | Where | What it does |
|---|---|---|
| `pre-compact-summary.sh` (macOS/Linux) | `~/.claude/scripts/` | Runs before compaction — tells Claude what to preserve |
| `pre-compact-summary.ps1` (Windows) | `~/.claude/scripts/` | Same, PowerShell variant |
| `post-compact-capture.sh` (macOS/Linux) | `~/.claude/scripts/` | Runs after compaction — saves the summary to disk |
| `post-compact-capture.ps1` (Windows) | `~/.claude/scripts/` | Same, PowerShell variant |
| Hook entries | `~/.claude/settings.json` | Wires the scripts into Claude Code's lifecycle |
| Session Resume block | `~/.claude/CLAUDE.md` | Tells Claude to load the saved summary at session start |

Anything you already have in `settings.json` or `CLAUDE.md` stays untouched. Running the installer again is safe.

---

## Verify it's working

Open Claude Code and run:

```
/hooks
```

You should see `PreCompact` and `PostCompact` listed. Then run `/compact` to trigger a test — you'll see status messages while it runs.

Start a new session after that. If a summary was saved, Claude will read it before responding to anything.

---

## Something's broken

**macOS / Linux:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.sh)
```

**Windows:**

```powershell
irm https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.ps1 | iex
```

This runs through 8 checks and fixes what it can on its own. If the scripts themselves need to be rewritten, it'll tell you to re-run the installer.

---

## How it actually works

<details>
<summary>Show technical details</summary>

**Before compaction (`pre-compact-summary.sh` / `pre-compact-summary.ps1`)**

Claude Code fires this hook before compacting. The script returns a JSON payload that gets passed into the compaction model, asking it to specifically preserve:

- What the user is ultimately trying to accomplish
- The reasoning behind key decisions made during the session
- What's done, what's in progress, what's next
- Exact paths of every file touched this session
- The most recent error message verbatim
- Any unresolved questions or blockers

**After compaction (`post-compact-capture.sh` / `post-compact-capture.ps1`)**

This one runs in the background after compaction finishes. It reads the session transcript, finds the compaction boundary, pulls out the summary Claude wrote, and saves it to `~/.claude/last-compact-summary.md` with a timestamp.

If the primary extraction fails, it falls back to the last assistant message. If that also fails, it writes a diagnostic file so the next session knows the summary is not trustworthy.

**Session Resume**

A two-line addition to `~/.claude/CLAUDE.md` tells Claude to check for that file at the start of every session and read it if it exists.

**A few notes on the implementation**

- Zero runtime dependencies — bash 3.2+ on macOS/Linux, PowerShell 5.1+ on Windows (both built in)
- Input is parsed with native JSON tooling, never `eval()` or shell interpolation
- The transcript path is validated as absolute before use
- Everything writes to `~/.claude/` — no elevated permissions needed

</details>

---

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

---

## Make it yours

This is a starting point, not a prescription. The defaults I picked reflect how I think about sessions — but your mental model might be completely different, and that's the whole point.

The two files most worth rewriting are:

**`CLAUDE-md-addition.md`** — this becomes the instruction Claude reads at the start of every session. It doesn't have to say what mine says. If you work in a way where something else matters more, write that instead.

**The `CONTEXT` string in `pre-compact-summary.sh` (or `pre-compact-summary.ps1` on Windows)** — this is what gets passed to Claude during compaction to shape what it preserves. The six sections I used are just one way to think about it. Rip them out. Add your own. Make it match how your brain actually organizes work.

```bash
# pre-compact-summary.sh — find this variable and rewrite it however you want
CONTEXT='COMPACTION IMMINENT — your summary MUST preserve ALL of the following:

1. OVERALL TASK ...
# ↑ this is yours to change
'
```

After editing, run the installer again to push your version to `~/.claude/scripts/`. Or edit the file directly there.

If something you build on top of this turns out to be genuinely useful, I'd love to see it.

---

## Contributing

If you find a bug or want to improve something, feel free to open an issue or a PR. Feedback is welcome.

Before submitting a change:

```bash
# macOS / Linux
bash install.sh --preview   # make sure the completion screen still renders
bash doctor.sh              # make sure all checks pass on a real install
bash tests/test-pre-compact-summary.sh
bash tests/test-post-compact-capture.sh
```

```powershell
# Windows
.\install.ps1 -Preview
.\doctor.ps1
pwsh tests/test-pre-compact-summary.ps1
pwsh tests/test-post-compact-capture.ps1
```

---

## Requirements

| | Minimum | Notes |
|---|---|---|
| Claude Code | recent | needs `PreCompact` / `PostCompact` hook support |
| bash | 3.2 | macOS ships 3.2; all Linux distros include it |
| PowerShell | 5.1 | built into Windows 10+; no install needed |
| OS | macOS / Linux / Windows | all supported natively |

---

## License

MIT — do whatever you want with it. See [LICENSE](LICENSE).
