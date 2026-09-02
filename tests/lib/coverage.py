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
import os
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


def _xtrace_disabled_line_set(lines: list[str]) -> set[int]:
    """Lines after an explicit ``set +x`` through the matching ``set -x``.

    The command that disables tracing is still observable; subsequent commands,
    including the command that re-enables tracing, cannot emit xtrace markers.
    """
    disabled: set[int] = set()
    tracing_off = False
    for idx, raw in enumerate(lines, start=1):
        stripped = raw.strip()
        if tracing_off:
            disabled.add(idx)
            if re.search(r"(^|[; ])set\s+-x([; ]|$)", stripped):
                tracing_off = False
            continue
        if re.search(r"(^|[; ])set\s+\+x([; ]|$)", stripped) and not re.search(
            r"set\s+-x", stripped
        ):
            tracing_off = True
    return disabled


def coverable_lines(path: str | Path) -> set[int]:
    """Lines that *could* produce an xtrace command for `path`."""
    text = Path(path).read_text().splitlines()
    heredoc = _heredoc_line_set(text)
    xtrace_disabled = _xtrace_disabled_line_set(text)
    coverable: set[int] = set()
    prev_continues = False
    for idx, raw in enumerate(text, start=1):
        stripped = raw.strip()
        cont = prev_continues
        prev_continues = stripped.endswith("\\") or stripped.endswith("|")
        if idx in heredoc or idx in xtrace_disabled:
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


def analyze(trace_text: str, targets: list[str]) -> list[tuple[str, set[int], set[int]]]:
    """Return (target, coverable_lines, hit_lines) for each target script."""
    hits = executed_by_name(trace_text)
    results = []
    for target in targets:
        coverable = coverable_lines(target)
        hit = hits.get(Path(target).name, set()) & coverable
        results.append((target, coverable, hit))
    return results


def print_report(results: list[tuple[str, set[int], set[int]]], threshold: float) -> bool:
    print("\n=== bash line coverage ===")
    total_cov = total_hit = 0
    for target, coverable, hit in results:
        name = Path(target).name
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


def write_lcov(results, lcov_path: str, source_root: str) -> None:
    """Emit an lcov tracefile (Codecov-ingestible) with SF paths relative to root."""
    out = []
    for target, coverable, hit in results:
        out.append("TN:")
        out.append(f"SF:{os.path.relpath(target, source_root)}")
        for ln in sorted(coverable):
            out.append(f"DA:{ln},{1 if ln in hit else 0}")
        out.append(f"LF:{len(coverable)}")
        out.append(f"LH:{len(hit)}")
        out.append("end_of_record")
    Path(lcov_path).write_text("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--threshold", type=float, default=90.0)
    ap.add_argument("--lcov", help="write an lcov tracefile to this path")
    ap.add_argument("--source-root", default=".", help="root for relative SF paths in lcov")
    ap.add_argument("targets", nargs="+")
    args = ap.parse_args()
    trace_text = Path(args.trace).read_text(errors="replace")
    results = analyze(trace_text, args.targets)
    ok = print_report(results, args.threshold)
    if args.lcov:
        write_lcov(results, args.lcov, args.source_root)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
