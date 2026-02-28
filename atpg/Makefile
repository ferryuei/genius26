#==============================================================================
# DFT/ATPG 完整工具链 Makefile
# 
# 目录结构:
#   software/  - 软件工具 (atpg.py, scan_insert.py, verilog2bench.py)
#   rtl/       - RTL设计源文件
#   run/       - 运行输出 (syn/, dft/)
#   doc/       - 文档
#
# 使用方法:
#   make all         - 执行完整流程
#   make synth       - Yosys综合
#   make dft         - DFT Scan Chain插入
#   make atpg        - ATPG测试向量生成
#   make report      - 生成报告
#   make clean       - 清理输出
#==============================================================================

# 工具路径
YOSYS       := yosys
PYTHON      := python3 -u

# 目录定义
TOP_DIR     := $(shell pwd)
SW_DIR      := $(TOP_DIR)/software
RTL_DIR     := $(TOP_DIR)/rtl
RUN_DIR     := $(TOP_DIR)/run
SYN_DIR     := $(RUN_DIR)/syn
DFT_DIR     := $(RUN_DIR)/dft
DOC_DIR     := $(TOP_DIR)/doc

# 设计配置
DESIGN      := apb_uart

# DFT配置
NUM_CHAINS  := 4
ENABLE_EDT  := 1
LFSR_WIDTH  := 16
MISR_WIDTH  := 16

# ATPG配置
MAX_PATTERNS    := 300
TARGET_COVERAGE := 95
ALGORITHM       := auto

# 文件定义
RTL_FILE        := $(RTL_DIR)/$(DESIGN).v
SYNTH_SCRIPT    := $(SW_DIR)/synth.ys
SYNTH_VERILOG   := $(SYN_DIR)/$(DESIGN)_synth.v
SYNTH_BENCH     := $(SYN_DIR)/$(DESIGN).bench

DFT_BENCH       := $(DFT_DIR)/$(DESIGN)_dft.bench
DFT_VERILOG     := $(DFT_DIR)/$(DESIGN)_dft.v
DFT_SCANDEF     := $(DFT_DIR)/$(DESIGN).scandef
DFT_REPORT      := $(DFT_DIR)/$(DESIGN)_dft.rpt

ATPG_STIL       := $(DFT_DIR)/$(DESIGN).stil
ATPG_REPORT     := $(DFT_DIR)/$(DESIGN)_atpg.rpt

#==============================================================================
# 主目标
#==============================================================================
.PHONY: all clean synth dft atpg report help check

all: synth dft atpg report
	@echo ""
	@echo "=============================================="
	@echo "  完整流程执行完毕!"
	@echo "=============================================="
	@echo "  综合输出: $(SYN_DIR)/"
	@echo "  DFT输出:  $(DFT_DIR)/"
	@echo "=============================================="

help:
	@echo "=============================================="
	@echo "  DFT/ATPG 工具链"
	@echo "=============================================="
	@echo ""
	@echo "目标:"
	@echo "  make all          - 完整流程 (synth->dft->atpg->report)"
	@echo "  make synth        - Yosys综合"
	@echo "  make dft          - Scan Chain插入"
	@echo "  make atpg         - ATPG测试向量生成"
	@echo "  make atpg-scan    - Scan模式ATPG (推荐)"
	@echo "  make report       - 生成报告"
	@echo "  make clean        - 清理输出"
	@echo "  make check        - 检查工具"
	@echo ""
	@echo "配置变量:"
	@echo "  DESIGN=$(DESIGN)"
	@echo "  NUM_CHAINS=$(NUM_CHAINS)"
	@echo "  ENABLE_EDT=$(ENABLE_EDT)"
	@echo "  MAX_PATTERNS=$(MAX_PATTERNS)"
	@echo "  TARGET_COVERAGE=$(TARGET_COVERAGE)"
	@echo "  ALGORITHM=$(ALGORITHM)"
	@echo ""
	@echo "示例:"
	@echo "  make all NUM_CHAINS=8           # 8条Scan链"
	@echo "  make atpg-scan TARGET_COVERAGE=98  # 98%覆盖率"
	@echo "  make dft ENABLE_EDT=0           # 禁用EDT压缩"

check:
	@echo "检查工具..."
	@which $(YOSYS) > /dev/null && echo "  Yosys: OK" || echo "  Yosys: 未安装"
	@which $(PYTHON) > /dev/null && echo "  Python: OK" || echo "  Python: 未安装"
	@test -f $(SW_DIR)/atpg.py && echo "  ATPG工具: OK" || echo "  ATPG工具: 缺失"
	@test -f $(SW_DIR)/scan_insert.py && echo "  DFT工具: OK" || echo "  DFT工具: 缺失"
	@test -f $(SW_DIR)/verilog2bench.py && echo "  转换工具: OK" || echo "  转换工具: 缺失"

#==============================================================================
# Step 1: Yosys 综合
#==============================================================================
synth: $(SYNTH_BENCH)
	@echo "[SYNTH] 综合完成: $(SYNTH_BENCH)"

$(SYNTH_BENCH): $(SYNTH_VERILOG)
	@echo "[SYNTH] 转换Verilog到BENCH..."
	$(PYTHON) $(SW_DIR)/verilog2bench.py $(SYNTH_VERILOG) $(SYNTH_BENCH)

$(SYNTH_VERILOG): $(RTL_FILE) | $(SYN_DIR)
	@echo "[SYNTH] 运行Yosys综合..."
	@echo "read_verilog $(RTL_FILE)" > $(SYN_DIR)/_synth.ys
	@echo "synth -top $(DESIGN)" >> $(SYN_DIR)/_synth.ys
	@echo "abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX" >> $(SYN_DIR)/_synth.ys
	@echo "clean" >> $(SYN_DIR)/_synth.ys
	@echo "write_verilog -noattr $(SYNTH_VERILOG)" >> $(SYN_DIR)/_synth.ys
	cd $(SYN_DIR) && $(YOSYS) -q _synth.ys 2>&1 | tee synth.log

$(SYN_DIR):
	@mkdir -p $(SYN_DIR)

#==============================================================================
# Step 2: DFT Scan Chain 插入
#==============================================================================
dft: $(DFT_BENCH)
	@echo "[DFT] Scan插入完成: $(DFT_BENCH)"

$(DFT_BENCH): $(SYNTH_BENCH) | $(DFT_DIR)
	@echo "[DFT] 插入Scan Chain (chains=$(NUM_CHAINS), EDT=$(ENABLE_EDT))..."
ifeq ($(ENABLE_EDT),1)
	$(PYTHON) $(SW_DIR)/scan_insert.py $(SYNTH_BENCH) \
		-o $(DFT_DIR)/$(DESIGN)_dft \
		-f both \
		--scan-def $(DFT_SCANDEF) \
		--num-chains $(NUM_CHAINS) \
		--enable-edt \
		--lfsr-width $(LFSR_WIDTH) \
		--misr-width $(MISR_WIDTH) \
		2>&1 | tee $(DFT_REPORT)
else
	$(PYTHON) $(SW_DIR)/scan_insert.py $(SYNTH_BENCH) \
		-o $(DFT_DIR)/$(DESIGN)_dft \
		-f both \
		--scan-def $(DFT_SCANDEF) \
		--num-chains $(NUM_CHAINS) \
		2>&1 | tee $(DFT_REPORT)
endif

$(DFT_DIR):
	@mkdir -p $(DFT_DIR)

#==============================================================================
# Step 3: ATPG 测试向量生成
#==============================================================================
atpg: $(ATPG_STIL)
	@echo "[ATPG] 测试向量生成完成: $(ATPG_STIL)"

# Scan模式ATPG (推荐,覆盖率更高)
atpg-scan: $(SYNTH_BENCH) | $(DFT_DIR)
	@echo "[ATPG] 运行Scan模式ATPG..."
	$(PYTHON) $(SW_DIR)/atpg.py $(SYNTH_BENCH) \
		--scan \
		--algorithm $(ALGORITHM) \
		-n $(MAX_PATTERNS) \
		-c $(TARGET_COVERAGE) \
		-o $(ATPG_STIL) \
		-r stil \
		2>&1 | tee $(ATPG_REPORT)

# 标准ATPG
$(ATPG_STIL): $(SYNTH_BENCH) | $(DFT_DIR)
	@echo "[ATPG] 运行ATPG (algorithm=$(ALGORITHM))..."
	$(PYTHON) $(SW_DIR)/atpg.py $(SYNTH_BENCH) \
		--scan \
		--algorithm $(ALGORITHM) \
		-n $(MAX_PATTERNS) \
		-c $(TARGET_COVERAGE) \
		-o $(ATPG_STIL) \
		-r stil \
		2>&1 | tee $(ATPG_REPORT)

#==============================================================================
# Step 4: 报告生成
#==============================================================================
report:
	@echo ""
	@echo "=============================================="
	@echo "           DFT/ATPG 报告汇总"
	@echo "=============================================="
	@echo ""
	@echo ">>> Scan Chain 信息 <<<"
	@if [ -f $(DFT_SCANDEF) ]; then \
		head -30 $(DFT_SCANDEF); \
	else \
		echo "Scandef未生成"; \
	fi
	@echo ""
	@echo ">>> ATPG 覆盖率 <<<"
	@if [ -f $(ATPG_REPORT) ]; then \
		grep -E "(Coverage|Detected|Total|Pattern)" $(ATPG_REPORT) | head -20; \
	else \
		echo "ATPG报告未生成"; \
	fi
	@echo ""
	@echo ">>> 输出文件 <<<"
	@ls -lh $(DFT_DIR)/ 2>/dev/null || echo "无输出文件"

#==============================================================================
# 清理
#==============================================================================
clean:
	@echo "[CLEAN] 清理运行输出..."
	rm -rf $(RUN_DIR)/*
	@echo "[CLEAN] 完成"

clean-all: clean
	@echo "[CLEAN] 清理所有生成文件..."
	rm -rf $(RUN_DIR)

#==============================================================================
# 快捷目标
#==============================================================================
.PHONY: quick full

# 快速测试 (单链,无EDT)
quick:
	$(MAKE) all NUM_CHAINS=1 ENABLE_EDT=0 MAX_PATTERNS=100 TARGET_COVERAGE=80

# 完整测试 (多链,EDT,高覆盖率)
full:
	$(MAKE) all NUM_CHAINS=4 ENABLE_EDT=1 MAX_PATTERNS=500 TARGET_COVERAGE=95

# Transition Fault测试
transition:
	@echo "[ATPG] 运行Transition Fault ATPG..."
	$(PYTHON) $(SW_DIR)/atpg.py $(SYNTH_BENCH) \
		--scan \
		--transition \
		-n $(MAX_PATTERNS) \
		-c $(TARGET_COVERAGE) \
		-o $(DFT_DIR)/$(DESIGN)_transition.stil \
		-r stil \
		2>&1 | tee $(DFT_DIR)/$(DESIGN)_transition.rpt
