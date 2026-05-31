LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY regfile_top IS
    PORT (
        i_clk : IN STD_LOGIC;
        i_rst_n : IN STD_LOGIC;
        i_rd_addr : IN STD_LOGIC_VECTOR(7 - 1 DOWNTO 0);
        i_wrt_addr : IN STD_LOGIC_VECTOR(7 - 1 DOWNTO 0);
        i_wrt_enb : IN STD_LOGIC;
        i_wrt_data : IN STD_LOGIC_VECTOR(32 - 1 DOWNTO 0);
        o_rd_data : OUT STD_LOGIC_VECTOR(32 - 1 DOWNTO 0);
        o_data_valid : OUT STD_LOGIC
    );
END regfile_top;

ARCHITECTURE rtl OF regfile_top IS

    CONSTANT C_N_REGFILES : POSITIVE := 3;

    TYPE t_out_array IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(32 - 1 DOWNTO 0);
    TYPE t_valid_array IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC;

    -- top 2 bits select the regfile; bottom 5 bits are the in-regfile address
    SIGNAL s_rd_sel : INTEGER RANGE 0 TO C_N_REGFILES - 1 := 0;
    SIGNAL s_wrt_sel : INTEGER RANGE 0 TO C_N_REGFILES - 1 := 0;
    SIGNAL s_rd_addr : STD_LOGIC_VECTOR(5 - 1 DOWNTO 0);
    SIGNAL s_wrt_addr : STD_LOGIC_VECTOR(5 - 1 DOWNTO 0);

    SIGNAL s_rd_data_array : t_out_array(0 TO C_N_REGFILES - 1);
    SIGNAL s_rd_valid_array : t_valid_array(0 TO C_N_REGFILES - 1);
    SIGNAL s_wrt_enb_array : t_valid_array(0 TO C_N_REGFILES - 1);

BEGIN

    -- Split address: [6:5] selects regfile, [4:0] is the register within it
    s_rd_sel <= to_integer(unsigned(i_rd_addr (6 DOWNTO 5)));
    s_wrt_sel <= to_integer(unsigned(i_wrt_addr(6 DOWNTO 5)));
    s_rd_addr <= i_rd_addr (4 DOWNTO 0);
    s_wrt_addr <= i_wrt_addr(4 DOWNTO 0);

    -- Instantiate one regfile per motor
    gen_wrt_enb : FOR i IN 0 TO C_N_REGFILES - 1 GENERATE
        s_wrt_enb_array(i) <= i_wrt_enb WHEN (i = s_wrt_sel) ELSE
        '0';
    END GENERATE;

    gen_regfiles : FOR i IN 0 TO C_N_REGFILES - 1 GENERATE
        u_regfile : ENTITY work.generic_regfile(rtl)
            GENERIC MAP(G_BIT => 32, G_DEPTH => 8)
            PORT MAP(
                i_clk => i_clk,
                i_rst_n => i_rst_n,
                i_rd_addr => s_rd_addr,
                i_wrt_addr => s_wrt_addr,
                i_wrt_enb => s_wrt_enb_array(i),
                i_wrt_data => i_wrt_data,
                o_rd_data => s_rd_data_array(i),
                o_data_valid => s_rd_valid_array(i)
            );
    END GENERATE;

    -- Mux the read output by the read selector
    o_rd_data <= s_rd_data_array(s_rd_sel);
    o_data_valid <= s_rd_valid_array(s_rd_sel);

END ARCHITECTURE;