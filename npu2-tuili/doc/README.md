# NPU项目 - 完整README

## 项目概述

**项目名称**: 高性能Transformer推理专用NPU  
**目标平台**: Intel Stratix 10 GX 2800 FPGA  
**版本**: V2.0  
**日期**: 2026-02-27

### 核心特性

- **4个Systolic Array**: 默认96×96 PEs(可配置24/48/64/96),共36,864处理单元(满配)
- **混合精度**: INT8 / BF16 双精度支持
- **可配置算力**:
  - 24×24: INT8 2.76 TOPS / BF16 2.76 TFLOPS (快速仿真)
  - 48×48: INT8 11.06 TOPS / BF16 11.06 TFLOPS (推荐调试)
  - 64×64: INT8 19.66 TOPS / BF16 19.66 TFLOPS (较大规模)
  - 96×96: INT8 44.24 TOPS / BF16 44.24 TFLOPS (完整规模,有效算力约22 TOPS)
- **大容量片上存储**: 228MB M20K缓存
- **高速接口**: 48通道 @ 17.4Gbps (103 GB/s)
- **DDR4内存**: 4通道,64GB容量
- **可综合RTL**: 完整Verilog设计

---

## 目录结构

```
npu2-tuili/
├── doc/                        # 设计文档
│   ├── 需求定义.md             # 项目需求 (S10平台)
│   └── 技术方案-S10.md         # 完整技术方案 (46KB)
│
├── rtl/                        # RTL源代码 (1,896行)
│   ├── README.md               # RTL设计文档
│   ├── top/                    # 顶层模块
│   │   └── npu_top.v           # NPU顶层集成
│   ├── pe/                     # 处理单元
│   │   ├── vp_pe.v             # Variable Precision PE
│   │   └── systolic_array.v    # 96×96脉动阵列
│   ├── memory/                 # 存储子系统
│   │   └── m20k_buffer.v       # M20K双端口缓存
│   ├── dma/                    # DMA引擎
│   │   └── dma_engine.v        # DDR4传输控制器
│   ├── control/                # 控制单元
│   │   └── control_unit.v      # 指令解码与调度
│   ├── sfu/                    # 特殊函数单元
│   │   └── sfu_unit.v          # Softmax/LayerNorm/GELU
│   └── ip_models/              # FPGA IP模型
│       └── intel_ip_models.v   # Transceiver/DDR4/DSP模型
│
├── tb/                         # 测试平台 (1,021行)
│   ├── README.md               # 仿真指南
│   ├── tb_vp_pe.v              # PE单元测试
│   ├── tb_m20k_buffer.v        # 缓存测试
│   └── tb_npu_top.v            # 顶层系统测试
│
├── run/                        # 仿真运行目录
│   ├── waves/                  # 波形文件 (.vcd)
│   └── logs/                   # 仿真日志
│
├── Makefile                    # 仿真构建文件 (295行)
├── run_sim.sh                  # 快速仿真脚本 (127行)
└── MANIFEST.md                 # 项目文件清单
```

**统计**:
- RTL代码: 1,896行Verilog
- Testbench: 1,021行
- 文档: 80KB (技术文档) + 933行 (README)
- 脚本: 422行

---

## 快速开始

### 1. 环境准备

**必需工具**:
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install verilator gtkwave g++ make

# 验证安装
verilator --version  # >= 4.0
make --version
```

**可选工具** (用于FPGA综合):
- Intel Quartus Prime Pro 23.4+
- ModelSim (Intel FPGA Edition)

### 2. 克隆/下载项目

```bash
cd /path/to/project
ls -la  # 确认目录结构
```

### 3. 运行仿真

**快速测试**:
```bash
# 方法1: 使用脚本
./run_sim.sh all

# 方法2: 使用Makefile
make all_tests
```

**单个测试**:
```bash
make tb_vp_pe          # PE单元测试
make tb_m20k_buffer    # 缓存测试
make tb_npu_top        # 顶层测试
```

### 4. 查看结果

**日志**:
```bash
cat run/logs/tb_vp_pe.log
```

**波形**:
```bash
gtkwave run/waves/tb_vp_pe.vcd &
```

---

## 模块说明

### 核心计算模块

#### 1. Variable Precision PE (vp_pe.v)
- **功能**: 支持INT8/BF16的处理单元
- **流水线**: 3级 (Input → Multiply → Accumulate)
- **延迟**: 3 cycles
- **资源**: 1 DSP块 + 寄存器

#### 2. Systolic Array (systolic_array.v)
- **规模**: 可配置 24×24 / 48×48 / 64×64 / 96×96
- **架构**: Weight Stationary
- **性能** (96×96配置): INT8 18K ops/cycle, BF16 9K ops/cycle
- **状态**: IDLE → LOAD_W → COMPUTE → DRAIN
- **说明**: 通过修改`ARRAY_SIZE`参数可调整阵列规模,降低仿真复杂度

#### 3. M20K Buffer (m20k_buffer.v)
- **类型**: True Dual-Port
- **容量**: 可配置 (默认1MB)
- **延迟**: 读取1 cycle
- **特性**: 双缓冲权重管理

### 控制与接口

#### 4. Control Unit (control_unit.v)
- **指令集**: 256-bit宽指令
- **调度**: 4路阵列调度
- **性能计数**: 周期数、操作数统计

#### 5. DMA Engine (dma_engine.v)
- **接口**: Avalon-MM Master
- **Burst**: 最大256 beats
- **FIFO**: 16-entry缓冲

#### 6. SFU Unit (sfu_unit.v)
- **功能**: Softmax, LayerNorm, GELU
- **实现**: LUT近似 + 流水线

### IP模型

#### 7. Intel IP Models (intel_ip_models.v)
- **Transceiver**: 通信接口模型
- **DDR4 EMIF**: 内存控制器模型
- **VP DSP**: Variable Precision DSP模型
- **用途**: 仿真验证,综合时替换为真实IP

---

## 仿真验证

### Testbench功能

| Testbench | 测试内容 | 测试数量 |
|-----------|---------|---------|
| tb_vp_pe | INT8/BF16运算,流水线 | 5个测试 |
| tb_m20k_buffer | 读写、双端口、延迟 | 4个测试 |
| tb_npu_top | 复位、指令、性能计数 | 4个测试 |

### 运行仿真

```bash
# 单个测试
make tb_vp_pe

# 所有测试
make all_tests

# 快速脚本
./run_sim.sh pe       # PE测试
./run_sim.sh buffer   # Buffer测试
./run_sim.sh top      # 顶层测试
./run_sim.sh all      # 所有测试
```

### 预期结果

```
=========================================
  NPU Simulation Runner
=========================================

Using: Verilator 4.228 2022-01-17 rev v4.228

Running test: tb_vp_pe
----------------------------------------
========================================
  Variable Precision PE Testbench
========================================

Test 1: INT8 Simple Multiply
----------------------------
  PASS: 5 * 3 = 15 (expected 15)

...

========================================
  Test Summary
========================================
Total tests: 5
Passed:      5
Failed:      0

*** ALL TESTS PASSED ***
```

### 查看波形

```bash
# 使用Makefile
make view_vp_pe

# 手动打开
gtkwave run/waves/tb_vp_pe.vcd &
```

---

## FPGA综合

### Quartus设置

**创建项目**:
1. 打开Quartus Prime Pro
2. File → New Project Wizard
3. 添加RTL文件 (rtl/**/*.v)
4. 设备: 1SG280LU3F50E3VG (Stratix 10 GX 2800)

**时钟约束** (npu.sdc):
```sdc
create_clock -name clk -period 1.667ns [get_ports clk]
set_false_path -from [get_ports rst_n]
```

**综合设置**:
```tcl
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED
```

**替换IP**:
- `comm_interface` → Intel Transceiver PHY IP
- `ddr4_emif_model` → Intel EMIF IP
- `vp_dsp_model` → `twentynm_mac` 原语

### 资源预估

| 资源 | 预计 | 可用 | 利用率 |
|------|------|------|--------|
| ALM | 560K | 933K | 60% |
| DSP | 5,760 | 5,760 | 100% |
| M20K | 11,400 | 11,721 | 97% |
| 寄存器 | 2.2M | 3.7M | 59% |

### 预期性能

**完整配置 (96×96 PE阵列)**:
- **INT8理论峰值**: 44.24 TOPS @ 600MHz
- **INT8有效算力**: ~22 TOPS (考虑40-50%访存效率)
- **BF16理论峰值**: 44.24 TFLOPS @ 600MHz  
- **BF16有效算力**: ~5.5 TFLOPS (考虑约20%访存效率)
- **功耗**: ~90W (典型)

**可配置规模对应算力**:
| 配置 | 理论峰值(INT8) | 有效算力(INT8) | 适用场景 |
|------|--------------|--------------|---------|
| 24×24 | 2.76 TOPS | ~1.4 TOPS | 快速仿真 |
| 48×48 | 11.06 TOPS | ~5.5 TOPS | 推荐调试 |
| 64×64 | 19.66 TOPS | ~9.8 TOPS | 较大规模 |
| 96×96 | 44.24 TOPS | ~22 TOPS | 完整规模 |

---

## 文档

### 核心文档

1. **doc/需求定义.md**
   - 项目需求
   - 性能目标
   - 接口规格

2. **doc/技术方案-S10.md** (46KB)
   - 完整架构设计
   - 模块详细说明
   - 性能分析
   - 实现路线图

3. **rtl/README.md**
   - RTL模块说明
   - 综合指南
   - 已知限制

4. **tb/README.md**
   - 仿真指南
   - Testbench说明
   - 调试技巧

5. **MANIFEST.md**
   - 文件清单
   - 代码统计
   - 验证状态

---

## 开发指南

### 添加新模块

1. **创建RTL文件**: `rtl/category/module_name.v`
2. **编写testbench**: `tb/tb_module_name.v`
3. **更新Makefile**: 添加编译规则
4. **运行测试**: `make tb_module_name`

### 修改现有模块

1. 修改RTL文件
2. 运行相关testbench验证
3. 检查综合结果
4. 更新文档

### 代码规范

- 使用4空格缩进
- 模块命名: `module_name.v`
- 信号命名: `snake_case`
- 添加头部注释说明功能
- 重要逻辑添加行内注释

---

## 常见问题

### Q1: Verilator编译错误

**错误**: `Cannot find file`

**解决**:
- 检查Makefile中的路径
- 确认所有RTL文件存在
- 使用 `make clean` 清理后重试

### Q2: 仿真卡住不动

**原因**: 缺少 `$finish` 或超时设置

**解决**: 检查testbench中的超时监控

### Q3: 波形显示异常

**解决**:
```bash
# 清理并重新生成
make clean_waves
make tb_vp_pe
gtkwave run/waves/tb_vp_pe.vcd
```

### Q4: Quartus综合失败

**可能原因**:
- 时序不满足: 降低频率或增加流水线
- 资源超限: 减少阵列规模
- IP未替换: 用真实IP替换模型

---

## 未来工作

### 短期 (1-2周)
- [ ] 完善DMA写通道
- [ ] 增加更多testbench
- [ ] 替换BF16为Intel FP IP
- [ ] 时序优化

### 中期 (1个月)
- [ ] 集成实际Intel IP
- [ ] FPGA板级验证
- [ ] 性能profiling
- [ ] 功耗优化

### 长期 (2-3个月)
- [ ] 编译器工具链
- [ ] 多卡互联
- [ ] 端到端模型验证
- [ ] 软件驱动开发

---

## 贡献

欢迎提交Issue和Pull Request!

### 联系方式

技术问题: 提交Issue  
文档改进: Pull Request

---

## 许可证

本项目仅供学习和研究使用。

---

## 致谢

- Intel Stratix 10 FPGA平台
- Verilator开源仿真器
- 开源社区

---

**项目状态**: 开发中  
**最后更新**: 2026-02-27  
**版本**: V2.0
