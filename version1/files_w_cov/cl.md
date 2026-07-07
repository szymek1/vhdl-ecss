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

# model 
Good refinement questions — all four touch real SystemC patterns. Let me address each design decision, then give you the comprehensive version.

**Per-motor parameters.** `SC_MODULE` is a C++ class, so the constructor takes arguments after the mandatory module name. The idiomatic pattern for many parameters is a plain `struct` passed by const reference — one bundle per motor, defined in the VHDL-facing TB or a config header. Since you'll add a constructor with arguments, you need `SC_HAS_PROCESS` instead of `SC_CTOR` (that's the SystemC equivalent you're asking about).

**Time step.** Don't hardcode `dt` and don't pass it as a number that can drift from reality — *derive it from the clock the module actually runs on*. Cleanest: pass the clock period as a constructor parameter (`sc_time`) and compute `dt = period.to_seconds()` once. Even better self-checking: on the second clock edge, measure `sc_time_stamp()` delta and assert it matches the configured dt — that catches a TB/clock mismatch instantly and permanently.

**duty_to_volts.** Your PWM chain gives the plant a *switching* signal if you instantiate your VHDL `pwm_gen` (the plan from last time), or a *duty word* if you connect the core's duty registers directly. Two different converters: for a switching input, the phase voltage is simply `pin ? +U0 : −U0` (H-bridge, 27 V from Table 3.1) — no math, and Euler at 25 ns resolves the switching directly. For a duty-word input, it's the average `U0 * (2*duty/range − 1)` (signed around midscale, matching eq 5.11's PWM normalization). Support both with a mode flag so you can run fast smoke tests without the PWM entity and full-fidelity runs with it.

**ADC as a separate module — yes, right instinct.** Injecting it as its own `SC_MODULE` (instantiated per phase, or one dual-channel) mirrors the real signal chain, keeps the plant purely physical, and lets you unit-test quantization/offset in isolation. Connect plant→ADC through `sc_signal<double>` — analog values crossing between SystemC modules is exactly what `sc_signal<double>` is for. Only the ADC touches `sc_lv`; only the ADC knows about bias and gain (the ~33-count structural offset the normalizer must cancel).

**Logging** lives in the plant (it owns ground truth), decimated, CSV via `std::ofstream`, with commanded values fed in as side inputs so each row is *commanded vs. actual*.

Here's the comprehensive design:

```cpp
// motor_plant.h ---------------------------------------------------------
#include <systemc.h>
#include <fstream>
#include <string>
#include <cmath>

// ── Per-motor physical parameters (defaults = thesis Table 3.1) ───────
struct motor_params {
    double R      = 9.6;      // phase resistance [ohm]
    double L      = 24e-3;    // phase inductance [H]
    double U0     = 27.0;     // supply voltage [V]
    double Ke     = 0.05;     // back-EMF constant [V·s/rad] (electrical)
    double Kt     = 0.05;     // torque constant [N·m/A]
    double J      = 1e-5;     // rotor+load inertia [kg·m²]
    double B      = 1e-4;     // viscous friction [N·m·s/rad]
    int    Np     = 50;       // pole pairs (th_e = Np * th_m)
    // disturbances, eq 4.1: k0·sin(th_m+p0) + k1·sin(2·th_m+p1) + kr·sin(4·th_m+pr)
    double k0=0, p0=0, k1=0, p1=0, kr=0, pr=0;
};

// ── ADC: separate module, owns quantization + structural offset ───────
SC_MODULE(adc_model) {
    sc_in<bool>        clk;
    sc_in<double>      i_analog;      // current from plant [A]
    sc_out<sc_lv<12>>  o_code;

    double fullscale, gain;   // amps at full scale; gain error factor
    int    bias;              // structural offset in counts (~33)

    void sample() {
        double lsb  = fullscale / 2048.0;                    // signed 12-bit
        int    code = int(std::lround(i_analog.read()*gain/lsb)) + 2048 + bias;
        if (code < 0) code = 0; if (code > 4095) code = 4095; // saturate
        o_code.write(sc_lv<12>(sc_uint<12>(code)));
    }
    SC_HAS_PROCESS(adc_model);
    adc_model(sc_module_name nm, double fs, int bias_counts, double gain_err)
      : sc_module(nm), fullscale(fs), gain(gain_err), bias(bias_counts) {
        SC_METHOD(sample); sensitive << clk.pos(); dont_initialize();
    }
};

// ── Plant: pure physics, analog out, CSV logging ──────────────────────
SC_MODULE(motor_plant) {
    sc_in<bool>     clk;
    sc_in<sc_logic> rst_n;

    // drive input: either switching pins (mode SWITCHED) or duty words
    sc_in<sc_logic> pwm_pin_a, pwm_pin_b;          // from your VHDL pwm_gen
    sc_in<sc_lv<16>> duty_a, duty_b;               // direct-duty mode
    sc_out<double>  ia_out, ib_out;                // analog, into adc_model

    // commanded values (side inputs, logging only — wired from TB signals)
    sc_in<sc_lv<32>> cmd_step;
    sc_in<sc_lv<16>> cmd_frac;

    enum drive_mode { SWITCHED, AVG_DUTY };

    motor_params P;
    drive_mode   mode;
    double dt;                    // derived from clock period
    int    motor_id;
    unsigned decim, log_cnt = 0;
    std::ofstream csv;

    double ia=0, ib=0, th_m=0, om=0;
    bool   dt_checked = false;
    sc_time last_edge = SC_ZERO_TIME;

    double volts(bool phase_b) {
        if (mode == SWITCHED) {
            sc_logic p = phase_b ? pwm_pin_b.read() : pwm_pin_a.read();
            return (p == SC_LOGIC_1) ? P.U0 : -P.U0;          // H-bridge
        } else {
            unsigned d = (phase_b ? duty_b : duty_a).read().to_uint();
            return P.U0 * (2.0*double(d)/65535.0 - 1.0);       // eq 5.11 avg
        }
    }

    void step() {
        // one-shot dt self-check against the actual clock
        if (!dt_checked) {
            if (last_edge != SC_ZERO_TIME) {
                double meas = (sc_time_stamp()-last_edge).to_seconds();
                sc_assert(std::abs(meas-dt) < 1e-12 && "dt != clock period");
                dt_checked = true;
            }
            last_edge = sc_time_stamp();
        }

        if (rst_n.read() != SC_LOGIC_1) { ia=ib=th_m=om=0; }
        else {
            double the = P.Np * th_m;                          // electrical angle
            // eq 2.3: electrical, with back-EMF
            ia += dt/P.L * (volts(false) - P.R*ia + P.Ke*om*P.Np*std::sin(the));
            ib += dt/P.L * (volts(true)  - P.R*ib - P.Ke*om*P.Np*std::cos(the));
            // eq 2.4 torque from actual currents
            double Te = P.Kt * (-ia*std::sin(the) + ib*std::cos(the));
            // eq 4.1 disturbances
            double Td = P.k0*std::sin(th_m+P.p0) + P.k1*std::sin(2*th_m+P.p1)
                      + P.kr*std::sin(4*th_m+P.pr);
            om   += dt/P.J * (Te + Td - P.B*om);
            th_m += dt * om;
        }
        ia_out.write(ia); ib_out.write(ib);

        if (++log_cnt >= decim) {
            log_cnt = 0;
            csv << sc_time_stamp().to_seconds() << ',' << motor_id << ','
                << cmd_step.read().to_int() << ',' << cmd_frac.read().to_uint()
                << ',' << th_m << ',' << om << ',' << ia << ',' << ib << '\n';
        }
    }

    SC_HAS_PROCESS(motor_plant);
    motor_plant(sc_module_name nm, const motor_params& p, int id,
                sc_time clk_period, drive_mode m = SWITCHED,
                unsigned decimation = 32,
                const std::string& logdir = "build/closed_loop")
      : sc_module(nm), P(p), mode(m),
        dt(clk_period.to_seconds()), motor_id(id), decim(decimation),
        csv(logdir + "/motor" + std::to_string(id) + ".csv") {
        csv << "t,motor,cmd_step,cmd_frac,th_m,om,ia,ib\n";
        SC_METHOD(step); sensitive << clk.pos(); dont_initialize();
    }
};
```

And a top-level SystemC wrapper per motor that bundles plant + two ADCs, so the VHDL side instantiates *one* component per motor with the clean digital interface:

```cpp
// motor_channel.h — what the VHDL actually instantiates ---------------
SC_MODULE(motor_channel) {
    sc_in<bool>       clk;
    sc_in<sc_logic>   rst_n;
    sc_in<sc_logic>   pwm_pin_a, pwm_pin_b;
    sc_in<sc_lv<16>>  duty_a, duty_b;
    sc_in<sc_lv<32>>  cmd_step;
    sc_in<sc_lv<16>>  cmd_frac;
    sc_out<sc_lv<12>> adc_a, adc_b;

    sc_signal<double> ia_sig, ib_sig;             // analog plumbing
    motor_plant plant;
    adc_model   adc_ph_a, adc_ph_b;

    SC_HAS_PROCESS(motor_channel);
    motor_channel(sc_module_name nm, const motor_params& p, int id,
                  sc_time period, motor_plant::drive_mode m,
                  double adc_fs = 2.0, int adc_bias = 33, double adc_gain = 1.0)
      : sc_module(nm),
        plant("plant", p, id, period, m),
        adc_ph_a("adc_a_m", adc_fs, adc_bias, adc_gain),
        adc_ph_b("adc_b_m", adc_fs, adc_bias, adc_gain) {
        plant.clk(clk); plant.rst_n(rst_n);
        plant.pwm_pin_a(pwm_pin_a); plant.pwm_pin_b(pwm_pin_b);
        plant.duty_a(duty_a); plant.duty_b(duty_b);
        plant.cmd_step(cmd_step); plant.cmd_frac(cmd_frac);
        plant.ia_out(ia_sig); plant.ib_out(ib_sig);
        adc_ph_a.clk(clk); adc_ph_a.i_analog(ia_sig); adc_ph_a.o_code(adc_a);
        adc_ph_b.clk(clk); adc_ph_b.i_analog(ib_sig); adc_ph_b.o_code(adc_b);
    }
};
```

Design notes on the choices baked in there:

The **`motor_params` struct with thesis defaults** means motor 0 can be nominal while motor 1 gets `R = 10.2`, a torque-constant mismatch (via per-phase gain, which you can add as `Kta/Ktb` if you want to exercise the ga/gb correction path), and motor 2 gets disturbance amplitudes — three motors, three parameter sets, one line each in the TB config. That asymmetry is precisely what makes the multi-motor closed loop worth running: identical plants can't catch per-motor wiring or normalization bugs.

The **dt self-check** converts "I passed the right clock period" from an assumption into an assertion — one-time cost, permanent protection, same philosophy as your WB-overrun assertion.

The **two drive modes** let you keep one plant for both configurations: `AVG_DUTY` for fast functional runs wired straight to the core's duty registers (no PWM entity, coarser physics, much faster to converge tests), `SWITCHED` for the full-fidelity run with your VHDL `pwm_gen` in the chain contributing code coverage. Pick per-TB via constructor argument.

The **ADC separation** puts fullscale/bias/gain in the one module whose job is signal conditioning. Your normalizer-verification vector (settle at zero → expect `yk ≈ 0` after cOff correction) now tests against a bias *you* injected in `adc_model`, and a second run with `adc_bias = 0` proves the correction is doing the work rather than masking a modeling accident.

One caveat on the mixed-language boundary: Questa's SystemC↔VHDL binding is most robust with digital types at the boundary (`sc_logic`/`sc_lv` ↔ `std_logic`/`std_logic_vector`), which is why `motor_channel` is the unit VHDL instantiates — the `double` signals stay entirely inside the SystemC island. Register `motor_channel` for elaboration with `SC_MODULE_EXPORT` in the .cpp, and note that per-motor constructor parameters can't come through a VHDL generic map — the standard trick is a tiny SystemC top factory or reading a config table (id-indexed) inside the constructor; the id itself can come through as a plain integer parameter Questa passes via `sccom`-registered generics, or simplest of all, N `motor_channel` variants instantiated from a small SystemC wrapper that VHDL sees as one entity with a motor-count generic. Start with the config-table-indexed-by-id approach — it keeps the VHDL side to a plain component instantiation inside your existing generate loop.