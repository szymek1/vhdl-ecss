Good — sccom working unlocks the whole plan. Let me lay out the architecture layer by layer, answer the TLM/AMS question directly (short version: no to both, with reasons), and give you the data-logging design that gets you the debug plots.

## The layered architecture

```
┌─ closed_loop_tb (VHDL, top) ─────────────────────────────────────────┐
│                                                                       │
│  ┌────────────┐   AXI4-Lite    ┌──────────────┐  settings/telemetry  │
│  │ Stimulus    │ ─────────────► │   MCE-NG     │                      │
│  │ process     │  (BFM: yours   │   IP CORE    │                      │
│  │ (vector-    │   or OSVVM VC) │  (the DUT)   │                      │
│  │  driven)    │                └──┬───────▲───┘                      │
│  └─────┬──────┘        duty_a/b (per motor)│ adc_a/b (per motor)      │
│        │                          ▼        │                          │
│  ┌─────▼──────┐            ┌──────────┐  ┌─┴─────────┐               │
│  │ OSVVM      │            │ pwm_gen  │  │ adc_model │ (VHDL or in   │
│  │ CoveragePkg│            │ (your    │  │ (quantize │  the SC plant)│
│  │ bins       │            │  VHDL)   │  │  + offset)│               │
│  └────────────┘            └────┬─────┘  └────▲──────┘               │
│                          pwm switching │      │ analog currents      │
│                                  ▼     │      │                      │
│                           ┌────────────┴──────┴───┐                  │
│                           │  motor_plant (SystemC) │ ×N motors        │
│                           │  ODEs @ clk rate       │                  │
│                           │  + CSV logger          │                  │
│                           └───────────────────────┘                  │
└───────────────────────────────────────────────────────────────────────┘
```

Signal-level VHDL/SystemC boundary, everything inside one `vsim` process. Now the decisions.

## TLM? No — and here's the precise reason

TLM (transaction-level modeling) exists to *abstract away* pin-level timing so untimed/loosely-timed software models can talk fast (function calls carrying transactions instead of toggling wires). Your situation is the opposite: the whole point of the closed loop is that the plant reacts to the **actual cycle-accurate PWM edges** the IP core produces, and feeds currents back with real sample timing. The physics *is* the timing. Wrapping the plant in TLM sockets would add the FIFO/quantum machinery of loosely-timed modeling only to immediately re-synchronize to the clock — pure overhead, zero benefit. TLM would make sense if you were, say, modeling the *host CPU* running the driver stack and wanted fast register traffic without an AXI BFM. You're not. Signal-level `sc_in`/`sc_out` bound directly to the VHDL ports is the right abstraction here.

## AMS? Also no — you're already doing its job cheaper

SystemC-AMS gives you TDF/ELN solvers for continuous-time networks. But your plant is a small, stiff-friendly ODE set you already integrate stably with explicit Euler at dt = 25 ns (τ = 2.5 ms ≫ dt, as established). A hand-rolled integrator inside an `SC_METHOD` sensitive to `clk.pos()` is simpler, faster, fully under your control, and — decisive point — **AMS is a separate library that may not ship with your Questa SystemC support**. Don't gamble the plan on an optional add-on when 20 lines of Euler already validated in Python do the job. Plain SystemC, clocked method, done.

## OSVVM AXI4-Lite VC — yes, this is the right moment

Earlier I called the OSVVM VC "a strong maybe — adopt if top-level AXI stress grows." The closed-loop TB is exactly where it pays: long-running stimulus with mode switches, commits mid-run, telemetry polling — and the VC gives you randomized ready/valid delays on every channel *for free* across hours of simulated traffic, which your hand BFM only does where you hand-coded it (`proc_axi_read_stress`). Structure:

- Instantiate the OSVVM `Axi4LiteManager` VC + its transaction record in the closed-loop TB only. Your unit TBs keep your BFM — no churn where things already work.
- Your stimulus process speaks `Write(TransRec, addr, data)` / `Read(TransRec, addr, data)`. Wrap those in thin helpers that take `(motor, reg)` via your `motor_addr()` function so vectors stay in register-map terms.
- Keep your `assertion_pkg` checks as the pass/fail layer on the *read-back values* — the VC handles protocol, your checks handle meaning, results flow into `collect_results.py` unchanged.

One honest caveat: budget half a day for the VC's compile order and API (it evolves between releases — check the docs of the version you pin). If it fights you, your BFM is a fully adequate fallback; the architecture doesn't change either way.

## PWM: use your VHDL implementation, definitely

Since the PWM generator is real project VHDL (not part of the core), putting it in the loop buys you two things: the plant sees genuine switching waveforms (real edge timing, keep-out behavior), and — bonus — the PWM module itself sits under `+cover=bcsefT` and contributes to merged code coverage. Chain: core's duty-cycle registers → `pwm_gen` → switching signal → plant converts to phase voltage. Give the plant a simple RC-style averaging or direct switched-voltage drive of the electrical ODE; at dt = 25 ns you resolve the switching directly, no averaging needed.

## The ADC path — small but load-bearing detail

Put the quantization + structural offset (the ~33-count bias from the thesis, §current-normalizer discussion) in *one* place. Two options: a tiny VHDL `adc_model` entity, or inside the SystemC plant just before the output write. I'd put it **in the plant** (fewer entities, and the offset is a plant-physics artifact anyway) — but make the offset/gain generics/parameters, because one of your closed-loop test vectors should verify the normalizer's `cOffA` correction actually nulls it (settle at zero setpoint → check `yk ≈ 0`). That's a functional bin, not just a nicety.

## Functional coverage design — the bins that matter for a closed loop

All measurement lives in VHDL (OSVVM CoveragePkg), sampled by a dedicated monitor process — the plant stays dumb. Declare the model around *system behaviors*, not module internals (units already cover those):

- **Mode space**: bins {position_mode, poly_mode} and, crucially, the *transition* cross {from × to} — mode switches mid-motion are where sequencing bugs live.
- **Commit-timing cross**: {coeff commit} × {core state: IDLE / mid-computation} — verifies the shadow/active atomicity under real traffic, the property the whole shadow design exists for.
- **Motor cross**: {motor 0..N−1} × {mode} — catches per-motor wiring asymmetries that single-motor tests miss.
- **Dynamic-regime bins** sampled from *telemetry read-backs*: speed in {zero, low, near-target}, position error in {large, small, settled} — this is what makes it *closed-loop* coverage rather than register coverage.
- **AXI stress bins** (free if you use the OSVVM VC's randomized delays): {read during computation}, {write burst then commit}.

Sample on events (mode change written, commit fired, telemetry poll) rather than every clock. End-of-sim: `WriteBin` the coverage report to `build/coverage/CL/closed_loop_fc.txt`, and teach `collect_results.py` one tiny parser so functional-coverage holes appear next to code coverage in `summary.md`. Now the claim "we measure functional coverage" is literally true, per the earlier discussion.

## Data logging for debug plots — do it in the plant, CSV, decimated

The plant already holds ground truth (θ_m, ω, i_a/i_b) and sees the commands. Log from C++ — it's the one place with everything, and file I/O in SystemC is plain `std::ofstream`:

```cpp
// in motor_plant: log every DECIM clocks (e.g. 32 → one row per 0.8 µs; or
// log per control sample by triggering on the core's sample strobe if exposed)
if (++log_cnt >= DECIM) {
    log_cnt = 0;
    csv << sc_time_stamp().to_seconds() << ',' << motor_id << ','
        << target_step_seen << ',' << th_m << ',' << om << ','
        << ia << ',' << ib << ',' << duty_a << ',' << duty_b << '\n';
}
```

Target parameters (setpoint step/frac, speed target) come from a small side input: mirror the values the stimulus wrote into plain TB signals wired into the plant (`sc_in`), so each CSV row carries *commanded vs. actual*. Decimation matters: a "run for a while" sim (say 0.5 s simulated = 20 M clocks) at full rate would be gigabytes; decimate by 32–128 or gate on the 32 kHz sample tick.

Post-processing: `tools/plot_closed_loop.py` (matplotlib, offline-wheel-friendly) reading the CSV → position-vs-target, speed profile, current waveforms, error convergence. Hook it as `make plot-closed-loop` reading `build/closed_loop/motors.csv`. That's your "extra edge": every closed-loop regression run leaves behind plots you can flip through when a check fails, and they're thesis-figure-ready.

## Make target, completing your flow

```make
sim-closed-loop: compile sc-compile
	$(VSIM) -c -coverage -wlf $(BUILD_DIR)/CL/closed_loop_tb.wlf \
	  -do "set tb_name closed_loop_tb; set req_class CL; set is_wave $$(SAVE_WAVES); \
	       set sim_time $(CL_SIM_TIME); do $(RUN_SIM_TCL)" work.closed_loop_tb
	python3 tools/plot_closed_loop.py $(BUILD_DIR)/closed_loop/motors.csv

CL_SIM_TIME ?= 500ms
```

`CL_SIM_TIME` as a variable because "runs for a while" should be tunable: 10 ms for smoke, 500 ms+ for the coverage-filling run. UCDB from this run merges into your existing `vcover merge` list; functional-coverage txt goes through the new parser; assertion results flow unchanged.

## Build order

1. Plant C++ port, open-loop sanity vs. `motor_plant.py` step response (same stimulus, diff the trajectories).
2. Closed-loop TB, one motor, your existing BFM, no coverage — get the loop stable (watch: PWM polarity, ADC scaling, reset sequencing).
3. Swap in / add the OSVVM VC (timeboxed; fallback = keep BFM).
4. Vector table + temporal checks (`check_equal` with sfixed tolerance on telemetry after settle windows).
5. OSVVM bins + monitor process + parser hook.
6. CSV logging + plot script; scale to N motors; long run.

That ordering means every step lands on something already working, and by step 4 you have a genuinely closed loop with pass/fail — steps 5–6 turn it into measured functional coverage plus a debugging instrument.