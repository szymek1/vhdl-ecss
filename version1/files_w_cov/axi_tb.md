Here's a focused integration testbench. The instantiation/wiring is left as placeholders for you, and the value is in the AXI master BFM and the scenario process built on your `assertion_pkg` checks.

```vhdl
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.finish;
USE work.assertion_pkg.ALL;          -- your established check_* procedures

ENTITY axi_regfile_top_tb IS
    GENERIC (
        G_RESULT_FILE : string := "axi_regfile_top_tb.result";
        G_REQ_CLASS   : string := "C";
        G_TB_NAME     : string := "axi_regfile_top_tb"
    );
END axi_regfile_top_tb;

ARCHITECTURE testbench OF axi_regfile_top_tb IS

    -- ── Clock / data parameters ─────────────────────────────────────────────
    CONSTANT clk_hz     : INTEGER := 40e6;
    CONSTANT clk_period : TIME    := 1 sec / clk_hz;
    CONSTANT C_ADDR_W   : POSITIVE := 16;
    CONSTANT C_DATA_W   : POSITIVE := 32;

    -- ── AXI response codes ──────────────────────────────────────────────────
    CONSTANT RRESP_OKAY   : STD_LOGIC_VECTOR(1 DOWNTO 0) := "00";
    CONSTANT RRESP_DECERR : STD_LOGIC_VECTOR(1 DOWNTO 0) := "11";

    -- ── Clock / reset ───────────────────────────────────────────────────────
    SIGNAL clk   : STD_LOGIC := '0';
    SIGNAL rst_n : STD_LOGIC := '0';

    -- ── AXI4-Lite master-facing signals (flat) ──────────────────────────────
    -- Connect these to your AXI slave's master-facing ports (records or flat).
    -- Write address channel
    SIGNAL s_awaddr  : STD_LOGIC_VECTOR(C_ADDR_W - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_awvalid : STD_LOGIC := '0';
    SIGNAL s_awready : STD_LOGIC;
    -- Write data channel
    SIGNAL s_wdata   : STD_LOGIC_VECTOR(C_DATA_W - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_wstrb   : STD_LOGIC_VECTOR(C_DATA_W/8 - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_wvalid  : STD_LOGIC := '0';
    SIGNAL s_wready  : STD_LOGIC;
    -- Write response channel
    SIGNAL s_bresp   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL s_bvalid  : STD_LOGIC;
    SIGNAL s_bready  : STD_LOGIC := '0';
    -- Read address channel
    SIGNAL s_araddr  : STD_LOGIC_VECTOR(C_ADDR_W - 1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_arvalid : STD_LOGIC := '0';
    SIGNAL s_arready : STD_LOGIC;
    -- Read data channel
    SIGNAL s_rdata   : STD_LOGIC_VECTOR(C_DATA_W - 1 DOWNTO 0);
    SIGNAL s_rresp   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL s_rvalid  : STD_LOGIC;
    SIGNAL s_rready  : STD_LOGIC := '0';

    -- ── Register-map constants ──────────────────────────────────────────────
    -- Adjust these to match your actual C_MOTOR_POLICY / C_GLOBAL_POLICY.
    CONSTANT REG_RW_SIMPLE : NATURAL := 0;   -- plain RW motor register (e.g. MODE)
    CONSTANT REG_SHADOW_A  : NATURAL := 2;   -- shadowed RW reg, commit group 1
    CONSTANT REG_SHADOW_B  : NATURAL := 3;   -- shadowed RW reg, same commit group
    CONSTANT REG_COMMIT    : NATURAL := 7;   -- commit/valid reg for group 1
    CONSTANT REG_RO_TELEM  : NATURAL := 31;  -- read-only motor register
    CONSTANT GLOB_RW       : NATURAL := 3;   -- RW global register (e.g. SYS_CTRL)

    -- ── Address helpers ─────────────────────────────────────────────────────
    -- Layout (your convention): bit 10 = 0 -> global, 1 -> motor;
    --   bits 9:8 = motor index; bits 7:2 = register index; bits 1:0 = 00.
    FUNCTION motor_addr(motor_idx : NATURAL; reg_idx : NATURAL) RETURN NATURAL IS
    BEGIN
        RETURN 1024 + (motor_idx * 256) + (reg_idx * 4);   -- bit10=1 | m<<8 | r<<2
    END FUNCTION;

    FUNCTION global_addr(reg_idx : NATURAL) RETURN NATURAL IS
    BEGIN
        RETURN (reg_idx * 4);                              -- bit10=0 | r<<2
    END FUNCTION;

    -- ── AXI master BFM: single write ────────────────────────────────────────
    PROCEDURE axi_write(
        SIGNAL   clk      : IN  STD_LOGIC;
        SIGNAL   awaddr   : OUT STD_LOGIC_VECTOR(C_ADDR_W - 1 DOWNTO 0);
        SIGNAL   awvalid  : OUT STD_LOGIC;
        SIGNAL   awready  : IN  STD_LOGIC;
        SIGNAL   wdata    : OUT STD_LOGIC_VECTOR(C_DATA_W - 1 DOWNTO 0);
        SIGNAL   wstrb    : OUT STD_LOGIC_VECTOR(C_DATA_W/8 - 1 DOWNTO 0);
        SIGNAL   wvalid   : OUT STD_LOGIC;
        SIGNAL   wready   : IN  STD_LOGIC;
        SIGNAL   bresp    : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
        SIGNAL   bvalid   : IN  STD_LOGIC;
        SIGNAL   bready   : OUT STD_LOGIC;
        CONSTANT addr     : IN  NATURAL;
        CONSTANT data     : IN  NATURAL;
        VARIABLE resp_out : OUT STD_LOGIC_VECTOR(1 DOWNTO 0)
    ) IS
        VARIABLE aw_done : BOOLEAN := false;
        VARIABLE w_done  : BOOLEAN := false;
    BEGIN
        -- Drive address and data phases together (AXI4-Lite allows concurrency)
        awaddr  <= STD_LOGIC_VECTOR(to_unsigned(addr, C_ADDR_W));
        awvalid <= '1';
        wdata   <= STD_LOGIC_VECTOR(to_unsigned(data, C_DATA_W));
        wstrb   <= (OTHERS => '1');
        wvalid  <= '1';
        aw_done := false;
        w_done  := false;
        -- Wait for both handshakes; they may complete in either order
        WHILE NOT (aw_done AND w_done) LOOP
            WAIT UNTIL rising_edge(clk);
            IF awready = '1' AND NOT aw_done THEN
                awvalid <= '0';
                aw_done := true;
            END IF;
            IF wready = '1' AND NOT w_done THEN
                wvalid <= '0';
                w_done := true;
            END IF;
        END LOOP;
        -- Write response phase
        bready <= '1';
        WAIT UNTIL rising_edge(clk) AND bvalid = '1';
        resp_out := bresp;
        bready <= '0';
    END PROCEDURE;

    -- ── AXI master BFM: single read ─────────────────────────────────────────
    -- The slave internally handles the one-cycle register-file read latency;
    -- the BFM just follows the AXI handshake, so no latency logic is needed here.
    PROCEDURE axi_read(
        SIGNAL   clk      : IN  STD_LOGIC;
        SIGNAL   araddr   : OUT STD_LOGIC_VECTOR(C_ADDR_W - 1 DOWNTO 0);
        SIGNAL   arvalid  : OUT STD_LOGIC;
        SIGNAL   arready  : IN  STD_LOGIC;
        SIGNAL   rdata    : IN  STD_LOGIC_VECTOR(C_DATA_W - 1 DOWNTO 0);
        SIGNAL   rresp    : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
        SIGNAL   rvalid   : IN  STD_LOGIC;
        SIGNAL   rready   : OUT STD_LOGIC;
        CONSTANT addr     : IN  NATURAL;
        VARIABLE data_out : OUT INTEGER;
        VARIABLE resp_out : OUT STD_LOGIC_VECTOR(1 DOWNTO 0)
    ) IS
    BEGIN
        araddr  <= STD_LOGIC_VECTOR(to_unsigned(addr, C_ADDR_W));
        arvalid <= '1';
        WAIT UNTIL rising_edge(clk) AND arready = '1';
        arvalid <= '0';
        rready  <= '1';
        WAIT UNTIL rising_edge(clk) AND rvalid = '1';
        data_out := to_integer(unsigned(rdata));
        resp_out := rresp;
        rready  <= '0';
    END PROCEDURE;

BEGIN

    -- ════════════════════════════════════════════════════════════════════════
    -- INSTANTIATE AND WIRE HERE (your job):
    --   * the AXI4-Lite slave, with master-facing ports connected to the
    --     s_* signals above and register-file-facing ports connected to the
    --     register file instance below
    --   * the register file (3 motor regfiles + 1 global), connected to the
    --     slave's register-file-facing ports
    -- ════════════════════════════════════════════════════════════════════════

    -- ── Clock and reset ─────────────────────────────────────────────────────
    clk   <= NOT clk AFTER clk_period / 2;
    rst_n <= '0', '1' AFTER 5 * clk_period;

    -- ── Watchdog: fail cleanly if the DUT hangs ─────────────────────────────
    p_watchdog : PROCESS IS
    BEGIN
        WAIT FOR 500 us;
        check_true("REQ-RF-AXI-WDG", "watchdog_timeout", false,
                   "testbench exceeded time budget - DUT likely hung");
        finish;
    END PROCESS;

    -- ── Main stimulus / checking ────────────────────────────────────────────
    p_verification : PROCESS IS
        VARIABLE v_rdata : INTEGER;
        VARIABLE v_resp  : STD_LOGIC_VECTOR(1 DOWNTO 0);
        VARIABLE v_wresp : STD_LOGIC_VECTOR(1 DOWNTO 0);
        VARIABLE v_old   : INTEGER;
        CONSTANT V1 : NATURAL := 16#DEADBE#;   -- arbitrary distinct test values
        CONSTANT V2 : NATURAL := 16#0BADF0#;
        CONSTANT V3 : NATURAL := 16#123456#;
    BEGIN
        init_results(G_RESULT_FILE, G_REQ_CLASS, G_TB_NAME);  -- match your API
        WAIT UNTIL rst_n = '1';
        WAIT UNTIL rising_edge(clk);

        ----------------------------------------------------------------------
        -- Scenario 1 — basic RW round-trip on motor 0
        -- REQ: a value written to a RW motor register reads back unchanged.
        ----------------------------------------------------------------------
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(0, REG_RW_SIMPLE), V1, v_wresp);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_RW_SIMPLE), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-001", "motor0_rw_roundtrip", v_rdata, V1);

        ----------------------------------------------------------------------
        -- Scenario 2 — motor independence (correct motor-index decode)
        -- REQ: writing the same register index in different motors does not
        --      alias; each motor stores its own value.
        ----------------------------------------------------------------------
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(0, REG_RW_SIMPLE), 111, v_wresp);
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(1, REG_RW_SIMPLE), 222, v_wresp);
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(2, REG_RW_SIMPLE), 333, v_wresp);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_RW_SIMPLE), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-002", "motor0_independent", v_rdata, 111);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(1, REG_RW_SIMPLE), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-002", "motor1_independent", v_rdata, 222);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(2, REG_RW_SIMPLE), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-002", "motor2_independent", v_rdata, 333);

        ----------------------------------------------------------------------
        -- Scenario 3 — global vs motor decode (bit 10)
        -- REQ: a global write lands in the global block, not in a motor block
        --      at the same register index.
        ----------------------------------------------------------------------
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  global_addr(GLOB_RW), V3, v_wresp);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, global_addr(GLOB_RW), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-003", "global_rw_roundtrip", v_rdata, V3);
        -- the motor register at the same index must be unaffected
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, GLOB_RW), v_rdata, v_resp);
        check_true("REQ-RF-AXI-003", "global_motor_no_alias",
                   v_rdata /= V3, "motor reg aliased global write");

        ----------------------------------------------------------------------
        -- Scenario 4 — read-only register is not writable
        -- REQ: a write to a RO register does not change its value.
        ----------------------------------------------------------------------
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_RO_TELEM), v_rdata, v_resp);
        v_old := v_rdata;
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(0, REG_RO_TELEM), 16#FFFFFF#, v_wresp);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_RO_TELEM), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-004", "ro_write_ignored", v_rdata, v_old);

        ----------------------------------------------------------------------
        -- Scenario 5 — shadow / active commit (the important one)
        -- REQ: writes to shadowed registers do not affect reads until the
        --      commit register is set; after commit, the group updates together
        --      and the commit register self-clears.
        ----------------------------------------------------------------------
        -- start from a known active state: commit zeros, then capture baseline
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_SHADOW_A), v_old, v_resp);

        -- write new values into the shadow copies
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(0, REG_SHADOW_A), V1, v_wresp);
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(0, REG_SHADOW_B), V2, v_wresp);

        -- before commit: reads must still return the OLD active values
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_SHADOW_A), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-005", "shadow_not_visible_precommit",
                    v_rdata, v_old);

        -- fire the commit
        axi_write(clk, s_awaddr, s_awvalid, s_awready, s_wdata, s_wstrb,
                  s_wvalid, s_wready, s_bresp, s_bvalid, s_bready,
                  motor_addr(0, REG_COMMIT), 1, v_wresp);
        -- allow the commit to propagate
        FOR k IN 0 TO 3 LOOP WAIT UNTIL rising_edge(clk); END LOOP;

        -- after commit: both registers in the group reflect the new values
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_SHADOW_A), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-005", "shadow_A_committed", v_rdata, V1);
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_SHADOW_B), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-005", "shadow_B_committed", v_rdata, V2);

        -- the commit register must have self-cleared
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(0, REG_COMMIT), v_rdata, v_resp);
        check_equal("REQ-RF-AXI-005", "commit_self_cleared", v_rdata, 0);

        -- committing one motor must not commit another motor's group
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, motor_addr(1, REG_SHADOW_A), v_rdata, v_resp);
        check_true("REQ-RF-AXI-005", "commit_motor_isolated",
                   v_rdata /= V1, "motor1 committed by motor0 trigger");

        ----------------------------------------------------------------------
        -- Scenario 6 — out-of-range read returns DECERR
        -- REQ: an address outside the decoded space yields a DECERR response.
        -- (Comment out if your slave does not implement DECERR.)
        ----------------------------------------------------------------------
        axi_read(clk, s_araddr, s_arvalid, s_arready, s_rdata, s_rresp,
                 s_rvalid, s_rready, 16#7FC#, v_rdata, v_resp);  -- unmapped addr
        check_true("REQ-RF-AXI-006", "oor_read_decerr",
                   v_resp = RRESP_DECERR, "out-of-range read not DECERR");

        WAIT FOR 5 * clk_period;
        close_results;                       -- match your assertion_pkg API
        finish;
    END PROCESS p_verification;

END testbench;
```

## What each scenario verifies

The scenarios are chosen to test the *integration*, not the regfile in isolation (you already have a regfile unit testbench). Each targets a seam where the AXI slave, the address decode, and the regfile meet:

1. **Basic round-trip** confirms the whole path works: AXI write → decode → regfile write → AXI read → decode → regfile read → AXI data, including the slave's one-cycle-latency handling. If `rvalid`/`rdata` timing is wrong (the thing you were just fixing), this fails.

2. **Motor independence** is the key test for the motor-index decode (bits 9:8). Writing distinct values to the same register index across all three motors and reading each back catches any cross-talk or wrong-motor routing. The distinct values (111/222/333) make a misroute visible.

3. **Global vs motor decode** exercises bit 10. It also checks that a global write doesn't alias into a motor block at the same register offset — a classic decode bug.

4. **Read-only enforcement** confirms the policy map's `ACCESS_RO` is honored end-to-end: a write to a telemetry register is silently ignored.

5. **Shadow/active commit** is the most valuable test, because it exercises the mechanism you built specifically for this design. It checks all four properties: shadow writes are invisible before commit, the whole group updates on commit, the commit register self-clears, and one motor's commit doesn't fire another motor's group.

6. **DECERR** confirms out-of-range addresses produce the right AXI response (comment it out if your slave doesn't implement DECERR yet).

## Assumptions you'll need to reconcile

**The `assertion_pkg` API.** I used `init_results`, `check_equal`, `check_true`, and `close_results` with the argument order `(req_id, check_name, actual, expected)` and `(req_id, check_name, condition, detail)`. Adjust these calls to match your actual procedure signatures — the logic stays the same, only the call syntax changes.

**Flat AXI signals.** Your slave uses record ports (I saw `i_axi_rd_addr.arvalid` etc. in the photo). I declared flat signals because the BFM is cleaner that way and it's portable. When you wire the instantiation, map the flat `s_*` signals to the record fields — e.g. `i_axi_rd_addr.araddr => s_araddr, i_axi_rd_addr.arvalid => s_arvalid`. If you prefer, you can change the BFM parameters to take the record types directly, but flat keeps the BFM reusable.

**Register indices and the bit-10 convention.** I encoded your stated convention (bit 10 = 0 → global, 1 → motor) in the `motor_addr`/`global_addr` helpers. The register index constants (`REG_SHADOW_A`, `REG_COMMIT`, etc.) are placeholders — set them to match your real `C_MOTOR_POLICY` so the shadowed registers and their commit register line up with the group you're testing.

**The post-commit settle delay.** I inserted a few clock cycles after writing the commit register before reading back, to let the commit propagate through the write process. If your commit takes a different number of cycles, adjust the loop count.

The watchdog process gives you a clean failure if the DUT hangs (e.g. `rvalid` never asserts because the latency handling is wrong) rather than relying solely on the simulator-level timeout — and it writes a result record so the failure shows up in your report rather than as a silent hang.
