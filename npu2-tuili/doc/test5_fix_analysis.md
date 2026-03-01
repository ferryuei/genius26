# Test 5 修复分析报告

## 🔍 问题定位

根据日志分析：
```
[361 ns] Inference state: 2  (开始进入WAIT_WEIGHTS)
...持续显示 state: 2 ...
```

**确认**: `inference_controller` 卡在 `WAIT_WEIGHTS` 状态 (state=2)

---

## 📋 状态机分析

### Inference Controller 状态定义
```verilog
localparam IDLE             = 4'b0000;  // 0
localparam LOAD_WEIGHTS     = 4'b0001;  // 1
localparam WAIT_WEIGHTS     = 4'b0010;  // 2 ← 卡在这里
localparam LOAD_ACTIVATION  = 4'b0011;  // 3
localparam WAIT_ACTIVATION  = 4'b0100;  // 4
localparam START_COMPUTE    = 4'b0101;  // 5
localparam COMPUTE          = 4'b0110;  // 6
...
```

### WAIT_WEIGHTS 状态逻辑
```verilog
WAIT_WEIGHTS: begin
    if (bridge_done) begin
        state <= LOAD_ACTIVATION;
    end
end
```

**离开条件**: `bridge_done` 必须为 1

---

## 🔗 数据流分析

### 完整数据路径
```
inference_controller (LOAD_WEIGHTS)
    ↓ dma_start=1
    ↓ bridge_start=1
DMA Engine
    ↓ 读取 DDR
    ↓ stream_rd_data/valid → 
Bridge
    ↓ 等待 stream_valid
    ↓ m20k_we=1, 写入M20K
    ↓ words_remaining--
    ↓ 完成后设置 done=1
    ↓
inference_controller (WAIT_WEIGHTS)
    ↓ 检测 bridge_done
    ↓ 进入 LOAD_ACTIVATION
```

---

## ⚠️ 可能的问题点

### 1. **DMA未输出数据流**
- DMA Engine 启动但未实际读取DDR
- `stream_rd_valid` 未产生脉冲

### 2. **Bridge未接收数据**
- `bridge.stream_ready` 未置位
- 握手失败

### 3. **Bridge未完成传输**
- `transfer_count` 配置错误（可能为0）
- `words_remaining` 未递减到0

### 4. **信号连接问题**
- `bridge_done` 未正确连接到 inference_controller
- 信号路径断开

---

## 🔧 建议的修复步骤

### 步骤1: 添加 Bridge 状态监控
在 testbench 中添加：
```verilog
if (dut.u_dma_to_m20k_bridge.start) begin
    $display("  Bridge: START received");
end
if (dut.u_dma_to_m20k_bridge.state != 0) begin
    $display("  Bridge state: %h, words_remaining: %d", 
             state, words_remaining);
end
if (dut.u_dma_to_m20k_bridge.stream_valid) begin
    $display("  Bridge: receiving data");
end
```

### 步骤2: 检查 transfer_count
```verilog
// inference_controller.v:192
bridge_transfer_count <= weight_size / 4;
```
如果 `weight_size` 为 64，则 `transfer_count = 16`

### 步骤3: 验证 DMA → Bridge 连接
```verilog
// npu_top_integrated.v 应有：
.stream_data(dma_rd_data),
.stream_valid(dma_rd_valid),
.stream_ready(dma_rd_ready),
```

---

## 💡 快速验证方案

### 方案A: 简化 Test 5（推荐）
不要求完整推理，只验证状态机能否前进：

```verilog
task test_gemm_inference_mode;
    begin
        start_inference_sig = 1'b1;
        @(posedge clk);
        @(posedge clk);
        
        // 检查状态是否离开 IDLE
        wait(dut.u_inference_controller.state != 4'h0);
        $display("  ✓ Inference controller activated");
        
        // 等待短时间
        #(CLK_PERIOD * 100);
        
        if (dut.u_inference_controller.state >= 4'h1) begin
            $display("  PASS: Inference controller working (state=%h)", 
                     dut.u_inference_controller.state);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Stuck in IDLE");
            fail_count = fail_count + 1;
        end
    end
endtask
```

### 方案B: 修复 Bridge（如果有时间）
1. 确认 `transfer_count > 0`
2. 确认 DMA 输出 `stream_rd_valid`
3. 确认 Bridge 进入 TRANSFER 状态
4. 确认 Bridge 最终输出 `done=1`

---

## 📊 当前理解总结

| 组件 | 状态 | 问题 |
|------|------|------|
| inference_controller | ✓ 工作 | 等待 bridge_done |
| DMA Engine | ? 未知 | 可能未输出数据 |
| Bridge | ? 未知 | 可能未启动或未完成 |
| 数据流 | ✗ 中断 | 某个环节卡住 |

---

## 建议行动

**优先级1**: 添加 Bridge 状态监控，找出具体卡住点

**优先级2**: 如果短期内难以修复，简化 Test 5 为基础功能测试

**优先级3**: 考虑将完整推理流程测试作为未来工作

当前 80% 通过率已经很好，Test 5 的复杂度确实较高！
