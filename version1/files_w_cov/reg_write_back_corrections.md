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

# fsm 
Your instinct is exactly right, and it's worth understanding *why* it's right, because the smell you detected has a name. What you've built is one state machine trying to serve two masters: the **computation sequencing** (IDLE → START → ... → PREP_DATA → ISSUE_WRT → loop) and the **write-back scheduling** (sequential writes after each motor, plus flag-refresh writes from IDLE). The complexity explosion you're feeling — the `r_seq_update`/`r_idl_update` flag pair, the *two* stepper counters (`stepper_counter` and `stepper_counter_IDLE_update`), the `with select` mux choosing which counter feeds `var_cnt`, the nested conditions in ISSUE_WRT deciding whether to go to START or IDLE based on which update type ran — all of that is the coupling cost. Every new write-back reason multiplies against every computation state. The evidence is visible in your own screenshots: the TODOs in the START state ("how this one should update???"), the select-mux gymnastics in PREP_DATA, and the four-way branch in ISSUE_WRT are all symptoms of one FSM carrying two concerns.

**Splitting into two state machines is the correct fix.** This is the standard decomposition: a *producer* FSM (computation) and a *service* FSM (write-back), connected by a small request interface. Here's the shape I'd give it.

## The decomposition

**Computation FSM** keeps its natural flow and knows nothing about write-back mechanics. When it finishes a motor's computation, it doesn't sequence the write itself — it *posts a request* and moves on (or waits, see below):

```
IDLE → START → (compute states) → PREP_DATA → [post WRITE request for motor N] → next motor / IDLE
```

**Write-back FSM** owns everything about getting data into the register file: talking to `hw_regfile_writer`, waiting on `i_mot_busy`, driving `o_mot_update`, holding `o_core_data` stable for the duration. It services requests one at a time:

```
WB_IDLE → (request pending?) → WB_ISSUE (assert o_mot_update, present o_core_data) → WB_WAIT (until not busy) → WB_IDLE
```

**The interface between them** is a request record — this is the key design object:

```vhdl
type t_wb_request is record
    pending    : std_logic;                          -- a write is requested
    motor      : natural range 0 to LAST_STEPPER;    -- which motor
    data       : t_core_data;                        -- snapshot of what to write
end record;
```

The computation FSM (and the IDLE-refresh logic) *fill* this; the write-back FSM *consumes* it and clears `pending`. Crucially, `data` is a **snapshot** captured at request time — that's what lets the computation FSM move on to the next motor without worrying that `o_core_data` will change under the in-flight write. Right now your PREP_DATA muxes live state through `var_cnt` into `o_core_data`, which is exactly why the two write sources fight: they share the live mux. A latched snapshot decouples them.

## How this dissolves your specific problems

**The two counters and the select-mux disappear.** `stepper_counter` stays with the computation FSM (it's genuinely computation state: which motor am I serving). `stepper_counter_IDLE_update` and the `with std_logic_vector'(r_seq_update & r_idl_update) select` mux exist only because both write paths funnel through one shared `var_cnt` into one shared `o_core_data`. With the request interface, each requester passes its own motor index *in the request*, and the mux evaporates. The IDLE-refresh logic keeps its own little counter privately; the computation path uses `stepper_counter`; neither needs to know about the other's counter.

**The `r_seq_update`/`r_idl_update` flag pair disappears.** Those flags encode "who asked for this write" so ISSUE_WRT can decide where to return afterwards. In the split design, the write-back FSM doesn't care who asked — it just services requests — and the computation FSM never leaves its own flow, so there's no "where do I return" question at all. The identity-of-requester bookkeeping was pure coupling overhead.

**The IDLE-refresh becomes trivial.** In IDLE (not the very first one — your `r_very_first_IDLE` guard is correct and stays), the flag-refresh logic just posts requests: one per motor whose flags need updating, at whatever pace the write-back FSM drains them. It doesn't need to know about computation states, and computation doesn't need to know refreshes happen.

## The arbitration question (there is one, but it's small)

Two producers (computation, IDLE-refresh) posting into a shared request path need arbitration — but notice this is the *same* problem you just solved for the global regfile's clock/reset writers, and the same solution applies: fixed priority, defer-not-drop. Computation writes get priority (they're the fresh telemetry from the motor just served); IDLE-refresh requests wait if a computation write is in flight. And your own timing analysis tells you why this is safe: you have ~1200 idle cycles between service rounds, and the write-back FSM needs a handful of cycles per motor (one write per telemetry register through `hw_regfile_writer`). The IDLE refreshes will always drain long before the next START. You can even make the structural guarantee airtight: **the computation FSM only posts requests during the compute phase, the IDLE-refresh only posts during IDLE, and the two phases are mutually exclusive by construction** — so a one-deep request slot with a busy flag is genuinely sufficient. No queue needed. If you want belt-and-braces, assert (simulation assertion) that a request is never posted while `pending = '1'`; that converts the "can't happen" timing argument into a checked invariant.

One subtlety to decide consciously: does the computation FSM *wait* for the write-back to complete before starting the next motor, or fire-and-forget? Given your cycle budget (136 cycles of computation per motor, ~1220 available), **fire-and-forget with the snapshot is safe and simpler**: post the request, immediately continue to the next motor; the write-back FSM drains it in parallel while the next motor computes. The snapshot guarantees correctness; the timing budget guarantees the one-deep slot is free again before the next post. Your current ISSUE_WRT state — which stalls computation waiting on `i_mot_busy` — becomes unnecessary; that whole state can go away, and with it the nested go-to-START-or-IDLE logic inside it.

## What stays in the computation FSM

After the split, the computation FSM's states are purely about sequencing the datapath: IDLE (wait for start pulse, post refresh requests), START (kick the pipeline for motor `stepper_counter`), the compute states, PREP_DATA (snapshot results into a request, advance `stepper_counter`, loop to START or return to IDLE). Each state has one job. The `main_sm` case statement loses the ISSUE_WRT state, both update flags, the second counter, and the select-mux — it should shrink noticeably, which is the practical confirmation that the decomposition is right.

## Connection to what you already have

Note that `hw_regfile_writer` *already is* a service FSM — it sequences the individual register writes for one motor update. What you're adding is one thin layer above it: a write-back scheduler that decides *when* and *for which motor* to trigger `hw_regfile_writer`, fed by requests. So the hierarchy becomes: computation FSM → (request) → write-back scheduler FSM → (o_mot_update + o_core_data) → hw_regfile_writer → register file. Each layer has a single responsibility and a clean handshake to the next. That's also a much easier story to verify — you can unit-test the scheduler with directed requests (including the collision case: refresh request posted, then computation request arrives) without any datapath at all — and a much easier one to document for the thesis than the entangled single-FSM version.

So: yes, second state machine, with a snapshot-carrying request record as the interface, fixed priority computation-over-refresh, and fire-and-forget posting given your cycle budget. Your on-paper timing reasoning (1200 cycles of IDLE headroom) is exactly the argument that makes the simple one-slot version sufficient — turn it into a simulation assertion and you've converted intuition into a verified property.