# NPU项目文件清单

## 已生成文件统计

### 文档 (doc/)
- `需求定义.md` (6.1KB) - Intel S10平台需求定义
- `技术方案.md` (28KB) - Xilinx VU13P原始方案
- `技术方案-S10.md` (46KB) - Intel S10完整技术方案

### RTL代码 (rtl/)

#### 核心模块 (1,896行Verilog代码)
1. **顶层** (265行)
   - `top/npu_top.v` - NPU顶层集成模块

2. **处理单元** (393行)
   - `pe/vp_pe.v` (196行) - Variable Precision PE
   - `pe/systolic_array.v` (197行) - 96×96 Systolic Array

3. **存储子系统** (211行)
   - `memory/m20k_buffer.v` - M20K双端口缓存 + 权重管理器

4. **DMA引擎** (219行)
   - `dma/dma_engine.v` - DDR4 Avalon-MM DMA传输

5. **控制单元** (272行)
   - `control/control_unit.v` - 指令解码与调度器

6. **特殊函数单元** (291行)
   - `sfu/sfu_unit.v` - Softmax/LayerNorm/GELU加速器

7. **IP模型** (245行)
   - `ip_models/intel_ip_models.v` - Intel IP行为模型
     - comm_interface (Transceiver)
     - ddr4_emif_model (DDR4 EMIF)
     - vp_dsp_model (Variable Precision DSP)

#### 文档
- `rtl/README.md` (426行) - 完整的RTL设计文档

### 总代码量
- **Verilog代码**: 1,896行
- **文档**: 426行 (README) + 80KB (技术文档)
- **总计**: 2,322行

---

## 文件目录树

```
npu2-tuili/
├── doc/
│   ├── 需求定义.md                  # S10平台需求 (V2.0)
│   ├── 技术方案.md                  # VU13P原始方案
│   └── 技术方案-S10.md              # S10完整技术方案 ⭐
│
└── rtl/
    ├── README.md                    # RTL设计文档 ⭐
    ├── top/
    │   └── npu_top.v                # 顶层模块 ⭐
    ├── pe/
    │   ├── vp_pe.v                  # Variable Precision PE ⭐
    │   └── systolic_array.v         # Systolic Array ⭐
    ├── memory/
    │   └── m20k_buffer.v            # M20K缓存管理 ⭐
    ├── dma/
    │   └── dma_engine.v             # DMA引擎 ⭐
    ├── control/
    │   └── control_unit.v           # 控制器 ⭐
    ├── sfu/
    │   └── sfu_unit.v               # 特殊函数单元 ⭐
    ├── ip_models/
    │   └── intel_ip_models.v        # Intel IP模型 ⭐
    ├── utils/                       # (预留)
    └── tb/                          # (预留)
```

---

## 模块连接关系

```
npu_top
├── comm_interface (IP模型)
│   └── 解析Transceiver数据包 → 生成指令
│
├── control_unit
│   ├── 解码256-bit指令
│   ├── 调度4个阵列
│   └── 管理精度切换
│
├── dma_engine
│   ├── 连接DDR4 (Avalon-MM)
│   └── 数据流 → M20K缓存
│
├── systolic_array (×4)
│   ├── 96×96 PEs (vp_pe)
│   ├── INT8: 11 GOPS/阵列
│   └── BF16: 1.38 TFLOPS/阵列
│
├── m20k_buffer (×4)
│   ├── 双缓冲权重管理
│   └── 180MB总缓存
│
└── sfu_unit
    ├── Softmax
    ├── LayerNorm
    └── GELU
```

---

## 关键设计特点

### 1. 模块化设计
- 清晰的层次结构
- 标准接口 (Avalon-MM, AXI-Stream风格)
- 易于集成和测试

### 2. FPGA友好
- 使用`(* ramstyle = "M20K" *)`推断M20K
- 流水线设计,适合高频
- 避免组合逻辑环路

### 3. 参数化
- 可配置阵列大小、数据宽度
- 易于缩放和移植

### 4. IP隔离
- Intel IP用行为模型替代
- 便于仿真和跨平台移植
- 生产时替换为真实IP

### 5. 注释完善
- 每个模块有详细功能说明
- 接口定义清晰
- 包含综合建议

---

## 代码质量

### 可综合性
- ✅ 所有代码遵循可综合Verilog规范
- ✅ 避免initial块 (仅用于仿真初始化)
- ✅ 使用always @(posedge clk)同步逻辑
- ✅ 参数化设计

### 时序考虑
- ✅ 充分流水线化 (PE: 3级流水)
- ✅ 寄存器输出
- ⚠️ 需时序约束文件 (.sdc)

### 功能完整性
- ✅ 核心计算路径完整
- ⚠️ SFU为简化模型,需增强
- ⚠️ DMA写通道待完成
- ⚠️ 缺少testbench

---

## 下一步建议

### 立即可做
1. **创建.sdc时钟约束文件**
2. **编写简单testbench验证PE功能**
3. **替换BF16行为模型为Intel FP IP**

### 短期 (1周内)
4. **完善DMA写通道**
5. **增加SignalTap调试节点**
6. **资源利用率优化**

### 中期 (1月内)
7. **集成实际Intel EMIF IP**
8. **板级验证**
9. **性能profiling**

---

## 验证状态

| 模块 | 仿真验证 | 综合验证 | 板级验证 |
|------|---------|---------|---------|
| vp_pe | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |
| systolic_array | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |
| m20k_buffer | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |
| dma_engine | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |
| control_unit | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |
| sfu_unit | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |
| npu_top | ⏳ 待完成 | ⏳ 待完成 | ⏳ 待完成 |

---

**生成时间**: 2026-02-27  
**代码版本**: V1.0
