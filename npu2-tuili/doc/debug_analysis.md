# NPU 仿真调试分析

## 问题现状

仿真运行完成，但 **Test 3 无数组活动**：
- ✓ 指令被接收 (`type=0x0010`)
- ✗ `array_busy` 保持 `4'b0000`
- ✗ `perf_counter_ops = 0`

## 关键发现

### 1. **Inference Controller 的启动条件**

查看 `inference_controller.v:165`：
```verilog
if (start_inference || (instr_valid && instr_ready)) begin
```

这意味着 inference_controller 可以通过**两种方式**启动：
- **方式A**: `start_inference` 信号（推理模式）
- **方式B**: `instr_valid` 信号（指令模式）

### 2. **当前 Testbench 状态**

```verilog
// 在 tb_npu_top.v 中：
start_inference_sig = 0;  // 初始化为0，测试中未改变

// 发送 GEMM 指令：
xcvr_rx_data <= {...};  // PKT_TYPE_INSTR = 0x0010
xcvr_rx_valid <= 1;
```

### 3. **数据流分析**

```
Testbench
   ↓ xcvr_rx_valid=1, xcvr_rx_data (PKT_TYPE_INSTR)
comm_interface (解析数据包)
   ↓ instr_valid=1, instruction[255:0]
inference_controller (IDLE 状态)
   ↓ 检查: start_inference || instr_valid
   ✓ 条件满足！应该进入 LOAD_WEIGHTS
```

理论上应该工作！那为什么没有响应？

## 可能的原因

### **原因1: comm_interface 与 inference_controller 连接问题**

查看 `npu_top_integrated.v`，需要确认：
- `comm_interface.instr_valid` → `inference_controller.instr_valid`
- `comm_interface.instruction` → `inference_controller.instruction`

可能存在信号连接错误或冲突。

### **原因2: control_unit 抢占了 instruction**

`npu_top_integrated.v` 中可能同时实例化了：
- `control_unit` - 接收 `instruction`
- `inference_controller` - 也接收 `instruction`

可能存在**优先级冲突**或**信号争用**。

### **原因3: 指令格式问题**

虽然我们按照规范构造了指令：
```
[255:240] = 0x0010 (OP_GEMM)
[239:224] = 0x0000 (Flags)
[223:192] = src_addr
...
```

但 `inference_controller` 可能期望**不同的字段布局**。

## 验证步骤

### 步骤1: 检查波形中的关键信号

在 GTKWave 中添加这些信号：
```
dut.u_comm_interface.instr_valid
dut.u_comm_interface.instruction[255:240]
dut.u_inference_controller.instr_valid
dut.u_inference_controller.state[3:0]
dut.u_inference_controller.instr_ready
dut.u_control_unit.instr_valid
dut.u_control_unit.instr_ready
```

### 步骤2: 分析信号时序

在 88ns（指令发送时）：
- `xcvr_rx_valid` 应该为 1
- `comm_interface.instr_valid` 应该在下个周期变为 1
- `inference_controller.instr_valid` 应该收到信号
- `inference_controller.state` 应该从 IDLE (0000) → LOAD_WEIGHTS (0001)

### 步骤3: 检查连接

查看 `npu_top_integrated.v` 中的实例化：
```verilog
comm_interface u_comm_interface (
    .instruction(instruction),
    .instr_valid(instr_valid),
    ...
);

inference_controller u_inference_controller (
    .instruction(instruction),      // 同一个信号？
    .instr_valid(instr_valid),      // 同一个信号？
    .instr_ready(instr_ready),
    ...
);

control_unit u_control_unit (
    .instruction(instruction),      // 冲突！
    .instr_valid(instr_valid),      // 冲突！
    .instr_ready(instr_ready),      // 冲突！
    ...
);
```

**这里是问题所在！**

两个模块都连接到同一个 `instruction` 和 `instr_valid` 信号，但它们的 `instr_ready` 可能不同步，导致握手失败！

## 解决方案

### 方案A: 使用 inference_controller，禁用 control_unit
在集成版本中，inference_controller 应该替代 control_unit 的部分功能。

### 方案B: 添加仲裁逻辑
在两个控制器之间添加指令分发逻辑：
- 如果 `start_inference=1`，指令路由到 `inference_controller`
- 否则路由到 `control_unit`

### 方案C: 简化测试 - 直接驱动 inference_controller
绕过 comm_interface，直接在 testbench 中设置：
```verilog
force dut.u_inference_controller.instr_valid = 1;
force dut.u_inference_controller.instruction = {...};
```

## 下一步行动

1. ✓ 打开 GTKWave 查看波形
2. 检查 `dut.u_inference_controller.state` 是否离开 IDLE
3. 检查 `instr_ready` 握手是否成功
4. 查看 `npu_top_integrated.v` 的连接
5. 根据发现选择修复方案
