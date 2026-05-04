Good framing — the key insight is that ECSS compliance is not about the simulator, it is about what the testbench produces as evidence. The simulator is just the engine. Let me lay out a concrete architecture.
The core idea: separate concerns into four layers
┌─────────────────────────────────────────────────────────┐
│  Layer 4 — Reporting     (TCL + Python post-processing) │
│  "What was the verdict and which requirement does it    │
│   satisfy?"                                             │
├─────────────────────────────────────────────────────────┤
│  Layer 3 — Assertions    (VHDL packages per module)     │
│  "Was the output correct?"                              │
├─────────────────────────────────────────────────────────┤
│  Layer 2 — Stimulus      (VHDL test sequences)          │
│  "What inputs were applied and why?"                    │
├─────────────────────────────────────────────────────────┤
│  Layer 1 — Infrastructure (Makefile + TCL)              │
│  "Compile, run, collect, repeat — reproducibly"         │
└─────────────────────────────────────────────────────────┘
Layer 1 — Makefile structure
The Makefile is the single entry point. A developer or CI pipeline only ever calls make. The rules map directly to ECSS artifacts:
# ── Configuration ──────────────────────────────────────────────────────────
QUESTA     := vsim
VCOM       := vcom
VLIB       := vlib
VMAP       := vmap

TOP_TB     := tb_current_controller
WORK_LIB   := work
SIM_TCL    := scripts/run_sim.tcl
REPORT_DIR := reports
WAVE_DIR   := waves

VCOM_FLAGS := -2008 -pedanticerrors -O5

# Source compilation order — explicit, no wildcards
# ECSS-E-ST-20-40C requires deterministic build
SOURCES := \
    ip_core/rtl/packages/mce_ng_types_pkg.vhd      \
    ip_core/rtl/packages/mce_ng_constants_pkg.vhd  \
    ip_core/rtl/cordic/cordic.vhd                  \
    ip_core/rtl/current_controller/current_ctrl.vhd \
    verification/tb/common/tb_utils_pkg.vhd        \
    verification/tb/common/assertion_pkg.vhd       \
    verification/tb/current_controller/motor_plant_bfm.vhd  \
    verification/tb/current_controller/tb_current_controller.vhd

.PHONY: all sim regression report clean

all: sim report

# ── Compile ────────────────────────────────────────────────────────────────
compile:
	$(VLIB) $(WORK_LIB)
	$(VMAP) $(WORK_LIB) $(WORK_LIB)
	@for src in $(SOURCES); do \
	    echo "Compiling: $$src"; \
	    $(VCOM) $(VCOM_FLAGS) -work $(WORK_LIB) $$src || exit 1; \
	done
	@touch $@

# ── Single testbench run ───────────────────────────────────────────────────
sim: compile
	$(QUESTA) -batch -do "$(SIM_TCL)" \
	          -G TB_TOP=$(TOP_TB)      \
	          -logfile $(REPORT_DIR)/questa.log

# ── Full regression: run every testbench in sequence ──────────────────────
regression: compile
	@mkdir -p $(REPORT_DIR)
	@for tb in $(shell cat scripts/regression_list.txt); do \
	    echo "=== Running $$tb ==="; \
	    $(QUESTA) -batch                                  \
	        -do "do scripts/run_sim.tcl"                  \
	        -G TB_TOP=$$tb                                \
	        -logfile $(REPORT_DIR)/$$tb.log || true;      \
	done
	python3 scripts/collect_results.py $(REPORT_DIR)

# ── Generate ECSS verification report ─────────────────────────────────────
report: regression
	python3 scripts/generate_report.py \
	    --results $(REPORT_DIR) \
	    --requirements docs/requirements.md \
	    --output $(REPORT_DIR)/verification_report.md

clean:
	rm -rf $(WORK_LIB) $(REPORT_DIR) transcript *.wlf compile
The -pedanticerrors flag on vcom is important for ECSS — it rejects any VHDL that relies on simulator-specific extensions rather than the standard, which ECSS-E-ST-20-40C §5.1 requires.
Layer 1 — The TCL simulation script
This is where QuestaSim-specific control lives. The key principle is that the TCL script must not contain any test logic — it only controls simulation mechanics and extracts results.
# scripts/run_sim.tcl
# ─────────────────────────────────────────────────────────────────────────
# ECSS-Q-ST-60-03C §8: all tool invocations must be scripted and
# reproducible. This script is the sole means of launching simulation.
# No manual vsim commands are permitted for a compliant run.
# ─────────────────────────────────────────────────────────────────────────

# Timestamp the run for the CM log
set run_timestamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
echo "MCE-NG Simulation Run: $run_timestamp"

# Load the testbench — $TB_TOP is passed from Makefile via -G
quietly set tb_top [lindex $argv 0]
if {$tb_top eq ""} { set tb_top "tb_current_controller" }

vsim -t 1ns \
     -voptargs=+acc \
     -sv_seed random \
     work.$tb_top

# ── Waveform capture (for debug — not part of pass/fail) ──────────────────
if {[info exists ::env(SAVE_WAVES)] && $::env(SAVE_WAVES) == "1"} {
    vcd file waves/${tb_top}_${run_timestamp}.vcd
    vcd add -r *
}

# ── Run to completion ──────────────────────────────────────────────────────
# All testbenches must terminate by calling tb_end() which asserts
# the done signal. We do NOT use 'run -all' with an implicit timeout —
# that would hide hung simulations.
set timeout_ns 100000000
run $timeout_ns ns

# ── Check termination ──────────────────────────────────────────────────────
# ECSS requires every test to have a defined end condition.
# If the TB did not assert tb_done, it timed out — this is a test failure.
quietly set done_val [examine -radix unsigned sim:/$tb_top/tb_done]
if {$done_val != 1} {
    echo "FAIL: Testbench $tb_top did not complete within timeout"
    echo "VERDICT:TIMEOUT:$tb_top" >> reports/questa.log
    quit -code 1
}

# ── Collect assertion results ──────────────────────────────────────────────
# The assertion package writes structured results to a text file.
# TCL reads it and appends to the run log for collect_results.py.
quietly set result_file "reports/${tb_top}_assertions.txt"
if {[file exists $result_file]} {
    set fd [open $result_file r]
    while {[gets $fd line] >= 0} {
        echo "ASSERTION_RESULT: $line"
    }
    close $fd
}

echo "VERDICT:COMPLETE:$tb_top:$run_timestamp"
quit -code 0
Layer 2 — Stimulus: how inputs are declared
Every test sequence is a named procedure in the testbench, and the procedure header is the specification. No magic numbers appear at the call site.
-- verification/tb/current_controller/tb_current_controller.vhd
-- =============================================================================
-- Module      : tb_current_controller
-- Requirement : REQ-CC-001, REQ-CC-002, REQ-CC-003, REQ-CC-004, REQ-CC-005
-- Description : Closed-loop verification of H-infinity current controller.
--               Each test procedure below maps to one or more requirements.
--               Pass/fail logged via assertion_pkg to reports/ directory.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.fixed_pkg.all;
use work.mce_ng_constants_pkg.all;
use work.assertion_pkg.all;
use work.tb_utils_pkg.all;

architecture sim of tb_current_controller is

    -- ── DUT and plant instantiation (wiring shown earlier) ─────────────────
    -- ...

    -- ── Test control ───────────────────────────────────────────────────────
    signal tb_done : std_logic := '0';

begin

    -- ─────────────────────────────────────────────────────────────────────
    -- TEST SEQUENCER
    -- Each call maps to a named requirement. The requirement ID, a short
    -- description of the stimulus, and the expected outcome are all visible
    -- at the call site — no hidden magic numbers.
    -- ─────────────────────────────────────────────────────────────────────
    sequencer : process
    begin
        wait until rst = '0';
        wait for 10 * T_CLK;

        -- REQ-CC-001: Step response must reach setpoint within 2 ms
        --             with no overshoot above 5% of I0.
        run_step_response_test(
            req_id          => "REQ-CC-001",
            setpoint_pu     => 1.0,          -- full rated current
            settle_time_us  => 2000,         -- must settle within 2 ms
            overshoot_pct   => 5.0,          -- max 5% overshoot
            clk_period_ns   => 30            -- 1/32768 Hz in ns
        );

        -- REQ-CC-002: Steady-state error at rated current must be < 1%
        run_steady_state_test(
            req_id          => "REQ-CC-002",
            setpoint_pu     => 1.0,
            max_error_pct   => 1.0,
            measure_after_us => 5000         -- measure after transient
        );

        -- REQ-CC-003: Sinusoidal tracking at 1 Hz (4 stp/s)
        --             RMS error must stay below 1% of I0
        run_sinusoidal_tracking_test(
            req_id          => "REQ-CC-003",
            freq_hz         => 1.0,
            amplitude_pu    => 1.0,
            duration_cycles => 3,            -- 3 full sinusoidal periods
            max_rms_error   => 0.01          -- 1% of I0
        );

        -- REQ-CC-004: Sinusoidal tracking at 50 Hz (90 stp/s)
        run_sinusoidal_tracking_test(
            req_id          => "REQ-CC-004",
            freq_hz         => 50.0,
            amplitude_pu    => 1.0,
            duration_cycles => 3,
            max_rms_error   => 0.02          -- 2% allowed at higher freq
        );

        -- REQ-CC-005: Robustness — resistance varies 50% from nominal.
        --             Controller must remain stable (no divergence).
        run_parameter_variation_test(
            req_id          => "REQ-CC-005",
            R_variation_pct => 50.0,         -- thesis Rmin/max range
            L_variation_pct => 12.5,
            stability_check => true
        );

        tb_done <= '1';
        wait;
    end process;

end architecture;
Each run_* procedure is defined in tb_utils_pkg.vhd. The signatures force the caller to name every parameter — there is no way to call run_step_response_test without explicitly stating what the requirement ID, setpoint, time limit, and pass criterion are.
Layer 3 — The assertion package
This is the ECSS compliance core. Every assertion writes a structured line to a file that the reporting layer can parse.
-- verification/tb/common/assertion_pkg.vhd
-- =============================================================================
-- ECSS-E-ST-20-40C §5.4.3f: verification files shall include expected
-- outputs and self-checking logic. This package provides the mechanism.
-- =============================================================================

package assertion_pkg is

    -- ── File handle — shared across all procedures ─────────────────────────
    -- Opened once at simulation start via tb_utils_pkg.

    -- ── Core assertion procedure ───────────────────────────────────────────
    -- Every assertion call writes one line to the result file:
    --
    --   PASS|REQ-CC-001|step_response_settle_time|actual=1450us|limit=2000us
    --   FAIL|REQ-CC-002|steady_state_error|actual=1.8%|limit=1.0%
    --
    -- This format is parsed by collect_results.py in Layer 4.

    procedure assert_less_than (
        req_id      : in string;
        check_name  : in string;
        actual      : in real;
        limit       : in real;
        units       : in string
    );

    procedure assert_greater_than (
        req_id      : in string;
        check_name  : in string;
        actual      : in real;
        limit       : in real;
        units       : in string
    );

    procedure assert_within_pct (
        req_id      : in string;
        check_name  : in string;
        actual      : in real;
        expected    : in real;
        tolerance   : in real      -- percentage
    );

    procedure assert_stable (
        req_id      : in string;
        check_name  : in string;
        signal_val  : in real;
        window_us   : in real;
        max_delta   : in real
    );

end package;


package body assertion_pkg is

    -- Shared file for structured results
    file result_file : text;

    procedure write_result (
        verdict    : in string;
        req_id     : in string;
        check_name : in string;
        detail     : in string
    ) is
        variable L : line;
    begin
        -- Format: VERDICT|REQ_ID|CHECK_NAME|DETAIL|SIMTIME
        write(L, verdict & "|" & req_id & "|" & check_name
                         & "|" & detail
                         & "|t=" & time'image(now));
        writeline(result_file, L);
        -- Also echo to transcript for live monitoring
        report verdict & " [" & req_id & "] " & check_name
               & " — " & detail
               severity note;
    end procedure;

    procedure assert_less_than (
        req_id, check_name : in string;
        actual, limit      : in real;
        units              : in string
    ) is
    begin
        if actual < limit then
            write_result("PASS", req_id, check_name,
                "actual=" & real'image(actual) & units
                & " limit=" & real'image(limit) & units);
        else
            write_result("FAIL", req_id, check_name,
                "actual=" & real'image(actual) & units
                & " limit=" & real'image(limit) & units);
            -- Severity failure would abort simulation — we want to
            -- continue and collect all failures, then report at end.
            report "ASSERTION FAILED: [" & req_id & "] "
                   & check_name severity error;
        end if;
    end procedure;

    -- ... other procedures follow same pattern

end package body;
The severity error rather than failure is intentional — QuestaSim records it but continues running, so all assertions in a testbench execute even if one fails. The final verdict comes from the result file, not from whether the simulator aborted.
Layer 4 — Reporting
A small Python script collects all the *_assertions.txt files and produces a markdown table that maps directly into your ECSS verification report document:
# scripts/collect_results.py
import sys, pathlib, re, datetime

RESULT_LINE = re.compile(
    r"^(PASS|FAIL)\|([^|]+)\|([^|]+)\|([^|]+)\|(.+)$"
)

def collect(reports_dir: str) -> None:
    rows = []
    for f in pathlib.Path(reports_dir).glob("*_assertions.txt"):
        tb_name = f.stem.replace("_assertions", "")
        for line in f.read_text().splitlines():
            m = RESULT_LINE.match(line)
            if m:
                rows.append({
                    "verdict":    m.group(1),
                    "req_id":     m.group(2),
                    "check":      m.group(3),
                    "detail":     m.group(4),
                    "simtime":    m.group(5),
                    "testbench":  tb_name,
                })

    passed = sum(1 for r in rows if r["verdict"] == "PASS")
    failed = sum(1 for r in rows if r["verdict"] == "FAIL")

    # ── Console summary ────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"  MCE-NG Verification Results  {datetime.date.today()}")
    print(f"  PASSED: {passed}   FAILED: {failed}   TOTAL: {len(rows)}")
    print(f"{'='*60}\n")

    # ── Markdown table for verification report ─────────────────────────────
    out = pathlib.Path(reports_dir) / "summary_table.md"
    with out.open("w") as f:
        f.write("| Verdict | Requirement | Check | Detail | Sim Time |\n")
        f.write("|---------|-------------|-------|--------|----------|\n")
        for r in sorted(rows, key=lambda x: x["req_id"]):
            icon = "✅" if r["verdict"] == "PASS" else "❌"
            f.write(
                f"| {icon} {r['verdict']} "
                f"| {r['req_id']} "
                f"| {r['check']} "
                f"| {r['detail']} "
                f"| {r['simtime']} |\n"
            )

    # ── Exit code for CI ───────────────────────────────────────────────────
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    collect(sys.argv[1])
The output table pasted into your docs/verification_report.md becomes the ECSS-Q-ST-60-03C §7.1 product metrics report with no additional manual work.
What a single make regression produces
reports/
├── questa.log                        ← raw QuestaSim transcript
├── tb_current_controller.log         ← per-TB QuestaSim log
├── tb_current_controller_assertions.txt   ← structured assertion results
├── tb_cordic.log
├── tb_cordic_assertions.txt
├── summary_table.md                  ← paste into verification report
└── verification_report.md            ← full ECSS document
And to the console:
============================================================
  MCE-NG Verification Results  2025-03-01
  PASSED: 23   FAILED: 1   TOTAL: 24
============================================================

❌ FAIL | REQ-CC-002 | steady_state_error | actual=1.8% limit=1.0% | t=5020000 ns
The single failing line tells you exactly which requirement, which check, what the actual value was, and at what simulation time it was measured. No waveform inspection needed.