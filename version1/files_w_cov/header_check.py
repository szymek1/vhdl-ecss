#!/usr/bin/env python3
# =============================================================================
# tools/header_check.py
# -----------------------------------------------------------------------------
# Verifies that every VHDL source and testbench file contains the mandatory
# ECSS-E-ST-20-40C header block.
#
# A compliant header looks like:
#
#   -- =========================================================================
#   -- Project     : MCE-NG IP Core
#   -- Module      : <module_name>
#   -- Author      : <author>
#   -- Created     : YYYY-MM-DD
#   -- Version     : <semver>
#   -- Description : <one or more lines>
#   -- Requirements: <REQ-XX-NNN[, ...]>      (testbenches only — RTL: optional)
#   -- =========================================================================
#
# Usage:
#   header_check.py --sources src/ --testbenches verification/requirements_tb/ \
#                   --log build/log/header_check.log
#
# Exit codes:
#   0   all files compliant
#   1   one or more files missing required fields
#
# License: GNU GPL
# =============================================================================

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass


# ── Mandatory header fields ────────────────────────────────────────────────
# Different file kinds have slightly different mandatory sets.
RTL_REQUIRED_FIELDS = (
    "Project", "Module", "Author", "Created", "Version", "Description"
)
TB_REQUIRED_FIELDS = RTL_REQUIRED_FIELDS + ("Requirements",)

# Field-line regex: matches `-- <Field> : <value>` with flexible whitespace.
FIELD_RE = re.compile(r"^--\s*([A-Za-z]+)\s*:\s*(.+?)\s*$")

# How many lines we are willing to read looking for the header block.
HEADER_SCAN_LIMIT = 40


@dataclass
class CheckResult:
    path: pathlib.Path
    kind: str                  # "rtl" or "tb"
    missing: list[str]         # missing required fields
    found: dict[str, str]      # fields that were found

    @property
    def ok(self) -> bool:
        return not self.missing


def parse_header(path: pathlib.Path) -> dict[str, str]:
    """Read the first HEADER_SCAN_LIMIT lines and extract `-- Field : value` pairs."""
    fields: dict[str, str] = {}
    try:
        with path.open("r", encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                if i >= HEADER_SCAN_LIMIT:
                    break
                m = FIELD_RE.match(line)
                if m:
                    fields[m.group(1)] = m.group(2)
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
    return fields


def classify(path: pathlib.Path, declared_kind: str) -> str:
    """
    Sub-classify a file beyond the directory-derived "rtl"/"tb" kind.

    Packages and shared utilities under the testbench tree do not target
    a single requirement, so the Requirements field is not mandatory for
    them — they are infrastructure, not test cases.

    Returns the effective kind: "rtl", "tb", or "tb_pkg".
    """
    name = path.stem.lower()
    if declared_kind == "tb" and (name.endswith("_pkg") or name.endswith("_bfm")):
        return "tb_pkg"
    return declared_kind


def check_file(path: pathlib.Path, declared_kind: str) -> CheckResult:
    """Check one VHDL file against its mandatory header field set."""
    kind = classify(path, declared_kind)
    if kind == "tb":
        required = TB_REQUIRED_FIELDS
    else:
        # rtl or tb_pkg — Requirements field optional
        required = RTL_REQUIRED_FIELDS
    found = parse_header(path)
    missing = [f for f in required if f not in found]
    return CheckResult(path=path, kind=kind, missing=missing, found=found)


def collect_vhdl(root: pathlib.Path) -> list[pathlib.Path]:
    """Return all .vhd / .vhdl files under root, sorted for deterministic output."""
    return sorted(
        list(root.rglob("*.vhd")) + list(root.rglob("*.vhdl"))
    )


def main() -> int:
    ap = argparse.ArgumentParser(description="ECSS header compliance checker")
    ap.add_argument("--sources",     required=True, type=pathlib.Path,
                    help="directory containing RTL source files")
    ap.add_argument("--testbenches", required=True, type=pathlib.Path,
                    help="directory containing testbenches (organised by class)")
    ap.add_argument("--log",         required=True, type=pathlib.Path,
                    help="path to log file (overwritten on each run)")
    args = ap.parse_args()

    args.log.parent.mkdir(parents=True, exist_ok=True)

    rtl_files = collect_vhdl(args.sources)     if args.sources.exists()     else []
    tb_files  = collect_vhdl(args.testbenches) if args.testbenches.exists() else []

    # If absolutely nothing was found, we treat it as a soft pass —
    # a fresh checkout might not yet contain any sources. Real CI catches
    # this via downstream targets that need the files to exist.
    if not rtl_files and not tb_files:
        args.log.write_text("INFO: no VHDL files found — skipping check\n")
        print("INFO: no VHDL files found")
        return 0

    results = (
        [check_file(p, "rtl") for p in rtl_files] +
        [check_file(p, "tb")  for p in tb_files]
    )

    failures = [r for r in results if not r.ok]

    # ── Write detailed log ─────────────────────────────────────────────────
    with args.log.open("w") as f:
        f.write(f"Checked files : {len(results)}\n")
        f.write(f"Compliant     : {len(results) - len(failures)}\n")
        f.write(f"Non-compliant : {len(failures)}\n\n")

        if failures:
            f.write("── Failures ───────────────────────────────────────────\n")
            for r in failures:
                f.write(f"\n  {r.path}  [{r.kind}]\n")
                f.write(f"    Missing fields: {', '.join(r.missing)}\n")
                if r.found:
                    f.write(f"    Found fields  : {', '.join(sorted(r.found))}\n")
                else:
                    f.write(f"    No header detected at all in first "
                            f"{HEADER_SCAN_LIMIT} lines\n")

        f.write("\n── Compliant files ────────────────────────────────────\n")
        for r in results:
            if r.ok:
                f.write(f"  OK  {r.path}\n")

    # ── Console summary ────────────────────────────────────────────────────
    if failures:
        print(f"FAIL: {len(failures)} of {len(results)} files non-compliant")
        for r in failures:
            print(f"  {r.path}: missing {', '.join(r.missing)}")
        return 1

    print(f"OK: all {len(results)} files compliant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
