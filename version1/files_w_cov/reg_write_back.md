Your concern is exactly correct, and you've diagnosed it precisely: `s_active_mot_regfiles` and `s_active_glo_regfile` are **outputs** of the register file (driven by `active_mem` inside `generic_register_file`), and in Image 1 lines 491–495 and Image 2 lines 519–546 you're *also* assigning to them from the wrapper. That's two drivers on the same signal — the register file drives them as outputs, the wrapper drives them with telemetry/diagnostic values. In simulation that resolves to `X`; in synthesis it won't build (or builds wrong). You can't write back by assigning to the *output* of the read view. So the read-path exposure was right, but write-back needs its own path *into* the register file. Let me lay out the clean architecture.

## The core principle: reads and writes need separate ports, and each register needs exactly one writer

The register file already has one write path — the AXI side (`i_wrt_addr`, `i_wrt_data`, `i_wrt_enb`). You now need a **second write path** for the core's telemetry/diagnostics, and you need to guarantee the two writers never target the same register. The elegant way to guarantee that is **by policy, not by arbitration**: partition the address map so that every register has a single owner.

Three classes of register, by who writes:

- **Host-writable config** (coefficients, targets, cal data, poly): written by **AXI only**. The core *reads* these via the active-view. AXI never collides with the core here because the core never writes them.
- **Core-writable telemetry/status** (current step/frac/speed, clock/reset fault flags, glob_err): written by the **core only**. AXI *reads* these. The core never collides with AXI because AXI never writes them — they're marked `ACCESS_RO` from AXI's perspective.
- **Shared-but-disjoint-bits** (rare): avoid this; it's the only case that needs care, and you can usually design it away.

If you enforce that partition, **there is no write clash to arbitrate** — the architecture makes collisions impossible rather than resolving them at runtime. That's the elegant solution: don't build a write arbiter, build an ownership rule.

## What that means concretely for the register file

Add a **second write port** to `generic_register_file` dedicated to hardware (core) writes, separate from the AXI write port:

```vhdl
-- generic_register_file: existing AXI write port stays as-is.
-- NEW: hardware write port for core-owned (telemetry/status) registers.
i_hw_wrt_addr : in  std_logic_vector(clog2(G_DEPTH)-1 downto 0);
i_hw_wrt_data : in  std_logic_vector(G_BIT-1 downto 0);
i_hw_wrt_enb  : in  std_logic;
```

Inside the write process, the two writers target disjoint registers *by policy*, so you can let both run without a mux — but to be safe and explicit, route by the policy's access type: the AXI write path only writes registers whose policy is host-writable (RW/WO), and the hardware write path only writes registers marked as core-owned (a new policy attribute, e.g. `is_hw_writable` or simply reuse `ACCESS_RO`-from-AXI to mean "hardware owns this"). Since the sets are disjoint, `active_mem(idx)` has exactly one writer for any given `idx`, and synthesis is happy.

The cleanest encoding: extend your `t_reg_policy` with a `hw_writable : boolean` field. AXI writes are gated on `access_type = RW or WO`; hardware writes are gated on `hw_writable = true`. A register is never both host-writable and hw-writable. That single rule eliminates the clash.

## What that means for the wrapper

Right now (Image 1, lines 491–495) you're doing `s_active_mot_regfiles(m)(REG_OUT_STEP) <= ... & s_state(m).position.step;` — assigning to the *read-view output*. Replace that with driving the **hardware write port** instead:

```vhdl
-- WRONG (current): assigning to the read-view output -> multiple driver
-- s_active_mot_regfiles(m)(REG_OUT_STEP) <= ... & s_state(m).position.step;

-- RIGHT: drive the hardware write port of motor m's regfile
-- (the register file writes it into active_mem internally)
s_hw_wrt_addr(m) <= REG_OUT_STEP;
s_hw_wrt_data(m) <= (C_DATA_BITS_LEN-1 downto position_type'high+1 => '0')
                    & s_state(m).position.step;
s_hw_wrt_enb(m)  <= '1';
```

Then the **read-view** (`s_active_mot_regfiles`) is used *only* for reading — feeding `settings(m)` (Image 1 lines, the config reads) and for AXI to read telemetry back. It's never assigned in the wrapper. One direction only.

But there's a subtlety: the core writes *several* telemetry registers per motor (step, frac, speed, plus the diagnostic flags), and a single hardware write port writes one register per cycle. You have two clean options:

**Option A — a small write sequencer per regfile.** The core's telemetry isn't latency-critical (the host polls it occasionally), so a tiny state machine can cycle through the handful of telemetry registers, writing one per cycle via the single hardware write port. Cheap, minimal ports, slightly stale telemetry (a few cycles), which is fine for status registers.

**Option B — direct hardware-written storage for telemetry, bypassing the addressed write.** Since telemetry registers are *only* written by hardware and *only* read by AXI, they don't need the full addressed-write machinery. You can give `generic_register_file` a parallel hardware-write input that writes specific registers directly each cycle (a wide bus, like the read-view but inbound). This is the mirror image of the parallel read-view: a parallel write-view for core-owned registers. It costs wiring but no sequencing and gives always-fresh telemetry.

For your motor count and the fact that telemetry is status (not real-time-critical), **Option A (the sequencer) is the simpler, lower-wire choice**, and slightly-stale status registers are perfectly acceptable. Use Option B only if you want zero-latency telemetry and don't mind the wide inbound bus.

## The diagnostic/global writes (Images 2–3)

Same principle applies to the clock/reset fault registers and `glob_err`. Right now `p_clk_diagnostic_update` and `p_rst_diagnostic_update` assign directly to `s_active_glo_regfile(REG_CLK_A_STCK)` etc. — again, assigning to the read-view output. These are core-owned registers, so they go through the **global regfile's hardware write port**, marked `hw_writable` in `C_GLOBAL_POLICY` and `ACCESS_RO` from AXI. The diagnostic processes drive the hardware write port (sequenced or parallel) rather than the read-view.

`REG_GLOB_ERR` (Image 2 line, `s_active_glo_regfile(REG_GLOB_ERR) <= s_ip_core_err`) is the clearest case: it's written by the core (the error state), read by the host. Mark it hw-writable, drive it through the hardware write port. `REG_ENABLE` is the opposite — written by the host via AXI, read by the core (`s_ip_core_en <= s_active_glo_regfile(REG_ENABLE)`), so it stays AXI-writable and the core only reads it. That read is fine as-is.

## The one genuinely-shared register to think about

`REG_CLK_FAULT_LT` / `REG_RST_FAULT_LT` (the latched-fault registers, Images 2–3) are interesting: the **core sets** them (latches a fault) and the **host clears** them (writes the clear bit, your `REG_CLK_CLC_FLT`). That looks like two writers. But notice you've already split it correctly: the *clear command* is a separate register (`REG_CLK_CLC_FLT`) that the **host** writes, and the **core** reads that clear bit and clears the latch itself (Image 2 lines 525–527). So the latched-fault register has exactly one writer — the core — and the host influences it indirectly through a separate host-owned clear register. That's the right pattern (it's the same "host requests, core acts" structure as your shadow-commit valid bit). Keep it; it already avoids the clash.

## So the architecture, stated cleanly

Give the register file two write ports (AXI write, hardware write) and one-or-two read views (the addressed AXI read you already have, plus the parallel active-view for the core). Partition every register to a single writer by policy: host-writable config (AXI writes, core reads) and core-owned telemetry/status (core writes via the hardware port, AXI reads). Because the writer sets are disjoint, no runtime arbitration is needed — the clash is designed out. In the wrapper, the active-view (`s_active_mot_regfiles`, `s_active_glo_regfile`) becomes **read-only**: it feeds `settings(m)` and is never assigned. Telemetry and diagnostics drive the hardware write port instead (sequenced for low wire count, since status isn't latency-critical). Indirect host actions on core-owned registers (clear-fault, commit-coefficients) go through separate host-owned command registers that the core reads and acts on — preserving single-writer ownership.

That removes the multiple-driver problem (you stop assigning to outputs), it synthesizes (one writer per register), and it needs no arbiter (disjoint ownership). It's the same discipline you already applied successfully to the shadow-commit valid bit and the fault-clear register — you're just extending "one writer per register, host requests via command registers" to the whole telemetry/diagnostic path.

## A note for the verification side

Once you add the hardware write port, add a top-level test that exercises the collision-avoidance *as a property*: have AXI attempt to write a core-owned (RO-from-AXI) telemetry register and confirm the write is ignored (the value reflects only what the core wrote), and confirm an AXI read of that register returns the core's telemetry. That test documents and locks in the ownership partition — it proves there's no path for AXI to corrupt core-owned state, which is exactly the property the architecture relies on. It's also a clean ECSS talking point: the single-writer invariant is enforced by design and verified by test.