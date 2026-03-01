#******************************************************************************
# Makefile for NPU RTL Simulation
# Tool: Verilator and Icarus Verilog
# Description: Build and run testbenches
#******************************************************************************

# Simulator selection (verilator or iverilog)
SIM ?= verilator

# Project directories
RTL_DIR = rtl
TB_DIR = tb
RUN_DIR = run
WAVE_DIR = $(RUN_DIR)/waves
LOG_DIR = $(RUN_DIR)/logs

# Verilator settings
VERILATOR = verilator
VERILATOR_FLAGS_BASE = \
	--cc \
	--exe \
	--build \
	--timing \
	--trace \
	-Wall \
	-Wno-fatal \
	-Wno-UNUSED \
	-Wno-UNOPTFLAT \
	-Wno-WIDTHTRUNC

# Icarus Verilog settings
IVERILOG = iverilog
IVERILOG_FLAGS = -g2012 -Wall -Winfloop -DIVERILOG
VVP = vvp
VVP_FLAGS =

# Compiler settings
CXX = g++
CXXFLAGS = -std=c++14 -O2

# Default target
.PHONY: all
all: help

#==============================================================================
# Help
#==============================================================================

.PHONY: help
help:
	@echo "========================================="
	@echo "  NPU RTL Simulation Makefile"
	@echo "========================================="
	@echo ""
	@echo "Available targets:"
	@echo "  make tb_vp_pe         - Run PE testbench"
	@echo "  make tb_m20k_buffer   - Run M20K buffer testbench"
	@echo "  make tb_npu_top       - Run top-level testbench"
	@echo "  make all_tests        - Run all testbenches"
	@echo ""
	@echo "  make clean            - Clean build artifacts"
	@echo "  make clean_waves      - Clean waveforms"
	@echo "  make clean_all        - Clean everything"
	@echo ""
	@echo "Simulator Selection:"
	@echo "  SIM=verilator         - Use Verilator (default)"
	@echo "  SIM=iverilog          - Use Icarus Verilog"
	@echo ""
	@echo "Examples:"
	@echo "  make tb_vp_pe                    # Verilator (default)"
	@echo "  make tb_vp_pe SIM=iverilog       # Icarus Verilog"
	@echo "  make all_tests SIM=iverilog      # All tests with iverilog"
	@echo ""

#==============================================================================
# Test: Variable Precision PE
#==============================================================================

TB_VP_PE = tb_vp_pe
OBJ_VP_PE = $(RUN_DIR)/obj_$(TB_VP_PE)

ifeq ($(SIM),iverilog)
# Icarus Verilog targets
.PHONY: tb_vp_pe
tb_vp_pe: $(RUN_DIR)/$(TB_VP_PE).vvp
	@echo "========================================="
	@echo "  Running $(TB_VP_PE) with Icarus Verilog"
	@echo "========================================="
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && $(VVP) $(VVP_FLAGS) $(TB_VP_PE).vvp 2>&1 | tee logs/$(TB_VP_PE).log
	@echo ""
	@echo "Simulation complete. Check:"
	@echo "  Log:      $(LOG_DIR)/$(TB_VP_PE).log"
	@echo "  Waveform: $(WAVE_DIR)/$(TB_VP_PE).vcd"
	@echo ""

$(RUN_DIR)/$(TB_VP_PE).vvp: $(TB_DIR)/$(TB_VP_PE).v $(RTL_DIR)/pe/vp_pe.v
	@echo "Building $(TB_VP_PE) with Icarus Verilog..."
	@mkdir -p $(RUN_DIR) $(WAVE_DIR) $(LOG_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) \
		-o $(RUN_DIR)/$(TB_VP_PE).vvp \
		$(TB_DIR)/$(TB_VP_PE).v \
		$(RTL_DIR)/pe/vp_pe.v

else
# Verilator targets
.PHONY: tb_vp_pe
tb_vp_pe: $(OBJ_VP_PE)/V$(TB_VP_PE)
	@echo "========================================="
	@echo "  Running $(TB_VP_PE) with Verilator"
	@echo "========================================="
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && ./obj_$(TB_VP_PE)/V$(TB_VP_PE) +trace 2>&1 | tee logs/$(TB_VP_PE).log
	@echo ""
	@echo "Simulation complete. Check:"
	@echo "  Log:      $(LOG_DIR)/$(TB_VP_PE).log"
	@echo "  Waveform: $(WAVE_DIR)/$(TB_VP_PE).vcd"
	@echo ""

$(OBJ_VP_PE)/V$(TB_VP_PE): $(TB_DIR)/$(TB_VP_PE).v $(RTL_DIR)/pe/vp_pe.v $(TB_DIR)/$(TB_VP_PE)_main.cpp
	@echo "Building $(TB_VP_PE) with Verilator..."
	@mkdir -p $(OBJ_VP_PE)
	$(VERILATOR) $(VERILATOR_FLAGS_BASE) \
		--top-module $(TB_VP_PE) \
		-Mdir $(OBJ_VP_PE) \
		$(TB_DIR)/$(TB_VP_PE).v \
		$(RTL_DIR)/pe/vp_pe.v \
		$(TB_DIR)/$(TB_VP_PE)_main.cpp
endif

#==============================================================================
# Test: M20K Buffer
#==============================================================================

TB_M20K = tb_m20k_buffer
OBJ_M20K = $(RUN_DIR)/obj_$(TB_M20K)

ifeq ($(SIM),iverilog)
# Icarus Verilog targets
.PHONY: tb_m20k_buffer
tb_m20k_buffer: $(RUN_DIR)/$(TB_M20K).vvp
	@echo "========================================="
	@echo "  Running $(TB_M20K) with Icarus Verilog"
	@echo "========================================="
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && $(VVP) $(VVP_FLAGS) $(TB_M20K).vvp 2>&1 | tee logs/$(TB_M20K).log
	@echo ""
	@echo "Simulation complete. Check:"
	@echo "  Log:      $(LOG_DIR)/$(TB_M20K).log"
	@echo "  Waveform: $(WAVE_DIR)/$(TB_M20K).vcd"
	@echo ""

$(RUN_DIR)/$(TB_M20K).vvp: $(TB_DIR)/$(TB_M20K).v $(RTL_DIR)/memory/m20k_buffer.v
	@echo "Building $(TB_M20K) with Icarus Verilog..."
	@mkdir -p $(RUN_DIR) $(WAVE_DIR) $(LOG_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) \
		-o $(RUN_DIR)/$(TB_M20K).vvp \
		$(TB_DIR)/$(TB_M20K).v \
		$(RTL_DIR)/memory/m20k_buffer.v

else
# Verilator targets
.PHONY: tb_m20k_buffer
tb_m20k_buffer: $(OBJ_M20K)/V$(TB_M20K)
	@echo "========================================="
	@echo "  Running $(TB_M20K) with Verilator"
	@echo "========================================="
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && ./obj_$(TB_M20K)/V$(TB_M20K) +trace 2>&1 | tee logs/$(TB_M20K).log
	@echo ""
	@echo "Simulation complete. Check:"
	@echo "  Log:      $(LOG_DIR)/$(TB_M20K).log"
	@echo "  Waveform: $(WAVE_DIR)/$(TB_M20K).vcd"
	@echo ""

$(OBJ_M20K)/V$(TB_M20K): $(TB_DIR)/$(TB_M20K).v $(RTL_DIR)/memory/m20k_buffer.v $(TB_DIR)/$(TB_M20K)_main.cpp
	@echo "Building $(TB_M20K) with Verilator..."
	@mkdir -p $(OBJ_M20K)
	$(VERILATOR) $(VERILATOR_FLAGS_BASE) \
		--top-module $(TB_M20K) \
		-Mdir $(OBJ_M20K) \
		$(TB_DIR)/$(TB_M20K).v \
		$(RTL_DIR)/memory/m20k_buffer.v \
		$(TB_DIR)/$(TB_M20K)_main.cpp
endif

#==============================================================================
# Test: NPU Top (Full System)
#==============================================================================

TB_TOP = tb_npu_top
OBJ_TOP = $(RUN_DIR)/obj_$(TB_TOP)

# RTL source files for top-level
RTL_SOURCES = \
	$(RTL_DIR)/pe/vp_pe.v \
	$(RTL_DIR)/pe/systolic_array.v \
	$(RTL_DIR)/memory/m20k_buffer.v \
	$(RTL_DIR)/dma/dma_engine.v \
	$(RTL_DIR)/control/control_unit.v \
	$(RTL_DIR)/datapath/inference_controller.v \
	$(RTL_DIR)/datapath/dma_to_m20k_bridge.v \
	$(RTL_DIR)/datapath/activation_feeder.v \
	$(RTL_DIR)/datapath/result_collector.v \
	$(RTL_DIR)/datapath/sfu_datapath_bridge.v \
	$(RTL_DIR)/sfu/sfu_unit_enhanced.v \
	$(RTL_DIR)/ip_models/intel_ip_models.v \
	$(RTL_DIR)/top/npu_top_integrated.v

ifeq ($(SIM),iverilog)
# Icarus Verilog targets
.PHONY: tb_npu_top
tb_npu_top: $(RUN_DIR)/$(TB_TOP).vvp
	@echo "========================================="
	@echo "  Running $(TB_TOP) with Icarus Verilog"
	@echo "========================================="
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && $(VVP) $(VVP_FLAGS) $(TB_TOP).vvp 2>&1 | tee logs/$(TB_TOP).log
	@echo ""
	@echo "Simulation complete. Check:"
	@echo "  Log:      $(LOG_DIR)/$(TB_TOP).log"
	@echo "  Waveform: $(WAVE_DIR)/$(TB_TOP).vcd"
	@echo ""

$(RUN_DIR)/$(TB_TOP).vvp: $(TB_DIR)/$(TB_TOP).v $(RTL_SOURCES)
	@echo "Building $(TB_TOP) with Icarus Verilog..."
	@mkdir -p $(RUN_DIR) $(WAVE_DIR) $(LOG_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) \
		-o $(RUN_DIR)/$(TB_TOP).vvp \
		$(TB_DIR)/$(TB_TOP).v \
		$(RTL_SOURCES)

else
# Verilator targets
.PHONY: tb_npu_top
tb_npu_top: $(OBJ_TOP)/V$(TB_TOP)
	@echo "========================================="
	@echo "  Running $(TB_TOP) with Verilator"
	@echo "========================================="
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && ./obj_$(TB_TOP)/V$(TB_TOP) +trace 2>&1 | tee logs/$(TB_TOP).log
	@echo ""
	@echo "Simulation complete. Check:"
	@echo "  Log:      $(LOG_DIR)/$(TB_TOP).log"
	@echo "  Waveform: $(WAVE_DIR)/$(TB_TOP).vcd"
	@echo ""

$(OBJ_TOP)/V$(TB_TOP): $(TB_DIR)/$(TB_TOP).v $(RTL_SOURCES) $(TB_DIR)/$(TB_TOP)_main.cpp
	@echo "Building $(TB_TOP) with Verilator..."
	@mkdir -p $(OBJ_TOP)
	$(VERILATOR) $(VERILATOR_FLAGS_BASE) \
		--top-module $(TB_TOP) \
		-Mdir $(OBJ_TOP) \
		$(TB_DIR)/$(TB_TOP).v \
		$(RTL_SOURCES) \
		$(TB_DIR)/$(TB_TOP)_main.cpp
endif

#==============================================================================
# Run All Tests
#==============================================================================

.PHONY: all_tests
all_tests:
	@echo "========================================="
	@echo "  Running All Testbenches"
	@echo "========================================="
	@echo ""
	@$(MAKE) tb_vp_pe
	@$(MAKE) tb_m20k_buffer
	@$(MAKE) tb_npu_top
	@echo ""
	@echo "========================================="
	@echo "  All Tests Complete"
	@echo "========================================="
	@echo "Check logs in $(LOG_DIR)/"
	@echo "Check waveforms in $(WAVE_DIR)/"
	@echo ""

#==============================================================================
# Lint (Static Analysis)
#==============================================================================

.PHONY: lint
lint:
	@echo "Running Verilator lint on RTL..."
	$(VERILATOR) --lint-only \
		-Wall \
		$(RTL_SOURCES)

#==============================================================================
# View Waveforms
#==============================================================================

.PHONY: view_vp_pe
view_vp_pe:
	@echo "Opening waveform for $(TB_VP_PE)..."
	@if command -v gtkwave > /dev/null; then \
		gtkwave $(WAVE_DIR)/$(TB_VP_PE).vcd & \
	else \
		echo "GTKWave not found. Install with: sudo apt install gtkwave"; \
	fi

.PHONY: view_m20k
view_m20k:
	@echo "Opening waveform for $(TB_M20K)..."
	@if command -v gtkwave > /dev/null; then \
		gtkwave $(WAVE_DIR)/$(TB_M20K).vcd & \
	else \
		echo "GTKWave not found. Install with: sudo apt install gtkwave"; \
	fi

.PHONY: view_top
view_top:
	@echo "Opening waveform for $(TB_TOP)..."
	@if command -v gtkwave > /dev/null; then \
		gtkwave $(WAVE_DIR)/$(TB_TOP).vcd & \
	else \
		echo "GTKWave not found. Install with: sudo apt install gtkwave"; \
	fi

#==============================================================================
# Clean
#==============================================================================

.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(RUN_DIR)/obj_*
	@rm -f $(RUN_DIR)/*.vvp
	@rm -f $(LOG_DIR)/*.log
	@echo "Clean complete."

.PHONY: clean_waves
clean_waves:
	@echo "Cleaning waveforms..."
	@rm -f $(WAVE_DIR)/*.vcd
	@rm -f $(WAVE_DIR)/*.fst
	@echo "Waveforms cleaned."

.PHONY: clean_all
clean_all: clean clean_waves
	@echo "Cleaning all build products..."
	@rm -rf $(RUN_DIR)
	@echo "All clean."

#==============================================================================
# Info
#==============================================================================

.PHONY: info
info:
	@echo "Project Information"
	@echo "==================="
	@echo "Simulator:       $(SIM)"
	@echo "RTL Directory:   $(RTL_DIR)"
	@echo "TB Directory:    $(TB_DIR)"
	@echo "Run Directory:   $(RUN_DIR)"
	@echo ""
	@echo "Tool Availability:"
	@echo "  Verilator:     $(shell which $(VERILATOR) 2>/dev/null || echo 'Not found')"
	@echo "  Verilator Ver: $(shell $(VERILATOR) --version 2>/dev/null | head -1 || echo 'N/A')"
	@echo "  Icarus Ver:    $(shell $(IVERILOG) -V 2>/dev/null | head -1 || echo 'Not found')"
	@echo "  GTKWave:       $(shell which gtkwave 2>/dev/null || echo 'Not found')"
	@echo ""
	@echo "RTL Files:       $(shell ls -1 $(RTL_DIR)/*/*.v 2>/dev/null | wc -l)"
	@echo "Testbenches:     $(shell ls -1 $(TB_DIR)/tb_*.v 2>/dev/null | wc -l)"
	@echo ""

#==============================================================================
# Dependencies
#==============================================================================

.PHONY: check_deps
check_deps:
	@echo "Checking dependencies..."
	@if [ "$(SIM)" = "iverilog" ]; then \
		command -v $(IVERILOG) >/dev/null 2>&1 || \
			(echo "ERROR: Icarus Verilog not found. Install with:"; \
			 echo "  sudo apt install iverilog"; exit 1); \
		command -v $(VVP) >/dev/null 2>&1 || \
			(echo "ERROR: vvp not found. Should be installed with iverilog."; exit 1); \
	else \
		command -v $(VERILATOR) >/dev/null 2>&1 || \
			(echo "ERROR: Verilator not found. Install with:"; \
			 echo "  sudo apt install verilator"; exit 1); \
		command -v $(CXX) >/dev/null 2>&1 || \
			(echo "ERROR: g++ not found. Install with:"; \
			 echo "  sudo apt install g++"; exit 1); \
	fi
	@echo "All dependencies satisfied."

#==============================================================================
# Phony Targets
#==============================================================================

.PHONY: all help clean clean_waves clean_all info check_deps lint \
        tb_vp_pe tb_m20k_buffer tb_npu_top all_tests \
        view_vp_pe view_m20k view_top
