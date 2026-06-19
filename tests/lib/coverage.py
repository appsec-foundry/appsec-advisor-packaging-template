#!/usr/bin/env python3
"""Zero-dependency bash line-coverage analysis.

Same principle as kcov: scripts are run under `set -x` with a marker PS4, and
the executed `$LINENO`s (captured by the bash driver into a trace file) are
compared against the set of *coverable* lines — non-blank, non-comment,
non-structural, non-continuation, non-heredoc.

This module does NOT spawn processes; the bash driver (tests/run.sh) runs the
scenarios and collects the trace. Here we only read text and count lines, so
there is nothing that can deadlock. Every uncovered line is printed, making the
measurement fully auditable.

CLI:  python3 coverage.py --trace FILE --threshold 90 SCRIPT [SCRIPT ...]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MARKER = "@@COV:"
_MARKER_RE = re.compile(re.escape(MARKER) + r"(?P<src>[^:@]*):(?P<line>\d+)@@")

# Lines whose stripped content is purely structural — bash never emits an xtrace
# command for them, exactly as kcov treats them as non-instrumentable.
_STRUCTURAL = {
    "fi", "done", "else", "esac", "do", "then", "in",
    "{", "}", "(", ")", ";;", "&&", "||",
}
_CASE_LABEL_RE = re.compile(r"^[^;]*\)\s*$")          # e.g. `*)` or `[yY]*)`
_EMPTY_BRANCH_RE = re.compile(r"^[^;]*\)\s*;;\s*$")    # e.g. `[yY]*) ;;` (no body)
_CASE_HEADER_RE = re.compile(r"^\s*case\b.*\bin\s*$")  # `case X in`
_FUNC_DECL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{?\s*$")
_HEREDOC_START_RE = re.compile(r"<<-?\s*[\"']?(?P<tag>[A-Za-z_][A-Za-z0-9_]*)[\"']?")


def _heredoc_line_set(lines: list[str]) -> set[int]:
    """1-based line numbers inside a heredoc body (incl. closing delimiter)."""
    inside: set[int] = set()
    i, n = 0, len(lines)
    while i < n:
        m = _HEREDOC_START_RE.search(lines[i])
        if m and not lines[i].lstrip().startswith("#"):
            tag = m.group("tag")
            j = i + 1
            while j < n and lines[j].strip() != tag:
                inside.add(j + 1)
                j += 1
            if j < n:
                inside.add(j + 1)
            i = j + 1
            continue
        i += 1
    return inside


def coverable_lines(path: str | Path) -> set[int]:
    """Lines that *could* produce an xtrace command for `path`."""
    text = Path(path).read_text().splitlines()
    heredoc = _heredoc_line_set(text)
    coverable: set[int] = set()
    prev_continues = False
    for idx, raw in enumerate(text, start=1):
        stripped = raw.strip()
        cont = prev_continues
        prev_continues = stripped.endswith("\\") or stripped.endswith("|")
        if idx in heredoc:
            continue
        if not stripped or stripped.startswith("#"):
            continue
        if cont:                       # continuation of a previous command
            continue
        if stripped.endswith("\\"):
            # First physical line of a backslash-continued command. bash reports
            # the command on a continuation line, not here, so exclude the whole
            # command from measurement (neither covered nor penalised).
            continue
        if stripped in _STRUCTURAL:
            continue
        if _FUNC_DECL_RE.match(stripped):
            continue
        if _CASE_HEADER_RE.match(stripped):
            continue
        if _EMPTY_BRANCH_RE.match(stripped):  # matched case branch with no command
            continue
        if _CASE_LABEL_RE.match(stripped) and ";" not in stripped and "&&" not in stripped:
            continue
        coverable.add(idx)
    return coverable


def executed_by_name(trace_text: str) -> dict[str, set[int]]:
    """Map script basename -> set of executed line numbers, from a trace."""
    hits: dict[str, set[int]] = {}
    for m in _MARKER_RE.finditer(trace_text):
        name = Path(m.group("src")).name
        hits.setdefault(name, set()).add(int(m.group("line")))
    return hits


def report(trace_text: str, targets: list[str], threshold: float) -> bool:
    hits = executed_by_name(trace_text)
    print("\n=== bash line coverage ===")
    total_cov = total_hit = 0
    for target in targets:
        name = Path(target).name
        coverable = coverable_lines(target)
        hit = hits.get(name, set()) & coverable
        missed = sorted(coverable - hit)
        total_cov += len(coverable)
        total_hit += len(hit)
        pct = 100.0 * len(hit) / len(coverable) if coverable else 100.0
        mark = "ok" if pct >= threshold else "LOW"
        print(f"  [{mark}] {name}: {len(hit)}/{len(coverable)} = {pct:.1f}%")
        if missed:
            print(f"        uncovered lines: {missed}")
    agg = 100.0 * total_hit / total_cov if total_cov else 100.0
    ok = agg >= threshold
    print(f"\n  TOTAL: {total_hit}/{total_cov} = {agg:.1f}%  (threshold {threshold:.0f}%)")
    print("  RESULT:", "PASS" if ok else "FAIL")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--threshold", type=float, default=90.0)
    ap.add_argument("targets", nargs="+")
    args = ap.parse_args()
    trace_text = Path(args.trace).read_text(errors="replace")
    ok = report(trace_text, args.targets, args.threshold)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
