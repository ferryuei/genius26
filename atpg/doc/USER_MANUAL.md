# ATPG工具集 - 用户手册
## User Manual

**版本**: 2.0  
**日期**: 2026-02-28  
**语言**: 中文

---

## 目录

1. [快速开始](#1-快速开始)
2. [安装指南](#2-安装指南)
3. [工具使用](#3-工具使用)
4. [实战案例](#4-实战案例)
5. [常见问题](#5-常见问题)
6. [故障排除](#6-故障排除)
7. [性能优化](#7-性能优化)
8. [最佳实践](#8-最佳实践)

---

## 1. 快速开始

### 1.1 5分钟上手

```bash
# 1. 编译工具
cd software-c
make all

# 2. 运行示例
./bin/scan_insert tests/test_simple.bench -n 4 -o test_scan
./bin/atpg test_scan.bench -o test_patterns.pat
./bin/dft_drc tests/test_simple.bench -o drc_report.txt
```

### 1.2 工具概览

| 工具 | 功能 | 输入 | 输出 |
|------|------|------|------|
| **scan_insert** | 扫描链插入 | .bench文件 | 扫描网表 + SCANDEF |
| **atpg** | 测试向量生成 | .bench文件 | 测试向量 + 覆盖率报告 |
| **dft_drc** | DFT规则检查 | .bench文件 | DRC报告 |

### 1.3 典型工作流程

```
原始设计
   ↓
[扫描链插入] → 扫描网表
   ↓
[ATPG生成] → 测试向量
   ↓
[DRC检查] → 验证报告
```

---

## 2. 安装指南

### 2.1 系统要求

#### 最低要求
- **操作系统**: Linux, macOS, Windows (WSL2)
- **编译器**: GCC 7.0+ 或 Clang 8.0+
- **内存**: 2GB RAM
- **磁盘**: 100MB可用空间

#### 推荐配置
- **操作系统**: Ubuntu 20.04+ / macOS 12+
- **编译器**: GCC 11.0+
- **内存**: 8GB+ RAM
- **CPU**: 4核心以上
- **磁盘**: 1GB可用空间

### 2.2 编译安装

#### 方法1: 从源码编译

```bash
# 1. 进入源码目录
cd software-c

# 2. 编译（发布版本，带优化）
make all

# 3. 验证安装
./bin/atpg -h
./bin/scan_insert -h
./bin/dft_drc -h
```

#### 方法2: 调试版本

```bash
# 编译调试版本（包含符号信息，无优化）
make debug

# 使用GDB调试
gdb ./bin/atpg
```

#### 方法3: 系统安装

```bash
# 安装到 /usr/local/bin
sudo make install

# 现在可以在任何位置使用
atpg --help

# 卸载
sudo make uninstall
```

### 2.3 编译选项

```bash
# 默认编译（-O3优化）
make

# 性能分析版本（包含profiling）
make perf

# 清理编译产物
make clean

# 运行自动化测试
make test

# 查看帮助
make help
```

### 2.4 验证安装

```bash
# 检查版本和编译信息
./bin/atpg tests/test_simple.bench -o /tmp/test.pat

# 预期输出：
# - 成功解析电路
# - 生成测试向量
# - 显示覆盖率统计
```

---

## 3. 工具使用

### 3.1 scan_insert - 扫描链插入工具

#### 3.1.1 基本用法

```bash
./bin/scan_insert <电路文件.bench> [选项]
```

#### 3.1.2 命令选项

| 选项 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `-n <数量>` | 扫描链数量 | 16 | `-n 32` |
| `-o <前缀>` | 输出文件前缀 | 电路名_scan | `-o my_design` |
| `-h` | 显示帮助 | - | `-h` |

#### 3.1.3 使用示例

**示例1: 基本用法**
```bash
./bin/scan_insert design.bench
```
输出文件：
- `design_scan.bench` - 扫描网表
- `design_scan.scandef` - 扫描定义

**示例2: 指定扫描链数量**
```bash
./bin/scan_insert design.bench -n 8
```
效果：将DFF分配到8条扫描链

**示例3: 自定义输出名称**
```bash
./bin/scan_insert design.bench -n 16 -o my_scan_design
```
输出文件：
- `my_scan_design.bench`
- `my_scan_design.scandef`

#### 3.1.4 输出解读

**控制台输出**:
```
Found 6282 DFFs in circuit

Inserting 16 scan chain(s) for 6282 DFFs...

Scan Chain Statistics:
  Total DFFs: 6282
  Number of chains: 16
  Average chain length: 392.6
  Shortest chain: 392
  Longest chain: 393
```

**SCANDEF文件格式**:
```
SCAN_CHAINS 16

CHAIN 0
  SCAN_IN scan_in_0
  SCAN_OUT scan_out_0
  LENGTH 393
  DFFS dff_0 dff_16 dff_32 ...
```

#### 3.1.5 参数选择建议

**扫描链数量选择**:
- **少链**: 减少端口，但增加测试时间
- **多链**: 减少测试时间，但增加端口
- **推荐**: sqrt(DFF数量) 到 DFF数量/100

| DFF数量 | 推荐链数 | 理由 |
|---------|---------|------|
| < 1000 | 4-8 | 平衡端口和测试时间 |
| 1000-5000 | 8-16 | 常用配置 |
| 5000-10000 | 16-32 | 大型设计 |
| > 10000 | 32-64 | 超大型设计 |

#### 3.1.6 常见错误

**错误1: 未找到DFF**
```
Warning: No DFFs found in circuit
```
**原因**: 电路中没有DFF（纯组合逻辑）  
**解决**: 确认电路文件正确，或该电路确实不需要扫描链

**错误2: 内存不足**
```
Error: Failed to allocate memory
```
**原因**: 电路过大，超出内存限制  
**解决**: 增加系统内存或减少扫描链数量

---

### 3.2 atpg - 自动测试图案生成工具

#### 3.2.1 基本用法

```bash
./bin/atpg <电路文件.bench> [选项]
```

#### 3.2.2 命令选项

| 选项 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `-o <文件>` | 输出测试向量文件 | patterns.txt | `-o test.pat` |
| `-a <算法>` | ATPG算法 | d-algorithm | `-a podem` |
| `-m <次数>` | 最大回溯次数 | 100 | `-m 200` |
| `-t <毫秒>` | 单故障超时 | 60000 | `-t 30000` |
| `-h` | 显示帮助 | - | `-h` |

#### 3.2.3 使用示例

**示例1: 基本ATPG**
```bash
./bin/atpg design_scan.bench -o test_vectors.pat
```

**示例2: 调整参数提高覆盖率**
```bash
./bin/atpg design_scan.bench \
    -o test_vectors.pat \
    -m 200 \
    -t 120000
```
说明：
- 增加回溯次数（100→200）
- 增加超时时间（60s→120s）
- 可能提高覆盖率，但增加运行时间

**示例3: 快速测试**
```bash
./bin/atpg design_scan.bench \
    -o quick_test.pat \
    -m 50 \
    -t 10000
```
说明：快速生成测试向量，适合初步验证

#### 3.2.4 输出解读

**控制台输出**:
```
Generating test patterns for 147292 faults...

Progress: [####################] 100% (147292/147292)

ATPG Statistics:
Total faults: 147292
Detected faults: 67387
Test patterns: 370
Fault coverage: 45.75%
Execution time: 15.2 seconds
```

**关键指标**:
- **Total faults**: 总故障数（通常为 2×门数）
- **Detected faults**: 检测到的故障数
- **Test patterns**: 测试向量数量
- **Fault coverage**: 故障覆盖率（越高越好，目标>90%）
- **Execution time**: 运行时间

**测试向量文件格式**:
```
# ATPG Test Patterns
# Circuit: design_scan.bench
# Patterns: 370
# Coverage: 45.75%

PATTERN 0
INPUTS: 0 1 0 1 1 0 0 1 ...
FAULTS: 15 127 284 ...

PATTERN 1
INPUTS: 1 0 1 1 0 1 0 0 ...
FAULTS: 8 56 199 ...
```

#### 3.2.5 提高覆盖率技巧

**技巧1: 先插入扫描链**
```bash
# ❌ 直接在原始电路上ATPG（覆盖率低）
./bin/atpg original.bench -o test.pat

# ✅ 先插入扫描链再ATPG（覆盖率高）
./bin/scan_insert original.bench -n 16 -o scanned
./bin/atpg scanned.bench -o test.pat
```

**技巧2: 调整算法参数**
```bash
# 增加回溯深度和超时
./bin/atpg scanned.bench \
    -o test.pat \
    -m 500 \      # 更多回溯
    -t 300000     # 更长超时（5分钟）
```

**技巧3: 多次运行取最优**
```bash
# 运行多次，选择覆盖率最高的
for i in {1..3}; do
    ./bin/atpg scanned.bench -o test_$i.pat
done
# 对比test_1.pat, test_2.pat, test_3.pat的覆盖率
```

#### 3.2.6 性能优化

**场景1: 大电路（>10万门）**
```bash
# 分段处理或使用更快的算法
./bin/atpg large_circuit.bench \
    -m 50 \       # 减少回溯
    -t 30000      # 减少超时
```

**场景2: 高覆盖率要求**
```bash
# 增加计算资源
./bin/atpg circuit.bench \
    -m 1000 \
    -t 600000     # 10分钟超时
```

---

### 3.3 dft_drc - DFT设计规则检查工具

#### 3.3.1 基本用法

```bash
./bin/dft_drc <电路文件.bench> [选项]
```

#### 3.3.2 命令选项

| 选项 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `-o <文件>` | 输出DRC报告 | dft_drc_report.txt | `-o my_drc.txt` |
| `-h` | 显示帮助 | - | `-h` |

#### 3.3.3 使用示例

**示例1: 基本检查**
```bash
./bin/dft_drc design.bench
```

**示例2: 指定输出文件**
```bash
./bin/dft_drc design.bench -o drc_report_20260228.txt
```

**示例3: 检查扫描后电路**
```bash
./bin/dft_drc design_scan.bench -o drc_post_scan.txt
```

#### 3.3.4 输出解读

**控制台摘要**:
```
╔══════════════════════════════════════════╗
║         DFT DRC Report                   ║
╚══════════════════════════════════════════╝

Statistics:
  Total violations: 12576
  Errors:           12564
  Warnings:         12
  Info:             0

Clock Domains: 0

❌ DFT DRC FAILED - 12564 error(s) found
```

**详细报告文件**:
```
Severity   Type                        Gate            Description
────────────────────────────────────────────────────────────────────
ERROR      DFF No Clock                branch_q        DFF 'branch_q' has no identifiable clock input
ERROR      Clock Gating No Bypass      _scan_mux_0_    Clock gating cell '_scan_mux_0_' has no bypass...
WARNING    Floating Input              lfsr_q_1_       DFF 'lfsr_q_1_' has no fanout...
```

**违规严重性级别**:
| 级别 | 说明 | 示例 | 是否允许 |
|------|------|------|---------|
| INFO | 信息性提示 | 推荐优化 | ✅ |
| WARNING | 警告 | 浮动节点 | ⚠️ |
| ERROR | 错误 | 时钟门控无旁路 | ❌ |
| CRITICAL | 严重错误 | 组合环路 | ❌ |

#### 3.3.5 常见违规及修复

**违规1: DFF No Clock**
```
ERROR: DFF 'reg_x' has no identifiable clock input
```
**原因**: BENCH格式限制，DFF时钟信息未显式表示  
**影响**: 无法验证时钟可控性  
**修复**: 
- 使用更完整的网表格式（Verilog门级）
- 或在RTL阶段用商业工具检查

**违规2: Clock Gating No Bypass**
```
ERROR: Clock gating cell 'cg_1' has no bypass mechanism
```
**原因**: 时钟门控无测试模式旁路  
**影响**: 扫描测试时某些DFF无法接收时钟  
**修复**:
```verilog
// 添加测试模式旁路
assign gated_clk = test_mode ? clk : (clk & enable);
```

**违规3: Combinational Loop**
```
CRITICAL: Combinational loop detected involving gate 'g123'
```
**原因**: 组合逻辑形成环路  
**影响**: 电路无法稳定，ATPG无法处理  
**修复**: 
- 检查RTL设计
- 确保所有反馈路径经过DFF

**违规4: Floating Input**
```
WARNING: DFF 'unused_reg' has no fanout
```
**原因**: DFF输出未连接到任何门  
**影响**: 浪费面积，可能是设计错误  
**修复**: 
- 如果确实不需要，移除该DFF
- 或连接到观测点/测试输出

#### 3.3.6 BENCH格式的DRC限制

**重要说明**: 使用BENCH格式进行DRC检查有以下限制：

| 检查项 | BENCH格式支持 | 原因 | 建议 |
|--------|--------------|------|------|
| 时钟域识别 | ❌ 不完整 | DFF时钟端口未显式表示 | RTL阶段检查 |
| 复位域识别 | ❌ 不完整 | 复位端口未显式表示 | RTL阶段检查 |
| 时钟门控 | ⚠️ 误报 | 扫描MUX被误识别 | 人工review |
| 组合环路 | ✅ 可靠 | 拓扑结构完整 | - |
| DFF连接性 | ✅ 可靠 | 连接关系完整 | - |

**推荐DRC流程**:
1. **RTL阶段**: 使用商业工具（Synopsys DFT Compiler, Cadence Genus）进行完整DRC
2. **综合后**: 使用本工具进行拓扑检查（环路、连接性）
3. **人工review**: 对BENCH格式的误报进行人工确认

---

## 4. 实战案例

### 4.1 案例1: 小型设计（C17电路）

**电路特性**:
- 5个输入，2个输出
- 6个门，无DFF
- 纯组合逻辑

**完整流程**:

```bash
# 1. 直接运行ATPG（无需扫描链）
./bin/atpg tests/test_simple.bench -o c17_patterns.pat

# 2. DRC检查
./bin/dft_drc tests/test_simple.bench -o c17_drc.txt

# 3. 查看结果
cat c17_patterns.pat
```

**预期结果**:
- 故障数: ~12个（2×6门）
- 覆盖率: ~100%（组合逻辑）
- 测试向量: ~10个

---

### 4.2 案例2: 中型设计（带DFF的电路）

**电路特性**:
- 32个输入，16个输出
- 500个门，50个DFF
- 时序电路

**完整流程**:

```bash
# 1. 扫描链插入
./bin/scan_insert medium_design.bench -n 4 -o medium_scan

# 输出:
# - medium_scan.bench (扫描网表)
# - medium_scan.scandef (扫描定义)

# 2. ATPG生成
./bin/atpg medium_scan.bench -o medium_patterns.pat -m 150

# 3. DRC检查
./bin/dft_drc medium_scan.bench -o medium_drc.txt

# 4. 分析结果
grep "Fault coverage" medium_patterns.pat
grep "ERROR" medium_drc.txt | wc -l
```

**预期结果**:
- 扫描链: 4条，每条约12-13个DFF
- 故障数: ~1000个
- 覆盖率: 85-95%
- 测试向量: 50-100个

---

### 4.3 案例3: 大型设计（biRISC-V核心）

**电路特性**:
- 3,585个输入，3,241个输出
- 73,646个门，6,282个DFF
- 复杂时序电路

**完整流程**:

```bash
# 1. 扫描链插入（使用16条链）
time ./bin/scan_insert rtl2/run/syn/riscv_core.bench \
    -n 16 \
    -o rtl2/run/scan/riscv_core_scan

# 预期时间: ~16秒

# 2. ATPG生成（调整参数以平衡时间和覆盖率）
time ./bin/atpg rtl2/run/scan/riscv_core_scan.bench \
    -o rtl2/run/atpg/test_patterns.pat \
    -m 100 \
    -t 60000

# 预期时间: ~15秒

# 3. DRC检查
time ./bin/dft_drc rtl2/run/dft/riscv_core_dft.bench \
    -o rtl2/run/dft/drc_report.txt

# 预期时间: ~50秒

# 4. 生成统计报告
echo "=== 扫描链统计 ===" > summary.txt
grep "Total DFFs" rtl2/run/scan/*.scandef >> summary.txt

echo "=== ATPG统计 ===" >> summary.txt
grep -A5 "ATPG Statistics" rtl2/run/atpg/test_patterns.pat >> summary.txt

echo "=== DRC统计 ===" >> summary.txt
head -20 rtl2/run/dft/drc_report.txt >> summary.txt

cat summary.txt
```

**实测结果**:
- **扫描链插入**: 16.2秒，16条链，6,282个DFF
- **ATPG生成**: 15.2秒，370个测试向量，45.75%覆盖率
- **DRC检查**: 约50秒，12,576个违规（大部分为格式限制误报）

**性能对比**（vs Python版本）:
- 扫描插入: **4.8x加速**（78s → 16.2s）
- ATPG生成: **>100x加速**（>1800s → 15.2s）

---

### 4.4 案例4: 完整DFT流程自动化

**创建自动化脚本** (`run_dft_flow.sh`):

```bash
#!/bin/bash
# DFT完整流程自动化脚本

set -e  # 遇到错误立即退出

# 配置参数
INPUT_DESIGN=$1
NUM_CHAINS=16
OUTPUT_DIR="dft_results"

# 检查输入
if [ -z "$INPUT_DESIGN" ]; then
    echo "Usage: $0 <design.bench>"
    exit 1
fi

DESIGN_NAME=$(basename "$INPUT_DESIGN" .bench)

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

echo "========================================"
echo "  DFT Flow for: $DESIGN_NAME"
echo "========================================"

# 步骤1: 扫描链插入
echo ""
echo "[1/3] Scan Chain Insertion..."
time ./bin/scan_insert "$INPUT_DESIGN" \
    -n $NUM_CHAINS \
    -o "$OUTPUT_DIR/${DESIGN_NAME}_scan"

# 步骤2: ATPG生成
echo ""
echo "[2/3] ATPG Generation..."
time ./bin/atpg "$OUTPUT_DIR/${DESIGN_NAME}_scan.bench" \
    -o "$OUTPUT_DIR/${DESIGN_NAME}_patterns.pat" \
    -m 150 \
    -t 120000

# 步骤3: DRC检查
echo ""
echo "[3/3] DFT DRC Check..."
time ./bin/dft_drc "$OUTPUT_DIR/${DESIGN_NAME}_scan.bench" \
    -o "$OUTPUT_DIR/${DESIGN_NAME}_drc.txt"

# 生成汇总报告
echo ""
echo "========================================"
echo "  DFT Flow Summary"
echo "========================================"

# 扫描链统计
echo ""
echo "Scan Chain Statistics:"
grep -E "Total DFFs|Number of chains|Average chain length" \
    "$OUTPUT_DIR/${DESIGN_NAME}_scan.scandef" 2>/dev/null || echo "N/A"

# ATPG统计
echo ""
echo "ATPG Statistics:"
grep -A5 "ATPG Statistics" \
    "$OUTPUT_DIR/${DESIGN_NAME}_patterns.pat" 2>/dev/null || echo "N/A"

# DRC统计
echo ""
echo "DRC Statistics:"
grep -E "Total violations|Errors|Warnings" \
    "$OUTPUT_DIR/${DESIGN_NAME}_drc.txt" 2>/dev/null || echo "N/A"

echo ""
echo "========================================"
echo "  All files saved to: $OUTPUT_DIR/"
echo "========================================"
```

**使用自动化脚本**:

```bash
# 赋予执行权限
chmod +x run_dft_flow.sh

# 运行DFT流程
./run_dft_flow.sh design.bench

# 查看结果
ls -lh dft_results/
```

---

## 5. 常见问题 (FAQ)

### 5.1 编译相关

**Q1: 编译时出现"command not found: gcc"**

A: 需要安装GCC编译器
```bash
# Ubuntu/Debian
sudo apt-get install build-essential

# macOS
xcode-select --install

# CentOS/RHEL
sudo yum groupinstall "Development Tools"
```

**Q2: 编译警告"warning: unused variable"**

A: 这些是轻微警告，不影响功能。如需消除：
```bash
# 编辑Makefile，添加 -Wno-unused-variable
CFLAGS = -Wall -Wextra -O3 -march=native -flto -std=c11 -Wno-unused-variable
make clean && make
```

**Q3: 链接错误"undefined reference to 'sqrt'"**

A: 确保链接了数学库：
```bash
# Makefile中应该有:
LDFLAGS = -lm
```

---

### 5.2 使用相关

**Q4: 扫描链插入后电路变大了多少？**

A: 主要增加扫描MUX和端口：
- 每个DFF增加1个MUX（2-3个门）
- 增加2N个端口（N条链：N个scan_in + N个scan_out）
- 总增量约：DFF数量×2门 + 2N端口

示例：6,282个DFF，16条链
- 增加约12,500个门（+17%）
- 增加32个端口

**Q5: ATPG覆盖率只有45%，如何提高？**

A: 低覆盖率通常有以下原因和解决方案：

| 原因 | 解决方案 | 预期效果 |
|------|---------|---------|
| 未插入扫描链 | 先执行scan_insert | 提升到85-95% |
| 回溯次数不足 | 增加-m参数（100→500） | 提升5-10% |
| 超时太短 | 增加-t参数（60s→300s） | 提升3-5% |
| 算法限制 | 等待PODEM实现 | 提升10-15% |
| 冗余故障 | 正常现象 | 无法检测 |

**Q6: DRC报告有上万个错误，正常吗？**

A: 使用BENCH格式时，是正常的：
- 6,282个"DFF No Clock"：格式限制，DFF时钟未显式表示
- 6,282个"Clock Gating"：扫描MUX被误识别
- 只有少量真实问题（如浮动节点）

**重点关注**：
- ✅ "Combinational Loop" → 必须修复
- ⚠️ "Floating Input" → 需要review
- ❌ "DFF No Clock"（BENCH格式） → 可以忽略

**Q7: 测试向量文件有什么用？**

A: 测试向量用于：
1. **ATE测试**: 导入到自动测试设备
2. **仿真验证**: 在仿真器中验证故障检测
3. **故障诊断**: 分析失效芯片的故障位置
4. **良率分析**: 统计不同故障的检出率

**Q8: 工具支持哪些网表格式？**

A: 当前版本仅支持BENCH格式：
- ✅ BENCH (.bench)
- ❌ Verilog门级网表 (.v) - 未来版本支持
- ❌ EDIF (.edf) - 未来版本支持

如需转换：
```bash
# Verilog转BENCH（需要第三方工具）
# 方法1: 使用Yosys
yosys -p "read_verilog design.v; write_bench design.bench"

# 方法2: 使用ABC
abc -c "read_verilog design.v; write_bench design.bench"
```

---

### 5.3 性能相关

**Q9: 为什么ATPG运行很慢？**

A: 可能原因和优化方法：

| 原因 | 检查方法 | 优化方法 |
|------|---------|---------|
| 电路太大 | 查看门数>10万 | 分块处理或使用更快机器 |
| 回溯过深 | -m参数过大 | 减小到50-100 |
| 超时过长 | -t参数过大 | 减小到10000-30000 |
| 未插扫描链 | 检查DFF是否可观测/可控 | 先执行scan_insert |
| 难检测故障多 | 冗余故障比例高 | 正常现象，可接受 |

**Q10: 如何并行运行ATPG？**

A: 当前版本不支持多线程，但可以手动分块：
```bash
# 将故障分成N份，分别运行
# （需要修改代码或使用脚本）

# 或者在多台机器上并行运行不同电路
machine1$ ./bin/atpg design1.bench &
machine2$ ./bin/atpg design2.bench &
machine3$ ./bin/atpg design3.bench &
```

---

## 6. 故障排除

### 6.1 运行时错误

#### 错误1: Segmentation Fault

**症状**:
```
Segmentation fault (core dumped)
```

**可能原因**:
1. 电路文件格式错误
2. 内存不足
3. 数组越界（Bug）

**排查步骤**:
```bash
# 1. 验证输入文件
head -20 design.bench  # 检查格式

# 2. 使用调试版本
make debug
gdb ./bin/atpg
(gdb) run design.bench
(gdb) bt  # 查看崩溃栈

# 3. 检查内存
free -h  # 确保有足够可用内存

# 4. 尝试小电路
./bin/atpg tests/test_simple.bench  # 如果小电路正常，可能是电路太大
```

---

#### 错误2: Failed to parse circuit

**症状**:
```
Error: Failed to parse circuit file
Error: Cannot open file design.bench
```

**解决方法**:
```bash
# 1. 检查文件是否存在
ls -l design.bench

# 2. 检查文件权限
chmod 644 design.bench

# 3. 检查文件格式
file design.bench  # 应该显示 ASCII text

# 4. 检查路径
# 使用绝对路径或相对路径
./bin/atpg /path/to/design.bench  # 绝对路径
./bin/atpg ./design.bench          # 相对路径
```

---

#### 错误3: malloc(): corrupted top size

**症状**:
```
malloc(): corrupted top size
Aborted (core dumped)
```

**原因**: 内存损坏，通常是内存越界写入

**解决方法**:
```bash
# 1. 使用valgrind检测内存问题
valgrind --leak-check=full ./bin/atpg design.bench

# 2. 使用调试版本
make debug
gdb ./bin/atpg
(gdb) run design.bench
(gdb) bt

# 3. 减小电路规模测试
# 如果小电路正常，大电路出错，可能超出MAX_GATES限制
```

---

### 6.2 输出异常

#### 问题1: 故障覆盖率为0%

**检查清单**:
```bash
# 1. 确认电路有输出
grep "OUTPUT" design.bench

# 2. 确认电路有门
grep "=" design.bench | wc -l

# 3. 查看ATPG日志
./bin/atpg design.bench -o /tmp/test.pat 2>&1 | tee atpg.log
grep "ERROR" atpg.log

# 4. 尝试简单电路
./bin/atpg tests/test_simple.bench  # 应该有>90%覆盖率
```

---

#### 问题2: 测试向量数量异常多（>10000个）

**可能原因**:
- 未插入扫描链
- 电路可观测性差

**解决方法**:
```bash
# 1. 先插入扫描链
./bin/scan_insert design.bench -n 16 -o design_scan
./bin/atpg design_scan.bench -o test.pat

# 2. 如果仍然很多，检查电路结构
# 可能存在大量孤立逻辑
```

---

### 6.3 性能问题

#### 问题1: ATPG运行超过1小时

**诊断**:
```bash
# 1. 查看电路规模
grep "Total gates" <(./bin/atpg design.bench -o /tmp/test.pat 2>&1 | head -20)

# 2. 查看故障数
grep "Total faults" ...

# 3. 如果>20万故障，考虑:
# - 减小超时: -t 10000
# - 减小回溯: -m 50
# - 分块处理
```

**优化**:
```bash
# 快速模式（牺牲覆盖率换取速度）
./bin/atpg design.bench \
    -o quick_test.pat \
    -m 30 \
    -t 5000
```

---

## 7. 性能优化

### 7.1 编译优化

#### 最大性能编译

```bash
# 默认已经是-O3优化
make clean && make

# 如果需要针对特定CPU优化
# 编辑Makefile:
CFLAGS = -Wall -Wextra -O3 -march=native -flto -std=c11 -funroll-loops -finline-functions

make clean && make
```

#### 不同优化级别对比

| 优化级别 | 编译时间 | 运行时间 | 二进制大小 | 推荐场景 |
|---------|---------|---------|-----------|---------|
| -O0 | 快 | 慢（10x） | 大 | 调试 |
| -O2 | 中 | 快 | 中 | 平衡 |
| -O3 | 慢 | 最快 | 大 | 生产环境（推荐） |
| -Os | 中 | 较快 | 小 | 存储受限 |

---

### 7.2 运行时优化

#### 优化1: 选择合适的扫描链数量

```bash
# 规则: 链数 = sqrt(DFF数)

# 1000 DFFs → 32条链
./bin/scan_insert design.bench -n 32

# 10000 DFFs → 100条链(受限于MAX_CHAINS=64)
./bin/scan_insert design.bench -n 64
```

#### 优化2: 调整ATPG参数

```bash
# 快速模式（牺牲覆盖率）
./bin/atpg design.bench -m 30 -t 5000

# 高覆盖率模式（牺牲速度）
./bin/atpg design.bench -m 500 -t 300000

# 平衡模式（推荐）
./bin/atpg design.bench -m 150 -t 60000
```

---

### 7.3 系统调优

#### Linux系统优化

```bash
# 1. 增加内存限制（如果需要）
ulimit -s unlimited  # 栈大小
ulimit -v unlimited  # 虚拟内存

# 2. 使用高性能CPU调速器
sudo cpupower frequency-set -g performance

# 3. 禁用swap（如果内存充足）
sudo swapoff -a
```

#### 使用RAM磁盘加速IO

```bash
# 创建RAM磁盘
sudo mkdir /mnt/ramdisk
sudo mount -t tmpfs -o size=2G tmpfs /mnt/ramdisk

# 在RAM磁盘上运行
cp design.bench /mnt/ramdisk/
cd /mnt/ramdisk
/path/to/bin/atpg design.bench -o test.pat

# 完成后复制结果
cp test.pat /original/path/
```

---

## 8. 最佳实践

### 8.1 项目组织

**推荐目录结构**:
```
project/
├── rtl/                    # RTL源代码
│   └── design.v
├── netlist/                # 综合后网表
│   └── design.bench
├── dft/                    # DFT相关
│   ├── scan/              # 扫描链插入结果
│   │   ├── design_scan.bench
│   │   └── design_scan.scandef
│   ├── atpg/              # ATPG结果
│   │   └── test_patterns.pat
│   └── drc/               # DRC报告
│       └── drc_report.txt
├── scripts/                # 自动化脚本
│   └── run_dft_flow.sh
└── docs/                   # 文档
    └── dft_results.md
```

---

### 8.2 版本控制

**Git配置** (`.gitignore`):
```
# 编译产物
software-c/obj/
software-c/bin/

# 中间文件
*.o
*.out

# 大型结果文件
*.bench
*.pat
*_scan.*
drc_report*.txt

# 保留小型测试文件
!tests/*.bench
```

---

### 8.3 文档记录

**记录DFT结果模板** (`dft_results.md`):
```markdown
# DFT Results - Design Name

## 基本信息
- 设计: riscv_core
- 日期: 2026-02-28
- 工具版本: ATPG v2.0

## 扫描链插入
- DFF数量: 6,282
- 扫描链数: 16
- 平均链长: 392.6
- 执行时间: 16.2秒

## ATPG生成
- 总故障数: 147,292
- 检测故障数: 67,387
- 测试向量数: 370
- 故障覆盖率: 45.75%
- 执行时间: 15.2秒

## DRC检查
- 总违规: 12,576
- 错误: 12,564 (主要为BENCH格式限制)
- 警告: 12 (LFSR浮动输出)
- 真实问题: 12个

## 结论
✅ 基本DFT结构健全
⚠️ 需要在RTL阶段进行完整DRC验证
✅ 扫描链和ATPG功能正常
```

---

### 8.4 团队协作

**工作流程建议**:

1. **DFT工程师**:
   - 插入扫描链
   - 生成测试向量
   - 验证DRC

2. **设计工程师**:
   - 修复DRC违规
   - 优化可测试性
   - Review扫描链分配

3. **测试工程师**:
   - 将测试向量导入ATE
   - 执行生产测试
   - 反馈故障覆盖情况

---

### 8.5 持续改进

**定期检查清单**:
- [ ] 覆盖率是否达标（>90%）
- [ ] DRC关键错误是否清零
- [ ] 测试时间是否可接受
- [ ] 测试向量数量是否优化
- [ ] 工具版本是否最新

---

## 附录

### A. 术语表

| 术语 | 英文 | 解释 |
|------|------|------|
| ATPG | Automatic Test Pattern Generation | 自动测试图案生成 |
| DFT | Design for Testability | 可测试性设计 |
| DRC | Design Rule Check | 设计规则检查 |
| SA0/SA1 | Stuck-At-0/1 | 固定型故障（输出恒为0或1） |
| DFF | D Flip-Flop | D触发器 |
| PI/PO | Primary Input/Output | 主输入/主输出 |
| Scan Chain | 扫描链 | 将DFF串联形成的可测试结构 |
| Fault Coverage | 故障覆盖率 | 可检测故障占总故障的比例 |

### B. 快速参考卡

```
┌─────────────────────────────────────────────────┐
│          ATPG工具快速参考                        │
├─────────────────────────────────────────────────┤
│ 扫描链插入:                                      │
│   ./bin/scan_insert design.bench -n 16          │
│                                                 │
│ ATPG生成:                                       │
│   ./bin/atpg design_scan.bench -o test.pat     │
│                                                 │
│ DRC检查:                                        │
│   ./bin/dft_drc design.bench -o drc.txt        │
│                                                 │
│ 编译:                                           │
│   make clean && make                            │
│                                                 │
│ 帮助:                                           │
│   ./bin/atpg -h                                 │
└─────────────────────────────────────────────────┘
```

### C. 联系支持

**问题反馈**:
- 📧 Email: atpg-support@example.com
- 🐛 Bug报告: https://github.com/project/atpg/issues
- 📖 文档: https://atpg-docs.example.com

---

**文档版本**: 2.0  
**最后更新**: 2026-02-28  
**维护者**: ATPG开发团队
