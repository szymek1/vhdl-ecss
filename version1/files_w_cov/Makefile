# =============================================================================
# MCE-NG IP Core — Verification & Build Makefile
# -----------------------------------------------------------------------------
# Author      : Maximilian Stief
# License     : GNU GPL
# Description : Drives QuestaSim-based unit-level verification of the MCE-NG
#               stepper motor controller IP core. Targets are organized
#               around ECSS requirement classes so individual testbenches,
#               whole requirement classes, or the full regression can be
#               executed with one command.
#
# Compliance  : ECSS-E-ST-20-40C §5.1.3f — every step is automated and
#               reproducible from this single entry point.
#               ECSS-Q-ST-60-03C §8     — no manual tool invocations.
# =============================================================================

ROOT_DIR        := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

# ── Project directories ─────────────────────────────────────────────────────
SRC_DIR         := $(ROOT_DIR)/src
HDL_DIR         := $(SRC_DIR)/hdl
PKG_DIR         := $(SRC_DIR)/pkg

VERIF_DIR       := $(ROOT_DIR)/verification
REQ_TB_DIR      := $(VERIF_DIR)/requirements_tb

TOOLS_DIR       := $(ROOT_DIR)/tools
SCRIPTS_DIR     := $(ROOT_DIR)/scripts
DOCS_DIR        := $(ROOT_DIR)/docs

# ── Build outputs (gitignored) ──────────────────────────────────────────────
BUILD_DIR       := $(ROOT_DIR)/build
WORK_DIR        := $(BUILD_DIR)/work
LOG_DIR         := $(BUILD_DIR)/log
REPORT_DIR      := $(BUILD_DIR)/reports
WAVE_DIR        := $(BUILD_DIR)/waves
COV_DIR         := $(BUILD_DIR)/coverage

# Per-TB UCDBs go under $(COV_DIR)/<class>/<tb>.ucdb
# Merged regression UCDB:
COV_MERGED      := $(COV_DIR)/merged.ucdb
COV_REPORT_TXT  := $(COV_DIR)/coverage.txt
COV_REPORT_HTML := $(COV_DIR)/html

# ── TCL scripts ─────────────────────────────────────────────────────────────
COMPILE_TCL     := $(SCRIPTS_DIR)/compile.tcl
RUN_SIM_TCL     := $(SCRIPTS_DIR)/run_sim.tcl

# ── Python tools ────────────────────────────────────────────────────────────
HEADER_CHECK    := $(TOOLS_DIR)/header_check.py
COLLECT_RESULTS := $(TOOLS_DIR)/collect_results.py
PARSE_COVERAGE  := $(TOOLS_DIR)/parse_coverage.py

# ── QuestaSim configuration ─────────────────────────────────────────────────
VLIB            := vlib
VMAP            := vmap
VCOM            := vcom
VSIM            := vsim
VCOVER          := vcover

# Coverage metrics enabled at compile time:
#   b — branch
#   c — condition
#   s — statement
#   e — expression
#   f — finite state machine
#   t — toggle (signal transitions)
# Combine into one option string: +cover=bcsefT
# The capital T enables toggle on ALL ports/signals — heavier but the most
# complete metric. Drop to lower-case t to limit toggle to ports only,
# or remove entirely for faster sims. ECSS-E-ST-20-40C §C.2.1 lets the
# verification plan justify which metrics are tracked.
COV_METRICS     := bcsefT
COV_OPT         := +cover=$(COV_METRICS)

# Coverage instrumentation is applied ONLY to the IP core (src/),
# never to testbench files. This keeps the metrics meaningful — we want
# to know whether the *RTL* is exercised, not the testbench.
VCOM_FLAGS      := -2008 -pedanticerrors -mixedsvvh -autoorder
VCOM_RTL_FLAGS  := $(VCOM_FLAGS) $(COV_OPT)
VCOM_TB_FLAGS   := $(VCOM_FLAGS)

VSIM_FLAGS      := -batch -voptargs=+acc -t 1ns -coverage

# When SAVE_WAVES=1 is exported, run_sim.tcl will dump WLF waveforms
# (debug only; not used by pass/fail logic)
ifeq ($(SAVE_WAVES),1)
  export SAVE_WAVES
endif

# ── Source discovery ────────────────────────────────────────────────────────
# Packages must be compiled first; the autoorder flag of vcom resolves
# the rest from there.
PKG_SRCS        := $(wildcard $(PKG_DIR)/*.vhd)
HDL_SRCS        := $(wildcard $(HDL_DIR)/*.vhd) $(wildcard $(HDL_DIR)/**/*.vhd)
ALL_RTL_SRCS    := $(PKG_SRCS) $(HDL_SRCS)

# ── Requirement-class discovery ─────────────────────────────────────────────
# Every directory directly under verification/requirements_tb/ is treated
# as a requirement class. Adding a new class requires no Makefile changes.
REQ_CLASSES     := $(notdir $(patsubst %/,%,$(wildcard $(REQ_TB_DIR)/*/)))

# ── Testbench discovery ─────────────────────────────────────────────────────
# A testbench is any file matching <name>_tb.vhd anywhere under a class
# directory. The class is encoded in the path:
#   verification/requirements_tb/<class>/<name>_tb.vhd
# We build two parallel lists indexed by the same testbench name:
#   TB_NAMES      = pwm_generator cordic ...
#   TB_FILES      = full path to each testbench source
#   TB_CLASS_<n>  = class for testbench n (lookup variable)

TB_FILES        := $(foreach c,$(REQ_CLASSES),$(wildcard $(REQ_TB_DIR)/$(c)/*_tb.vhd))
TB_NAMES        := $(notdir $(basename $(TB_FILES)))

# Build a per-testbench class map: TB_CLASS_pwm_generator_tb := A
$(foreach c,$(REQ_CLASSES), \
  $(foreach f,$(wildcard $(REQ_TB_DIR)/$(c)/*_tb.vhd), \
    $(eval TB_CLASS_$(notdir $(basename $(f))) := $(c)) \
    $(eval TB_FILE_$(notdir $(basename $(f))) := $(f))))

# Per-class testbench lists: TBS_IN_CLASS_A := pwm_generator_tb adc_iface_tb
$(foreach c,$(REQ_CLASSES), \
  $(eval TBS_IN_CLASS_$(c) := $(notdir $(basename $(wildcard $(REQ_TB_DIR)/$(c)/*_tb.vhd)))))

# ─────────────────────────────────────────────────────────────────────────────
# Default target: show help
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "MCE-NG IP Core verification — available targets"
	@echo ""
	@echo "  Information"
	@echo "    list-classes          List all requirement classes found"
	@echo "    list-tbs              List all discovered testbenches"
	@echo "    list-class-<class>    List testbenches in one class (e.g. list-class-A)"
	@echo ""
	@echo "  Pre-flight checks"
	@echo "    check-headers         Verify ECSS header compliance on all sources"
	@echo ""
	@echo "  Compilation"
	@echo "    compile               Compile RTL + all testbenches into work library"
	@echo "                          (RTL is instrumented for coverage: $(COV_METRICS))"
	@echo ""
	@echo "  Simulation"
	@echo "    sim-<tb_name>         Run one testbench (e.g. sim-pwm_generator_tb)"
	@echo "    sim-class-<class>     Run all TBs of one class + class coverage report"
	@echo "    sim-all               Run the full regression + global coverage report"
	@echo "    sim                   Alias for sim-all"
	@echo ""
	@echo "  Coverage"
	@echo "    coverage              Merge all UCDBs and produce txt + HTML reports"
	@echo "    coverage-class-<cls>  Coverage report from one class only"
	@echo ""
	@echo "  Reporting"
	@echo "    report                Aggregate per-TB results + coverage into summary.md"
	@echo "    report-<class>        Per-class summary"
	@echo ""
	@echo "  Maintenance"
	@echo "    clean                 Remove build/ directory entirely"
	@echo ""
	@echo "  Options (export or pass on command line)"
	@echo "    SAVE_WAVES=1          Dump WLF waveforms (debug only)"
	@echo "    COV_METRICS=...       Override coverage metrics (default: $(COV_METRICS))"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Information targets
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: list-classes list-tbs
list-classes:
	@echo "Requirement classes:"
	@for c in $(REQ_CLASSES); do echo "  - $$c"; done

list-tbs:
	@echo "Testbenches discovered:"
	@$(foreach tb,$(sort $(TB_NAMES)),echo "  $(tb)  (class $(TB_CLASS_$(tb)))";)

# Dynamic per-class info target: list-class-A, list-class-B, ...
define LIST_CLASS_RULE
.PHONY: list-class-$(1)
list-class-$(1):
	@echo "Testbenches in class $(1):"
	@for tb in $$(TBS_IN_CLASS_$(1)); do echo "  - $$$$tb"; done

endef
$(foreach c,$(REQ_CLASSES),$(eval $(call LIST_CLASS_RULE,$(c))))

# ─────────────────────────────────────────────────────────────────────────────
# Header compliance check (ECSS-E-ST-20-40C §A.2.1)
# Every test target depends on this — no simulation runs if a file is
# missing its header. Run independently with `make check-headers`.
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: check-headers
check-headers:
	@mkdir -p $(LOG_DIR)
	@echo "── ECSS header compliance check ──"
	@python3 $(HEADER_CHECK) \
	    --sources $(SRC_DIR) \
	    --testbenches $(REQ_TB_DIR) \
	    --log $(LOG_DIR)/header_check.log \
	    || (echo "FAIL: header check failed — see $(LOG_DIR)/header_check.log"; exit 1)
	@echo "PASS: all files have compliant headers"

# ─────────────────────────────────────────────────────────────────────────────
# Compilation
# Uses vcom -autoorder to resolve VHDL dependencies automatically.
# Packages are still compiled first to give vcom the type definitions
# it needs before encountering downstream consumers.
#
# Coverage instrumentation rules:
#   * Packages and RTL (src/)        compiled with $(COV_OPT)  → instrumented
#   * Testbenches (verification/)    compiled WITHOUT coverage → not measured
# This keeps coverage metrics meaningful — they reflect exercise of the RTL.
# ─────────────────────────────────────────────────────────────────────────────
$(WORK_DIR)/.compiled: check-headers $(ALL_RTL_SRCS) $(TB_FILES)
	@mkdir -p $(WORK_DIR) $(LOG_DIR)
	@echo "── Creating QuestaSim work library at $(WORK_DIR) ──"
	@cd $(BUILD_DIR) && $(VLIB) work > /dev/null
	@cd $(BUILD_DIR) && $(VMAP) work work > /dev/null
	@echo "── Compiling RTL packages [coverage: $(COV_METRICS)] ──"
	@cd $(BUILD_DIR) && $(VCOM) $(VCOM_RTL_FLAGS) -work work \
	    $(PKG_SRCS) > $(LOG_DIR)/compile_pkg.log 2>&1 \
	    || (cat $(LOG_DIR)/compile_pkg.log; exit 1)
	@echo "── Compiling RTL design (autoorder) [coverage: $(COV_METRICS)] ──"
	@cd $(BUILD_DIR) && $(VCOM) $(VCOM_RTL_FLAGS) -work work \
	    $(HDL_SRCS) > $(LOG_DIR)/compile_hdl.log 2>&1 \
	    || (cat $(LOG_DIR)/compile_hdl.log; exit 1)
	@echo "── Compiling testbenches (autoorder) [no coverage] ──"
	@cd $(BUILD_DIR) && $(VCOM) $(VCOM_TB_FLAGS) -work work \
	    $(TB_FILES) > $(LOG_DIR)/compile_tb.log 2>&1 \
	    || (cat $(LOG_DIR)/compile_tb.log; exit 1)
	@touch $@
	@echo "── Compilation OK ──"

.PHONY: compile
compile: $(WORK_DIR)/.compiled

# ─────────────────────────────────────────────────────────────────────────────
# Per-testbench simulation rule
# ----------------------------------------------------------------------------
# A testbench named pwm_generator_tb in class A produces:
#   build/reports/A/pwm_generator_tb.result      (structured assertion log)
#   build/log/A/pwm_generator_tb.log             (full QuestaSim transcript)
#   build/coverage/A/pwm_generator_tb.ucdb       (per-TB coverage database)
#
# The UCDB is captured by run_sim.tcl via `coverage save`. Coverage data
# does NOT affect testbench pass/fail — only assertion records do.
# ECSS-E-ST-20-40C §C.2.1 leaves coverage targets to the verification plan.
# ─────────────────────────────────────────────────────────────────────────────

# Recipe template — instantiated per class so the path is class-specific
define SIM_TB_RULE
$(REPORT_DIR)/$(1)/%.result: $(REQ_TB_DIR)/$(1)/%.vhd $(WORK_DIR)/.compiled
	@mkdir -p $(REPORT_DIR)/$(1) $(LOG_DIR)/$(1) $(WAVE_DIR)/$(1) $(COV_DIR)/$(1)
	@echo "── [$(1)] running $$*  ──"
	@cd $(BUILD_DIR) && $(VSIM) $(VSIM_FLAGS) \
	    -do "do $(RUN_SIM_TCL) $$* $(1) $(REPORT_DIR) $(WAVE_DIR) $(COV_DIR)" \
	    work.$$* \
	    > $(LOG_DIR)/$(1)/$$*.log 2>&1; \
	    sim_status=$$$$?; \
	    if [ $$$$sim_status -ne 0 ]; then \
	        echo "  FAIL: simulator exited with $$$$sim_status (see $(LOG_DIR)/$(1)/$$*.log)"; \
	        exit $$$$sim_status; \
	    fi
	@if [ ! -f $$@ ]; then \
	    echo "  FAIL: testbench did not produce a result file ($$@)"; \
	    exit 1; \
	fi
	@if grep -q "^FAIL" $$@; then \
	    echo "  FAIL: assertion failures (see $$@)"; \
	    grep "^FAIL" $$@ | sed 's/^/    /'; \
	    exit 1; \
	fi
	@if [ ! -f $(COV_DIR)/$(1)/$$*.ucdb ]; then \
	    echo "  WARN: no coverage database produced (expected $(COV_DIR)/$(1)/$$*.ucdb)"; \
	fi
	@echo "  PASS"
endef

# Instantiate the rule once per requirement class
$(foreach c,$(REQ_CLASSES),$(eval $(call SIM_TB_RULE,$(c))))

# ─────────────────────────────────────────────────────────────────────────────
# Convenience aliases: sim-<tb_name>  →  build the corresponding result file
# Each testbench gets its own alias regardless of which class it lives in.
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: $(addprefix sim-,$(TB_NAMES))
$(foreach tb,$(TB_NAMES),$(eval \
  sim-$(tb): $(REPORT_DIR)/$(TB_CLASS_$(tb))/$(tb).result))

# ─────────────────────────────────────────────────────────────────────────────
# Per-class regression: sim-class-A, sim-class-B, ...
#
# Each class regression runs every TB in that class, then merges only the
# UCDBs from that class into a per-class coverage report. This lets you see
# how well a single class of tests covers the RTL on its own — useful for
# identifying which RTL areas need more tests in a given class.
# ─────────────────────────────────────────────────────────────────────────────
define SIM_CLASS_RULE
.PHONY: sim-class-$(1)
sim-class-$(1): $(foreach tb,$(TBS_IN_CLASS_$(1)),$(REPORT_DIR)/$(1)/$(tb).result)
	@$$(MAKE) --no-print-directory coverage-class-$(1)
	@$$(MAKE) --no-print-directory report-$(1)

endef
$(foreach c,$(REQ_CLASSES),$(eval $(call SIM_CLASS_RULE,$(c))))

# ─────────────────────────────────────────────────────────────────────────────
# Full regression
# Runs every TB, merges all UCDBs, generates the global coverage report
# and the global Markdown summary.
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: sim-all sim
sim-all: $(foreach tb,$(TB_NAMES),$(REPORT_DIR)/$(TB_CLASS_$(tb))/$(tb).result)
	@$(MAKE) --no-print-directory coverage
	@$(MAKE) --no-print-directory report

sim: sim-all

# ─────────────────────────────────────────────────────────────────────────────
# Coverage merge & report
# ─────────────────────────────────────────────────────────────────────────────
# Coverage targets are decoupled from sim targets so they can be re-run
# without re-simulating. They consume whichever UCDB files happen to exist
# in $(COV_DIR) at the moment they run.
#
# Coverage NEVER fails the build. The targets succeed even when coverage
# is below any threshold — that policy is enforced at the verification-plan
# level, not at the build level. ECSS-E-ST-20-40C §C.2.1 requires only that
# the metrics are collected and reported.

# Find all UCDBs currently on disk (evaluated lazily each invocation)
ALL_UCDBS         = $(shell find $(COV_DIR) -name '*.ucdb' 2>/dev/null)

.PHONY: coverage
coverage:
	@if [ -z "$(strip $(ALL_UCDBS))" ]; then \
	    echo "── No UCDBs to merge — run a sim target first ──"; \
	    exit 0; \
	fi
	@mkdir -p $(COV_DIR)
	@echo "── Merging $$(echo $(ALL_UCDBS) | wc -w) coverage databases ──"
	@$(VCOVER) merge -64 -out $(COV_MERGED) $(ALL_UCDBS) \
	    > $(LOG_DIR)/coverage_merge.log 2>&1 \
	    || (cat $(LOG_DIR)/coverage_merge.log; \
	        echo "WARN: coverage merge failed — continuing without coverage"; \
	        exit 0)
	@echo "── Generating text coverage report ──"
	@$(VCOVER) report -details -all -output $(COV_REPORT_TXT) $(COV_MERGED) \
	    > $(LOG_DIR)/coverage_report.log 2>&1 \
	    || (cat $(LOG_DIR)/coverage_report.log; exit 0)
	@echo "── Generating HTML coverage report ──"
	@$(VCOVER) report -html -htmldir $(COV_REPORT_HTML) -details $(COV_MERGED) \
	    > $(LOG_DIR)/coverage_html.log 2>&1 \
	    || (cat $(LOG_DIR)/coverage_html.log; exit 0)
	@python3 $(PARSE_COVERAGE) \
	    --txt-report $(COV_REPORT_TXT) \
	    --output $(COV_DIR)/coverage_summary.md
	@echo "── Coverage report at $(COV_DIR) ──"

# Per-class coverage: merge only the UCDBs from one class
define COV_CLASS_RULE
.PHONY: coverage-class-$(1)
coverage-class-$(1):
	@if [ ! -d $(COV_DIR)/$(1) ] || [ -z "$$$$(ls $(COV_DIR)/$(1)/*.ucdb 2>/dev/null)" ]; then \
	    echo "── No UCDBs for class $(1) — run sim-class-$(1) first ──"; \
	    exit 0; \
	fi
	@mkdir -p $(COV_DIR)
	@echo "── Merging coverage for class $(1) ──"
	@$$(VCOVER) merge -64 -out $(COV_DIR)/merged_$(1).ucdb \
	    $(COV_DIR)/$(1)/*.ucdb \
	    > $(LOG_DIR)/coverage_merge_$(1).log 2>&1 \
	    || (cat $(LOG_DIR)/coverage_merge_$(1).log; exit 0)
	@$$(VCOVER) report -details -all \
	    -output $(COV_DIR)/coverage_$(1).txt \
	    $(COV_DIR)/merged_$(1).ucdb \
	    > $(LOG_DIR)/coverage_report_$(1).log 2>&1 \
	    || (cat $(LOG_DIR)/coverage_report_$(1).log; exit 0)
	@python3 $$(PARSE_COVERAGE) \
	    --txt-report $(COV_DIR)/coverage_$(1).txt \
	    --output $(COV_DIR)/coverage_$(1)_summary.md
	@echo "── Class $(1) coverage at $(COV_DIR)/coverage_$(1).txt ──"

endef
$(foreach c,$(REQ_CLASSES),$(eval $(call COV_CLASS_RULE,$(c))))

# ─────────────────────────────────────────────────────────────────────────────
# Reporting
# Aggregates per-TB results into a Markdown summary. When a coverage report
# is available (coverage_summary.md or coverage_<class>_summary.md), it is
# embedded into the corresponding requirements summary.
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: report
report:
	@python3 $(COLLECT_RESULTS) \
	    --report-dir $(REPORT_DIR) \
	    --coverage-md $(COV_DIR)/coverage_summary.md \
	    --output $(REPORT_DIR)/summary.md

# Per-class report: report-A, report-B, ...
define REPORT_CLASS_RULE
.PHONY: report-$(1)
report-$(1):
	@python3 $$(COLLECT_RESULTS) \
	    --report-dir $$(REPORT_DIR) \
	    --filter-class $(1) \
	    --coverage-md $$(COV_DIR)/coverage_$(1)_summary.md \
	    --output $$(REPORT_DIR)/summary_$(1).md

endef
$(foreach c,$(REQ_CLASSES),$(eval $(call REPORT_CLASS_RULE,$(c))))

# ─────────────────────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@echo "Removing build directory..."
	@rm -rf $(BUILD_DIR)
	@rm -f transcript modelsim.ini vsim.wlf *.vstf
	@echo "Clean complete."
