# 新增数据通路模块说明

## 目录结构
```
rtl/datapath/
├── dma_to_m20k_bridge.v      # DMA→M20K桥接控制器
├── activation_feeder.v        # 激活数据分发器
├── result_collector.v         # 结果收集器
├── inference_controller.v     # 推理流程控制器
└── sfu_datapath_bridge.v      # SFU数据通路桥接
```

## 模块功能概述

### 1. DMA to M20K Bridge (`dma_to_m20k_bridge.v`)
**功能**: 将DMA的Stream输出转换为M20K的写接口

**接口**:
- Input: DMA stream (data, valid, ready)
- Output: M20K write ports (waddr, wdata, we)
- Control: target_buffer, base_addr, transfer_count

**使用场景**: DDR权重/激活数据加载到片上缓冲

---

### 2. Activation Feeder (`activation_feeder.v`)
**功能**: 从M20K读取激活数据并馈送到PE阵列左边界

**特性**:
- 支持INT8 (4 bytes/word) 和 BF16 (2 values/word)
- 自动地址生成
- 可配置ARRAY_SIZE

**数据流**: M20K → Feeder → PE Array[0][*]

---

### 3. Result Collector (`result_collector.v`)
**功能**: 收集PE阵列底部输出的计算结果

**特性**:
- 16深度FIFO缓冲
- 双输出：M20K写入 + DMA Stream
- 自动计数和完成检测

**数据流**: PE Array[*][ARRAY_SIZE-1] → Collector → M20K/DDR

---

### 4. Inference Controller (`inference_controller.v`)
**功能**: 顶层推理流程orchestrator

**状态机** (11状态):
```
IDLE → LOAD_WEIGHTS → WAIT_WEIGHTS →
LOAD_ACTIVATION → WAIT_ACTIVATION →
START_COMPUTE → COMPUTE →
COLLECT_RESULTS → WRITEBACK → WAIT_WRITEBACK →
NEXT_LAYER → [DONE or IDLE]
```

**Ping-Pong缓冲管理**:
- Ping: 0x4000
- Pong: 0x8000
- 自动层间切换

---

### 5. SFU Datapath Bridge (`sfu_datapath_bridge.v`)
**功能**: SFU与M20K之间的数据桥接

**流水线**: Read → SFU Process → Write

**使用场景**: Softmax, LayerNorm, GELU向量化计算

---

## DMA Engine更新

**新增功能**:
- `write_mode` 参数 (0=DDR→Fabric, 1=Fabric→DDR)
- 独立Stream接口:
  - `stream_rd_*` - 读通道 (DDR→Fabric)
  - `stream_wr_*` - 写通道 (Fabric→DDR)
- 写数据打包: 32bit×16 → 512bit

**状态新增**:
- WRITE_REQ: 累积32位字到512位缓冲
- WRITE_DATA: 发起DDR写请求
- WRITE_WAIT: 等待写完成

---

## 完整数据通路

### 推理前向传播流程:
```
1. DDR (weights)
   ↓ [DMA read]
2. dma_to_m20k_bridge
   ↓
3. M20K Buffer (weights)
   ↓ [systolic_array内部加载]
4. PE Array
   ↓ (同时)
5. M20K Buffer (activations)
   ↓ [activation_feeder]
6. PE Array (compute)
   ↓
7. result_collector
   ↓
8. M20K Buffer (results)
   ↓ [DMA write via collector stream]
9. DDR (results)
```

### 控制层次:
```
inference_controller (顶层协调器)
├── DMA Engine (数据搬运)
├── dma_to_m20k_bridge (写入控制)
├── activation_feeder×4 (每个array一个)
├── systolic_array×4 (计算核心)
└── result_collector×4 (结果收集)
```

---

## 集成到npu_top的变更

### 新增信号:
1. DMA读/写Stream分离
2. Bridge控制信号 (target_buffer, base_addr等)
3. Feeder控制信号 (start, done, base_addr)
4. Collector控制信号 (start, done)
5. Inference Controller状态输出

### M20K接口扩展:
- 原有: 只有读端口 (systolic_array权重访问)
- 新增: 写端口 (bridge写入)
- 新增: 第二读端口 (activation_feeder)

---

## 使用示例

### 简单推理任务:
```verilog
// 1. 启动推理
start_inference <= 1'b1;
num_layers <= 8'd1;

// 2. 等待完成
wait(inference_done);

// 3. 检查结果
// 结果已自动写回DDR的result_ddr_addr
```

### 手动控制单层:
```verilog
// 1. 加载权重
dma_start <= 1'b1;
dma_write_mode <= 1'b0;  // Read
bridge_start <= 1'b1;

// 2. 等待加载完成
wait(bridge_done);

// 3. 启动计算
feeder_start[0] <= 1'b1;
array_start[0] <= 1'b1;

// 4. 收集结果
wait(array_done[0]);
collector_start[0] <= 1'b1;
```

---

## 综合资源估算 (Stratix 10)

| 模块 | ALM | M20K | DSP |
|------|-----|------|-----|
| dma_to_m20k_bridge | ~200 | 0 | 0 |
| activation_feeder | ~300 | 0 | 0 |
| result_collector | ~400 | 0 | 0 |
| inference_controller | ~500 | 0 | 0 |
| sfu_datapath_bridge | ~250 | 0 | 0 |
| **Total新增** | ~1650 | 0 | 0 |

**占比**: <1% ALM (Stratix 10 有~933k ALM)

---

## 后续优化方向

1. **性能优化**:
   - DMA burst优化 (当前单beat写)
   - 双缓冲完全流水线化
   - 多阵列并行加载

2. **功能增强**:
   - 动态量化支持
   - Residual Add直接路径
   - Batch处理

3. **调试支持**:
   - Performance counters细化
   - 数据通路追踪
   - Stall原因分析

---

生成日期: 2026-02-28  
版本: 1.0
