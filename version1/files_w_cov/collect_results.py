#!/usr/bin/env python3
# =============================================================================
# tools/collect_results.py
# -----------------------------------------------------------------------------
# Walks build/reports/<class>/<tb>.result, parses each line as a structured
# assertion record, and produces:
#
#   * a console summary (PASS/FAIL counts)
#   * a Markdown table grouped by requirement class — paste directly into the
#     ECSS-Q-ST-60-03C verification report
#   * an exit code: 0 if everything passed, 1 if any FAIL is present
#
# Result file format (written by assertion_pkg.vhd in the testbenches):
#
#   VERDICT|REQ_ID|CHECK_NAME|DETAIL|SIMTIME
#
# Example:
#
#   PASS|REQ-PWM-001|duty_cycle_centred|actual=32768 expected=32768|t=10500 ns
#   FAIL|REQ-PWM-002|duty_cycle_max    |actual=65535 expected<=65534|t=12340 ns
#
# Usage:
#   collect_results.py --report-dir build/reports/ --output build/reports/summary.md
#   collect_results.py --report-dir build/reports/ --filter-class A --output ...
#
# License: GNU GPL
# =============================================================================

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass


RESULT_LINE_RE = re.compile(
    r"^(PASS|FAIL|TIMEOUT)\|"     # verdict
    r"([^|]+)\|"                  # requirement id
    r"([^|]+)\|"                  # check name
    r"([^|]+)\|"                  # detail
    r"(.+)$"                      # simtime
)


@dataclass
class Record:
    verdict: str
    req_id: str
    check: str
    detail: str
    simtime: str
    testbench: str
    req_class: str

    @property
    def is_pass(self) -> bool:
        return self.verdict == "PASS"


def parse_result_file(path: pathlib.Path, req_class: str, tb_name: str) -> list[Record]:
    records: list[Record] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = RESULT_LINE_RE.match(line)
        if not m:
            # Malformed line — record it so the user can fix the testbench
            records.append(Record(
                verdict="FAIL",
                req_id="???",
                check="malformed_result_line",
                detail=f"raw='{line}'",
                simtime="-",
                testbench=tb_name,
                req_class=req_class,
            ))
            continue
        records.append(Record(
            verdict=m.group(1),
            req_id=m.group(2).strip(),
            check=m.group(3).strip(),
            detail=m.group(4).strip(),
            simtime=m.group(5).strip(),
            testbench=tb_name,
            req_class=req_class,
        ))
    return records


def collect(report_dir: pathlib.Path, filter_class: str | None) -> list[Record]:
    """Walk report_dir/<class>/*.result and parse all of them."""
    records: list[Record] = []
    if not report_dir.exists():
        return records

    for class_dir in sorted(report_dir.iterdir()):
        if not class_dir.is_dir():
            continue
        req_class = class_dir.name
        if filter_class and req_class != filter_class:
            continue
        for result_file in sorted(class_dir.glob("*.result")):
            tb_name = result_file.stem
            records.extend(parse_result_file(result_file, req_class, tb_name))
    return records


def emit_markdown(records: list[Record],
                  output: pathlib.Path,
                  coverage_md: pathlib.Path | None = None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)

    by_class: dict[str, list[Record]] = {}
    for r in records:
        by_class.setdefault(r.req_class, []).append(r)

    total_pass = sum(1 for r in records if r.is_pass)
    total_fail = len(records) - total_pass

    with output.open("w", encoding="utf-8") as f:
        f.write("# MCE-NG IP Core — Verification Summary\n\n")
        f.write(f"- Total checks : **{len(records)}**\n")
        f.write(f"- Passed       : **{total_pass}**\n")
        f.write(f"- Failed       : **{total_fail}**\n\n")

        # ── Embed coverage section, if available ──────────────────────────
        # Coverage data is collected at build time but reported here so the
        # summary contains both requirement verdicts and code-coverage
        # metrics in one document — this is the artefact reviewers cite.
        if coverage_md is not None and coverage_md.exists():
            f.write(coverage_md.read_text(encoding="utf-8"))
            f.write("\n")
        else:
            f.write("## Code coverage\n\n")
            f.write("*Coverage data not available for this run. "
                    "Re-run with `make coverage` after a sim target.*\n\n")

        # ── Per-class summary table ───────────────────────────────────────
        f.write("## Results by requirement class\n\n")
        f.write("| Class | Checks | Passed | Failed |\n")
        f.write("|-------|--------|--------|--------|\n")
        for req_class in sorted(by_class):
            rs = by_class[req_class]
            n_pass = sum(1 for r in rs if r.is_pass)
            f.write(f"| {req_class} | {len(rs)} | {n_pass} | {len(rs) - n_pass} |\n")
        f.write("\n")

        # ── Detailed table per class ──────────────────────────────────────
        for req_class in sorted(by_class):
            f.write(f"## Class {req_class}\n\n")
            f.write("| Verdict | Requirement | Testbench | Check | Detail | Sim Time |\n")
            f.write("|---------|-------------|-----------|-------|--------|----------|\n")
            for r in sorted(by_class[req_class],
                            key=lambda x: (x.req_id, x.check)):
                icon = "✅" if r.is_pass else ("⏰" if r.verdict == "TIMEOUT" else "❌")
                f.write(
                    f"| {icon} {r.verdict} "
                    f"| {r.req_id} "
                    f"| {r.testbench} "
                    f"| {r.check} "
                    f"| {r.detail} "
                    f"| {r.simtime} |\n"
                )
            f.write("\n")


def emit_console(records: list[Record], filter_class: str | None) -> None:
    n_total = len(records)
    n_pass  = sum(1 for r in records if r.is_pass)
    n_fail  = n_total - n_pass

    print()
    print("═══════════════════════════════════════════════════════════════════")
    if filter_class:
        print(f"  MCE-NG verification — class {filter_class}")
    else:
        print("  MCE-NG verification — overall summary")
    print("═══════════════════════════════════════════════════════════════════")
    print(f"  PASSED  : {n_pass}")
    print(f"  FAILED  : {n_fail}")
    print(f"  TOTAL   : {n_total}")
    print("═══════════════════════════════════════════════════════════════════")

    if n_fail:
        print("\nFailures:")
        for r in records:
            if not r.is_pass:
                print(f"  [{r.req_class}] {r.req_id} / {r.check}")
                print(f"      tb={r.testbench}  detail={r.detail}  t={r.simtime}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Aggregate testbench result files")
    ap.add_argument("--report-dir",   required=True, type=pathlib.Path)
    ap.add_argument("--output",       required=True, type=pathlib.Path)
    ap.add_argument("--filter-class", default=None,
                    help="restrict to a single requirement class")
    ap.add_argument("--coverage-md",  default=None, type=pathlib.Path,
                    help="optional coverage Markdown produced by parse_coverage.py")
    args = ap.parse_args()

    records = collect(args.report_dir, args.filter_class)
    if not records:
        print("WARNING: no result files found")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text("# No results\n")
        return 0

    emit_markdown(records, args.output, args.coverage_md)
    emit_console(records, args.filter_class)

    n_fail = sum(1 for r in records if not r.is_pass)
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
