LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.math_real.ALL;

USE std.textio.ALL;
USE std.env.finish;

ENTITY generic_regfile_tb IS
END generic_regfile_tb;

ARCHITECTURE testbench OF generic_regfile_tb IS

    CONSTANT clk_hz : INTEGER := 40e6;
    CONSTANT clk_period : TIME := 1 sec / clk_hz;
    CONSTANT bits : POSITIVE := 32;
    CONSTANT depth : POSITIVE := 8;

    SIGNAL clk : STD_LOGIC := '0';
    SIGNAL rst : STD_LOGIC := '0';

    SIGNAL s_read_addr : STD_LOGIC_VECTOR(5 - 1 DOWNTO 0);
    SIGNAL s_write_addr : STD_LOGIC_VECTOR(5 - 1 DOWNTO 0);

    SIGNAL s_read_data : STD_LOGIC_VECTOR(bits - 1 DOWNTO 0);
    SIGNAL s_read_valid : STD_LOGIC;

    SIGNAL s_write_data : STD_LOGIC_VECTOR(bits - 1 DOWNTO 0);
    SIGNAL s_write_enb : STD_LOGIC := '0';

    -- procedures
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

    PROCEDURE proc_regfile_rd(
        SIGNAL in_clk : IN STD_LOGIC;
        SIGNAL in_data_valid : IN STD_LOGIC;
        SIGNAL in_out_data : IN STD_LOGIC_VECTOR(bits - 1 DOWNTO 0);
        VARIABLE out_data : OUT INTEGER
    ) IS
    BEGIN
        WAIT UNTIL rising_edge(in_clk) AND in_data_valid = '1';
        WAIT FOR clk_period;
        out_data := to_integer(signed(in_out_data));
    END PROCEDURE;

BEGIN
    DUT : ENTITY work.generic_regfile(rtl)
        GENERIC MAP(
            G_BIT => bits,
            G_DEPTH => depth
        )
        PORT MAP(
            i_clk => clk,
            i_rst_n => rst,
            i_rd_addr => s_read_addr,
            i_wrt_addr => s_write_addr,
            i_wrt_enb => s_write_enb,
            i_wrt_data => s_write_data,
            o_rd_data => s_read_data,
            o_data_valid => s_read_valid
        );

    clk <= NOT clk AFTER clk_period / 2;
    rst <= '0', '1' AFTER 5 * clk_period;

    p_verification : PROCESS IS
        VARIABLE var_curr_reg_value : INTEGER;
        VARIABLE var_curr_reg_addr : INTEGER;
    BEGIN
        WAIT UNTIL rst = '1'; -- wait for the reset to finish
        -- Initialization of the register file
        FOR i IN 0 TO depth - 1 LOOP
            var_curr_reg_value := i + 1;
            var_curr_reg_addr := i;
            s_write_data <= STD_LOGIC_VECTOR(to_unsigned(var_curr_reg_value, s_write_data'length));
            s_write_addr <= STD_LOGIC_VECTOR(to_unsigned(var_curr_reg_addr, s_write_addr'length));
            proc_regfile_wrt(clk, s_write_enb);
            var_curr_reg_value := var_curr_reg_value + 1;
        END LOOP;

        -- Reading values of the register file
        FOR i IN 0 TO depth - 1 LOOP
            var_curr_reg_addr := i;
            s_read_addr <= STD_LOGIC_VECTOR(to_unsigned(i, s_read_addr'length));
            proc_regfile_rd(clk, s_read_valid, s_read_data, var_curr_reg_value);
            IF (var_curr_reg_value = var_curr_reg_addr + 1) THEN
                REPORT "REG[" & INTEGER'image(i) & "]: value OK";
            ELSE
                REPORT "REG[" & INTEGER'image(i) & "] value is WRONG: "
                    & INTEGER'image(var_curr_reg_value);
            END IF;
        END LOOP;

        WAIT FOR 5 * clk_period;

        REPORT "Simulaiton has finished";
        finish;
    END PROCESS p_verification;

END testbench;