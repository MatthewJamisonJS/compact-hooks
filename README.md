# compact-hooks

A small quality-of-life setup for Claude Code that I put together and wanted to share.

When Claude compacts a long conversation, these hooks make sure the context that matters — what you were working on, the decisions made along the way, what's still left — actually survives into the next session.

It's a starting point. The defaults are mine. Change them to fit how you work.

![Python](https://img.shields.io/badge/python-3.7%2B-8be9fd?style=flat-square&labelColor=282a36)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-bd93f9?style=flat-square&labelColor=282a36)
![License](https://img.shields.io/badge/license-MIT-50fa7b?style=flat-square&labelColor=282a36)

---

## Why this exists

Claude Code compacts conversations automatically when they get long. It writes a summary — but that summary doesn't always hold onto the thread of what you were actually doing. The next session starts fresh and you end up re-explaining things.

This is just two small hook scripts and one line in your CLAUDE.md that work together to fix that.

---

## Install

**You'll need:** Python 3.7+ and Claude Code.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.sh)
```

> [!NOTE]
> Use `bash <(...)` rather than `curl ... | bash`. The `<(...)` form keeps your terminal's stdin connected so the interactive prompts work correctly.

The installer shows you what it's going to do and where before it does anything, and asks you to confirm each step.

**Just want to see what the finish screen looks like without actually installing?**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/install.sh) --preview
```

---

## What it installs

| File | Where | What it does |
|---|---|---|
| `pre-compact-summary.py` | `~/.claude/scripts/` | Runs before compaction — tells Claude what to preserve |
| `post-compact-capture.py` | `~/.claude/scripts/` | Runs after compaction — saves the summary to disk |
| Hook entries | `~/.claude/settings.json` | Wires the two scripts into Claude Code's lifecycle |
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

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MatthewJamisonJS/compact-hooks/main/doctor.sh)
```

This runs through 8 checks and fixes what it can on its own. If the scripts themselves need to be rewritten, it'll tell you to re-run the installer.

---

## How it actually works

<details>
<summary>Show technical details</summary>

**Before compaction (`pre-compact-summary.py`)**

Claude Code fires this hook before compacting. The script returns a JSON payload that gets passed into the compaction model, asking it to specifically preserve:

- What the user is ultimately trying to accomplish
- The reasoning behind key decisions made during the session
- What's done, what's in progress, what's next
- Any unresolved questions or blockers

**After compaction (`post-compact-capture.py`)**

This one runs in the background after compaction finishes. It reads the session transcript, finds the compaction boundary, pulls out the summary Claude wrote, and saves it to `~/.claude/last-compact-summary.md` with a timestamp.

**Session Resume**

A two-line addition to `~/.claude/CLAUDE.md` tells Claude to check for that file at the start of every session and read it if it exists.

**A few notes on the implementation**

- Pure Python stdlib — nothing to install, no network calls
- Input is parsed with `json.load()`, never `eval()` or shell interpolation
- The transcript path is validated as absolute before use
- Everything writes to `~/.claude/` — no elevated permissions needed

</details>

---

## Files in this repo

```
compact-hooks/
├── install.sh                  # self-contained installer — the only file curl needs
├── doctor.sh                   # checks the installation and fixes common issues
├── pre-compact-summary.py      # readable copy of the PreCompact hook
├── post-compact-capture.py     # readable copy of the PostCompact hook
├── settings-hooks-snippet.json # the hook config that gets merged into settings.json
└── CLAUDE-md-addition.md       # the block that gets added to CLAUDE.md
```

The `.py` files here are for reading — `install.sh` is what actually writes them to your machine. If you change the scripts, update the heredocs in `install.sh` first.

---

## Make it yours

This is a starting point, not a prescription. The defaults I picked reflect how I think about sessions — but your mental model might be completely different, and that's the whole point.

The two files most worth rewriting are:

**`CLAUDE-md-addition.md`** — this becomes the instruction Claude reads at the start of every session. It doesn't have to say what mine says. If you work in a way where something else matters more, write that instead.

**The `additional_context` prompt in `pre-compact-summary.py`** — this is what gets passed to Claude during compaction to shape what it preserves. The four sections I used (overall task, decision chain, current state, open questions) are just one way to think about it. Rip them out. Add your own. Make it match how your brain actually organizes work.

```python
# pre-compact-summary.py — find this string and rewrite it however you want
additional_context = (
    "COMPACTION IMMINENT — your summary MUST preserve ALL of the following:\n\n"
    "1. OVERALL TASK ..."
    # ↑ this is yours to change
)
```

After editing, run the installer again to push your version to `~/.claude/scripts/`. Or edit the file directly there.

If something you build on top of this turns out to be genuinely useful, I'd love to see it.

---

## Contributing

If you find a bug or want to improve something, feel free to open an issue or a PR. Feedback is welcome.

Before submitting a change:

```bash
bash install.sh --preview   # make sure the completion screen still renders
bash doctor.sh              # make sure all 8 checks pass on a real install
```

---

## Requirements

| | Minimum | Notes |
|---|---|---|
| Claude Code | recent | needs `PreCompact` / `PostCompact` hook support |
| Python | 3.7 | standard library only |
| OS | macOS / Linux | untested on Windows |

---

## License

MIT — do whatever you want with it. See [LICENSE](LICENSE).
