#==============================================================================
# biRISC-V 完整设计 DFT/ATPG 流程 Makefile
#
# 综合完整的 riscv_core 设计（包含所有子模块）
#==============================================================================

# 工具路径
YOSYS       := yosys
PYTHON      := python3 -u

# 目录定义
TOP_DIR     := $(shell pwd)
RTL_DIR     := $(TOP_DIR)/../src
SW_DIR      := $(TOP_DIR)/../../software
SYN_DIR     := $(TOP_DIR)/syn
DFT_DIR     := $(TOP_DIR)/dft
ATPG_DIR    := $(TOP_DIR)/atpg

# 设计配置 - 完整核心设计
DESIGN      := riscv_core
TOP_MODULE  := riscv_core

# 所有RTL文件 (按依赖顺序)
RTL_FILES   := $(RTL_DIR)/core/biriscv_defs.v \
               $(RTL_DIR)/core/biriscv_alu.v \
               $(RTL_DIR)/core/biriscv_csr.v \
               $(RTL_DIR)/core/biriscv_csr_regfile.v \
               $(RTL_DIR)/core/biriscv_decode.v \
               $(RTL_DIR)/core/biriscv_decoder.v \
               $(RTL_DIR)/core/biriscv_divider.v \
               $(RTL_DIR)/core/biriscv_exec.v \
               $(RTL_DIR)/core/biriscv_fetch.v \
               $(RTL_DIR)/core/biriscv_frontend.v \
               $(RTL_DIR)/core/biriscv_issue.v \
               $(RTL_DIR)/core/biriscv_lsu.v \
               $(RTL_DIR)/core/biriscv_mmu.v \
               $(RTL_DIR)/core/biriscv_multiplier.v \
               $(RTL_DIR)/core/biriscv_npc.v \
               $(RTL_DIR)/core/biriscv_pipe_ctrl.v \
               $(RTL_DIR)/core/biriscv_regfile.v \
               $(RTL_DIR)/core/biriscv_xilinx_2r1w.v \
               $(RTL_DIR)/core/riscv_core.v

# DFT配置
NUM_CHAINS  := 16
ENABLE_EDT  := 0

# ATPG配置
MAX_PATTERNS    := 1000
TARGET_COVERAGE := 90
ALGORITHM       := auto

# 输出文件
SYNTH_VERILOG   := $(SYN_DIR)/$(DESIGN)_synth.v
SYNTH_BENCH     := $(SYN_DIR)/$(DESIGN).bench
DFT_BENCH       := $(DFT_DIR)/$(DESIGN)_dft.bench
DFT_VERILOG     := $(DFT_DIR)/$(DESIGN)_dft.v
DFT_SCANDEF     := $(DFT_DIR)/$(DESIGN).scandef
ATPG_STIL       := $(ATPG_DIR)/$(DESIGN).stil
ATPG_REPORT     := $(ATPG_DIR)/$(DESIGN)_atpg.rpt

#==============================================================================
# 主目标
#==============================================================================
.PHONY: all clean synth dft atpg report help

all: synth dft atpg report
	@echo ""
	@echo "=============================================="
	@echo "  biRISC-V 完整DFT/ATPG 流程完成!"
	@echo "=============================================="

help:
	@echo "=============================================="
	@echo "  biRISC-V 完整设计 DFT/ATPG"
	@echo "=============================================="
	@echo ""
	@echo "目标:"
	@echo "  make all          - 完整流程 (综合+DFT+ATPG)"
	@echo "  make synth        - Yosys综合"
	@echo "  make dft          - Scan Chain插入"
	@echo "  make atpg         - ATPG测试向量生成"
	@echo "  make report       - 生成报告"
	@echo "  make clean        - 清理输出"
	@echo ""
	@echo "配置:"
	@echo "  DESIGN=$(DESIGN)"
	@echo "  NUM_CHAINS=$(NUM_CHAINS)"
	@echo "  RTL文件数: $(words $(RTL_FILES))"

#==============================================================================
# Step 1: Yosys 综合 (完整设计)
#==============================================================================
synth: $(SYNTH_BENCH)
	@echo "[SYNTH] 完整设计综合完成"

$(SYNTH_BENCH): $(SYNTH_VERILOG)
	@echo "[SYNTH] 转换Verilog到BENCH格式..."
	$(PYTHON) $(SW_DIR)/verilog2bench.py $(SYNTH_VERILOG) $(SYNTH_BENCH)
	@echo "[SYNTH] BENCH转换完成"

$(SYNTH_VERILOG): $(RTL_FILES) | $(SYN_DIR)
	@echo "=============================================="
	@echo "[SYNTH] 综合完整 $(DESIGN) 设计"
	@echo "[SYNTH] RTL文件数: $(words $(RTL_FILES))"
	@echo "=============================================="
	@echo "# Yosys synthesis script for $(DESIGN)" > $(SYN_DIR)/_synth.ys
	@for f in $(RTL_FILES); do echo "read_verilog -sv $$f" >> $(SYN_DIR)/_synth.ys; done
	@echo "" >> $(SYN_DIR)/_synth.ys
	@echo "# Hierarchy and elaboration" >> $(SYN_DIR)/_synth.ys
	@echo "hierarchy -check -top $(TOP_MODULE)" >> $(SYN_DIR)/_synth.ys
	@echo "" >> $(SYN_DIR)/_synth.ys
	@echo "# Synthesis" >> $(SYN_DIR)/_synth.ys
	@echo "synth -top $(TOP_MODULE)" >> $(SYN_DIR)/_synth.ys
	@echo "" >> $(SYN_DIR)/_synth.ys
	@echo "# Technology mapping" >> $(SYN_DIR)/_synth.ys
	@echo "abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX" >> $(SYN_DIR)/_synth.ys
	@echo "clean" >> $(SYN_DIR)/_synth.ys
	@echo "" >> $(SYN_DIR)/_synth.ys
	@echo "# Output" >> $(SYN_DIR)/_synth.ys
	@echo "write_verilog -noattr $(SYNTH_VERILOG)" >> $(SYN_DIR)/_synth.ys
	@echo "[SYNTH] 开始Yosys综合 (可能需要几分钟)..."
	cd $(SYN_DIR) && $(YOSYS) _synth.ys 2>&1 | tee synth.log
	@echo "[SYNTH] Yosys综合完成"

$(SYN_DIR):
	@mkdir -p $(SYN_DIR)

#==============================================================================
# Step 2: DFT Scan Chain 插入
#==============================================================================
dft: $(DFT_BENCH)
	@echo "[DFT] Scan Chain插入完成"

$(DFT_BENCH): $(SYNTH_BENCH) | $(DFT_DIR)
	@echo "=============================================="
	@echo "[DFT] 插入Scan Chain"
	@echo "[DFT] 链数: $(NUM_CHAINS)"
	@echo "=============================================="
ifeq ($(ENABLE_EDT),1)
	$(PYTHON) $(SW_DIR)/scan_insert.py $(SYNTH_BENCH) \
		-o $(DFT_DIR)/$(DESIGN)_dft \
		-f both \
		--scan-def $(DFT_SCANDEF) \
		--num-chains $(NUM_CHAINS) \
		--enable-edt \
		2>&1 | tee $(DFT_DIR)/$(DESIGN)_dft.rpt
else
	$(PYTHON) $(SW_DIR)/scan_insert.py $(SYNTH_BENCH) \
		-o $(DFT_DIR)/$(DESIGN)_dft \
		-f both \
		--scan-def $(DFT_SCANDEF) \
		--num-chains $(NUM_CHAINS) \
		2>&1 | tee $(DFT_DIR)/$(DESIGN)_dft.rpt
endif

$(DFT_DIR):
	@mkdir -p $(DFT_DIR)

#==============================================================================
# Step 3: ATPG 测试向量生成
#==============================================================================
atpg: $(ATPG_STIL)
	@echo "[ATPG] 测试向量生成完成"

$(ATPG_STIL): $(SYNTH_BENCH) | $(ATPG_DIR)
	@echo "=============================================="
	@echo "[ATPG] 生成测试向量"
	@echo "[ATPG] 算法: $(ALGORITHM)"
	@echo "[ATPG] 最大向量: $(MAX_PATTERNS)"
	@echo "=============================================="
	$(PYTHON) $(SW_DIR)/atpg.py $(SYNTH_BENCH) \
		--scan \
		--algorithm $(ALGORITHM) \
		--parallel \
		-n $(MAX_PATTERNS) \
		-c $(TARGET_COVERAGE) \
		-o $(ATPG_STIL) \
		-r stil \
		2>&1 | tee $(ATPG_REPORT)

$(ATPG_DIR):
	@mkdir -p $(ATPG_DIR)

#==============================================================================
# 报告生成
#==============================================================================
report:
	@echo ""
	@echo "=============================================="
	@echo "      $(DESIGN) 完整设计 DFT/ATPG 报告"
	@echo "=============================================="
	@echo ""
	@echo ">>> 综合统计 <<<"
	@if [ -f $(SYN_DIR)/synth.log ]; then \
		echo ""; \
		grep -E "Number of|cells|wires|Printing statistics" $(SYN_DIR)/synth.log | head -20; \
	fi
	@echo ""
	@echo ">>> DFT Scan Chain 统计 <<<"
	@if [ -f $(DFT_DIR)/$(DESIGN)_dft.rpt ]; then \
		grep -E "Total|chains|chain|cells|Shift|DFFs" $(DFT_DIR)/$(DESIGN)_dft.rpt | head -15; \
	fi
	@echo ""
	@echo ">>> ATPG 覆盖率 <<<"
	@if [ -f $(ATPG_REPORT) ]; then \
		grep -E "faults|Detected|Coverage|Pattern|complete" $(ATPG_REPORT) | head -10; \
	fi
	@echo ""
	@echo ">>> 输出文件大小 <<<"
	@ls -lh $(SYN_DIR)/*.bench $(DFT_DIR)/*.bench $(ATPG_DIR)/*.stil 2>/dev/null || true
	@echo ""

#==============================================================================
# 清理
#==============================================================================
clean:
	@echo "[CLEAN] 清理输出..."
	rm -rf $(SYN_DIR)/* $(DFT_DIR)/* $(ATPG_DIR)/*
	@echo "[CLEAN] 完成"
