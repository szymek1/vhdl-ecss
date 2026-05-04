# =============================================================================
# scripts/run_sim.tcl
# -----------------------------------------------------------------------------
# Runs a single QuestaSim simulation of one testbench. Invoked by the
# Makefile via vsim -do. Produces a structured result file that the Python
# reporting layer aggregates into the verification report.
#
# Arguments (positional):
#   1. tb_name       — testbench entity name (e.g. pwm_generator_tb)
#   2. req_class     — requirement class (e.g. A, B, common)
#   3. report_dir    — absolute path to build/reports/
#   4. wave_dir      — absolute path to build/waves/
#
# Output files:
#   <report_dir>/<class>/<tb_name>.result
#   <wave_dir>/<class>/<tb_name>.wlf      (only when SAVE_WAVES=1)
#
# ECSS compliance:
#   * No test logic in this script — only simulation control.
#   * Every run is identifiable by class + name + simulation timestamp.
#   * Timeout enforces a hard upper bound on runtime — no hung tests.
# =============================================================================

if {[llength $argv] < 4} {
    puts "ERROR: run_sim.tcl expects 4 arguments: tb_name req_class report_dir wave_dir"
    quit -code 1
}

set tb_name    [lindex $argv 0]
set req_class  [lindex $argv 1]
set report_dir [lindex $argv 2]
set wave_dir   [lindex $argv 3]

set timestamp  [clock format [clock seconds] -format "%Y-%m-%d_%H:%M:%S"]
set result_file "$report_dir/$req_class/$tb_name.result"

# ── Banner in transcript ───────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Testbench       : $tb_name"
echo "  Requirement cls : $req_class"
echo "  Started at      : $timestamp"
echo "  Result file     : $result_file"
echo "═══════════════════════════════════════════════════════════════════════"

# ── Pass the result-file path into the testbench via a top-level generic ──
# All testbenches accept a generic G_RESULT_FILE of type string; the
# assertion package reuses this path to write its structured output.
vsim -t 1ns \
     -voptargs=+acc \
     -GG_RESULT_FILE=$result_file \
     -GG_REQ_CLASS=$req_class \
     -GG_TB_NAME=$tb_name \
     work.$tb_name

# ── Optional waveform capture ──────────────────────────────────────────────
if {[info exists ::env(SAVE_WAVES)] && $::env(SAVE_WAVES) == "1"} {
    set wlf_file "$wave_dir/$req_class/$tb_name.wlf"
    echo "Saving waveforms to $wlf_file"
    log -recursive /*
    # WLF is QuestaSim's native waveform format
    # (overrides default vsim.wlf in cwd)
    transcript file [file rootname $wlf_file].transcript
}

# ── Run with hard timeout ──────────────────────────────────────────────────
# Testbenches must self-terminate by stopping the simulator (assert
# severity failure or std.env.stop). 1 s of simulated time is far more
# than any unit test should need at 32 768 Hz sample rate.
set timeout_ns 1000000000
onerror {resume}
run $timeout_ns ns

# ── Verify the testbench produced its result file ─────────────────────────
# A missing or empty result file is itself a failure. The Makefile catches
# this case as well, but flagging it here makes the cause explicit.
if {![file exists $result_file]} {
    set fd [open $result_file w]
    puts $fd "FAIL|$tb_name|$req_class|tb_did_not_produce_result|simtime_at_exit=[time]|started=$timestamp"
    close $fd
    echo "ERROR: testbench did not write result file — synthesised TIMEOUT verdict"
}

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Simulation finished: $tb_name"
echo "═══════════════════════════════════════════════════════════════════════"
quit -code 0
