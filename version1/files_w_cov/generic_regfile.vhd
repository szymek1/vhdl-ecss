LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.math_real.ALL;

ENTITY generic_regfile IS
    GENERIC (
        G_BIT : POSITIVE := 32;
        G_DEPTH : POSITIVE := 8
    );
    PORT (
        i_clk : IN STD_LOGIC;
        i_rst_n : IN STD_LOGIC;
        i_rd_addr : IN STD_LOGIC_VECTOR(5 - 1 DOWNTO 0);
        i_wrt_addr : IN STD_LOGIC_VECTOR(5 - 1 DOWNTO 0);
        i_wrt_enb : IN STD_LOGIC;
        i_wrt_data : IN STD_LOGIC_VECTOR(G_BIT - 1 DOWNTO 0);

        o_rd_data : OUT STD_LOGIC_VECTOR(G_BIT - 1 DOWNTO 0);
        o_data_valid : OUT STD_LOGIC
    );
END;
ARCHITECTURE rtl OF generic_regfile IS
    TYPE t_mem IS ARRAY (0 TO G_DEPTH - 1) OF STD_LOGIC_VECTOR(G_BIT - 1 DOWNTO 0);
    SIGNAL reg_mem : t_mem := (OTHERS => (OTHERS => '0'));

    SIGNAL reg_rd_addr : STD_LOGIC_VECTOR(5 - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL reg_rd_data : STD_LOGIC_VECTOR(G_BIT - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL reg_rd_valid : STD_LOGIC := '0';
BEGIN

    p_read : PROCESS (i_clk) IS
        VARIABLE var_reg_addr : INTEGER;
    BEGIN
        IF (i_rst_n = '0') THEN
            reg_rd_addr <= (OTHERS => '0');
            reg_rd_data <= (OTHERS => '0');
            reg_rd_valid <= '0';
            var_reg_addr := 0;
        ELSIF rising_edge(i_clk) THEN
            var_reg_addr := to_integer(unsigned(i_rd_addr));
            IF var_reg_addr < G_DEPTH THEN
                reg_rd_data <= reg_mem(var_reg_addr);
                reg_rd_valid <= '1';
            ELSE
                reg_rd_data <= (OTHERS => '0');
                reg_rd_valid <= '0';
            END IF;
        END IF;
    END PROCESS p_read;

    p_write : PROCESS (i_clk) IS
        VARIABLE var_reg_addr : INTEGER;
    BEGIN
        IF (i_rst_n = '0') THEN
            reg_mem <= (OTHERS => (OTHERS => '0'));
        ELSIF rising_edge(i_clk) THEN
            IF i_wrt_enb = '1' THEN
                IF to_integer(unsigned(i_wrt_addr)) < G_DEPTH THEN
                    reg_mem(to_integer(unsigned(i_wrt_addr))) <= i_wrt_data;
                END IF;
            END IF;
        END IF;
    END PROCESS p_write;

    o_rd_data <= reg_rd_data;
    o_data_valid <= '0' WHEN i_wrt_enb = '1' ELSE
        reg_rd_valid; -- read data valid

END rtl;