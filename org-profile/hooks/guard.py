#!/usr/bin/env python3
"""Example org-supplied PreToolUse hook.

A real hook would inspect the tool call on stdin and optionally block it (e.g.
reject risky Bash invocations). This template ships a no-op that approves every
call, so packaging and the smoke test have a concrete script to bundle without
side effects. Replace the body with your org's policy.
"""

import json
import sys


def main() -> int:
    try:
        json.loads(sys.stdin.read() or "{}")
    except ValueError:
        pass
    print("{}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
