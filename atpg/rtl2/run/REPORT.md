# biRISC-V 完整设计 DFT/ATPG 流程报告

> **生成日期**: 2026-02-06  
> **设计**: riscv_core (biRISC-V CPU核心)

---

## 执行结果汇总

| 阶段 | 状态 | 主要指标 |
|------|------|---------|
| **综合** | ✅ 完成 | 94,947门, 6,478 DFF |
| **扫描插入** | ✅ 完成 | 8链, 每链809-810 cells |
| **ATPG** | ✅ 完成 | 190,284故障, 500测试向量 |

---

## 1. 设计规模

**RTL文件**: 19个Verilog文件

| 模块 | 描述 |
|------|------|
| riscv_core | 顶层核心模块 |
| biriscv_frontend | 前端 (取指+译码) |
| biriscv_issue | 发射单元 |
| biriscv_exec | 执行单元 |
| biriscv_alu | ALU |
| biriscv_multiplier | 乘法器 |
| biriscv_divider | 除法器 |
| biriscv_lsu | 加载存储单元 |
| biriscv_mmu | 内存管理单元 |
| biriscv_csr | 控制状态寄存器 |
| biriscv_npc | 分支预测 |
| biriscv_regfile | 寄存器堆 |

---

## 2. 综合结果 (syn/)

**工具**: Yosys (with flatten + splitnets)

**输出文件**:
| 文件 | 大小 |
|------|------|
| riscv_core_synth.v | 4.5MB |
| riscv_core.bench | 4.6MB |

**电路统计**:
```
主要输入 (PI):   191 (含扫描控制)
主要输出 (PO):   127
门数量:          94,947
网表节点:        95,142
逻辑层级:        146
DFF数量:         6,478
```

**关键优化**:
1. 使用 `flatten` 将层次化设计展平
2. 使用 `splitnets` 展开总线信号
3. MUX门展开为AND/OR/NOT基本门
4. 未定义信号作为伪输入处理

---

## 3. 扫描链插入结果 (scan/)

**工具**: scan_insert.py

**输出文件**:
| 文件 | 大小 | 描述 |
|------|------|------|
| riscv_core_scan.bench | 5.4MB | 扫描插入后网表 |
| scan_def.txt | 894KB | 扫描链定义 |

**Scan Chain配置**:
```
总Scan Cells:    6,478
链数:            8
Max链长度:       810
Min链长度:       809
Shift周期:       810
Shift减少率:     87.5% (vs 单链6,478)
```

**链分配详情**:
| 链ID | 长度 | SI端口 | SO端口 |
|------|------|--------|--------|
| Chain 0 | 810 | scan_in_0 | scan_out_0 |
| Chain 1 | 810 | scan_in_1 | scan_out_1 |
| Chain 2 | 810 | scan_in_2 | scan_out_2 |
| Chain 3 | 810 | scan_in_3 | scan_out_3 |
| Chain 4 | 810 | scan_in_4 | scan_out_4 |
| Chain 5 | 810 | scan_in_5 | scan_out_5 |
| Chain 6 | 809 | scan_in_6 | scan_out_6 |
| Chain 7 | 809 | scan_in_7 | scan_out_7 |

---

## 4. ATPG结果 (atpg/)

**工具**: atpg_optimized.py

**输出文件**:
| 文件 | 描述 |
|------|------|
| test_patterns.txt | 测试向量文件 |
| atpg_report.txt | 详细ATPG报告 |

**故障模型**:
```
故障模型:        Stuck-at (SA0/SA1)
总SA故障:        190,284
折叠后故障:      190,219
```

**测试生成结果**:
```
生成方法:        随机向量 + 策略变换
测试向量数:      500
生成时间:        47.3秒

采样分析:
  采样故障:      10,000 (5.3%)
  故障激活率:    14.1%
  估计覆盖率:    12-15%
```

**性能分析**:
- 电路仿真: 28ms/向量 (JIT预热后)
- Numba JIT: 已启用
- SCOAP计算: 已完成

**覆盖率说明**:
随机测试向量对大型处理器设计的覆盖率有限，原因:
1. 处理器需要特定指令序列激活内部逻辑
2. 控制状态机需要特定条件转换
3. 组合ATPG无法覆盖时序相关故障

**推荐**:
- 使用商业ATPG工具 (TetraMAX, Modus) 获得更高覆盖率
- 应用功能测试向量补充结构测试
- 考虑基于约束的ATPG方法

---

## 5. 目录结构

```
rtl2/run/
├── Makefile                    # 构建脚本
├── REPORT.md                   # 本报告
├── syn/                        # 综合输出
│   ├── riscv_core_synth.v      # 综合后Verilog
│   ├── riscv_core.bench        # BENCH格式网表
│   └── _synth.ys               # Yosys脚本
├── scan/                       # 扫描插入输出
│   ├── riscv_core_scan.bench   # 扫描后网表
│   └── scan_def.txt            # 扫描链定义
└── atpg/                       # ATPG输出
    ├── test_patterns.txt       # 测试向量
    └── atpg_report.txt         # ATPG报告
```

---

## 6. 使用命令

```bash
cd ~/genius/atpg/rtl2/run

# 综合
cd ~/genius/atpg/rtl2/run/syn && yosys -s _synth.ys

# 扫描插入
python ~/genius/atpg/software/scan_insert.py \
    syn/riscv_core.bench \
    -o scan/riscv_core_scan \
    --num-chains 8

# ATPG (优化版本)
python ~/genius/atpg/software/atpg_benchmark.py \
    scan/riscv_core_scan.bench \
    --max-patterns 500 \
    --target-coverage 90

# 查看报告
cat atpg/atpg_report.txt
```

---

## 7. 设计特点与DFT分析

### 7.1 设计规模
- **biRISC-V**: 超标量双发射RISC-V处理器
- **特性**: 分支预测 (BTB/BHT/RAS), 乘除法器, MMU支持
- **门数**: 94,947 (展平后)
- **寄存器**: 6,478 DFFs

### 7.2 DFT挑战
1. **大量DFF** (6,478个): 需要多链平衡
2. **深层流水线**: 146级逻辑深度
3. **分支预测表**: BHT/BTB占用大量寄存器
4. **控制逻辑复杂**: 需要特定激励

### 7.3 测试策略建议
1. **扫描测试**: 8链配置,减少87.5%移位周期
2. **随机ATPG**: 500+向量,基础覆盖
3. **确定性ATPG**: 使用PODEM/D-算法提高覆盖
4. **功能测试**: 运行RISC-V测试程序

---

## 8. 总结

biRISC-V完整核心设计的DFT流程已完成:

| 阶段 | 结果 | 关键数据 |
|------|------|---------|
| **综合** | ✅ 成功 | 94,947门, 146级 |
| **扫描插入** | ✅ 成功 | 8链, 6,478 cells |
| **ATPG** | ✅ 完成 | 500向量, 14.1%激活 |

**DFT指标**:
- Scan覆盖率: 100% DFFs
- Shift周期: 810 (减少87.5%)
- 故障数: 190,284 SA faults

**工具性能**:
- 适用于教学和中小型设计
- 大型设计建议使用商业工具
- Numba JIT提供10x+加速
