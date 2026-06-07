The key principle that should drive this: because you process motors one at a time, the datapath only ever needs the **active motor's** registers. So the right place to collapse "3 motors' worth of registers" down to "one motor's worth" is at the register-file boundary, via a mux on the active-motor index — *not* by fanning all three motors into the datapath. Your array-and-for-loop approach is on the right track; the improvement is where you do the selection and how you name the signals.

## The structure

Give the register file a **parallel register view** in addition to the addressed AXI read port. Each motor regfile exposes its active registers as a bundle; the top level muxes those bundles by the active-motor index and presents a single "current motor's registers" output to the shared datapath.

```
   AXI ─addr─► register_file_top ─addr port (existing, for host)
                     │
                     ├ motor_rf[0] ─► active regs ┐
                     ├ motor_rf[1] ─► active regs ┼─ mux by i_active_motor ─► o_active_cfg
                     ├ motor_rf[2] ─► active regs ┘
                     └ global_rf   ─► active regs ───────────────────────► o_global_cfg
                     ▲
              i_active_motor  (from the datapath's sequencer)
```

The datapath's FSM — the one that already cycles motor 0 → 1 → 2 — drives `i_active_motor`. When it's serving motor 1, it sets `i_active_motor = 1`, and the register file presents motor 1's registers on `o_active_cfg`. The datapath stays a **single shared instance**; it never sees all motors at once, only the one it's working on. That's what keeps the time-multiplexing efficient — you share one datapath across motors rather than replicating it.

## Exposing the parallel view

Add an output to `generic_register_file` that exposes the active memory directly (combinatorial from the registered `active_mem`, so it's stable and has no extra latency):

```vhdl
-- in generic_register_file
o_active_regs : out t_reg_array(0 to G_DEPTH - 1);
...
o_active_regs <= active_mem;   -- parallel view of committed values
```

This sits alongside the existing addressed read port. The AXI side keeps using the addressed read (one register at a time); the datapath uses the parallel view (everything at once). Both read from the same `active_mem`, so they always agree, and the datapath naturally sees *committed* (post-shadow-commit) values, which is what you want.

At `regfile_top`, collect the per-motor views and mux:

```vhdl
type t_active_array is array (0 to G_N_MOTORS - 1) of t_reg_array(0 to G_DEPTH-1);
signal s_motor_active : t_active_array;

gen_rf : for m in 0 to G_N_MOTORS - 1 generate
    u_rf : entity work.generic_register_file
        generic map ( G_BIT => 32, G_DEPTH => G_MOTOR_DEPTH, G_POLICY => C_MOTOR_POLICY )
        port map ( ..., o_active_regs => s_motor_active(m) );
end generate;

-- collapse to the active motor
o_active_cfg <= s_motor_active(i_active_motor);
```

That single mux line is the whole "route the right motor to the datapath" job.

## Name the registers, don't index them

The one thing I'd change from raw index arrays: give the datapath **named** access so a wiring mistake is a compile error, not a silent wrong-register bug. Two options:

The lighter retrofit is named index constants — `o_active_cfg(C_REG_COEFF_A0)` instead of `o_active_cfg(2)`. Define the constants once next to your policy map. This documents the address map and means renumbering a register changes one constant, not every consumer.

The cleaner (but more work) option is to map the array into a **record** with named fields at the top level:

```vhdl
type t_motor_cfg is record
    target_step : std_logic_vector(31 downto 0);
    coeff_a0    : std_logic_vector(31 downto 0);
    coeff_a1    : std_logic_vector(31 downto 0);
    -- ...
end record;

-- map indices to fields (written once, doubles as documentation)
o_active_cfg.target_step <= s_motor_active(i_active_motor)(C_REG_TARGET_STEP);
o_active_cfg.coeff_a0    <= s_motor_active(i_active_motor)(C_REG_COEFF_A0);
```

Then the control-law module connects `o_active_cfg.coeff_a0` to its `a0` input — and the type system makes it impossible to accidentally wire the velocity register into a coefficient port. For ECSS-clean, maintainable IP that's a real benefit. Given your time budget, named constants are the pragmatic choice; records are the ideal if you have room.

## Two things to watch

**The mux is combinatorial.** `s_motor_active(i_active_motor)` is a 3:1 mux on the whole register bundle. If `i_active_motor` changes and the datapath consumes the result in the same cycle, that mux plus the first datapath operation could be a longish path. Since your datapath is a sequential FSM, the clean fix is to set `i_active_motor` one state *before* you consume the registers, so the selection settles. Or register `o_active_cfg` by one cycle. At 40 MHz with a 3:1 mux it's probably fine, but it's the path to check after synthesis.

**Global registers are separate and always-on.** Don't run them through the active-motor mux — they're shared. Expose the global regfile's `o_active_regs` as its own bundle straight to whatever consumes global config (system enable, master clock divider, etc.).

## The alternative, if wiring gets heavy

The parallel-view approach routes the full active register set of the selected motor (35 × 32 ≈ 1100 bits) into the datapath. At 3–4 motors that's fine. If you ever scaled to many motors or wanted to minimize routing, the alternative is to give the datapath its own **addressed read port** (a second read port on the register file) and have its FSM *fetch* the handful of registers it needs into local latches at the start of each motor's time slot — issue address, wait the one-cycle latency, latch, repeat. That trades a few fetch cycles for far less wiring. For your motor count the parallel mux is simpler and the cycles aren't worth saving, so I'd stay with it; keep the fetch-port idea in reserve for if routing congestion shows up.

## On the write-back direction

You asked about feeding register values *to* the modules, which is the read direction above. The mirror image — the datapath writing telemetry/status back (position, velocity, current) — needs its own write path into the active motor's regfile, indexed the same way by `i_active_motor`, and must target registers that AXI treats as read-only so the two writers never collide. That's a separate port and worth designing deliberately, but it follows the same active-motor-indexed pattern: the datapath writes the *current* motor's status registers, and AXI reads them addressed. Keep the config-read and status-write paths distinct so there's never contention on a given register.