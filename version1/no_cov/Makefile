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

# ── TCL scripts ─────────────────────────────────────────────────────────────
COMPILE_TCL     := $(SCRIPTS_DIR)/compile.tcl
RUN_SIM_TCL     := $(SCRIPTS_DIR)/run_sim.tcl

# ── Python tools ────────────────────────────────────────────────────────────
HEADER_CHECK    := $(TOOLS_DIR)/header_check.py
COLLECT_RESULTS := $(TOOLS_DIR)/collect_results.py

# ── QuestaSim configuration ─────────────────────────────────────────────────
VLIB            := vlib
VMAP            := vmap
VCOM            := vcom
VSIM            := vsim

VCOM_FLAGS      := -2008 -pedanticerrors -mixedsvvh -autoorder
VSIM_FLAGS      := -batch -voptargs=+acc -t 1ns

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
	@echo ""
	@echo "  Simulation"
	@echo "    sim-<tb_name>         Run one testbench (e.g. sim-pwm_generator_tb)"
	@echo "    sim-class-<class>     Run all TBs of one class (e.g. sim-class-A)"
	@echo "    sim-all               Run the full regression"
	@echo "    sim                   Alias for sim-all"
	@echo ""
	@echo "  Reporting"
	@echo "    report                Aggregate per-TB results into one report"
	@echo "    report-<class>        Aggregate results filtered by class"
	@echo ""
	@echo "  Maintenance"
	@echo "    clean                 Remove build/ directory entirely"
	@echo ""
	@echo "  Options (export or pass on command line)"
	@echo "    SAVE_WAVES=1          Dump WLF waveforms (debug only)"
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
# ─────────────────────────────────────────────────────────────────────────────
$(WORK_DIR)/.compiled: check-headers $(ALL_RTL_SRCS) $(TB_FILES)
	@mkdir -p $(WORK_DIR) $(LOG_DIR)
	@echo "── Creating QuestaSim work library at $(WORK_DIR) ──"
	@cd $(BUILD_DIR) && $(VLIB) work > /dev/null
	@cd $(BUILD_DIR) && $(VMAP) work work > /dev/null
	@echo "── Compiling RTL packages ──"
	@cd $(BUILD_DIR) && $(VCOM) $(VCOM_FLAGS) -work work \
	    $(PKG_SRCS) > $(LOG_DIR)/compile_pkg.log 2>&1 \
	    || (cat $(LOG_DIR)/compile_pkg.log; exit 1)
	@echo "── Compiling RTL design (autoorder) ──"
	@cd $(BUILD_DIR) && $(VCOM) $(VCOM_FLAGS) -work work \
	    $(HDL_SRCS) > $(LOG_DIR)/compile_hdl.log 2>&1 \
	    || (cat $(LOG_DIR)/compile_hdl.log; exit 1)
	@echo "── Compiling testbenches (autoorder) ──"
	@cd $(BUILD_DIR) && $(VCOM) $(VCOM_FLAGS) -work work \
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
#
# We declare the per-TB pattern rule once, parameterised by class via the
# eval-foreach pattern, so adding a class requires no Makefile changes.
# ─────────────────────────────────────────────────────────────────────────────

# Recipe template — instantiated per class so the path is class-specific
define SIM_TB_RULE
$(REPORT_DIR)/$(1)/%.result: $(REQ_TB_DIR)/$(1)/%.vhd $(WORK_DIR)/.compiled
	@mkdir -p $(REPORT_DIR)/$(1) $(LOG_DIR)/$(1) $(WAVE_DIR)/$(1)
	@echo "── [$(1)] running $$*  ──"
	@cd $(BUILD_DIR) && $(VSIM) $(VSIM_FLAGS) \
	    -do "do $(RUN_SIM_TCL) $$* $(1) $(REPORT_DIR) $(WAVE_DIR)" \
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
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: $(addprefix sim-class-,$(REQ_CLASSES))
$(foreach c,$(REQ_CLASSES),$(eval \
  sim-class-$(c): $(foreach tb,$(TBS_IN_CLASS_$(c)),$(REPORT_DIR)/$(c)/$(tb).result)))

# ─────────────────────────────────────────────────────────────────────────────
# Full regression
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: sim-all sim
sim-all: $(foreach tb,$(TB_NAMES),$(REPORT_DIR)/$(TB_CLASS_$(tb))/$(tb).result)
	@$(MAKE) --no-print-directory report

sim: sim-all

# ─────────────────────────────────────────────────────────────────────────────
# Reporting
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: report
report:
	@python3 $(COLLECT_RESULTS) \
	    --report-dir $(REPORT_DIR) \
	    --output $(REPORT_DIR)/summary.md

# Per-class report: report-A, report-B, ...
define REPORT_CLASS_RULE
.PHONY: report-$(1)
report-$(1):
	@python3 $$(COLLECT_RESULTS) \
	    --report-dir $$(REPORT_DIR) \
	    --filter-class $(1) \
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
