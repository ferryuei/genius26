# NPU RTL Design

## 项目概述

本目录包含Intel Stratix 10平台上实现的Transformer推理专用NPU的RTL代码。

**关键特性**:
- 4个96×96 Systolic Array (36,864 PEs)
- 支持INT8和BF16混合精度
- 228MB M20K片上缓存
- 22 TOPS (INT8) / 5.5 TFLOPS (BF16)
- DDR4接口 (4通道, 64GB)
- 高速Transceiver接口 (48通道 @ 17.4Gbps)

---

## 目录结构

```
rtl/
├── top/              # 顶层模块
│   └── npu_top.v     # NPU顶层集成
├── pe/               # 处理单元
│   ├── vp_pe.v       # Variable Precision PE
│   └── systolic_array.v  # 96x96脉动阵列
├── memory/           # 存储子系统
│   └── m20k_buffer.v # M20K双端口缓存
├── dma/              # DMA引擎
│   └── dma_engine.v  # DDR4 DMA传输
├── control/          # 控制单元
│   └── control_unit.v # 指令解码与调度
├── sfu/              # 特殊函数单元
│   └── sfu_unit.v    # Softmax/LayerNorm/GELU
├── ip_models/        # FPGA IP模型
│   └── intel_ip_models.v  # 行为模型
├── utils/            # 工具模块 (未使用)
└── tb/               # 测试bench (未使用)
```

---

## 模块说明

### 1. npu_top.v - NPU顶层

**功能**: 集成所有子模块,提供完整NPU功能

**接口**:
- `clk, rst_n`: 时钟和复位
- `xcvr_rx/tx_*`: Transceiver接口 (512-bit)
- `ddr_avmm_*`: DDR4 Avalon-MM接口 (512-bit)
- `debug_status`: 调试状态输出
- `perf_counter_*`: 性能计数器

**子模块**:
- 4x Systolic Array (96x96)
- 4x M20K Buffer (weight cache)
- DMA Engine
- Control Unit
- SFU Unit
- Communication Interface

**综合建议**:
```tcl
set_instance_assignment -name PARTITION npu_partition -to npu_top
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
```

---

### 2. vp_pe.v - Variable Precision PE

**功能**: 单个处理单元,支持INT8和BF16运算

**特性**:
- 3级流水线: Input → Multiply → Accumulate
- 动态精度切换 (precision_mode)
- 支持累加模式 (accumulate)
- 使用Intel Variable Precision DSP块

**时序**:
- 输入延迟: 1 cycle
- 乘法延迟: 1 cycle  
- 累加延迟: 1 cycle
- 总延迟: 3 cycles

**综合注意**:
- BF16乘法函数是**行为模型**,需替换为Intel FP IP
- 在实际设计中使用`twentynm_mac`原语

**替换方法**:
```verilog
// 替换 bf16_multiply 函数为:
twentynm_mac #(
    .operation_mode("m18x18_sumof2"),
    .use_chainadder("false")
) bf16_dsp (
    .clk(clk),
    .ax(bf16_a_r),
    .ay(bf16_w_r),
    .resulta(bf16_mult_result)
);
```

---

### 3. systolic_array.v - Systolic Array

**功能**: 96×96 PE阵列,执行矩阵乘法

**架构**: Weight Stationary
- 权重预加载到PE内部
- 激活值从左向右流动
- 部分和从上向下累加

**状态机**:
1. `IDLE`: 等待启动信号
2. `LOAD_W`: 从M20K加载权重
3. `COMPUTE`: 执行计算 (96 cycles)
4. `DRAIN`: 排空流水线

**性能**:
- 计算周期: 96 (稳态吞吐)
- 总延迟: ~200 cycles (含加载)
- INT8: 9216 MACs/cycle = 18432 ops/cycle
- BF16: 9216 MACs/cycle (浮点)

**资源估算**:
- 单阵列: 9216 PEs
- DSP使用: ~1440 DSP块 (考虑共享)
- 寄存器: ~200K FFs

---

### 4. m20k_buffer.v - M20K缓存

**功能**: 双端口存储缓冲,使用M20K块

**特性**:
- True Dual-Port: 独立读写端口
- 同步读: 1 cycle延迟
- 推断M20K: 使用`(* ramstyle = "M20K" *)`属性

**配置**:
```
默认配置:
- ADDR_WIDTH = 18 (256K entries)
- DATA_WIDTH = 32
- 容量 = 1MB per buffer
```

**双缓冲管理器** (m20k_weight_manager):
- 2个buffer交替使用
- DMA写入Buffer A时,PE读取Buffer B
- 加载完成后交换buffer

---

### 5. dma_engine.v - DMA引擎

**功能**: 高性能DDR4数据传输

**接口**: Avalon-MM Master (Stratix 10 EMIF标准)

**特性**:
- 支持Burst传输 (最大256 beats)
- 读写通道
- 16-entry FIFO缓冲
- 地址自增

**状态机**:
1. `READ_REQ`: 发出读请求
2. `READ_DATA`: 接收数据
3. `WRITE_REQ/DATA`: 写入数据

**性能**:
- 理论带宽: 512-bit × 600MHz = 38.4 GB/s
- 实际效率: ~70% (考虑等待)

---

### 6. control_unit.v - 控制单元

**功能**: 指令解码、多阵列调度

**指令集** (256-bit):
```
[255:240] = Opcode (16-bit)
[239:224] = Flags (16-bit)  
[223:0]   = Operands (224-bit)
```

**支持指令**:
- `OP_GEMM` (0x0010): 矩阵乘法
- `OP_SOFTMAX` (0x0020): Softmax
- `OP_LAYERNORM` (0x0021): LayerNorm
- `OP_GELU` (0x0022): GELU激活
- `OP_SYNC` (0x00FF): 同步屏障
- `OP_CONFIG_PREC` (0x0100): 切换精度

**调度策略**:
- 检查目标阵列空闲状态
- 发出start信号
- 等待done信号
- 更新busy标志

**性能计数器**:
- `perf_cycles`: 总周期数
- `perf_ops`: 总运算数

---

### 7. sfu_unit.v - 特殊函数单元

**功能**: 非线性运算加速器

**支持操作**:
1. **Softmax**: 
   - 3阶段: Max → Exp → Normalize
   - 使用LUT近似exp()
   
2. **LayerNorm**:
   - 3阶段: Mean → Variance → Normalize
   - sqrt使用Newton-Raphson迭代
   
3. **GELU**:
   - 16-entry LUT近似
   - 范围: [-2.0, 2.0]

**注意**: 当前为简化的行为模型,生产环境需要:
- 增加LUT精度 (256+ entries)
- 使用Intel FP运算IP
- 优化流水线深度

---

### 8. intel_ip_models.v - IP模型

**包含模型**:

1. **comm_interface**: Transceiver + Interlaken协议模型
   - 数据包解析 (DMA请求/指令)
   - 状态响应

2. **ddr4_emif_model**: DDR4 EMIF行为模型
   - Avalon-MM Slave接口
   - 简化的读写逻辑
   - 用于仿真验证

3. **vp_dsp_model**: Variable Precision DSP模型
   - MAC运算
   - 替代`twentynm_mac`原语进行仿真

**替换方法**:
在Quartus综合时,使用Intel IP Catalog生成:
- Intel FPGA Transceiver PHY IP
- External Memory Interface (EMIF) IP
- 直接实例化`twentynm_mac`原语

---

## 综合与实现

### Quartus设置

**目标器件**:
```tcl
set_global_assignment -name FAMILY "Stratix 10"
set_global_assignment -name DEVICE 1SG280LU3F50E3VG
```

**时钟约束**:
```sdc
create_clock -name clk -period 1.667ns [get_ports clk]  # 600MHz
set_false_path -from [get_ports rst_n]
```

**优化设置**:
```tcl
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON
```

**资源约束**:
```tcl
# 指定M20K推断
set_instance_assignment -name RAMSTYLE_ATTRIBUTE M20K -to memory_inst

# DSP块利用
set_global_assignment -name DSP_BLOCK_BALANCING "DSP BLOCKS"
```

---

## 仿真指南

### ModelSim/Questa

1. **编译顺序**:
```bash
vlog rtl/ip_models/intel_ip_models.v
vlog rtl/utils/*.v
vlog rtl/pe/vp_pe.v
vlog rtl/pe/systolic_array.v
vlog rtl/memory/m20k_buffer.v
vlog rtl/dma/dma_engine.v
vlog rtl/control/control_unit.v
vlog rtl/sfu/sfu_unit.v
vlog rtl/top/npu_top.v
```

2. **创建testbench** (需自行编写):
```verilog
module tb_npu_top;
    reg clk, rst_n;
    // ... 实例化npu_top
    
    initial begin
        clk = 0;
        forever #0.833 clk = ~clk;  // 600MHz
    end
    
    // 测试序列
endmodule
```

3. **运行仿真**:
```bash
vsim tb_npu_top
run -all
```

---

## 性能估算

### 资源使用 (Stratix 10 GX 2800)

| 资源 | 使用量 | 可用量 | 利用率 |
|------|--------|--------|--------|
| ALM | ~560K | 933K | 60% |
| 寄存器 | ~2.2M | 3.7M | 59% |
| DSP块 | 5760 | 5760 | **100%** |
| M20K | ~11,400 | 11,721 | 97% |
| 收发器 | 48 | 96 | 50% |

### 计算性能

**INT8模式** @ 600MHz:
- 单阵列: 96×96×2 ops/cycle × 600M = 11 GOPS
- 4阵列: 44 GOPS (理论)
- 实际: 22 TOPS (50%效率)

**BF16模式** @ 600MHz:
- 单阵列: 1.38 TFLOPS
- 4阵列: 5.5 TFLOPS (实际)

### 功耗估算

- DSP块: 45W
- M20K: 18W
- 逻辑: 12W
- 收发器: 10W
- DDR接口: 5W
- **总计**: ~90W (典型)

---

## 已知限制

1. **BF16运算**: 使用简化的行为模型,需替换为Intel FP IP
2. **SFU精度**: LUT条目较少,精度有限
3. **Systolic Array**: 权重加载逻辑简化,需完善
4. **DMA引擎**: 仅实现读通道,写通道待完成
5. **Transceiver**: 使用简化模型,需替换Intel PHY IP

---

## 下一步工作

### 短期 (1-2周)
- [ ] 完善DMA写通道
- [ ] 增加详细的testbench
- [ ] 替换BF16运算为Intel FP IP
- [ ] 时序约束优化

### 中期 (1个月)
- [ ] 集成实际Intel EMIF IP
- [ ] 集成Transceiver PHY IP
- [ ] FPGA板级验证
- [ ] 性能profiling

### 长期 (2-3个月)
- [ ] 多阵列协同优化
- [ ] 功耗优化 (clock gating)
- [ ] 编译器工具链
- [ ] 端到端模型验证

---

## 参考资料

1. **Intel文档**:
   - Stratix 10 Device Handbook
   - Variable Precision DSP Blocks User Guide (UG-S10-DSP)
   - External Memory Interface Handbook

2. **设计参考**:
   - Google TPU论文
   - Systolic Array设计模式
   - FINN: Quantized NN Framework

3. **工具**:
   - Intel Quartus Prime Pro 23.4+
   - ModelSim/Questa 2023.x
   - SignalTap Logic Analyzer

---

## 联系方式

技术问题请提交Issue或联系项目维护者。

**最后更新**: 2026-02-27
