#!/usr/bin/env python3
# =============================================================================
# tools/parse_coverage.py
# -----------------------------------------------------------------------------
# Parses the text-format coverage report produced by:
#
#   vcover report -details -all -output coverage.txt merged.ucdb
#
# and emits a Markdown summary that can be embedded into the verification
# report by collect_results.py.
#
# QuestaSim's text report contains per-design-unit blocks like:
#
#   COVERAGE REPORT FOR DESIGN UNIT /current_controller(rtl)
#   ...
#   TOTAL STATEMENT COVERAGE: 92.51% COVERED: 75 OF 81
#   TOTAL BRANCH COVERAGE   : 88.88% COVERED: 71 OF 80
#   TOTAL CONDITION COVERAGE: 75.00% COVERED: 12 OF 16
#   ...
#
# and an overall summary at the end. We extract both.
#
# This script DOES NOT enforce thresholds — it only reports. ECSS-E-ST-20-40C
# §C.2.1 requires that coverage figures be reported with a justification
# when below target; the verification plan owns the thresholds.
#
# Output file layout:
#
#   ## Code coverage
#
#   | Metric    | Coverage | Covered / Total |
#   |-----------|----------|-----------------|
#   | Statement | 92.5%    | 75 / 81         |
#   | Branch    | 88.8%    | 71 / 80         |
#   | ...       | ...      | ...             |
#
#   ### Per design unit
#
#   | Unit                | Statement | Branch | Condition | FSM    | Toggle |
#   |---------------------|-----------|--------|-----------|--------|--------|
#   | current_controller  | 92.5%     | 88.8%  | 75.0%     |  100%  |  85.0% |
#
# License: GNU GPL
# =============================================================================

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass, field


# Regexes for the QuestaSim text report format.
#
# Lines we care about look like:
#   TOTAL STATEMENT COVERAGE: 92.51% COVERED: 75 OF 81
#   TOTAL BRANCH COVERAGE   : 88.88% COVERED: 71 OF 80
#   TOTAL CONDITION COVERAGE: 75.00% COVERED: 12 OF 16
#   TOTAL EXPRESSION COVERAGE: 60.00% COVERED: 6 OF 10
#   TOTAL FSM STATE COVERAGE: 100.00% COVERED: 8 OF 8
#   TOTAL FSM TRANSITION COVERAGE: 87.50% COVERED: 14 OF 16
#   TOTAL TOGGLE COVERAGE: 78.43% COVERED: 80 OF 102
#
# The overall (whole-design) totals appear in a similar format inside the
# "TOTAL COVERAGE TYPE FIGURES" section near the end of the report.

UNIT_HEADER_RE = re.compile(
    r"COVERAGE REPORT FOR DESIGN UNIT\s+(?P<unit>\S+)"
)

METRIC_LINE_RE = re.compile(
    r"^\s*TOTAL\s+(?P<metric>[A-Z][A-Z\s]+?)\s+COVERAGE\s*:\s*"
    r"(?P<pct>\d+\.\d+)%\s+COVERED:\s+(?P<covered>\d+)\s+OF\s+(?P<total>\d+)"
)

# The whole-design totals appear under a header line like
# "Total Coverage By Instance" or in the design summary block.
# Any "TOTAL ... COVERAGE: NN.NN% COVERED: A OF B" outside a per-unit
# block is treated as a global figure.

METRIC_RENAMES = {
    "STATEMENT":      "Statement",
    "BRANCH":         "Branch",
    "CONDITION":      "Condition",
    "EXPRESSION":     "Expression",
    "FSM STATE":      "FSM state",
    "FSM TRANSITION": "FSM transition",
    "TOGGLE":         "Toggle",
}


@dataclass
class MetricResult:
    pct:     float
    covered: int
    total:   int


@dataclass
class UnitResult:
    name: str
    metrics: dict[str, MetricResult] = field(default_factory=dict)


def normalise_metric(raw: str) -> str:
    """Map QuestaSim's metric names to display names."""
    raw = raw.strip().upper()
    return METRIC_RENAMES.get(raw, raw.title())


def parse_report(path: pathlib.Path) -> tuple[dict[str, MetricResult], list[UnitResult]]:
    """
    Parse a text-format coverage report.

    Returns
    -------
    overall : dict[str, MetricResult]
        Whole-design totals.
    units   : list[UnitResult]
        Per-design-unit totals, in the order they appear in the report.
    """
    if not path.exists():
        return {}, []

    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    overall: dict[str, MetricResult] = {}
    units: list[UnitResult] = []
    current_unit: UnitResult | None = None

    for line in lines:
        # ── New per-unit block? ────────────────────────────────────────────
        m = UNIT_HEADER_RE.search(line)
        if m:
            unit_name = m.group("unit").lstrip("/")
            # Strip trailing (rtl) / (sim) architecture marker for cleaner names
            unit_name = re.sub(r"\(\w+\)$", "", unit_name)
            current_unit = UnitResult(name=unit_name)
            units.append(current_unit)
            continue

        # ── Metric line ────────────────────────────────────────────────────
        m = METRIC_LINE_RE.match(line)
        if m:
            metric = normalise_metric(m.group("metric"))
            result = MetricResult(
                pct=float(m.group("pct")),
                covered=int(m.group("covered")),
                total=int(m.group("total")),
            )
            if current_unit is not None:
                current_unit.metrics[metric] = result
            # Always also accumulate as a candidate global metric:
            # the LAST occurrence (which is the design summary at the end)
            # wins. This is robust against vcover's varied report layouts.
            overall[metric] = result

    # Subtle: the per-unit metric lines also matched the overall regex, so
    # `overall` currently holds whatever unit was processed last, not the
    # design totals. Recover real totals by summing across units when no
    # explicit "design overall" section was present.
    if units:
        recomputed: dict[str, MetricResult] = {}
        for u in units:
            for metric, mr in u.metrics.items():
                acc = recomputed.setdefault(metric, MetricResult(0.0, 0, 0))
                acc.covered += mr.covered
                acc.total   += mr.total
        for metric, mr in recomputed.items():
            mr.pct = (mr.covered / mr.total * 100.0) if mr.total else 0.0
        overall = recomputed

    return overall, units


# ── Markdown emitter ────────────────────────────────────────────────────────

# Stable column ordering for per-unit table — only metrics actually present
# are kept, but in this canonical order.
PREFERRED_METRIC_ORDER = (
    "Statement", "Branch", "Condition", "Expression",
    "FSM state", "FSM transition", "Toggle",
)


def fmt_pct(m: MetricResult | None) -> str:
    if m is None or m.total == 0:
        return "—"
    return f"{m.pct:.1f}%"


def fmt_ratio(m: MetricResult | None) -> str:
    if m is None or m.total == 0:
        return "—"
    return f"{m.covered} / {m.total}"


def emit_markdown(
    overall: dict[str, MetricResult],
    units:   list[UnitResult],
    output:  pathlib.Path,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)

    if not overall and not units:
        output.write_text("## Code coverage\n\n*No coverage data available.*\n",
                          encoding="utf-8")
        return

    ordered_metrics = [m for m in PREFERRED_METRIC_ORDER if m in overall]
    # Pick up any metric we didn't anticipate in PREFERRED_METRIC_ORDER
    for m in overall:
        if m not in ordered_metrics:
            ordered_metrics.append(m)

    with output.open("w", encoding="utf-8") as f:
        f.write("## Code coverage\n\n")

        # ── Overall table ──────────────────────────────────────────────────
        f.write("| Metric | Coverage | Covered / Total |\n")
        f.write("|--------|----------|-----------------|\n")
        for metric in ordered_metrics:
            mr = overall[metric]
            f.write(f"| {metric} | {fmt_pct(mr)} | {fmt_ratio(mr)} |\n")
        f.write("\n")

        # ── Per-unit table ─────────────────────────────────────────────────
        if units:
            f.write("### Per design unit\n\n")
            header = "| Unit |" + "".join(
                f" {m} |" for m in ordered_metrics
            ) + "\n"
            sep = "|------|" + "".join("--------|" for _ in ordered_metrics) + "\n"
            f.write(header)
            f.write(sep)

            for u in units:
                row = f"| `{u.name}` |"
                for metric in ordered_metrics:
                    row += f" {fmt_pct(u.metrics.get(metric))} |"
                f.write(row + "\n")
            f.write("\n")


def emit_console(overall: dict[str, MetricResult]) -> None:
    if not overall:
        print("No coverage data parsed.")
        return

    print()
    print("═══════════════════════════════════════════════════════════════════")
    print("  Code coverage summary")
    print("═══════════════════════════════════════════════════════════════════")
    width = max(len(m) for m in overall) + 2
    for metric in PREFERRED_METRIC_ORDER:
        if metric in overall:
            mr = overall[metric]
            print(f"  {metric.ljust(width)} {fmt_pct(mr):>7}   "
                  f"({fmt_ratio(mr)})")
    print("═══════════════════════════════════════════════════════════════════")


def main() -> int:
    ap = argparse.ArgumentParser(description="Parse vcover text report")
    ap.add_argument("--txt-report", required=True, type=pathlib.Path,
                    help="path to vcover text report")
    ap.add_argument("--output",     required=True, type=pathlib.Path,
                    help="output Markdown file")
    args = ap.parse_args()

    overall, units = parse_report(args.txt_report)
    emit_markdown(overall, units, args.output)
    emit_console(overall)
    # Coverage parsing always succeeds — empty data is not an error.
    return 0


if __name__ == "__main__":
    sys.exit(main())
