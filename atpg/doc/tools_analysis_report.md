# DFT/ATPG 工具链分析报告 (v2.0)

> **文档更新日期**: 2026-02-05  
> **工具版本**: Enhanced Version (已完成主要功能升级)

## 执行结果汇总

| 阶段 | 工具 | 输入 | 输出 | 结果 |
|------|------|------|------|------|
| 综合 | Yosys | apb_uart.v | apb_uart.bench | 316门, 78 DFF |
| DFT | scan_insert.py | apb_uart.bench | apb_uart_dft.bench | 78 Scan Cells |
| ATPG | atpg.py | apb_uart.bench | apb_uart.stil | **83.0%** 覆盖率 |

---

## 工具升级总览

### 主要改进

| 工具 | 旧版本问题 | 新版本改进 | 状态 |
|------|-----------|-----------|------|
| scan_insert.py | 单链结构 | ✅ 多Scan Chain支持 | 已实现 |
| scan_insert.py | 无时钟域处理 | ✅ 时钟域自动识别与分组 | 已实现 |
| scan_insert.py | 无压缩支持 | ✅ EDT压缩 (LFSR/MISR) | 已实现 |
| atpg.py | 只有D-Algorithm | ✅ PODEM + FAN算法 | 已实现 |
| atpg.py | 无并行模拟 | ✅ 位并行故障模拟 | 已实现 |
| atpg.py | 无冗余故障识别 | ✅ 冗余/不可测故障分类 | 已实现 |
| atpg.py | 无Transition Fault | ✅ STR/STF跳变故障 | 已实现 |

---

## scan_insert.py 工具分析

### ✅ 已支持功能

| 功能 | 描述 | 命令行参数 |
|------|------|-----------|
| **DFF自动识别** | 从BENCH/Verilog网表识别DFF | - |
| **Scan MUX插入** | MUX-D扫描单元结构 | - |
| **多Scan Chain** | 支持任意数量Scan链 | `--num-chains N` |
| **时钟域处理** | 自动识别pclk/hclk/aclk等 | 自动 |
| **链平衡** | 贪心算法平衡各链长度 | 自动 |
| **EDT压缩** | LFSR解压缩 + MISR响应压缩 | `--enable-edt` |
| **LFSR配置** | 可配置位宽和多项式 | `--lfsr-width`, `--misr-width` |
| **多输出格式** | BENCH, Verilog, ScanDef | `-f bench/verilog/both` |

### 使用示例

```bash
# 基本用法 (单链)
python scan_insert.py netlist.bench -o output

# 多链模式 (4条链,减少shift时间)
python scan_insert.py netlist.bench -o output --num-chains 4

# 启用EDT压缩
python scan_insert.py netlist.bench -o output --num-chains 4 --enable-edt

# 自定义EDT参数
python scan_insert.py netlist.bench -o output --num-chains 8 \
    --enable-edt --lfsr-width 32 --misr-width 32
```

### 多链模式详情

```
多链效果示例:
┌────────────────────────────────────────────────┐
│ 单链模式: 78个DFF → Shift周期 = 78            │
│ 4链模式:  78个DFF → Shift周期 ≈ 20 (75%减少)  │
│ 8链模式:  78个DFF → Shift周期 ≈ 10 (87%减少)  │
└────────────────────────────────────────────────┘
```

### EDT压缩结构

```
  ┌────────┐     ┌────────────────┐     ┌────────┐
  │  LFSR  │────►│ Phase Shifter  │────►│ Scan   │
  │解压缩器 │     │ (XOR网络)      │     │ Chains │
  └────────┘     └────────────────┘     └────┬───┘
       ▲                                     │
       │                                     ▼
  少量外部                              ┌────────┐
  测试数据                              │  MISR  │────► 签名输出
                                        │ 压缩器  │
                                        └────────┘
```

### ❌ 当前不支持/限制

| 功能 | 状态 | 说明 |
|------|------|------|
| Lockup Latch | ⚠️ 未实现 | 跨时钟域需要手动处理 |
| 异步复位处理 | ⚠️ 未实现 | 假设同步设计 |
| DEF/LEF输出 | ⚠️ 未实现 | 仅支持BENCH/Verilog/ScanDef |
| 物理位置优化 | ⚠️ 未实现 | 链顺序基于逻辑顺序 |
| LBIST控制器 | ⚠️ 未实现 | 仅实现LFSR/MISR逻辑 |

---

## atpg.py 工具分析

### ✅ 已支持功能

| 功能 | 描述 | 命令行参数 |
|------|------|-----------|
| **多种ATPG算法** | D-Algorithm, PODEM, FAN | `--algorithm auto/podem/fan` |
| **Stuck-at故障** | s-a-0, s-a-1 | 默认 |
| **Transition Fault** | STR (慢上升), STF (慢下降) | `--transition` |
| **并行故障模拟** | 64位并行仿真 | `--parallel` |
| **故障折叠** | 等效故障合并 | 默认启用, `--no-collapse`禁用 |
| **冗余故障识别** | 标记不可测故障 | 自动 |
| **Scan ATPG** | 扫描链测试模式 | `--scan` |
| **多输出格式** | text, JSON, STIL | `-r text/json/stil` |

### ATPG算法详解

| 算法 | 特点 | 适用场景 |
|------|------|---------|
| **D-Algorithm** | 稳定可靠,回溯较多 | 基础算法,作为fallback |
| **PODEM** | 路径导向,效率高 | 难测故障,减少无效搜索 |
| **FAN** | 多路回溯,处理扇出 | 高扇出电路 |
| **auto** | 组合使用,自动选择 | 推荐默认使用 |

```
Auto模式工作流程:
┌─────────────┐    失败    ┌─────────────┐    失败    ┌─────────────┐
│ D-Algorithm ├───────────►│   PODEM     ├───────────►│ 标记未检测   │
│ (500回溯)   │            │ (1000回溯)  │            │ 或冗余故障   │
└─────────────┘            └─────────────┘            └─────────────┘
```

### 使用示例

```bash
# 基本用法
python atpg.py netlist.bench -o output.stil -r stil

# 使用PODEM算法,高覆盖率目标
python atpg.py netlist.bench --algorithm podem -c 98

# 并行模拟 + 大量向量
python atpg.py netlist.bench --parallel -n 1000 -c 99

# 包含跳变故障 (at-speed测试)
python atpg.py netlist.bench --transition -o trans.stil -r stil

# Scan模式ATPG
python atpg.py netlist_with_scan.bench --scan -n 500 -c 95
```

### 覆盖率分析 (v2.0)

```
当前测试结果 (apb_uart):
────────────────────────────────
总故障:     690
检测:       573 (83.0%)  ⬆ 从79.5%提升
未检测:     117 (17.0%)
────────────────────────────────
Scan链长度: 78
测试向量:   71
────────────────────────────────
```

### ❌ 当前不支持/限制

| 功能 | 状态 | 说明 |
|------|------|------|
| Path Delay Fault | ⚠️ 未实现 | 仅支持Transition Fault |
| 桥接故障 | ⚠️ 未实现 | 仅支持Stuck-at/Transition |
| 覆盖率 < 95% | ⚠️ 有待提升 | 部分难测故障未覆盖 |
| BIST控制器生成 | ⚠️ 未实现 | 不生成完整BIST逻辑 |
| 商业ATE格式 | ⚠️ 部分支持 | 仅支持STIL 1.0 |

---

## verilog2bench.py 工具分析

### ✅ 已支持功能

| 功能 | 描述 |
|------|------|
| **Yosys综合输出转换** | 支持标准Yosys输出格式 |
| **信号名清理** | 自动处理 `[n]` 索引 |
| **基本门识别** | AND, OR, NOT, NAND, NOR, XOR, XNOR |
| **DFF识别** | 从always块提取DFF |
| **复杂表达式** | 支持 `~(a & b)` 等组合表达式 |

### ❌ 当前不支持/限制

| 功能 | 状态 | 说明 |
|------|------|------|
| 多维数组 | ⚠️ 未实现 | `signal[7:0][3:0]` |
| 参数化模块 | ⚠️ 未实现 | 需预先展开 |
| generate块 | ⚠️ 未实现 | 需预先展开 |

---

## 工具集成架构

```
                    DFT/ATPG 工具链流程
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ┌──────────┐   Yosys    ┌──────────────┐  verilog2bench.py   │
│  │ RTL设计  ├───────────►│ 综合Verilog  ├────────────────┐    │
│  │ (.v)     │   综合     │ (*_synth.v)  │                │    │
│  └──────────┘            └──────────────┘                │    │
│                                                          ▼    │
│                                          ┌──────────────────┐  │
│                                          │   BENCH网表     │  │
│                                          │  (*.bench)      │  │
│                                          └────────┬────────┘  │
│                                                   │           │
│                          ┌────────────────────────┼──────┐    │
│                          │                        │      │    │
│                          ▼                        ▼      │    │
│  ┌─────────────────────────────┐  ┌─────────────────────┐│    │
│  │     scan_insert.py          │  │     atpg.py         ││    │
│  │                             │  │                     ││    │
│  │ • 多Scan Chain插入          │  │ • PODEM/FAN/D-Alg   ││    │
│  │ • 时钟域处理                │  │ • 并行故障模拟       ││    │
│  │ • EDT压缩                   │  │ • Transition Fault  ││    │
│  │                             │  │ • 冗余故障识别       ││    │
│  └────────────┬────────────────┘  └──────────┬──────────┘│    │
│               │                              │           │    │
│               ▼                              ▼           │    │
│  ┌─────────────────────────────┐  ┌─────────────────────┐│    │
│  │ 输出:                       │  │ 输出:               ││    │
│  │ • *_dft.bench               │  │ • *.stil (ATE)      ││    │
│  │ • *_dft.v                   │  │ • *.json (报告)     ││    │
│  │ • *.scandef                 │  │ • *.rpt (文本)      ││    │
│  └─────────────────────────────┘  └─────────────────────┘│    │
│                                                          │    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Makefile 快捷命令

| 命令 | 描述 |
|------|------|
| `make all` | 完整流程 (synth→dft→atpg→report) |
| `make synth` | Yosys综合 |
| `make dft` | Scan Chain插入 |
| `make atpg` | ATPG测试向量生成 |
| `make atpg-scan` | Scan模式ATPG (推荐) |
| `make transition` | Transition Fault ATPG |
| `make quick` | 快速测试 (单链,无EDT,80%覆盖) |
| `make full` | 完整测试 (多链,EDT,95%覆盖) |
| `make report` | 生成报告汇总 |
| `make clean` | 清理输出 |

### 配置变量

```makefile
# DFT配置
NUM_CHAINS  := 4      # Scan链数量
ENABLE_EDT  := 1      # 启用EDT压缩 (0/1)
LFSR_WIDTH  := 16     # LFSR位宽
MISR_WIDTH  := 16     # MISR位宽

# ATPG配置
MAX_PATTERNS    := 300  # 最大测试向量数
TARGET_COVERAGE := 95   # 目标覆盖率 (%)
ALGORITHM       := auto # ATPG算法 (auto/podem/fan)
```

---

## 性能基准

### 测试电路: apb_uart

| 指标 | v1.0 (旧) | v2.0 (新) | 改进 |
|------|----------|----------|------|
| 故障覆盖率 | 79.5% | 83.0% | +3.5% |
| ATPG算法 | D-Alg only | D-Alg+PODEM+FAN | ✅ |
| Scan Chain | 单链 | 多链支持 | ✅ |
| EDT压缩 | ❌ | ✅ | 新增 |
| 并行仿真 | ❌ | ✅ 64位并行 | 新增 |
| Transition Fault | ❌ | ✅ | 新增 |

---

## 后续优化方向

### 高优先级

| 目标 | 方法 | 预期效果 |
|------|------|---------|
| **覆盖率 → 95%+** | 改进PODEM回溯策略 | +12%覆盖率 |
| **完善冗余识别** | 增加ATPG-untestable分析 | 更准确报告 |
| **Scan ATPG集成** | 读取scandef文件 | 正确测试DFT网表 |

### 中优先级

| 目标 | 方法 | 预期效果 |
|------|------|---------|
| 跨时钟域Lockup | 自动插入Lockup Latch | 多时钟兼容 |
| 完整BIST控制器 | 生成test controller | 内建自测试 |
| 商业格式输出 | 支持WGL/STIL 2.0 | ATE兼容性 |

### 低优先级

| 目标 | 方法 | 预期效果 |
|------|------|---------|
| Path Delay Fault | 时序分析集成 | 精确时序测试 |
| DEF/LEF输出 | 集成物理信息 | EDA工具兼容 |
| GUI界面 | 可视化波形/覆盖率 | 用户体验 |

---

## 总结

工具链已完成主要功能升级:

1. **scan_insert.py**: 从单链升级为多链+EDT压缩架构
2. **atpg.py**: 从单一D-Algorithm升级为PODEM/FAN多算法引擎
3. **整体**: 覆盖率从79.5%提升至83.0%

当前主要限制:
- 覆盖率仍低于95%目标,需进一步优化ATPG算法
- 部分高级DFT功能(Lockup Latch, BIST控制器)未实现
- 工具间集成可进一步加强(自动读取scandef)
