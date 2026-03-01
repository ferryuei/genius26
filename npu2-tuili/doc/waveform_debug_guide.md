# GTKWave 信号分析指南

## 推理模式失败诊断

### Test 5 在 1102ns 开始，需要检查以下信号：

## 第1组：推理控制器状态
```
dut.u_inference_controller.state[3:0]
dut.u_inference_controller.start_inference
dut.u_inference_controller.instr_valid
dut.u_inference_controller.instr_ready
dut.u_inference_controller.inference_done
```

预期行为：
- state 应从 IDLE (0000) → LOAD_WEIGHTS (0001) → ...
- 如果卡在 IDLE，说明启动条件未满足

## 第2组：指令握手
```
dut.start_inference
dut.u_comm_interface.instr_valid
dut.instr_ready
dut.instr_ready_infer
dut.instr_ready_ctrl
```

检查点：
- start_inference = 1 时，instr_ready 应该 = instr_ready_infer
- instr_valid 和 instr_ready 握手成功吗？

## 第3组：DMA 控制
```
dut.u_dma_engine.dma_start
dut.u_dma_engine.state[2:0]
dut.ddr_avmm_read
dut.ddr_avmm_readdatavalid
```

检查点：
- dma_start 有脉冲吗？
- DMA 状态机离开 IDLE 了吗？
- DDR 读请求发出了吗？

## 第4组：Bridge 控制
```
dut.u_dma_to_m20k_bridge.bridge_start  
dut.u_dma_to_m20k_bridge.bridge_done
dut.u_dma_to_m20k_bridge.stream_valid
dut.u_dma_to_m20k_bridge.stream_ready
```

检查点：
- bridge_start 触发了吗？
- 数据流动了吗？

## 第5组：M20K 写入
```
dut.m20k_we[0]
dut.m20k_waddr[0]
dut.m20k_wdata[0][31:0]
```

检查点：
- M20K 写使能有脉冲吗？
- 地址递增了吗？

## 诊断流程

### 步骤1: 检查 inference_controller 是否启动
在 1102ns 后：
- 如果 state 保持 0000 (IDLE)，检查 start_inference 和 instr_valid
- 如果 state 变为 0001 (LOAD_WEIGHTS)，继续步骤2

### 步骤2: 检查 DMA 是否启动
在 LOAD_WEIGHTS 状态：
- dma_start 应该产生脉冲
- DMA 状态机应该从 IDLE → READ_REQ
- 如果没有，检查 DMA 控制信号连接

### 步骤3: 检查 DDR 读取
- ddr_avmm_read 应该置位
- 几个周期后 ddr_avmm_readdatavalid 应该返回
- 如果没有，检查 DDR 模型

### 步骤4: 检查 Bridge 数据流
- stream_valid 应该从 DMA 输出
- stream_ready 应该从 Bridge 反馈
- 如果不匹配，检查握手逻辑

### 步骤5: 检查 M20K 写入
- m20k_we 应该有写脉冲
- waddr 应该递增
- 如果没有，检查 Bridge 输出

## 常见问题模式

### 模式1: 卡在 IDLE
症状：state = 0000，不变化
可能原因：
- instr_valid 未到达 inference_controller
- instr_ready 握手失败
- start_inference 和 instr_valid 都未满足条件

### 模式2: 卡在 LOAD_WEIGHTS
症状：state = 0001，等待 bridge_done
可能原因：
- DMA 未启动
- DMA 启动但无数据返回
- Bridge 未接收数据

### 模式3: DMA 无响应
症状：dma_start 有脉冲，但 DMA state 不变
可能原因：
- dma_src_addr 配置错误
- dma_length 为 0
- DMA 内部逻辑问题

### 模式4: DDR 无响应
症状：ddr_avmm_read 置位，但无 readdatavalid
可能原因：
- DDR 模型的阻塞延迟问题
- 地址超出范围
- waitrequest 一直置位

## 快速检查命令

在 GTKWave 中添加信号后，按照时间顺序检查：

1. 找到 1102ns（Test 5 开始）
2. 检查 start_inference 是否 = 1
3. 检查 inference_controller.state
4. 如果 state != 0，跟踪后续状态转换
5. 如果 state = 0，检查启动条件

## 预期时序（正常情况）

```
T+0:    start_inference = 1, 发送指令
T+1:    instr_valid = 1
T+2:    state → LOAD_WEIGHTS
T+3:    dma_start = 1, bridge_start = 1
T+10:   ddr_avmm_read = 1
T+15:   ddr_avmm_readdatavalid = 1
T+20:   m20k_we = 1（开始写入）
T+100:  state → LOAD_ACTIVATION
...
```

对比实际时序，找出第一个偏差点！
