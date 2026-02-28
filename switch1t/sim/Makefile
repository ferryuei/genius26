# =============================================================================
# Makefile for 1.2Tbps 48x25G L2 Switch RTL Simulation
# =============================================================================

# Toolchain
VERILATOR = verilator
VERILATOR_FLAGS = --binary --trace -Wno-fatal --timing
VERILATOR_INCLUDES = -I../rtl

# Directories
RTL_DIR = ../rtl
TB_DIR = ../tb
OBJ_DIR = obj_dir
LOG_DIR = logs

# Package files
PKG_FILES = $(RTL_DIR)/switch_pkg.sv $(TB_DIR)/tb_pkg.sv

# Testbenches
TB_MAC = tb_mac_table
TB_VLAN = tb_vlan
TB_LAG = tb_lag_engine
TB_QOS = tb_qos
TB_PERF = tb_performance
TB_STORM = tb_storm_ctrl
TB_ACL = tb_acl_engine
TB_FC = tb_flow_ctrl
TB_PROTO = tb_protocol_engines

# Colors
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m

.PHONY: all clean help regression mac vlan lag qos perf storm acl fc proto
.PHONY: run_mac run_vlan run_lag run_qos run_perf run_storm run_acl run_fc run_proto

all: help

help:
	@echo "========================================"
	@echo "  1.2Tbps Switch RTL Build System"
	@echo "========================================"
	@echo ""
	@echo "Targets:"
	@echo "  make regression     - Run complete test suite"
	@echo ""
	@echo "Build individual tests:"
	@echo "  make mac            - Build MAC table test"
	@echo "  make vlan           - Build VLAN test"
	@echo "  make lag            - Build LAG test"
	@echo "  make qos            - Build QoS test"
	@echo "  make perf           - Build performance test"
	@echo "  make storm          - Build storm control test"
	@echo "  make acl            - Build ACL test"
	@echo "  make fc             - Build flow control test"
	@echo "  make proto          - Build protocol engines test"
	@echo ""
	@echo "Run individual tests:"
	@echo "  make run_mac        - Run MAC table test"
	@echo "  make run_vlan       - Run VLAN test"
	@echo "  make run_lag        - Run LAG test"
	@echo "  make run_qos        - Run QoS test"
	@echo "  make run_perf       - Run performance test"
	@echo "  make run_storm      - Run storm control test"
	@echo "  make run_acl        - Run ACL test"
	@echo "  make run_fc         - Run flow control test"
	@echo "  make run_proto      - Run protocol engines test"
	@echo ""
	@echo "  make clean          - Clean artifacts"
	@echo "========================================"

$(LOG_DIR):
	@mkdir -p $(LOG_DIR)

mac: $(OBJ_DIR)/V$(TB_MAC)

$(OBJ_DIR)/V$(TB_MAC): $(PKG_FILES) $(RTL_DIR)/mac_table.sv $(TB_DIR)/$(TB_MAC).sv
	@echo "$(BLUE)Building MAC Table Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_MAC) $(PKG_FILES) $(RTL_DIR)/mac_table.sv $(TB_DIR)/$(TB_MAC).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

vlan: $(OBJ_DIR)/V$(TB_VLAN)

$(OBJ_DIR)/V$(TB_VLAN): $(PKG_FILES) $(TB_DIR)/$(TB_VLAN).sv
	@echo "$(BLUE)Building VLAN Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_VLAN) $(PKG_FILES) $(TB_DIR)/$(TB_VLAN).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

lag: $(OBJ_DIR)/V$(TB_LAG)

$(OBJ_DIR)/V$(TB_LAG): $(PKG_FILES) $(RTL_DIR)/lag_engine.sv $(TB_DIR)/$(TB_LAG).sv
	@echo "$(BLUE)Building LAG Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_LAG) $(PKG_FILES) $(RTL_DIR)/lag_engine.sv $(TB_DIR)/$(TB_LAG).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

qos: $(OBJ_DIR)/V$(TB_QOS)

$(OBJ_DIR)/V$(TB_QOS): $(PKG_FILES) $(RTL_DIR)/egress_scheduler.sv $(TB_DIR)/$(TB_QOS).sv
	@echo "$(BLUE)Building QoS Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_QOS) $(PKG_FILES) $(RTL_DIR)/egress_scheduler.sv $(TB_DIR)/$(TB_QOS).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

perf: $(OBJ_DIR)/V$(TB_PERF)

$(OBJ_DIR)/V$(TB_PERF): $(PKG_FILES) $(TB_DIR)/$(TB_PERF).sv
	@echo "$(BLUE)Building Performance Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_PERF) $(PKG_FILES) $(TB_DIR)/$(TB_PERF).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

storm: $(OBJ_DIR)/V$(TB_STORM)

$(OBJ_DIR)/V$(TB_STORM): $(PKG_FILES) $(TB_DIR)/$(TB_STORM).sv
	@echo "$(BLUE)Building Storm Control Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_STORM) $(PKG_FILES) $(TB_DIR)/$(TB_STORM).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

acl: $(OBJ_DIR)/V$(TB_ACL)

$(OBJ_DIR)/V$(TB_ACL): $(PKG_FILES) $(RTL_DIR)/acl_engine.sv $(TB_DIR)/$(TB_ACL).sv
	@echo "$(BLUE)Building ACL Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_ACL) $(PKG_FILES) $(RTL_DIR)/acl_engine.sv $(TB_DIR)/$(TB_ACL).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

fc: $(OBJ_DIR)/V$(TB_FC)

$(OBJ_DIR)/V$(TB_FC): $(PKG_FILES) $(RTL_DIR)/flow_control.sv $(TB_DIR)/$(TB_FC).sv
	@echo "$(BLUE)Building Flow Control Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_FC) $(PKG_FILES) $(RTL_DIR)/flow_control.sv $(TB_DIR)/$(TB_FC).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

proto: $(OBJ_DIR)/V$(TB_PROTO)

$(OBJ_DIR)/V$(TB_PROTO): $(PKG_FILES) $(RTL_DIR)/rstp_engine.sv $(RTL_DIR)/lacp_engine.sv \
                          $(RTL_DIR)/lldp_engine.sv $(TB_DIR)/$(TB_PROTO).sv
	@echo "$(BLUE)Building Protocol Engines Test...$(NC)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDES) \
		--top-module $(TB_PROTO) $(PKG_FILES) $(RTL_DIR)/rstp_engine.sv \
		$(RTL_DIR)/lacp_engine.sv $(RTL_DIR)/lldp_engine.sv $(TB_DIR)/$(TB_PROTO).sv
	@echo "$(GREEN)✓ Build OK$(NC)"

run_mac: mac $(LOG_DIR)
	@echo "$(BLUE)Running MAC Table Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_MAC) 2>&1 | tee $(LOG_DIR)/$(TB_MAC).log
	@echo "$(GREEN)✓ Test complete$(NC)"

run_vlan: vlan $(LOG_DIR)
	@echo "$(BLUE)Running VLAN Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_VLAN) 2>&1 | tee $(LOG_DIR)/$(TB_VLAN).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_VLAN).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_lag: lag $(LOG_DIR)
	@echo "$(BLUE)Running LAG Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_LAG) 2>&1 | tee $(LOG_DIR)/$(TB_LAG).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_LAG).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_qos: qos $(LOG_DIR)
	@echo "$(BLUE)Running QoS Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_QOS) 2>&1 | tee $(LOG_DIR)/$(TB_QOS).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_QOS).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_perf: perf $(LOG_DIR)
	@echo "$(BLUE)Running Performance Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_PERF) 2>&1 | tee $(LOG_DIR)/$(TB_PERF).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_PERF).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_storm: storm $(LOG_DIR)
	@echo "$(BLUE)Running Storm Control Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_STORM) 2>&1 | tee $(LOG_DIR)/$(TB_STORM).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_STORM).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_acl: acl $(LOG_DIR)
	@echo "$(BLUE)Running ACL Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_ACL) 2>&1 | tee $(LOG_DIR)/$(TB_ACL).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_ACL).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_fc: fc $(LOG_DIR)
	@echo "$(BLUE)Running Flow Control Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_FC) 2>&1 | tee $(LOG_DIR)/$(TB_FC).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_FC).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

run_proto: proto $(LOG_DIR)
	@echo "$(BLUE)Running Protocol Engines Test...$(NC)"
	@$(OBJ_DIR)/V$(TB_PROTO) 2>&1 | tee $(LOG_DIR)/$(TB_PROTO).log
	@if grep -q "PASSED" $(LOG_DIR)/$(TB_PROTO).log; then \
		echo "$(GREEN)✓ Test PASSED$(NC)"; \
	else \
		echo "$(RED)✗ Test FAILED$(NC)"; exit 1; \
	fi

regression: clean
	@echo "========================================"; \
	echo "  Switch RTL Regression Suite"; \
	echo "  Enhanced Coverage (9 Test Categories)"; \
	echo "========================================"; \
	$(MAKE) --no-print-directory run_mac || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_vlan || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_lag || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_qos || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_perf || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_storm || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_acl || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_fc || true; \
	echo ""; \
	$(MAKE) --no-print-directory run_proto || true; \
	echo "========================================"; \
	echo "  Regression Complete"; \
	echo "  Target Coverage: 90%+"; \
	echo "========================================"

clean:
	@echo "$(BLUE)Cleaning...$(NC)"
	@rm -rf $(OBJ_DIR) *.vcd *.log $(LOG_DIR)
	@echo "$(GREEN)✓ Clean OK$(NC)"
