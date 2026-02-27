# NPU Simulation Guide

## 概述

本目录包含NPU项目的仿真环境,使用Verilator进行快速、高性能的Verilog仿真。

## 目录结构

```
.
├── tb/                  # Testbench源文件
│   ├── tb_vp_pe.v      # PE单元测试
│   ├── tb_m20k_buffer.v # M20K缓存测试
│   └── tb_npu_top.v    # 顶层系统测试
│
├── run/                 # 仿真运行目录
│   ├── waves/          # 波形文件 (.vcd)
│   ├── logs/           # 仿真日志
│   └── obj_*/          # Verilator编译输出
│
├── Makefile            # 仿真构建文件
└── run_sim.sh          # 快速仿真脚本
```

---

## 快速开始

### 1. 安装依赖

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install verilator gtkwave g++

# 验证安装
verilator --version
gtkwave --version
```

**最低版本要求**:
- Verilator: >= 4.0
- GTKWave: >= 3.3 (可选,用于查看波形)

### 2. 运行单个测试

```bash
# 方法1: 使用Makefile
make tb_vp_pe          # PE单元测试
make tb_m20k_buffer    # M20K缓存测试
make tb_npu_top        # 顶层系统测试

# 方法2: 使用快速脚本
./run_sim.sh pe        # PE测试
./run_sim.sh buffer    # Buffer测试
./run_sim.sh top       # 顶层测试
```

### 3. 运行所有测试

```bash
# 方法1
make all_tests

# 方法2
./run_sim.sh all
```

### 4. 查看波形

```bash
# 方法1: 使用Makefile
make view_vp_pe
make view_m20k
make view_top

# 方法2: 手动打开
gtkwave run/waves/tb_vp_pe.vcd &
```

---

## Testbench说明

### 1. tb_vp_pe.v - Variable Precision PE测试

**测试内容**:
- INT8简单乘法 (5 × 3 = 15)
- INT8 MAC累加 (4×2 + 3×5 = 23)
- 负数运算 (-7 × 6 = -42)
- BF16乘法 (简化测试)
- 流水线吞吐量

**运行**:
```bash
make tb_vp_pe
```

**预期输出**:
```
========================================
  Variable Precision PE Testbench
========================================

Test 1: INT8 Simple Multiply
----------------------------
  PASS: 5 * 3 = 15 (expected 15)

Test 2: INT8 MAC (Multiply-Accumulate)
---------------------------------------
  PASS: (4*2) + (3*5) = 23 (expected 23)

...

========================================
  Test Summary
========================================
Total tests: 5
Passed:      5
Failed:      0

*** ALL TESTS PASSED ***
```

**波形位置**: `run/waves/tb_vp_pe.vcd`

---

### 2. tb_m20k_buffer.v - M20K缓存测试

**测试内容**:
- 单次写入/读取
- 顺序访问 (16个地址)
- 双端口同时访问
- 读后写延迟验证

**运行**:
```bash
make tb_m20k_buffer
```

**关键检查点**:
- 写入数据完整性
- 读延迟 (1 cycle)
- 双端口独立性
- 地址映射正确性

**波形位置**: `run/waves/tb_m20k_buffer.vcd`

---

### 3. tb_npu_top.v - 顶层系统测试

**测试内容**:
- 复位状态检查
- NOP指令处理
- GEMM INT8指令
- 性能计数器
- DDR4接口 (简化模型)

**运行**:
```bash
make tb_npu_top
```

**注意事项**:
- 使用简化的DDR4模型
- Transceiver接口为行为模型
- 阵列启动可能需要额外设置

**波形位置**: `run/waves/tb_npu_top.vcd`

---

## Makefile使用

### 常用目标

| 目标 | 说明 |
|------|------|
| `make help` | 显示帮助信息 |
| `make tb_vp_pe` | 编译并运行PE测试 |
| `make tb_m20k_buffer` | 编译并运行Buffer测试 |
| `make tb_npu_top` | 编译并运行顶层测试 |
| `make all_tests` | 运行所有测试 |
| `make lint` | RTL静态检查 |
| `make clean` | 清理编译产物 |
| `make clean_waves` | 清理波形文件 |
| `make clean_all` | 清理所有生成文件 |
| `make info` | 显示项目信息 |
| `make check_deps` | 检查依赖工具 |

### 选项

- **TRACE=1**: 启用波形跟踪 (默认)
- **TRACE=0**: 禁用波形跟踪 (加速仿真)

示例:
```bash
make tb_vp_pe TRACE=0  # 不生成波形
```

---

## 仿真流程

### Verilator工作流程

```
┌─────────────┐
│ Verilog RTL │
└──────┬──────┘
       │
       ▼
┌─────────────────┐
│ Verilator       │  (将Verilog转换为C++)
│ --cc --trace    │
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ C++ Model       │
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ g++ Compile     │
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ Executable      │  (./Vtb_name)
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ Run & Generate  │
│ VCD Waveform    │
└─────────────────┘
```

### 编译选项说明

```makefile
VERILATOR_FLAGS = \
	--cc            # 生成C++模型
	--exe           # 生成可执行文件
	--build         # 自动编译
	--trace         # 启用波形跟踪
	-Wall           # 启用所有警告
	-Wno-UNUSED     # 忽略未使用信号警告
	-Wno-UNOPTFLAT  # 忽略组合逻辑环路警告
```

---

## 调试技巧

### 1. 查看仿真日志

```bash
# 实时查看
tail -f run/logs/tb_vp_pe.log

# 搜索错误
grep -i "error\|fail" run/logs/*.log
```

### 2. 波形分析

使用GTKWave查看关键信号:

```bash
gtkwave run/waves/tb_vp_pe.vcd &
```

**推荐查看的信号**:
- `clk`, `rst_n`: 时钟和复位
- `enable`, `valid_out`: 控制信号
- `int8_a_in`, `int8_w_in`: 输入数据
- `result_out`: 计算结果
- `state`: FSM状态 (如果有)

### 3. 增加调试输出

在testbench中添加:
```verilog
always @(posedge clk) begin
    if (enable) begin
        $display("[%0t] a=%d, w=%d, result=%d", 
                 $time, int8_a_in, int8_w_in, result_out);
    end
end
```

### 4. Lint检查

运行静态分析找出潜在问题:
```bash
make lint
```

常见警告:
- `UNUSED`: 未使用的信号 (通常可忽略)
- `UNOPTFLAT`: 组合逻辑环路 (需修复)
- `WIDTH`: 位宽不匹配 (需检查)

---

## 性能优化

### 加速仿真

1. **禁用波形跟踪**:
```bash
make tb_vp_pe TRACE=0
```

2. **减小测试规模**:
修改testbench中的循环次数、数据量

3. **使用优化编译**:
Makefile中已设置 `-O2` 优化

### Verilator vs. 其他仿真器

| 仿真器 | 编译时间 | 运行速度 | 波形支持 | 用途 |
|--------|---------|---------|---------|------|
| Verilator | 快 | **最快** | VCD | 功能验证 |
| ModelSim | 慢 | 中等 | 丰富 | 工业验证 |
| VCS | 中等 | 快 | 丰富 | 工业验证 |
| Icarus | 快 | 慢 | VCD | 教学 |

Verilator适合:
- 快速功能验证
- 回归测试
- 大规模仿真

---

## 常见问题

### Q1: Verilator编译失败

**错误**: `verilator: command not found`

**解决**:
```bash
sudo apt install verilator
```

---

### Q2: 波形文件未生成

**原因**: 
- 未添加 `+trace` 参数
- testbench中未调用 `$dumpfile`

**解决**:
确保testbench包含:
```verilog
initial begin
    if ($test$plusargs("trace")) begin
        $dumpfile("run/waves/tb_name.vcd");
        $dumpvars(0, tb_name);
    end
end
```

并运行时添加 `+trace`:
```bash
./Vtb_name +trace
```

---

### Q3: 仿真一直运行不停止

**原因**: 
- 缺少 `$finish` 语句
- 超时监控未设置

**解决**:
添加超时监控:
```verilog
initial begin
    #(CLK_PERIOD * 10000);
    $display("ERROR: Simulation timeout!");
    $finish;
end
```

---

### Q4: GTKWave显示空波形

**可能原因**:
- VCD文件损坏
- 信号层级错误
- 仿真未正常结束

**解决**:
- 检查VCD文件大小 (应该>0)
- 确保仿真调用了 `$finish`
- 重新运行仿真

---

### Q5: Verilator警告太多

**处理**:
- `UNUSED`: 可忽略 (在Makefile中已添加 `-Wno-UNUSED`)
- `UNOPTFLAT`: 需修复 (可能是组合逻辑环路)
- 其他: 根据具体情况处理

可在Makefile中添加 `-Wno-<WARNING>` 忽略特定警告

---

## 添加新的Testbench

### 步骤

1. **创建testbench文件**: `tb/tb_new_module.v`

2. **编写测试代码**:
```verilog
module tb_new_module;
    // Clock, reset
    // DUT instantiation
    // Test stimulus
    initial begin
        if ($test$plusargs("trace")) begin
            $dumpfile("run/waves/tb_new_module.vcd");
            $dumpvars(0, tb_new_module);
        end
    end
endmodule
```

3. **添加到Makefile**:
```makefile
TB_NEW = tb_new_module
OBJ_NEW = $(RUN_DIR)/obj_$(TB_NEW)

.PHONY: tb_new_module
tb_new_module: $(OBJ_NEW)/V$(TB_NEW)
	@mkdir -p $(WAVE_DIR) $(LOG_DIR)
	@cd $(RUN_DIR) && ./obj_$(TB_NEW)/V$(TB_NEW) +trace

$(OBJ_NEW)/V$(TB_NEW): $(TB_DIR)/$(TB_NEW).v $(RTL_DIR)/path/to/module.v
	@mkdir -p $(OBJ_NEW)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module $(TB_NEW) \
		-Mdir $(OBJ_NEW) \
		$(TB_DIR)/$(TB_NEW).v \
		$(RTL_DIR)/path/to/module.v \
		--exe /dev/null
```

4. **运行测试**:
```bash
make tb_new_module
```

---

## 进阶用法

### 1. 覆盖率分析

Verilator支持代码覆盖率:
```bash
verilator --coverage --cc ...
```

### 2. 性能分析

使用 `gprof` 分析仿真性能:
```bash
CXXFLAGS="-pg" make tb_vp_pe
gprof ./Vtb_vp_pe gmon.out > analysis.txt
```

### 3. 多线程仿真

Verilator支持多线程:
```makefile
VERILATOR_FLAGS += --threads 4
```

---

## 资源

### 官方文档
- [Verilator Manual](https://verilator.org/guide/latest/)
- [GTKWave Documentation](http://gtkwave.sourceforge.net/)

### 教程
- Verilator快速入门: https://zipcpu.com/blog/2017/06/21/looking-at-verilator.html
- GTKWave使用指南: https://ughe.github.io/2018/11/13/gtkwave-tutorial

---

**最后更新**: 2026-02-27
