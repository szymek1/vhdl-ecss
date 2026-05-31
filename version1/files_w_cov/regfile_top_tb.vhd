LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE std.env.finish;

ENTITY regfile_top_tb IS
END regfile_top_tb;

ARCHITECTURE sim OF regfile_top_tb IS
    CONSTANT clk_hz : INTEGER := 40e6;
    CONSTANT clk_period : TIME := 1 sec / clk_hz;
    CONSTANT bits : POSITIVE := 32;
    CONSTANT depth : POSITIVE := 8; -- registers per regfile to test
    CONSTANT n_regfiles : POSITIVE := 3;

    SIGNAL clk : STD_LOGIC := '0';
    SIGNAL rst : STD_LOGIC := '0';
    SIGNAL s_rd_addr : STD_LOGIC_VECTOR(7 - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_wrt_addr : STD_LOGIC_VECTOR(7 - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_wrt_enb : STD_LOGIC := '0';
    SIGNAL s_wrt_data : STD_LOGIC_VECTOR(32 - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_out_rd_data : STD_LOGIC_VECTOR(32 - 1 DOWNTO 0);
    SIGNAL s_out_data_valid : STD_LOGIC;

    -- Write one location: address and data are set by the caller beforehand,
    -- this just pulses the write enable for one cycle.
    PROCEDURE proc_regfile_wrt(
        SIGNAL in_clk : IN STD_LOGIC;
        SIGNAL in_enb : OUT STD_LOGIC
    ) IS
    BEGIN
        WAIT UNTIL rising_edge(in_clk);
        in_enb <= '1';
        WAIT UNTIL rising_edge(in_clk);
        in_enb <= '0';
    END PROCEDURE;

    -- Read one location: issue the full 7-bit address, wait out the
    -- one-cycle read latency, then sample. Adjust the wait count if your
    -- regfile_top latency differs.
    PROCEDURE proc_regfile_rd(
        SIGNAL in_clk : IN STD_LOGIC;
        SIGNAL out_rd_addr : OUT STD_LOGIC_VECTOR(7 - 1 DOWNTO 0);
        SIGNAL in_rd_data : IN STD_LOGIC_VECTOR(bits - 1 DOWNTO 0);
        CONSTANT addr : IN INTEGER;
        VARIABLE out_data : OUT INTEGER
    ) IS
    BEGIN
        out_rd_addr <= STD_LOGIC_VECTOR(to_unsigned(addr, out_rd_addr'length));
        WAIT UNTIL rising_edge(in_clk); -- address registers into the regfile
        WAIT UNTIL rising_edge(in_clk); -- registered read data emerges
        out_data := to_integer(unsigned(in_rd_data));
    END PROCEDURE;

BEGIN

    DUT : ENTITY work.regfile_top(rtl)
        PORT MAP(
            i_clk => clk,
            i_rst_n => rst,
            i_rd_addr => s_rd_addr,
            i_wrt_addr => s_wrt_addr,
            i_wrt_enb => s_wrt_enb,
            i_wrt_data => s_wrt_data,
            o_rd_data => s_out_rd_data,
            o_data_valid => s_out_data_valid
        );

    clk <= NOT clk AFTER clk_period / 2;
    rst <= '0', '1' AFTER 5 * clk_period;

    p_verification : PROCESS IS
        VARIABLE var_value : INTEGER;
        VARIABLE var_addr : INTEGER;
        VARIABLE var_expected : INTEGER;
        VARIABLE var_errors : INTEGER := 0;
    BEGIN
        WAIT UNTIL rst = '1'; -- wait for reset to finish

        -- ── Write phase: fill each regfile ────────────────────────────────
        FOR j IN 0 TO n_regfiles - 1 LOOP
            FOR i IN 0 TO depth - 1 LOOP
                var_value := j + i + 1; -- distinct per (j,i)
                var_addr := (j * 32) + i; -- selector at bits 6:5
                s_wrt_data <= STD_LOGIC_VECTOR(to_unsigned(var_value, s_wrt_data'length));
                s_wrt_addr <= STD_LOGIC_VECTOR(to_unsigned(var_addr, s_wrt_addr'length));
                proc_regfile_wrt(clk, s_wrt_enb);
            END LOOP;
        END LOOP;

        -- ── Read phase: verify each regfile ───────────────────────────────
        FOR j IN 0 TO n_regfiles - 1 LOOP
            FOR i IN 0 TO depth - 1 LOOP
                var_addr := (j * 32) + i;
                var_expected := j + i + 1;
                proc_regfile_rd(clk, s_rd_addr, s_out_rd_data, var_addr, var_value);
                IF var_value = var_expected THEN
                    REPORT "REGFILE[" & INTEGER'image(j) & "] REG["
                        & INTEGER'image(i) & "]: value OK ("
                        & INTEGER'image(var_value) & ")";
                ELSE
                    REPORT "REGFILE[" & INTEGER'image(j) & "] REG["
                        & INTEGER'image(i) & "] WRONG: got "
                        & INTEGER'image(var_value) & " expected "
                        & INTEGER'image(var_expected)
                        SEVERITY error;
                    var_errors := var_errors + 1;
                END IF;
            END LOOP;
        END LOOP;

        WAIT FOR 5 * clk_period;
        IF var_errors = 0 THEN
            REPORT "Simulation finished: ALL PASS";
        ELSE
            REPORT "Simulation finished: " & INTEGER'image(var_errors)
                & " FAILURES" SEVERITY error;
        END IF;
        finish;
    END PROCESS p_verification;

END ARCHITECTURE;