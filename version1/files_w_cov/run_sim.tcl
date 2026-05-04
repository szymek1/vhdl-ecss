# =============================================================================
# scripts/run_sim.tcl
# -----------------------------------------------------------------------------
# Runs a single QuestaSim simulation of one testbench. Invoked by the
# Makefile via vsim -do. Produces:
#
#   * a structured assertion result file        (PASS/FAIL records)
#   * a Unified Coverage Database (UCDB)        (line/branch/cond/stmt/...)
#   * an optional WLF waveform                  (when SAVE_WAVES=1)
#
# The result file drives the pass/fail verdict — coverage data does NOT.
# Coverage merging and threshold enforcement happen in separate Makefile
# targets, so a low-coverage TB is still allowed to pass.
#
# Arguments (positional):
#   1. tb_name       — testbench entity name (e.g. pwm_generator_tb)
#   2. req_class     — requirement class (e.g. A, B, common)
#   3. report_dir    — absolute path to build/reports/
#   4. wave_dir      — absolute path to build/waves/
#   5. cov_dir       — absolute path to build/coverage/
#
# Output files:
#   <report_dir>/<class>/<tb_name>.result
#   <cov_dir>/<class>/<tb_name>.ucdb
#   <wave_dir>/<class>/<tb_name>.wlf      (only when SAVE_WAVES=1)
#
# ECSS compliance:
#   * No test logic in this script — only simulation control.
#   * Every run is identifiable by class + name + simulation timestamp.
#   * Timeout enforces a hard upper bound on runtime — no hung tests.
# =============================================================================

if {[llength $argv] < 5} {
    puts "ERROR: run_sim.tcl expects 5 arguments: tb_name req_class report_dir wave_dir cov_dir"
    quit -code 1
}

set tb_name    [lindex $argv 0]
set req_class  [lindex $argv 1]
set report_dir [lindex $argv 2]
set wave_dir   [lindex $argv 3]
set cov_dir    [lindex $argv 4]

set timestamp   [clock format [clock seconds] -format "%Y-%m-%d_%H:%M:%S"]
set result_file "$report_dir/$req_class/$tb_name.result"
set ucdb_file   "$cov_dir/$req_class/$tb_name.ucdb"

# ── Banner in transcript ───────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Testbench       : $tb_name"
echo "  Requirement cls : $req_class"
echo "  Started at      : $timestamp"
echo "  Result file     : $result_file"
echo "  UCDB file       : $ucdb_file"
echo "═══════════════════════════════════════════════════════════════════════"

# ── Launch simulation with coverage enabled ───────────────────────────────
# -coverage on the vsim command line activates collection for code already
# instrumented at compile time (the +cover=... flag passed to vcom).
# -GG_RESULT_FILE feeds the per-TB result file path into the testbench.
vsim -t 1ns \
     -voptargs=+acc \
     -coverage \
     -GG_RESULT_FILE=$result_file \
     -GG_REQ_CLASS=$req_class \
     -GG_TB_NAME=$tb_name \
     work.$tb_name

# ── Optional waveform capture ──────────────────────────────────────────────
if {[info exists ::env(SAVE_WAVES)] && $::env(SAVE_WAVES) == "1"} {
    set wlf_file "$wave_dir/$req_class/$tb_name.wlf"
    echo "Saving waveforms to $wlf_file"
    log -recursive /*
    transcript file [file rootname $wlf_file].transcript
}

# ── Run with hard timeout ──────────────────────────────────────────────────
# Testbenches must self-terminate by stopping the simulator (assert
# severity failure or std.env.stop). 1 s of simulated time is far more
# than any unit test should need at 32 768 Hz sample rate.
set timeout_ns 1000000000
onerror {resume}
run $timeout_ns ns

# ── Save coverage database BEFORE quitting ────────────────────────────────
# `coverage save` flushes the in-memory coverage data to a UCDB file that
# can be merged later with `vcover merge`. Failure here must not abort
# the test run — coverage is supplementary information.
echo "Saving coverage database to $ucdb_file"
if {[catch {coverage save $ucdb_file} err]} {
    echo "WARN: coverage save failed: $err"
}

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
