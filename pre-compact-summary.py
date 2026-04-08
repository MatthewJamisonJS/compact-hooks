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
