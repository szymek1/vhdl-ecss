-- =============================================================================
-- Project     : MCE-NG IP Core
-- Module      : assertion_pkg
-- Author      : Maximilian Stief
-- Created     : 2025-04-15
-- Version     : 1.0.0
-- Description : Common assertion machinery for all unit-level testbenches.
--               Each procedure writes ONE line to the per-testbench result
--               file in the format expected by tools/collect_results.py:
--
--                 PASS|REQ-ID|check_name|detail|simtime
--                 FAIL|REQ-ID|check_name|detail|simtime
--
--               The result file path is supplied by the testbench through
--               its G_RESULT_FILE generic, which run_sim.tcl sets per run.
--
-- ECSS-E-ST-20-40C §5.4.3f : verification files include expected outputs
-- ECSS-Q-ST-60-03C §6      : self-checking with structured records
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package assertion_pkg is

    -- ── Open / close the per-testbench result file ──────────────────────────
    -- Every testbench calls open_result_file at the start of its main process
    -- and close_result_file before stopping the simulator.
    procedure open_result_file  (constant path : in string);
    procedure close_result_file;

    -- ── Core assertion procedures ───────────────────────────────────────────
    -- All procedures follow the same shape:
    --   * req_id    — ECSS requirement reference, e.g. "REQ-PWM-001"
    --   * check     — short identifier for this specific check
    --   * detail    — free-form text shown in the report
    --
    -- They write exactly one PASS or FAIL line per call.

    procedure check_equal (
        constant req_id   : in string;
        constant check    : in string;
        constant actual   : in integer;
        constant expected : in integer
    );

    procedure check_equal (
        constant req_id   : in string;
        constant check    : in string;
        constant actual   : in std_logic;
        constant expected : in std_logic
    );

    procedure check_in_range (
        constant req_id : in string;
        constant check  : in string;
        constant actual : in integer;
        constant lo     : in integer;
        constant hi     : in integer
    );

    procedure check_less_than (
        constant req_id : in string;
        constant check  : in string;
        constant actual : in real;
        constant limit  : in real;
        constant units  : in string
    );

    procedure check_within_pct (
        constant req_id    : in string;
        constant check     : in string;
        constant actual    : in real;
        constant expected  : in real;
        constant tolerance : in real        -- as percentage
    );

    -- ── Generic boolean check, when none of the above fits ─────────────────
    procedure check_true (
        constant req_id : in string;
        constant check  : in string;
        constant cond   : in boolean;
        constant detail : in string
    );

end package;


package body assertion_pkg is

    -- Single shared file handle. Tests are run one at a time (vsim is
    -- launched once per testbench) so this is safe.
    file result_file : text;

    -- ── Internal: write one PASS|FAIL line to the result file ──────────────
    procedure write_record (
        constant verdict : in string;
        constant req_id  : in string;
        constant check   : in string;
        constant detail  : in string
    ) is
        variable L : line;
    begin
        write(L, verdict & "|" & req_id & "|" & check & "|" & detail
                         & "|t=" & time'image(now));
        writeline(result_file, L);

        -- Echo to QuestaSim transcript so the developer sees live progress.
        -- severity NOTE never aborts; severity ERROR only flags in transcript.
        if verdict = "PASS" then
            report verdict & " [" & req_id & "] " & check
                   severity note;
        else
            report verdict & " [" & req_id & "] " & check & " — " & detail
                   severity error;
        end if;
    end procedure;

    -- ── File management ────────────────────────────────────────────────────
    procedure open_result_file (constant path : in string) is
    begin
        file_open(result_file, path, write_mode);
    end procedure;

    procedure close_result_file is
    begin
        file_close(result_file);
    end procedure;

    -- ── Equality, integer ──────────────────────────────────────────────────
    procedure check_equal (
        constant req_id   : in string;
        constant check    : in string;
        constant actual   : in integer;
        constant expected : in integer
    ) is
        variable s : string(1 to 64);
    begin
        if actual = expected then
            write_record("PASS", req_id, check,
                "actual=" & integer'image(actual)
                & " expected=" & integer'image(expected));
        else
            write_record("FAIL", req_id, check,
                "actual=" & integer'image(actual)
                & " expected=" & integer'image(expected));
        end if;
    end procedure;

    -- ── Equality, std_logic ────────────────────────────────────────────────
    procedure check_equal (
        constant req_id   : in string;
        constant check    : in string;
        constant actual   : in std_logic;
        constant expected : in std_logic
    ) is
    begin
        if actual = expected then
            write_record("PASS", req_id, check,
                "actual=" & std_logic'image(actual)
                & " expected=" & std_logic'image(expected));
        else
            write_record("FAIL", req_id, check,
                "actual=" & std_logic'image(actual)
                & " expected=" & std_logic'image(expected));
        end if;
    end procedure;

    -- ── Integer in inclusive range ─────────────────────────────────────────
    procedure check_in_range (
        constant req_id : in string;
        constant check  : in string;
        constant actual : in integer;
        constant lo     : in integer;
        constant hi     : in integer
    ) is
    begin
        if actual >= lo and actual <= hi then
            write_record("PASS", req_id, check,
                "actual=" & integer'image(actual)
                & " range=[" & integer'image(lo) & "," & integer'image(hi) & "]");
        else
            write_record("FAIL", req_id, check,
                "actual=" & integer'image(actual)
                & " range=[" & integer'image(lo) & "," & integer'image(hi) & "]");
        end if;
    end procedure;

    -- ── Real less than ─────────────────────────────────────────────────────
    procedure check_less_than (
        constant req_id : in string;
        constant check  : in string;
        constant actual : in real;
        constant limit  : in real;
        constant units  : in string
    ) is
    begin
        if actual < limit then
            write_record("PASS", req_id, check,
                "actual=" & real'image(actual) & units
                & " limit=" & real'image(limit) & units);
        else
            write_record("FAIL", req_id, check,
                "actual=" & real'image(actual) & units
                & " limit=" & real'image(limit) & units);
        end if;
    end procedure;

    -- ── Real within percentage of expected value ───────────────────────────
    procedure check_within_pct (
        constant req_id    : in string;
        constant check     : in string;
        constant actual    : in real;
        constant expected  : in real;
        constant tolerance : in real
    ) is
        variable diff_pct : real;
    begin
        if expected = 0.0 then
            diff_pct := abs(actual) * 100.0;
        else
            diff_pct := abs(actual - expected) / abs(expected) * 100.0;
        end if;

        if diff_pct <= tolerance then
            write_record("PASS", req_id, check,
                "actual=" & real'image(actual)
                & " expected=" & real'image(expected)
                & " diff=" & real'image(diff_pct) & "%"
                & " tol=" & real'image(tolerance) & "%");
        else
            write_record("FAIL", req_id, check,
                "actual=" & real'image(actual)
                & " expected=" & real'image(expected)
                & " diff=" & real'image(diff_pct) & "%"
                & " tol=" & real'image(tolerance) & "%");
        end if;
    end procedure;

    -- ── Generic boolean ────────────────────────────────────────────────────
    procedure check_true (
        constant req_id : in string;
        constant check  : in string;
        constant cond   : in boolean;
        constant detail : in string
    ) is
    begin
        if cond then
            write_record("PASS", req_id, check, detail);
        else
            write_record("FAIL", req_id, check, detail);
        end if;
    end procedure;

end package body;
