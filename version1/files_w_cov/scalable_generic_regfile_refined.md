This is a substantial design, and the central challenge isn't the shadow/active logic itself — it's how to *parameterise the per-register policy* cleanly so one generic entity can become any regfile. Let me work through the architecture before writing code, because the data structure you choose for the "map" determines everything else.

## The core problem: communicating per-register policy to a generic entity

You need each register to carry three independent properties:

1. **Access type** — RO, WO, or RW
2. **Has shadow** — whether this register is a shadow/active pair or active-only
3. **Commit trigger** — which (if any) "valid" register causes this register's shadow to copy to active, and whether this register *is* a commit-trigger register

The clean VHDL mechanism for this is an **array of records, passed as a generic**. VHDL-2008 allows unconstrained record arrays as generics, so you define a configuration type and hand each instance its own table. The map lives in a package (written once), and motor instances all reference the same map while the global instance references a different one.

## The configuration data structure

```vhdl
-- in regfile_config_pkg.vhd
package regfile_config_pkg is

    type t_access is (ACCESS_RO, ACCESS_WO, ACCESS_RW);

    -- One entry per register describing its policy
    type t_reg_policy is record
        access_type   : t_access;   -- RO / WO / RW
        has_shadow    : boolean;     -- true = shadow+active pair, false = active only
        is_commit     : boolean;     -- true = this register is a commit-trigger
        commit_group  : natural;     -- which commit group this register belongs to
                                     -- (only meaningful when has_shadow = true,
                                     --  or identifies which group a commit reg fires)
    end record;

    type t_reg_policy_array is array (natural range <>) of t_reg_policy;

    -- ... concrete maps defined below ...
end package;
```

The `commit_group` field is the key to linking commit-trigger registers to the registers they commit. The idea: every shadow/active register that belongs to "control law coefficients" gets `commit_group => 1`. The `CTRL_COEFFS_VALID` register is marked `is_commit => true, commit_group => 1`. When the valid register in group 1 is written high, every shadow register with `commit_group => 1` copies to active. This cleanly handles your requirement that coefficients commit as a set.

## Defining the actual maps

In the same package, you define the concrete policy table for the motor regfile and (separately) for the global regfile:

```vhdl
    -- Motor regfile: 35 registers. Indices are your register map offsets.
    -- This is illustrative — fill in to match your real register map.
    constant C_MOTOR_POLICY : t_reg_policy_array(0 to 34) := (
        -- index 0: MODE, read-write, no shadow
        0  => (ACCESS_RW, false, false, 0),
        -- index 1: ENABLE, read-write, no shadow
        1  => (ACCESS_RW, false, false, 0),
        -- indices 2..6: control law coefficients a0,a1,b0,b1,b2
        --   shadow+active, commit group 1
        2  => (ACCESS_RW, true,  false, 1),
        3  => (ACCESS_RW, true,  false, 1),
        4  => (ACCESS_RW, true,  false, 1),
        5  => (ACCESS_RW, true,  false, 1),
        6  => (ACCESS_RW, true,  false, 1),
        -- index 7: CTRL_COEFFS_VALID — commit trigger for group 1, active-only
        7  => (ACCESS_RW, false, true,  1),
        -- indices 8..12: polynomial coefficients, shadow+active, commit group 2
        8  => (ACCESS_RW, true,  false, 2),
        9  => (ACCESS_RW, true,  false, 2),
        10 => (ACCESS_RW, true,  false, 2),
        11 => (ACCESS_RW, true,  false, 2),
        12 => (ACCESS_RW, true,  false, 2),
        -- index 13: POLY_COEFFS_VALID — commit trigger for group 2
        13 => (ACCESS_RW, false, true,  2),
        -- indices 14..30: other parameters (mix of RW, some shadow groups)
        -- ...
        -- indices 31..34: telemetry, read-only, no shadow
        31 => (ACCESS_RO, false, false, 0),
        32 => (ACCESS_RO, false, false, 0),
        33 => (ACCESS_RO, false, false, 0),
        34 => (ACCESS_RO, false, false, 0),
        others => (ACCESS_RW, false, false, 0)
    );

    constant C_GLOBAL_POLICY : t_reg_policy_array(0 to 7) := (
        0 => (ACCESS_RO, false, false, 0),   -- IP_VERSION
        1 => (ACCESS_RO, false, false, 0),   -- IP_ID
        2 => (ACCESS_RO, false, false, 0),   -- N_MOTORS
        3 => (ACCESS_RW, false, false, 0),   -- SYS_CTRL
        4 => (ACCESS_RO, false, false, 0),   -- SYS_STATUS
        5 => (ACCESS_RW, false, false, 0),   -- IRQ_ENABLE
        6 => (ACCESS_RW, false, false, 0),   -- IRQ_STATUS (RW1C — see note)
        7 => (ACCESS_RW, false, false, 0),   -- MASTER_CLOCK_DIV
        others => (ACCESS_RW, false, false, 0)
    );
```

The map is written once in the package. Every motor instance references `C_MOTOR_POLICY`; the global instance references `C_GLOBAL_POLICY`. Since all motors share identical policy, they share the same constant — no duplication.

## The generic entity

The entity takes the policy array as a generic, plus the bit width and depth:

```vhdl
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regfile_config_pkg.all;

entity generic_regfile IS
    generic (
        G_BIT    : positive := 32;
        G_DEPTH  : positive := 35;
        G_POLICY : t_reg_policy_array        -- the per-register map
    );
    port (
        i_clk        : in  std_logic;
        i_rst_n      : in  std_logic;
        i_rd_addr    : in  std_logic_vector(clog2(G_DEPTH) - 1 downto 0);
        i_wrt_addr   : in  std_logic_vector(clog2(G_DEPTH) - 1 downto 0);
        i_wrt_enb    : in  std_logic;
        i_wrt_data   : in  std_logic_vector(G_BIT - 1 downto 0);
        o_rd_data    : out std_logic_vector(G_BIT - 1 downto 0);
        o_data_valid : out std_logic
    );
end entity;
```

Note `G_POLICY` has no default — each instantiation must supply its map. This is good: it forces the integrator to be explicit about the register policy.

## The architecture

The architecture maintains two memory arrays — shadow and active — and implements the three behaviours (access type, shadow/active routing, commit). Here's the structure:

```vhdl
architecture rtl of generic_regfile is

    type t_mem is array (0 to G_DEPTH - 1)
        of std_logic_vector(G_BIT - 1 downto 0);

    signal active_mem : t_mem := (others => (others => '0'));
    signal shadow_mem : t_mem := (others => (others => '0'));
    signal reg_rd_data  : std_logic_vector(G_BIT - 1 downto 0) := (others => '0');
    signal reg_rd_valid : std_logic := '0';

begin

    --------------------------------------------------------------------------
    -- WRITE + COMMIT process
    --------------------------------------------------------------------------
    p_write : process(i_clk) is
        variable wr_idx : integer range 0 to G_DEPTH - 1;
    begin
        if rising_edge(i_clk) then
            if i_rst_n = '0' then
                active_mem <= (others => (others => '0'));
                shadow_mem <= (others => (others => '0'));
            else
                ----------------------------------------------------------------
                -- 1. Handle an incoming write
                ----------------------------------------------------------------
                if i_wrt_enb = '1' then
                    wr_idx := to_integer(unsigned(i_wrt_addr));
                    if wr_idx < G_DEPTH then
                        -- Only writable registers accept writes
                        if G_POLICY(wr_idx).access_type = ACCESS_RW
                        or G_POLICY(wr_idx).access_type = ACCESS_WO then
                            if G_POLICY(wr_idx).has_shadow then
                                -- shadow/active pair: write goes to SHADOW
                                shadow_mem(wr_idx) <= i_wrt_data;
                            else
                                -- active-only: write goes to ACTIVE
                                active_mem(wr_idx) <= i_wrt_data;
                            end if;
                        end if;
                        -- (writes to RO registers are silently ignored)
                    end if;
                end if;

                ----------------------------------------------------------------
                -- 2. Handle commit triggers
                --    For every commit-trigger register that is currently 1,
                --    copy all shadow registers in its group to active, then
                --    clear the trigger.
                ----------------------------------------------------------------
                for t in 0 to G_DEPTH - 1 loop
                    if G_POLICY(t).is_commit then
                        -- a commit register holds its flag in active_mem(t) bit 0
                        if active_mem(t)(0) = '1' then
                            -- copy every shadow reg in this commit group to active
                            for r in 0 to G_DEPTH - 1 loop
                                if G_POLICY(r).has_shadow
                                and G_POLICY(r).commit_group = G_POLICY(t).commit_group then
                                    active_mem(r) <= shadow_mem(r);
                                end if;
                            end loop;
                            -- clear the trigger so it doesn't re-fire
                            active_mem(t) <= (others => '0');
                        end if;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- READ process (1-cycle latency, always reads ACTIVE)
    --------------------------------------------------------------------------
    p_read : process(i_clk) is
        variable rd_idx : integer range 0 to G_DEPTH - 1;
    begin
        if rising_edge(i_clk) then
            if i_rst_n = '0' then
                reg_rd_data  <= (others => '0');
                reg_rd_valid <= '0';
            else
                rd_idx := to_integer(unsigned(i_rd_addr));
                if rd_idx < G_DEPTH then
                    -- reads always come from ACTIVE (per your policy)
                    -- only readable registers return data
                    if G_POLICY(rd_idx).access_type = ACCESS_RO
                    or G_POLICY(rd_idx).access_type = ACCESS_RW then
                        reg_rd_data  <= active_mem(rd_idx);
                        reg_rd_valid <= '1';
                    else
                        -- WO register: reading returns nothing meaningful
                        reg_rd_data  <= (others => '0');
                        reg_rd_valid <= '0';
                    end if;
                else
                    reg_rd_data  <= (others => '0');
                    reg_rd_valid <= '0';
                end if;
            end if;
        end if;
    end process;

    o_rd_data    <= reg_rd_data;
    o_data_valid <= reg_rd_valid;

end architecture;
```

## How this satisfies each requirement

**Configurable depth and width** — `G_DEPTH` and `G_BIT` generics, used everywhere. The 35 registers is just `G_DEPTH => 35` at instantiation.

**Per-register access type (RO/WO/RW)** — the write process checks `access_type` before accepting a write (RO writes ignored), and the read process checks it before returning data (WO reads return nothing). The policy array carries this per register.

**Shadow/active routing** — the write process checks `has_shadow`: if true, writes land in `shadow_mem`; if false, in `active_mem`. The read process *always* reads `active_mem`, satisfying "write to shadow, read from active" for paired registers and "do both to active" for active-only (because active-only writes go directly to active, and reads come from active).

**Commit as a set** — the commit logic scans for any commit-trigger register that's high, and when found, copies *all* shadow registers in that commit group to active atomically (in one clock cycle), then clears the trigger. Your `CTRL_COEFFS_VALID` is marked `is_commit => true, commit_group => 1`, and all five coefficient registers are `commit_group => 1`, so setting CTRL_COEFFS_VALID high commits exactly those five together. The IP clears the valid register itself (the `active_mem(t) <= (others => '0')`), satisfying "host sets high, IP sets back to low."

**One entity for motor and global** — both instantiate `generic_regfile` with different `G_POLICY` and `G_DEPTH`. The global regfile passes `C_GLOBAL_POLICY` (8 registers, mostly RO), the motors pass `C_MOTOR_POLICY` (35 registers with shadow groups). Same RTL, different configuration.

**Shared map across motors** — all motor instances reference the same `C_MOTOR_POLICY` constant from the package. No duplication; change the map in one place.

## Important design considerations and caveats

**Synthesis of the nested commit loop.** The doubly-nested `for` loop in the commit logic (`for t` over triggers, `for r` over registers) unrolls at synthesis into combinatorial logic that, for every commit register, conditionally copies every shadow register. With 35 registers and a couple of commit groups this is modest, but it does create a fair amount of logic. If it becomes a timing or area problem, you'd precompute (at elaboration, in the package) a list of which registers belong to which group, shrinking the runtime loop. For 35 registers it's likely fine as-is; profile after synthesis.

**The commit-and-write same-cycle hazard.** If the host writes a shadow register in the *same* cycle that a commit fires for that register's group, the order matters: does the just-written shadow value get committed, or the previous one? In the code above, both the write and the commit happen in the same clocked process, and VHDL signal-assignment semantics mean the commit copies the shadow value *as it was at the start of the cycle* (before the write takes effect). So a same-cycle write would not be committed until the next commit. This is usually the desired behaviour (commit is atomic on the values present when the trigger was set), but document it. In practice the host writes all shadows, then in a later transaction sets the valid bit, so the hazard doesn't arise.

**The commit register's storage.** I assumed the commit-trigger flag lives in bit 0 of its active register (`active_mem(t)(0)`). Since the host writes the valid register like any other (it's active-only, so writes go to active), setting it to 1 puts 1 in `active_mem(t)`, the commit logic sees bit 0 high, fires, and clears it. That works, but make sure your address map documents that the valid register is a single-bit flag in bit 0.

**Read-during-commit.** Because reads always come from active and have one-cycle latency, a read issued in the same cycle as a commit will return the *pre-commit* active value (the read samples active at the clock edge, the commit updates active at the same edge — read-before-write semantics). One cycle later, reads return the committed values. This is consistent and usually fine; just be aware the freshly committed values appear on reads one cycle after the commit.

**RW1C registers (like IRQ_STATUS).** Your global `IRQ_STATUS` is write-1-to-clear, which is a fourth access semantic beyond RO/WO/RW. The policy record above doesn't capture it. If you need RW1C, add an `access_type` value `ACCESS_RW1C` and handle it specially in the write process (writing 1 to a bit clears it rather than sets it). I left it as plain RW above; extend the enum if RW1C is required.

## Instantiation example

```vhdl
-- A motor regfile
u_motor_rf : entity work.generic_regfile(rtl)
    generic map (
        G_BIT    => 32,
        G_DEPTH  => 35,
        G_POLICY => C_MOTOR_POLICY
    )
    port map ( ... );

-- The global regfile, same entity, different policy and depth
u_global_rf : entity work.generic_regfile(rtl)
    generic map (
        G_BIT    => 32,
        G_DEPTH  => 8,
        G_POLICY => C_GLOBAL_POLICY
    )
    port map ( ... );
```

## On the overall approach

Passing the per-register policy as a record-array generic is the right pattern for this. The alternative — hardcoding the shadow/active and access logic per regfile type — would mean two different entities that drift apart and can't share verification. The generic-map approach keeps one entity, one architecture, one testbench, and pushes all the per-regfile variation into a data table that lives in a package. That table doubles as documentation: reading `C_MOTOR_POLICY` tells you exactly which registers are RO/WO/RW, which have shadows, and which commit groups exist. It's also what you'd generate from your register-map document if you later automate that.

The one thing I'd watch as it grows is the synthesis cost of the commit loop. For 35 registers and a handful of commit groups it's fine. If you scale to many groups or much larger regfiles, precompute the group membership at elaboration to shrink the runtime logic. But get it working with the straightforward version first — premature optimisation here would just obscure the design.
