This is a solid design and the sequencer concept is right — one FSM walking through the telemetry registers, issuing one address/data per state, with a busy handshake back to the controller. But there are several concrete issues, one of which is a real bug. Let me go through them by severity.

## Bug — the motor FSM's last state writes data but immediately returns to IDLE, dropping the write

In `p_mot_update`, look at the final telemetry state, `ADC_RD` (Image 2, lines 188–198):

```vhdl
when ADC_RD =>
    if (i_mot_update = '1') then
        r_mot_update_state <= IDLE;
        o_wrt_hw_mot_addr  <= REG_ADC_CURRENT_RD;
        o_wrt_hw_mot_data  <= func_logic2vec(r_core_data.adc_curr_rd);
        o_mot_busy         <= '0';     -- ← busy dropped in the SAME cycle the addr/data are issued
```

Compare it to every earlier state (e.g. `POS_STEP`, Image 3), where `o_mot_busy <= '1'` while the address and data are presented. The write actually commits because `o_wrt_enb` (= `i_mot_update or i_glo_update`) is high and the regfile latches `addr`/`data` on the next clock edge. But in `ADC_RD` you assert the address/data **and** drop `o_mot_busy` to `'0'` in the same cycle. If the controller is watching `o_mot_busy` to know when the sequence is done, it may react to `busy=0` and deassert `i_mot_update` before the regfile has latched this last write — so the final telemetry register (ADC current) can be dropped. The fix: hold `o_mot_busy <= '1'` in `ADC_RD` while presenting the address/data, and only drop busy in a dedicated terminal state (or on the *next* cycle after the last write is guaranteed latched). Every state that issues a write must keep busy asserted through that write; the busy-low transition belongs in a clean-up state that issues no write.

## Design issue — `o_wrt_enb` is combinatorial on the update request, so writes fire before the address is valid

`o_wrt_enb <= i_mot_update or i_glo_update;` (Image 4, line 80) is concurrent. The instant `i_mot_update` goes high, `o_wrt_enb` is high — but the FSM is still in `IDLE` and hasn't issued the first real address/data yet (those appear when it transitions into `CTRL_COEFF_RD`). So for one cycle the write enable is high while `o_wrt_hw_mot_addr`/`data` still hold their reset (or stale) values, and the regfile will latch a spurious write to address 0. You want the write enable to track *the states that actually issue a write*, not the raw request. Drive `o_wrt_enb` from the FSM: assert it in each writing state, deassert in IDLE and the terminal cleanup state. That guarantees the enable is high only when valid address/data are on the bus.

## Correctness concern — the `i_mot_update` gating inside each state is backwards from the handshake you described

You said the controller "enters UPDATE and waits there until `o_mot_busy` is on." But look at the state logic: each state advances *only if* `i_mot_update = '1'`, and the `else` branch resets to IDLE and clears everything (e.g. Image 9 lines 110–114). That means the controller must **hold `i_mot_update` high for the entire multi-state sequence** — if it drops it mid-sequence, the FSM aborts back to IDLE and the remaining telemetry registers never get written. That may be what you intend, but it's fragile: a one-cycle glitch on `i_mot_update` discards the whole telemetry update. The cleaner handshake is a **pulse-to-start, busy-until-done** protocol: the controller pulses `i_mot_update` for one cycle to *start* the sequence; the FSM latches that, asserts `o_mot_busy`, runs all states to completion regardless of `i_mot_update`, then drops busy. The controller waits on `busy` going low. With your current design, the controller has to babysit `i_mot_update` high across the whole sequence and watch for busy, which couples the two more tightly than necessary. Decide which protocol you want and make all states consistent — right now the start condition and the "keep going" condition are the same signal, which is the source of the fragility.

## The global-write output mux (Image 8, lines 377–379) — check the busy-OR

```vhdl
o_glo_busy     <= r_glo_clk_busy or r_glo_rst_busy;
o_wrt_hw_glo_addr <= r_wrt_hw_glo_rst_addr when i_glo_writer = C_RST_UPDATE else r_wrt_hw_glo_clk_addr;
o_wrt_hw_glo_data <= r_wrt_hw_glo_rst_data when i_glo_writer = C_RST_UPDATE else r_wrt_hw_glo_clk_data;
```

This is correct *given* that reset-diagnostics and clock-diagnostics updates are mutually exclusive (you stated "either reset or clock parameters are updated, both at once cannot"). The `i_glo_writer` selector cleanly routes the right FSM's outputs. Good. But confirm the two global FSMs (`p_glo_rst_update` and `p_glo_clk_update`) can never both be non-IDLE at once — if `i_glo_writer` can change while one FSM is mid-sequence, the output mux would switch mid-write and corrupt the global regfile. Since both FSMs gate on `i_glo_writer = C_xxx_UPDATE` in every state, a mid-sequence change of `i_glo_writer` would abort one and start the other, with a glitch on the shared output. Guard against `i_glo_writer` changing while `o_glo_busy` is high (the top module should hold the selector stable for the whole global sequence, mirroring the motor handshake).

## Good things worth keeping

The **Gray + safe FSM encoding** (Image 4, lines 66–72, `syn_encoding "safe,gray"`) is exactly right for an ECSS-oriented design — the `safe` attribute gives you recovery from an illegal state (single-event-upset resilience), and you've applied it to all three state registers. That's a real robustness point you can cite.

The **separate hardware write ports per regfile** (motor vs global, each with its own addr/data) and the **per-motor sequential update with the controller specifying which motor** is the correct architecture — it keeps the single-writer-per-register invariant intact (these telemetry registers are hardware-written, AXI-read-only) and avoids any arbiter. The sequencer trading a few cycles for low wire count is the right call for telemetry, which isn't latency-critical, exactly as we discussed.

The **`func_logic2vec` zero-extension helper** (Image 4, lines 75–77) for packing single-bit and narrow fields into the 32-bit register word is clean and consistent across all the writes.

## Smaller things

The reset style is consistent across all three processes (async assert, reset in the sensitivity list `process(i_clk, i_rst_n)`, reset checked first) — that matches the async-reset template and is internally consistent, good. Just make sure the *whole* IP uses this same style (you'd flagged wanting consistency for the ECSS clock/reset-domain documentation).

`r_clk_update_state` is declared as type `t_glo_rst_update_state` (Image 4, line 52) but the clock FSM uses clock-specific states (`STCK_A`, `PH_FLT`, `CLK_FLT_LT`). If the clock states live in `t_glo_clk_update_state`, then `r_clk_update_state` has the wrong type and either won't compile or you've got the two enums conflated. Check that line — it looks like a copy-paste from the reset FSM's signal declaration. It should be `t_glo_clk_update_state`.

## Summary

The scheduling concept is correct and the architecture (per-regfile hardware write ports, sequential telemetry writes, controller-specified motor index, safe-Gray FSMs) is sound. Fix these in order: (1) the `ADC_RD` terminal state drops `o_mot_busy` while issuing a write — hold busy through every writing state and drop it only in a no-write cleanup state, or the last telemetry write can be lost; (2) drive `o_wrt_enb` from the writing states, not combinatorially from `i_mot_update or i_glo_update`, or you latch a spurious write to address 0 before the first real address is presented; (3) decide between "hold update high for the whole sequence" (current) and "pulse to start, busy until done" (cleaner) and make all states consistent — the current design aborts the whole sequence on any drop of `i_mot_update`; (4) ensure `i_glo_writer` (and the motor index) are held stable by the upstream logic for the entire duration that the corresponding busy is high, or the output mux switches mid-write; (5) check the `r_clk_update_state` type declaration — it looks like it should be `t_glo_clk_update_state`, not `t_glo_rst_update_state`. Items 1 and 2 are the ones that will actually corrupt writes; fix those first, then tighten the handshake protocol in 3 and 4.