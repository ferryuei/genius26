# NPU RTL集成和测试更新

本次更新添加了完整的数据通路集成和系统级测试支持。

## 新增文件

### RTL集成
- `rtl/top/npu_top_integrated.v` - 完整集成版NPU顶层
- `rtl/top/npu_top.v.backup` - 原始版本备份

### 数据通路模块 (rtl/datapath/)
- `dma_to_m20k_bridge.v` - DMA到M20K桥接
- `activation_feeder.v` - 激活数据馈送器
- `result_collector.v` - 结果收集器
- `inference_controller.v` - 推理流程控制器
- `sfu_datapath_bridge.v` - SFU数据通路桥接

### SFU增强
- `rtl/sfu/sfu_unit_enhanced.v` - 完整SFU实现
- `rtl/sfu/README_ENHANCED.md` - SFU技术文档

### 测试
- `tb/tb_npu_top_integrated.v` - 系统级测试用例

## 使用说明

### 1. 编译集成版NPU

```bash
# 使用Icarus Verilog (推荐)
make tb_npu_top_integrated SIM=iverilog

# 使用Verilator
make tb_npu_top_integrated
```

### 2. 运行推理测试

测试包含：
- 完整GEMM数据流验证
- DMA读写通道测试
- M20K缓冲验证
- PE阵列计算验证
- 结果回写DDR验证

### 3. 查看波形

```bash
make view_top_integrated
# 或手动
gtkwave run/waves/tb_npu_top_integrated.vcd
```

## 集成特性

### 完整数据通路
```
DDR → DMA(Read) → Bridge → M20K → Feeder → PE Array → Collector → DMA(Write) → DDR
```

### 新增功能
1. **DMA双向通道** - 读写分离
2. **Inference Controller** - 自动化推理流程
3. **完整SFU** - Softmax/LayerNorm/GELU
4. **向量缓冲** - 128元素支持
5. **Ping-Pong Buffer** - 层间数据管理

### 性能指标
- 阵列尺寸：8×8 (可配置到96×96)
- 频率：600MHz
- 算力：0.15 TOPS (8×8×4阵列 INT8)
- SFU延迟：~400 cycles (128元素)

## 故障排查

### 编译错误
```bash
# 检查依赖
make check_deps

# 查看详细信息
make info
```

### 仿真超时
- 减小ARRAY_SIZE参数
- 检查时钟生成
- 查看仿真日志

### 数据不匹配
- 检查DDR初始化数据
- 验证M20K地址映射
- 查看debug_status信号

## 下一步

1. 性能优化
2. 批处理支持
3. 多层推理测试
4. 综合时序分析

## 参考

- 完备性分析：见项目根目录报告
- SFU文档：`rtl/sfu/README_ENHANCED.md`
- 数据通路：`rtl/datapath/README.md`
