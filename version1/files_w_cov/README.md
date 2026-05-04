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
│       ├── B/                        ← Class B: e.g. torque compensation
│       └── C/                        ← Class C: e.g. AXI interface
├── scripts/
│   └── run_sim.tcl                   ← QuestaSim simulation control
├── tools/
│   ├── header_check.py               ← ECSS header compliance checker
│   ├── collect_results.py            ← Aggregates assertion results
│   └── parse_coverage.py             ← Parses vcover text reports
└── build/                            ← Generated, gitignored
    ├── work/                         ← QuestaSim work library
    ├── log/                          ← Per-TB transcripts
    │   └── <class>/<tb>.log
    ├── reports/                      ← Per-TB structured results
    │   ├── <class>/<tb>.result       ← Parsed by collect_results.py
    │   ├── summary.md                ← Aggregated regression report
    │   └── summary_<class>.md
    ├── coverage/                     ← Code-coverage outputs
    │   ├── <class>/<tb>.ucdb         ← Per-TB coverage database
    │   ├── merged.ucdb               ← Merged regression UCDB
    │   ├── coverage.txt              ← vcover text report
    │   ├── coverage_summary.md       ← Embedded into summary.md
    │   ├── html/                     ← Browseable HTML report
    │   └── coverage_<class>.txt
    └── waves/                        ← Optional WLF dumps
```

## Adding a new testbench

1. Choose the requirement class folder under `verification/requirements_tb/`.
   To create a new class, just create a new directory there — the Makefile
   discovers it automatically.

2. Create `<name>_tb.vhd` with:
   - The mandatory ECSS header block (see existing `pwm_generator_tb.vhd`).
   - Generics `G_RESULT_FILE`, `G_REQ_CLASS`, `G_TB_NAME` — these are set
     by `run_sim.tcl` per simulation run.
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
# → produces build/reports/common/pwm_generator_tb.result
# →          build/coverage/common/pwm_generator_tb.ucdb

# Whole class (also generates per-class coverage report)
make sim-class-A

# Full regression (also merges all UCDBs and embeds coverage in summary)
make sim-all          # or: make sim

# Re-merge coverage from existing UCDBs without re-simulating
make coverage
make coverage-class-A

# Just regenerate the Markdown report from existing .result files
make report
make report-A         # filter to class A

# With waveform capture (debug)
SAVE_WAVES=1 make sim-current_controller_tb

# Override coverage metrics (default: bcsefT)
COV_METRICS=bcs make compile         # statement+branch+condition only

# Clean everything
make clean
```

## Code coverage

Coverage is collected automatically every time a testbench runs. The
mechanism has three stages:

1. **Compile-time instrumentation.** `vcom +cover=$(COV_METRICS)` inserts
   coverage counters into the RTL. The default metric set is `bcsefT`
   (Branch, Condition, Statement, Expression, FSM, Toggle). Testbench
   files are compiled *without* coverage so their statements never count
   against the metrics — coverage measures exercise of the IP core, not
   of the testbench itself.

2. **Runtime collection.** `vsim -coverage` activates the counters during
   simulation. At the end of the run, `coverage save <file>.ucdb` in
   `run_sim.tcl` flushes a per-testbench Unified Coverage Database.

3. **Merge & report.** After all TBs in the requested scope have run, the
   Makefile invokes `vcover merge` to combine UCDBs, then `vcover report`
   for both text and HTML output. `tools/parse_coverage.py` extracts the
   numeric figures and produces a Markdown summary that is embedded into
   the corresponding requirements report.

**Important — coverage does not affect pass/fail.** Whether a testbench
passes depends solely on its assertion records:

| What fails           | Cause                                                                  |
|----------------------|------------------------------------------------------------------------|
| `make sim-X`         | Compile error, simulator crash, or any FAIL line in the `.result` file |
| `make coverage`      | *Never fails* — produces best-effort report from whatever UCDBs exist  |

This is intentional and aligns with ECSS-E-ST-20-40C §C.2.1: coverage
targets are owned by the verification plan, not the build system. If
coverage falls below an agreed threshold, the verification plan author
records a justification and obtains a waiver — the build does not block.

### Tuning the coverage metrics

The `COV_METRICS` Makefile variable controls which counters are inserted
at compile time. Each character is a metric flag:

| Char | Metric            | Cost / utility                                |
|------|-------------------|-----------------------------------------------|
| `b`  | Branch            | Low cost, very informative — always on        |
| `c`  | Condition         | Low cost — always on                          |
| `s`  | Statement         | Low cost — always on                          |
| `e`  | Expression        | Medium cost — useful for complex expressions  |
| `f`  | Finite state machine | Required for any state machines            |
| `T`  | Toggle (all signals) | High cost; comprehensive                    |
| `t`  | Toggle (ports only) | Medium cost; less complete                   |

For a full daily regression, `bcsefT` gives the most complete picture.
For a quick smoke test, drop to `bcs` or `bcse`.

### Coverage data flow

```
                ┌─────────────────────┐
                │  vcom +cover=bcsefT │  (one-time, RTL only)
                └──────────┬──────────┘
                           ▼
         ┌────────────────────────────────────┐
         │      Per-TB simulation:            │
         │  vsim -coverage  + coverage save   │
         │  → build/coverage/<class>/<tb>.ucdb│
         └──────────────────┬─────────────────┘
                            ▼
              ┌─────────────────────────────┐
              │   vcover merge              │
              │   → merged.ucdb             │
              └──────────────┬──────────────┘
                             ▼
              ┌──────────────┴──────────────┐
              ▼                             ▼
     ┌────────────────┐           ┌──────────────────┐
     │ vcover report  │           │ vcover report    │
     │ -details       │           │ -html            │
     │ → coverage.txt │           │ → html/          │
     └───────┬────────┘           └──────────────────┘
             ▼
   ┌────────────────────┐
   │ parse_coverage.py  │
   │ → coverage_*.md    │
   └─────────┬──────────┘
             ▼
   ┌─────────────────────┐
   │ collect_results.py  │ ← also reads .result files
   │ → summary.md        │
   └─────────────────────┘
```

## Result file format

Each testbench writes a structured `*.result` file under
`build/reports/<class>/`. Each line is one assertion record:

```
PASS|REQ-PWM-001|h_bridge_zero_at_50pct_duty|actual=50.0% expected=50.0%|t=2500 ns
FAIL|REQ-PWM-002|zero_duty_low_output|actual='1' expected='0'|t=4750 ns
```

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
| ECSS-E-ST-20-40C §C.2.1 coverage      | +cover=bcsefT + vcover merge/report      |
| ECSS-Q-ST-60-03C §6 verification plan | docs/verification_plan.md                |
| ECSS-Q-ST-60-03C §7.1 metrics         | build/reports/summary.md                 |
| ECSS-Q-ST-60-03C §8 CM                | git tags + docs/cm_plan.md               |
