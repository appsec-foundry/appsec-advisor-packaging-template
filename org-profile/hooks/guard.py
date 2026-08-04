#!/usr/bin/env python3
"""Example org-supplied PreToolUse hook for risky Bash commands.

This is a small, conservative baseline, not a shell sandbox. It blocks a few
high-impact commands before Claude Code asks for, or applies, its normal tool
permission decision. Extend the rules for the organization's environment and
keep irreversible deployment actions in centrally managed policy as well.
"""

import json
import re
import sys


COMMAND_START = r"(?:^|(?:&&|\|\||[;|])\s*)"
RULES = (
    (
        "recursive forced deletion",
        re.compile(
            COMMAND_START
            + r"(?:command\s+)?rm\s+(?=[^;|&\n]*(?:-[^\s]*[rR]|--recursive))"
            + r"(?=[^;|&\n]*(?:-[^\s]*[fF]|--force))",
        ),
    ),
    (
        "destructive Git reset or clean",
        re.compile(
            COMMAND_START + r"git\s+(?:reset\s+--hard|clean\s+-[^\s]*f)",
            re.IGNORECASE,
        ),
    ),
    (
        "privileged command execution",
        re.compile(COMMAND_START + r"(?:sudo|doas)\b"),
    ),
    (
        "filesystem or disk formatting",
        re.compile(COMMAND_START + r"(?:mkfs(?:\.[a-z0-9]+)?|fdisk|parted)\b", re.IGNORECASE),
    ),
    (
        "raw disk overwrite",
        re.compile(COMMAND_START + r"dd\b[^\n]*\bof=/dev/", re.IGNORECASE),
    ),
    (
        "system shutdown or reboot",
        re.compile(COMMAND_START + r"(?:shutdown|reboot|poweroff|halt)\b", re.IGNORECASE),
    ),
)


def blocked_reason(command: str) -> str | None:
    """Return the reason for a directly invoked unsafe command, if any.

    The expression deliberately only matches at a shell command boundary. That
    avoids treating explanatory text such as ``echo 'rm -rf'`` as an action.
    It cannot fully parse arbitrary shell syntax; managed permissions remain
    the enforcement boundary for comprehensive command control.
    """
    for reason, pattern in RULES:
        if pattern.search(command):
            return reason
    return None


def main() -> int:
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0

    if event.get("tool_name") != "Bash":
        return 0
    command = event.get("tool_input", {}).get("command")
    if not isinstance(command, str):
        return 0

    reason = blocked_reason(command)
    if reason is None:
        return 0

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"Blocked {reason} by the organization Bash safety hook."
                    ),
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
