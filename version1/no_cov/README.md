# MCE-NG IP Core — Verification Environment

ECSS-compliant development and verification environment for the MCE-NG
stepper motor controller IP core.

## Project layout

```
mce-ng-ip/
├── Makefile                          ← Single entry point
├── README.md
├── docs/                             ← ECSS deliverables
│   ├── requirements.md               ← REQ-XX-NNN list
│   ├── architecture.md               ← Clock/reset domains, naming
│   ├── verification_plan.md
│   └── cm_plan.md                    ← Configuration management
├── src/
│   ├── pkg/                          ← VHDL packages (compiled first)
│   │   └── *.vhd
│   └── hdl/                          ← Synthesizable RTL
│       ├── cordic/
│       ├── current_controller/
│       ├── setpoint/
│       ├── torque_compensation/
│       ├── motion_profile/
│       ├── pwm_generator/
│       └── top/
├── verification/
│   └── requirements_tb/              ← Organised by REQ class
│       ├── common/                   ← Shared TB packages + cross-cutting
│       │   ├── assertion_pkg.vhd
│       │   └── pwm_generator_tb.vhd
│       ├── A/                        ← Class A: e.g. current control loop
│       │   └── current_controller_tb.vhd
│       ├── B/                        ← Class B: e.g. torque compensation
│       │   └── torque_compensation_tb.vhd
│       └── C/                        ← Class C: e.g. AXI interface
│           └── axi_lite_tb.vhd
├── scripts/
│   └── run_sim.tcl                   ← QuestaSim simulation control
├── tools/
│   ├── header_check.py               ← ECSS header compliance checker
│   └── collect_results.py            ← Result aggregator
└── build/                            ← Generated, gitignored
    ├── work/                         ← QuestaSim work library
    ├── log/                          ← Per-TB transcripts
    │   └── <class>/<tb>.log
    ├── reports/                      ← Per-TB structured results
    │   ├── <class>/<tb>.result       ← Parsed by collect_results.py
    │   ├── summary.md                ← Aggregated regression report
    │   └── summary_<class>.md        ← Per-class report
    └── waves/                        ← Optional WLF dumps
```

## Adding a new testbench

1. Choose the requirement class folder under `verification/requirements_tb/`.
   To create a new class, just create a new directory there — the Makefile
   discovers it automatically.

2. Create `<name>_tb.vhd` with:
   - The mandatory ECSS header block (see existing `pwm_generator_tb.vhd`).
   - Generics `G_RESULT_FILE`, `G_REQ_CLASS`, `G_TB_NAME` — these are set
     by `run_sim.tcl` per simulation run. The defaults in the entity make
     interactive runs work without arguments.
   - `use work.assertion_pkg.all;` for the `check_*` procedures.
   - One process that drives stimulus and calls the assertions, then
     calls `close_result_file` and `stop`.

3. The Makefile auto-generates a `sim-<name>_tb` target. No Makefile edits
   needed.

## Common commands

```bash
# Discover what is available
make list-classes
make list-tbs
make list-class-A

# Pre-flight (runs automatically before any sim, but useful to run alone)
make check-headers

# Single testbench
make sim-pwm_generator_tb

# Whole class
make sim-class-A

# Full regression
make sim-all          # or simply: make sim

# Just regenerate the Markdown report from existing .result files
make report
make report-A         # filter to class A

# With waveform capture (debug)
SAVE_WAVES=1 make sim-current_controller_tb

# Clean everything
make clean
```

## Result file format

Each testbench writes a structured `*.result` file under
`build/reports/<class>/`. Each line is one assertion record:

```
PASS|REQ-PWM-001|h_bridge_zero_at_50pct_duty|actual=50.0% expected=50.0%|t=2500 ns
FAIL|REQ-PWM-002|zero_duty_low_output|actual='1' expected='0'|t=4750 ns
```

Fields:

| Field        | Meaning                                                            |
|--------------|--------------------------------------------------------------------|
| Verdict      | `PASS`, `FAIL`, or `TIMEOUT`                                       |
| Requirement  | ECSS requirement reference (e.g. `REQ-PWM-001`)                    |
| Check        | Short identifier of what was checked                               |
| Detail       | Free-form text — `actual=`, `expected=`, computed values           |
| Sim Time     | Simulation time at which the check was performed                   |

This format is parsed by `tools/collect_results.py` to build the
Markdown report and the console summary.

## ECSS compliance traceability

| Standard requirement                  | Where addressed                          |
|---------------------------------------|------------------------------------------|
| ECSS-E-ST-20-40C §5.1.3f reproducible | Makefile + run_sim.tcl, no manual steps  |
| ECSS-E-ST-20-40C §A.2.1 headers       | tools/header_check.py + check-headers    |
| ECSS-E-ST-20-40C §5.4.3f self-check   | assertion_pkg + .result files            |
| ECSS-Q-ST-60-03C §6 verification plan | docs/verification_plan.md                |
| ECSS-Q-ST-60-03C §8 CM                | git tags + docs/cm_plan.md               |
| ECSS-Q-ST-60-03C §7.1 metrics         | build/reports/summary.md                 |
