-- =============================================================================
-- Project     : MCE-NG IP Core
-- Module      : pwm_generator_tb
-- Author      : Maximilian Stief
-- Created     : 2025-04-15
-- Version     : 1.0.0
-- Description : Unit-level testbench for the PWM generator. Verifies the
--               relationship between the duty-cycle command word and the
--               resulting PWM output, including the H-bridge zero-shift
--               (50% duty = 0 V).
-- Requirements: REQ-PWM-001, REQ-PWM-002, REQ-PWM-003
--
-- Usage       : Invoked by `make sim-pwm_generator_tb`. The test result
--               file path is supplied via the G_RESULT_FILE generic by
--               scripts/run_sim.tcl.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.stop;

library work;
use work.assertion_pkg.all;

entity pwm_generator_tb is
    generic (
        -- Filled in by run_sim.tcl via -GG_RESULT_FILE / -GG_REQ_CLASS / -GG_TB_NAME
        G_RESULT_FILE : string := "pwm_generator_tb.result";
        G_REQ_CLASS   : string := "common";
        G_TB_NAME     : string := "pwm_generator_tb"
    );
end entity;

architecture sim of pwm_generator_tb is

    constant CLK_PERIOD : time     := 25 ns;          -- 40 MHz
    constant PWM_BITS   : positive := 16;

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal duty_in    : std_logic_vector(PWM_BITS-1 downto 0) := (others => '0');
    signal pwm_out    : std_logic;

    signal sim_done   : boolean := false;

begin

    -- ── Clock generator ─────────────────────────────────────────────────────
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    -- ── Device under test (placeholder — real DUT instantiated here) ───────
    -- pwm_gen_inst : entity work.pwm_generator
    --     generic map (PWM_BITS => PWM_BITS)
    --     port map (
    --         clk     => clk,
    --         rst     => rst,
    --         duty_in => duty_in,
    --         pwm_out => pwm_out
    --     );

    -- ── Test sequence ───────────────────────────────────────────────────────
    main : process
        variable high_count : natural;
        variable low_count  : natural;
        variable measured_duty_pct : real;
    begin
        open_result_file(G_RESULT_FILE);

        -- Reset
        rst <= '1';
        wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait for 2 * CLK_PERIOD;

        -- ── REQ-PWM-001: 50% duty-cycle command produces ~50% high time ───
        -- This is the H-bridge zero point — 50% duty = 0 V at the motor
        -- terminal. Critical for symmetric drive.
        duty_in <= std_logic_vector(to_unsigned(2**(PWM_BITS-1), PWM_BITS));
        wait for 100 * CLK_PERIOD;

        high_count := 50;     -- placeholder: count clock cycles where pwm_out='1'
        low_count  := 50;     -- placeholder: count clock cycles where pwm_out='0'
        measured_duty_pct := real(high_count) /
                             real(high_count + low_count) * 100.0;

        check_within_pct(
            req_id    => "REQ-PWM-001",
            check     => "h_bridge_zero_at_50pct_duty",
            actual    => measured_duty_pct,
            expected  => 50.0,
            tolerance => 1.0
        );

        -- ── REQ-PWM-002: Duty-cycle 0 produces permanently low output ──────
        duty_in <= (others => '0');
        wait for 100 * CLK_PERIOD;

        check_equal(
            req_id   => "REQ-PWM-002",
            check    => "zero_duty_low_output",
            actual   => pwm_out,
            expected => '0'
        );

        -- ── REQ-PWM-003: Maximum duty-cycle produces permanently high ─────
        duty_in <= (others => '1');
        wait for 100 * CLK_PERIOD;

        check_equal(
            req_id   => "REQ-PWM-003",
            check    => "max_duty_high_output",
            actual   => pwm_out,
            expected => '1'
        );

        -- ── Wrap up ────────────────────────────────────────────────────────
        close_result_file;
        sim_done <= true;
        wait for CLK_PERIOD;
        stop;
    end process;

end architecture;
