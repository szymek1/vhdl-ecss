Good — I can see your prior project already uses GHDL + cocotb + pytest + uv + Vivado/AXI on Zynq. That's an excellent foundation to reuse. Here is a complete roadmap.

---

## Overview of the two ECSS standards

Before diving into phases, you need to understand what these documents actually demand.

**ECSS-E-ST-20-40C** (VHDL design rules) is a coding standard. It mandates things like: all design units must have a header block (project, author, date, version, description), generics and ports must follow naming conventions, all signals must be explicitly typed with no guessing, no undriven signals, no latches in synthesizable code, all processes must have explicit sensitivity lists, clock domains must be documented, and reset strategy must be explicit (synchronous vs. asynchronous, active polarity). Think of it as a very strict "clean code" rulebook for VHDL.

**ECSS-Q-ST-60-03C** (ASIC/FPGA development) is a process standard. It governs the entire development lifecycle: requirements traceability (each HDL module must trace back to a requirement), functional verification coverage, independence between design and verification, configuration management (every synthesized bitstream must be reproducible from a tagged version), and formal documentation for each release. This is the standard that makes your project auditable for flight use.

In practice for a thesis continuation, you do not need to achieve full flight certification, but you need to demonstrate that the architecture is *compatible* with these standards. That means adopting the structures they require so that full compliance could be achieved with additional effort.

---

## Phase 0 — Foundation (Weeks 1–2)

### Repository structure

Based on your RISCV project's structure and the requirements of both standards, the layout should be:

```
mce-ng-ip/
├── ip_core/
│   ├── rtl/                   # Synthesizable VHDL sources
│   │   ├── packages/          # Shared type/constant packages
│   │   ├── cordic/
│   │   ├── current_controller/
│   │   ├── setpoint/
│   │   ├── torque_compensation/
│   │   ├── motion_profile/
│   │   └── top/               # AXI wrapper + top-level
│   └── constraints/           # Timing constraints
├── verification/
│   ├── tb/                    # cocotb testbenches (per module)
│   ├── models/                # Python reference models (bit-accurate)
│   ├── sim_top/               # Closed-loop full simulation
│   └── reports/               # Auto-generated coverage reports
├── software/
│   ├── driver/                # Bare-metal C AXI driver
│   └── test_app/              # C application for hardware-in-loop test
├── docs/
│   ├── requirements.md        # Traceable requirements list
│   ├── architecture.md
│   └── verification_plan.md
├── platforms/
│   └── zynq_z7/               # Vivado project scripts (TCL-based)
├── tools/
│   └── header_check.py        # Script to enforce ECSS header compliance
├── build.py                   # Reuse/extend from your RISCV project
├── pyproject.toml
└── uv.lock
```

The key principle from ECSS-Q-ST-60-03C is that the Vivado project must **never** be committed as binary. Only TCL scripts that regenerate it from scratch should be tracked. This guarantees reproducibility.

### Build system

Extend your existing `build.py` from the RISCV project. Add modes: `simulation`, `lint`, `hardware`, and `compliance-check`. Keep uv + pyproject.toml for dependency management. Add GHDL (already used), cocotb, and pytest as simulation stack. Add `vunit` as an optional alternative for VHDL-native assertions — it pairs well with GHDL and gives you structured test reporting that aligns with ECSS-Q-ST-60-03C verification documentation.

---

## Phase 1 — ECSS-E-ST-20-40C Compliance Refactor (Weeks 3–5)

This is purely a VHDL rework phase — no new features, only making the existing code standards-compliant.

Every source file must get a header block like this:

```vhdl
-- =============================================================================
-- Project     : MCE-NG IP Core
-- Module      : current_controller
-- Author      : Maximilian Stief
-- Created     : 2024-04-25
-- Version     : 1.0.0
-- Description : H-infinity current controller for one stepper motor phase.
--               Implements the discretized 2nd-order controller from eq. 3.24.
--               Requirement: REQ-CC-001 through REQ-CC-005.
-- =============================================================================
```

The "Requirement" line in the header is the bridge to ECSS-Q-ST-60-03C traceability.

Other things to fix in this pass: replace any `std_logic_vector` arithmetic with `numeric_std` typed signals, document every clock domain explicitly (there is at least the ADC clock, the PWM clock, and the control loop clock to be conscious of), ensure every reset is synchronous and active-high (or document exactly why not), remove any implicit signal initializations in the architecture body (allowed in simulation, forbidden in space FPGA flow), and add `-- synthesis off` guards around any simulation-only code.

Write `tools/header_check.py` — a simple Python script that parses every `.vhd` file and checks for the required header fields. This runs as a step in CI and fails the build if any file is missing a header or requirement reference. This single script will give your thesis a concrete artifact that demonstrates standards awareness.

---

## Phase 2 — Self-Checking Testbench Infrastructure (Weeks 6–9)

This phase addresses your challenge #1 directly.

### The reference model strategy

The most important architectural decision for your testbenches: write a **bit-accurate Python reference model** of each VHDL module in `verification/models/`. Since all your arithmetic is fixed-point, you can use Python's `fxpmath` or simply emulate fixed-point manually with integer arithmetic. Each cocotb testbench then drives the same inputs into both the DUT and the Python model, and asserts equality at every output. This gives you fully automatic pass/fail without waveform inspection.

For the current controller specifically, the reference model is straightforward — it is just equation 3.24 from your thesis implemented in Python with the same fixed-point word lengths as the VHDL.

### Closed-loop simulation strategy (challenge #1 deep dive)

Closing the loop in simulation is the hardest problem you listed, and the solution is a **behavioral motor model in Python** running inside cocotb. The model needs to implement:

- The electrical model from equation 2.3 (the RL circuit with back-EMF)
- The torque model from equation 2.6
- A simple mechanical integrator (torque → angular acceleration → velocity → position)

At each cocotb simulation timestep, the loop runs: FPGA outputs PWM duty cycle → Python motor model computes resulting current → Python model feeds back a quantized ADC value → FPGA controller receives it and computes next command. Since cocotb lets you drive and read signals at arbitrary simulation time, you can implement this loop cleanly. The timestep of the Python model should match your ADC sampling period (approximately 1/32768 s).

The closed-loop testbench lives in `verification/sim_top/`. Its pass criteria: at steady-state speed, the RMS current error must be below a defined threshold (taken from your thesis measurements), and the spectral power density of the simulated rotational velocity must be below the reference electronics baseline. These become your formal verification criteria.

For the CORDIC module and the fixed-point arithmetic blocks, standard component-level testbenches with sweep tests (check sin/cos accuracy across all input values) are sufficient and much simpler.

---

## Phase 3 — Multi-Motor Architecture (Weeks 10–12)

This addresses challenge #2.

The key design choice is **time-multiplexing** rather than instantiating N copies of the controller. Your thesis already hints at this as the intended approach. One controller instance runs at a clock rate that is N times the required control loop rate, and a state machine cycles through motors one at a time, storing per-motor state in a small RAM block.

The generic parameter `N_MOTORS` controls how many motors are supported. Each motor has a state record in a BRAM:

```vhdl
type t_motor_state is record
    position     : signed(31 downto 0);
    velocity     : signed(23 downto 0);
    uk_prev1     : sfixed(1 downto -14);   -- u_{k-1}
    uk_prev2     : sfixed(1 downto -14);   -- u_{k-2}
    ek_prev1     : sfixed(1 downto -14);   -- e_{k-1}
    ek_prev2     : sfixed(1 downto -14);   -- e_{k-2}
end record;
```

Motor parameters (R, L, compensation coefficients, gain normalization) are stored separately — more on this in Phase 4.

The timing constraint is: `f_clk / N_MOTORS ≥ f_sample_required`. For 32768 Hz sample rate and 4 motors, you need at least 131 kHz effective compute rate, which is trivially met on any modern FPGA.

---

## Phase 4 — AXI Interface and Parameter Management (Weeks 13–16)

This addresses challenge #3 and extends challenge #2.

### AXI-Lite register map

AXI-Lite (not full AXI) is the right choice here — the data rates are low and the register-mapped interface is simple to implement and to use from the ARM side. Define a register map document first, then implement. A sketch:

```
Offset 0x000: CTRL_REG        (start/stop, motor select, mode)
Offset 0x004: STATUS_REG      (ready, fault flags)
Offset 0x008: MOTOR_ID        (select which motor the next writes apply to)
Offset 0x00C: TARGET_VEL      (velocity setpoint)
Offset 0x010: TARGET_POS      (position setpoint)
Offset 0x100: PARAM_R         (phase resistance, fixed-point)
Offset 0x104: PARAM_L         (phase inductance, fixed-point)
Offset 0x108: PARAM_I0        (rated current)
Offset 0x10C: CTRL_A0..A2     (controller coefficients, one per register)
Offset 0x110: CTRL_B0..B2
Offset 0x120: COMP_GA, COMP_GB (gain compensation factors)
Offset 0x124: COMP_OA, COMP_OB (offset compensation)
Offset 0x130...: torque mod parameters
Offset 0x200: TELEM_VEL       (read-back current velocity)
Offset 0x204: TELEM_POS       (read-back current position)
Offset 0x208: TELEM_IA, TELEM_IB (actual phase currents)
```

The ARM Cortex on the Zynq reads motor parameters from EEPROM (or from a filesystem on the SD card, which is simpler for a thesis) at boot, then writes them into the IP core's AXI registers. This way the IP core itself is generic — it has no knowledge of a specific motor. The C driver running on the ARM is responsible for loading the correct parameters.

### The C driver structure

In `software/driver/`, implement a bare-metal driver with this interface:

```c
mce_ng_status_t mce_ng_init(mce_ng_handle_t *h, uint32_t base_addr);
mce_ng_status_t mce_ng_load_motor_params(mce_ng_handle_t *h, uint8_t motor_id, const motor_params_t *params);
mce_ng_status_t mce_ng_set_velocity(mce_ng_handle_t *h, uint8_t motor_id, int32_t velocity_stp_s);
mce_ng_status_t mce_ng_set_position(mce_ng_handle_t *h, uint8_t motor_id, int32_t position_steps);
mce_ng_status_t mce_ng_get_telemetry(mce_ng_handle_t *h, uint8_t motor_id, motor_telemetry_t *telem);
```

The `motor_params_t` struct maps directly to the AXI register offsets above. This clean separation between driver and hardware is exactly what ECSS-Q-ST-60-03C expects.

---

## Phase 5 — Verification Completion and Documentation (Weeks 17–19)

At this point you have working hardware and self-checking testbenches. The remaining work is closing the loop on ECSS-Q-ST-60-03C process requirements.

Write the **requirements document** (`docs/requirements.md`). Every REQ-XX-NNN entry corresponds to one or more headers in the RTL and one or more test cases. This creates the traceability matrix that the standard requires. It does not need to be exhaustive for a thesis — even 20–30 requirements covering the core functional blocks is enough to demonstrate the methodology.

Write the **verification plan** (`docs/verification_plan.md`). This states which requirements are covered by which testbenches, what the pass criteria are, and which are verified by simulation vs. hardware test. This document is the deliverable that reviewers look for.

Run the full test suite and generate a report. The cocotb + pytest combination already produces JUnit XML output, which you can format into a simple HTML report. This becomes your "verification report" artifact.

---

## Phase 6 — Hardware Integration and Final Validation (Weeks 20–22)

Bring everything together on the Zynq board. The Vivado project (generated entirely from TCL) instantiates the IP core, connects it via AXI-Lite to the ARM, and routes ADC/PWM signals to the physical pins. The C application on the ARM loads parameters from a JSON file on the SD card, initializes the IP core, and runs the same three speed profiles from Chapter 6 of your thesis. You measure vibrations with the same test setup and compare against the thesis results to validate that the IP core produces identical behavior.

---

## Summary timeline

| Phase | Content | Duration |
|---|---|---|
| 0 | Repo structure, build system | 2 weeks |
| 1 | ECSS-E-ST-20-40C VHDL refactor | 3 weeks |
| 2 | Self-checking TBs + closed-loop sim | 4 weeks |
| 3 | Multi-motor time-multiplexed architecture | 3 weeks |
| 4 | AXI-Lite interface + C driver | 4 weeks |
| 5 | Requirements doc + verification plan | 3 weeks |
| 6 | Hardware integration + validation | 3 weeks |

The critical path is Phase 2 (closed-loop simulation) feeding into Phase 3. Everything else can be done somewhat in parallel once the architecture in Phase 3 is stable.

One practical suggestion: start Phase 1 (the VHDL refactor) in parallel with Phase 0, since it does not depend on any new architecture. The header check script and the coding standard fixes are low-risk work that can fill the early weeks while you are thinking through the harder architectural decisions in Phases 2 and 3.
