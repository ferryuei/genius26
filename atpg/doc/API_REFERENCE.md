# ATPG工具集 API文档
## Application Programming Interface Reference

**版本**: 2.0  
**语言**: C (C11)  
**日期**: 2026-02-28

---

## 目录

1. [logic.h - 5值逻辑模块](#1-logich---5值逻辑模块)
2. [circuit.h - 电路数据结构模块](#2-circuith---电路数据结构模块)
3. [parser.h - BENCH格式解析模块](#3-parserh---bench格式解析模块)
4. [scan_insert.h - 扫描链插入模块](#4-scan_inserth---扫描链插入模块)
5. [atpg.h - ATPG引擎模块](#5-atpgh---atpg引擎模块)
6. [dft_drc.h - DFT DRC检查模块](#6-dft_drch---dft-drc检查模块)

---

## 1. logic.h - 5值逻辑模块

### 1.1 概述

实现ATPG所需的5值逻辑系统（0, 1, X, D, D'），用于D-algorithm中区分良好电路和故障电路的逻辑值。

### 1.2 数据类型

#### Logic

```c
typedef enum {
    LOGIC_0 = 0,      // 逻辑0
    LOGIC_1 = 1,      // 逻辑1
    LOGIC_X = 2,      // 未知值
    LOGIC_D = 3,      // 好电路为1，坏电路为0
    LOGIC_D_BAR = 4   // 好电路为0，坏电路为1
} Logic;
```

**说明**:
- `LOGIC_0`, `LOGIC_1`: 标准二值逻辑
- `LOGIC_X`: 未初始化或不确定的值
- `LOGIC_D`: 表示故障效应（好电路=1，故障电路=0）
- `LOGIC_D_BAR`: D的反相（好电路=0，故障电路=1）

### 1.3 API函数

#### logic_to_str

```c
const char* logic_to_str(Logic l);
```

**功能**: 将Logic值转换为字符串表示

**参数**:
- `l`: Logic值

**返回值**: 字符串 "0", "1", "X", "D", "D'"

**示例**:
```c
Logic val = LOGIC_D;
printf("Value: %s\n", logic_to_str(val));  // 输出: Value: D
```

---

#### logic_from_str

```c
Logic logic_from_str(const char* s);
```

**功能**: 从字符串解析Logic值

**参数**:
- `s`: 字符串表示 ("0", "1", "X", "D", "D'")

**返回值**: 对应的Logic值，无效输入返回LOGIC_X

**示例**:
```c
Logic val = logic_from_str("D'");  // val = LOGIC_D_BAR
```

---

#### logic_not

```c
Logic logic_not(Logic a);
```

**功能**: 逻辑非运算

**真值表**:
| 输入 | 输出 |
|------|------|
| 0 | 1 |
| 1 | 0 |
| X | X |
| D | D' |
| D' | D |

**示例**:
```c
Logic result = logic_not(LOGIC_D);  // result = LOGIC_D_BAR
```

---

#### logic_and

```c
Logic logic_and(Logic a, Logic b);
```

**功能**: 两输入AND运算

**真值表**:
```
AND | 0 | 1 | X | D | D'
----+---+---+---+---+----
0   | 0 | 0 | 0 | 0 | 0
1   | 0 | 1 | X | D | D'
X   | 0 | X | X | X | X
D   | 0 | D | X | D | 0
D'  | 0 | D'| X | 0 | D'
```

**示例**:
```c
Logic r1 = logic_and(LOGIC_1, LOGIC_D);    // r1 = LOGIC_D
Logic r2 = logic_and(LOGIC_D, LOGIC_D_BAR); // r2 = LOGIC_0
```

---

#### logic_or

```c
Logic logic_or(Logic a, Logic b);
```

**功能**: 两输入OR运算

**真值表**:
```
OR  | 0 | 1 | X | D | D'
----+---+---+---+---+----
0   | 0 | 1 | X | D | D'
1   | 1 | 1 | 1 | 1 | 1
X   | X | 1 | X | X | X
D   | D | 1 | X | D | 1
D'  | D'| 1 | X | 1 | D'
```

---

#### logic_xor

```c
Logic logic_xor(Logic a, Logic b);
```

**功能**: 两输入XOR运算

---

#### logic_nand, logic_nor, logic_xnor

```c
Logic logic_nand(Logic a, Logic b);
Logic logic_nor(Logic a, Logic b);
Logic logic_xnor(Logic a, Logic b);
```

**功能**: NAND, NOR, XNOR运算

---

#### logic_and_n, logic_or_n, logic_xor_n

```c
Logic logic_and_n(const Logic* inputs, int n);
Logic logic_or_n(const Logic* inputs, int n);
Logic logic_xor_n(const Logic* inputs, int n);
```

**功能**: 多输入逻辑运算

**参数**:
- `inputs`: Logic值数组
- `n`: 输入数量

**示例**:
```c
Logic inputs[] = {LOGIC_1, LOGIC_D, LOGIC_1};
Logic result = logic_and_n(inputs, 3);  // result = LOGIC_D
```

---

## 2. circuit.h - 电路数据结构模块

### 2.1 概述

定义电路、门、故障等核心数据结构，以及电路操作函数。

### 2.2 常量定义

```c
#define MAX_NAME_LEN 256    // 门名称最大长度
#define MAX_INPUTS 128      // 门最大输入数
#define MAX_GATES 200000    // 最大门数量
#define MAX_FANOUTS 128     // 最大扇出数
```

### 2.3 数据类型

#### GateType

```c
typedef enum {
    GATE_INPUT = 0,  // 主输入
    GATE_AND,        // 与门
    GATE_OR,         // 或门
    GATE_NOT,        // 非门
    GATE_NAND,       // 与非门
    GATE_NOR,        // 或非门
    GATE_XOR,        // 异或门
    GATE_XNOR,       // 同或门
    GATE_BUF,        // 缓冲器
    GATE_DFF         // D触发器
} GateType;
```

---

#### FaultType

```c
typedef enum {
    FAULT_SA0 = 0,  // Stuck-at-0故障
    FAULT_SA1 = 1   // Stuck-at-1故障
} FaultType;
```

---

#### Gate

```c
typedef struct {
    int id;                         // 门ID
    char name[MAX_NAME_LEN];        // 门名称
    GateType type;                  // 门类型
    int inputs[MAX_INPUTS];         // 输入门ID数组
    int num_inputs;                 // 输入数量
    int fanouts[MAX_FANOUTS];       // 扇出门ID数组
    int num_fanouts;                // 扇出数量
    Logic value;                    // 当前逻辑值
    int level;                      // 拓扑层级
    bool is_pi;                     // 是否为主输入
    bool is_po;                     // 是否为主输出
} Gate;
```

**成员说明**:
- `id`: 唯一标识符，从0开始
- `name`: 门名称，用于调试和报告
- `type`: 门的逻辑功能类型
- `inputs[]`: 输入门的ID数组
- `fanouts[]`: 该门驱动的门的ID数组
- `value`: 当前模拟值
- `level`: 拓扑排序后的层级（用于levelization）
- `is_pi/is_po`: 标记主输入/主输出

---

#### Fault

```c
typedef struct {
    int gate_id;                    // 故障位置门ID
    FaultType type;                 // 故障类型
    bool detected;                  // 是否已被检测
    bool redundant;                 // 是否冗余故障
    int pattern_id;                 // 检测该故障的测试向量ID
} Fault;
```

---

#### Circuit

```c
typedef struct {
    Gate* gates;                    // 门数组（动态分配）
    int num_gates;                  // 当前门数量
    int capacity;                   // 数组容量
    int* pi_ids;                    // 主输入ID数组
    int num_pis;                    // 主输入数量
    int* po_ids;                    // 主输出ID数组
    int num_pos;                    // 主输出数量
    int max_level;                  // 最大拓扑层级
} Circuit;
```

---

#### TestPattern

```c
typedef struct {
    Logic* pi_values;               // 主输入值数组
    int num_pis;                    // 主输入数量
    int* detected_faults;           // 检测到的故障ID
    int num_detected;               // 检测数量
} TestPattern;
```

### 2.4 API函数

#### circuit_create

```c
Circuit* circuit_create(void);
```

**功能**: 创建新电路对象

**返回值**: 
- 成功: Circuit指针
- 失败: NULL

**说明**: 
- 初始容量为10,000门
- 需要手动调用`circuit_free`释放

**示例**:
```c
Circuit* circuit = circuit_create();
if (!circuit) {
    fprintf(stderr, "Failed to create circuit\n");
    return -1;
}
```

---

#### circuit_free

```c
void circuit_free(Circuit* circuit);
```

**功能**: 释放电路占用的内存

**参数**:
- `circuit`: 要释放的电路指针

**说明**: 释放gates数组、PI/PO数组等所有动态分配的内存

**示例**:
```c
circuit_free(circuit);
```

---

#### circuit_add_gate

```c
int circuit_add_gate(Circuit* circuit, const char* name, GateType type);
```

**功能**: 向电路添加一个门

**参数**:
- `circuit`: 电路指针
- `name`: 门名称
- `type`: 门类型

**返回值**: 新添加门的ID（>=0），失败返回-1

**说明**: 
- 自动扩展容量（当前容量满时扩展2倍）
- 门ID从0开始递增

**示例**:
```c
int gate_id = circuit_add_gate(circuit, "g1", GATE_AND);
if (gate_id < 0) {
    fprintf(stderr, "Failed to add gate\n");
}
```

---

#### circuit_add_connection

```c
bool circuit_add_connection(Circuit* circuit, int from_id, int to_id);
```

**功能**: 连接两个门（from的输出连到to的输入）

**参数**:
- `circuit`: 电路指针
- `from_id`: 源门ID
- `to_id`: 目标门ID

**返回值**: 
- true: 成功
- false: 失败（ID无效或超出容量）

**说明**: 
- 自动更新from的fanouts数组
- 自动更新to的inputs数组

**示例**:
```c
if (!circuit_add_connection(circuit, gate1_id, gate2_id)) {
    fprintf(stderr, "Failed to connect gates\n");
}
```

---

#### circuit_get_gate_by_name

```c
Gate* circuit_get_gate_by_name(Circuit* circuit, const char* name);
```

**功能**: 根据名称查找门

**参数**:
- `circuit`: 电路指针
- `name`: 门名称

**返回值**: 
- 成功: Gate指针
- 失败: NULL

**示例**:
```c
Gate* gate = circuit_get_gate_by_name(circuit, "clk");
if (gate) {
    printf("Found gate: %s, type: %d\n", gate->name, gate->type);
}
```

---

#### circuit_get_gate

```c
Gate* circuit_get_gate(Circuit* circuit, int gate_id);
```

**功能**: 根据ID获取门

**参数**:
- `circuit`: 电路指针
- `gate_id`: 门ID

**返回值**: Gate指针，ID无效返回NULL

---

#### circuit_set_pi, circuit_set_po

```c
void circuit_set_pi(Circuit* circuit, int gate_id);
void circuit_set_po(Circuit* circuit, int gate_id);
```

**功能**: 设置门为主输入或主输出

**参数**:
- `circuit`: 电路指针
- `gate_id`: 门ID

**说明**: 自动更新pi_ids/po_ids数组

---

#### circuit_levelization

```c
void circuit_levelization(Circuit* circuit);
```

**功能**: 计算电路的拓扑层级

**参数**:
- `circuit`: 电路指针

**说明**: 
- 主输入为level 0
- 其他门的level = max(输入门level) + 1
- 更新circuit->max_level

**用途**: 用于拓扑排序，确保模拟时按正确顺序评估门

**示例**:
```c
circuit_levelization(circuit);
printf("Max level: %d\n", circuit->max_level);
```

---

#### circuit_evaluate

```c
void circuit_evaluate(Circuit* circuit, const Logic* pi_values);
```

**功能**: 评估整个电路（逻辑模拟）

**参数**:
- `circuit`: 电路指针
- `pi_values`: 主输入值数组

**说明**: 
- 按拓扑顺序评估所有门
- 更新每个门的value字段

**示例**:
```c
Logic inputs[num_pis];
inputs[0] = LOGIC_1;
inputs[1] = LOGIC_0;
// ...
circuit_evaluate(circuit, inputs);

// 读取输出
for (int i = 0; i < circuit->num_pos; i++) {
    Gate* po = circuit_get_gate(circuit, circuit->po_ids[i]);
    printf("Output %s: %s\n", po->name, logic_to_str(po->value));
}
```

---

#### gate_evaluate

```c
Logic gate_evaluate(const Gate* gate, const Circuit* circuit);
```

**功能**: 评估单个门的输出

**参数**:
- `gate`: 要评估的门
- `circuit`: 电路上下文（用于获取输入值）

**返回值**: 该门的逻辑输出值

**说明**: 根据gate->type和输入值计算输出

---

#### gate_type_to_str

```c
const char* gate_type_to_str(GateType type);
```

**功能**: 将GateType转换为字符串

**返回值**: "INPUT", "AND", "OR", "NOT", "DFF"等

---

#### gate_type_from_str

```c
GateType gate_type_from_str(const char* str);
```

**功能**: 从字符串解析GateType

**参数**: 字符串 "AND", "OR", "NOT", "DFF"等

**返回值**: 对应的GateType

---

## 3. parser.h - BENCH格式解析模块

### 3.1 概述

解析BENCH格式的门级网表文件。

### 3.2 API函数

#### parse_bench_file

```c
Circuit* parse_bench_file(const char* filename);
```

**功能**: 解析BENCH文件并构建Circuit对象

**参数**:
- `filename`: BENCH文件路径

**返回值**: 
- 成功: Circuit指针
- 失败: NULL

**说明**: 
- 自动处理INPUT/OUTPUT声明
- 解析门定义和连接
- 计算拓扑层级
- 显示解析进度（每10000行）

**BENCH格式示例**:
```
# 注释
INPUT(a)
INPUT(b)
OUTPUT(out)

g1 = AND(a, b)
g2 = NOT(g1)
out = OR(g1, g2)
```

**示例**:
```c
Circuit* circuit = parse_bench_file("design.bench");
if (!circuit) {
    fprintf(stderr, "Failed to parse circuit\n");
    return -1;
}

printf("Loaded circuit: %d gates, %d inputs, %d outputs\n",
       circuit->num_gates, circuit->num_pis, circuit->num_pos);
```

---

## 4. scan_insert.h - 扫描链插入模块

### 4.1 概述

将电路中的DFF组织成扫描链，使电路可测试。

### 4.2 数据类型

#### ScanChain

```c
typedef struct {
    int chain_id;                   // 链ID
    char si_port[MAX_NAME_LEN];     // 扫描输入端口名
    char so_port[MAX_NAME_LEN];     // 扫描输出端口名
    int* dff_ids;                   // 该链中的DFF ID数组
    int num_dffs;                   // DFF数量
    int capacity;                   // 数组容量
} ScanChain;
```

---

#### ScanEngine

```c
typedef struct {
    Circuit* circuit;               // 原始电路
    Circuit* scan_circuit;          // 插入扫描链后的电路
    ScanChain* chains;              // 扫描链数组
    int num_chains;                 // 链数量
    int* dff_list;                  // 所有DFF的ID列表
    int num_dffs;                   // 总DFF数量
    bool scan_enable_added;         // 是否添加了scan_enable信号
    char scan_enable[MAX_NAME_LEN]; // scan_enable信号名
} ScanEngine;
```

### 4.3 API函数

#### scan_create

```c
ScanEngine* scan_create(Circuit* circuit);
```

**功能**: 创建扫描插入引擎

**参数**:
- `circuit`: 输入电路

**返回值**: ScanEngine指针

**示例**:
```c
ScanEngine* engine = scan_create(circuit);
```

---

#### scan_free

```c
void scan_free(ScanEngine* engine);
```

**功能**: 释放扫描引擎

**说明**: 释放chains、dff_list等内存，但不释放circuit（由调用者管理）

---

#### scan_find_dffs

```c
int scan_find_dffs(ScanEngine* engine);
```

**功能**: 查找电路中的所有DFF

**返回值**: DFF数量

**说明**: 
- 遍历所有门，识别type == GATE_DFF的门
- 填充engine->dff_list和engine->num_dffs

**示例**:
```c
int num_dffs = scan_find_dffs(engine);
printf("Found %d DFFs\n", num_dffs);
```

---

#### scan_insert_chains

```c
bool scan_insert_chains(ScanEngine* engine, int num_chains);
```

**功能**: 插入扫描链

**参数**:
- `engine`: 扫描引擎
- `num_chains`: 要创建的扫描链数量（1-64）

**返回值**: 
- true: 成功
- false: 失败

**算法**:
1. 将DFF均匀分配到各条链
2. 为每条链创建scan_in_N和scan_out_N端口
3. 串联链中的DFF

**示例**:
```c
if (!scan_insert_chains(engine, 16)) {
    fprintf(stderr, "Failed to insert scan chains\n");
}
```

---

#### scan_save_scandef

```c
bool scan_save_scandef(const ScanEngine* engine, const char* filename);
```

**功能**: 保存扫描链定义到SCANDEF文件

**参数**:
- `engine`: 扫描引擎
- `filename`: 输出文件名

**返回值**: true/false

**输出格式**:
```
SCAN_CHAINS 16

CHAIN 0
  SCAN_IN scan_in_0
  SCAN_OUT scan_out_0
  LENGTH 393
  DFFS dff0 dff16 dff32 ...

CHAIN 1
  ...
```

---

#### scan_print_stats

```c
void scan_print_stats(const ScanEngine* engine);
```

**功能**: 打印扫描链统计信息

**输出示例**:
```
Scan Chain Statistics:
  Total DFFs: 6282
  Number of chains: 16
  Average chain length: 392.6
  Shortest chain: 392
  Longest chain: 393
```

---

## 5. atpg.h - ATPG引擎模块

### 5.1 概述

自动测试图案生成引擎，实现D-algorithm等ATPG算法。

### 5.2 数据类型

#### ATPGAlgorithm

```c
typedef enum {
    ATPG_D_ALGORITHM,  // D-algorithm
    ATPG_PODEM,        // PODEM (未实现)
    ATPG_FAN           // FAN (未实现)
} ATPGAlgorithm;
```

---

#### ATPGEngine

```c
typedef struct {
    Circuit* circuit;               // 测试电路
    Fault* faults;                  // 故障列表
    int num_faults;                 // 故障数量
    TestPattern* patterns;          // 测试向量
    int num_patterns;               // 向量数量
    ATPGAlgorithm algorithm;        // 使用的算法
    int max_backtracks;             // 最大回溯次数
    int timeout_ms;                 // 超时时间（毫秒）
} ATPGEngine;
```

### 5.3 API函数

#### atpg_create

```c
ATPGEngine* atpg_create(Circuit* circuit, ATPGAlgorithm algorithm);
```

**功能**: 创建ATPG引擎

**参数**:
- `circuit`: 电路指针
- `algorithm`: ATPG算法类型

**返回值**: ATPGEngine指针

**示例**:
```c
ATPGEngine* atpg = atpg_create(circuit, ATPG_D_ALGORITHM);
```

---

#### atpg_free

```c
void atpg_free(ATPGEngine* atpg);
```

**功能**: 释放ATPG引擎

---

#### atpg_generate_faults

```c
void atpg_generate_faults(ATPGEngine* atpg);
```

**功能**: 生成所有stuck-at故障

**说明**: 
- 为每个门生成SA0和SA1故障
- 填充atpg->faults数组
- 设置atpg->num_faults

**故障数量**: 通常为 2 × num_gates

**示例**:
```c
atpg_generate_faults(atpg);
printf("Generated %d faults\n", atpg->num_faults);
```

---

#### atpg_run

```c
bool atpg_run(ATPGEngine* atpg);
```

**功能**: 运行ATPG算法生成所有测试向量

**返回值**: true/false

**说明**: 
- 对每个未检测的故障调用atpg_generate_pattern
- 生成的测试向量用于故障模拟，标记所有检测到的故障
- 压缩测试向量（一个向量可以检测多个故障）

**示例**:
```c
if (!atpg_run(atpg)) {
    fprintf(stderr, "ATPG failed\n");
}
atpg_print_stats(atpg);
```

---

#### atpg_generate_pattern

```c
bool atpg_generate_pattern(ATPGEngine* atpg, Fault* fault, TestPattern* pattern);
```

**功能**: 为特定故障生成测试向量

**参数**:
- `atpg`: ATPG引擎
- `fault`: 目标故障
- `pattern`: 输出测试向量

**返回值**: 
- true: 成功生成向量
- false: 故障不可检测或超时

**说明**: 调用具体算法实现（如atpg_d_algorithm）

---

#### atpg_fault_simulate

```c
int atpg_fault_simulate(ATPGEngine* atpg, const TestPattern* pattern);
```

**功能**: 故障模拟 - 用一个测试向量模拟所有故障

**参数**:
- `atpg`: ATPG引擎
- `pattern`: 测试向量

**返回值**: 本次检测到的故障数量

**算法**:
1. 用pattern评估良好电路
2. 对每个未检测故障:
   - 注入故障
   - 评估故障电路
   - 比较主输出
   - 如果不同，标记故障为已检测

**示例**:
```c
int detected = atpg_fault_simulate(atpg, &pattern);
printf("Detected %d faults\n", detected);
```

---

#### atpg_calculate_coverage

```c
double atpg_calculate_coverage(const ATPGEngine* atpg);
```

**功能**: 计算故障覆盖率

**返回值**: 覆盖率（0.0-1.0）

**公式**: coverage = detected_faults / total_faults

**示例**:
```c
double coverage = atpg_calculate_coverage(atpg);
printf("Fault coverage: %.2f%%\n", coverage * 100);
```

---

#### atpg_print_stats

```c
void atpg_print_stats(const ATPGEngine* atpg);
```

**功能**: 打印ATPG统计信息

**输出示例**:
```
ATPG Statistics:
Total faults: 147292
Detected faults: 67387
Test patterns: 370
Fault coverage: 45.75%
Execution time: 15.2 seconds
```

---

#### atpg_save_patterns

```c
bool atpg_save_patterns(const ATPGEngine* atpg, const char* filename);
```

**功能**: 保存测试向量到文件

**参数**:
- `atpg`: ATPG引擎
- `filename`: 输出文件名

**返回值**: true/false

---

#### atpg_d_algorithm

```c
bool atpg_d_algorithm(ATPGEngine* atpg, Fault* fault, TestPattern* pattern);
```

**功能**: D-algorithm实现

**参数**:
- `atpg`: ATPG引擎
- `fault`: 目标故障
- `pattern`: 输出测试向量

**返回值**: true/false

**算法步骤**:
1. **故障激活**: 在故障位置产生D或D'
2. **D传播**: 将D/D'传播到主输出
3. **一致性检查**: 回溯设置主输入值
4. **验证**: 验证生成的向量

---

## 6. dft_drc.h - DFT DRC检查模块

### 6.1 概述

DFT设计规则检查，验证电路的可测试性设计。

### 6.2 数据类型

#### DRCViolationType

```c
typedef enum {
    DRC_CLOCK_UNCONTROLLABLE,      // 时钟不可控
    DRC_RESET_UNCONTROLLABLE,      // 复位不可控
    DRC_CLOCK_GATING_NO_BYPASS,    // 时钟门控无旁路
    DRC_ASYNC_RESET_NO_CONTROL,    // 异步复位无控制
    DRC_COMBINATIONAL_LOOP,        // 组合环路
    DRC_TRISTATE_IN_SCAN,          // 扫描中有三态
    DRC_DFF_NO_CLOCK,              // DFF无时钟
    DRC_DFF_NO_RESET,              // DFF无复位
    DRC_SCAN_CHAIN_INCOMPLETE,     // 扫描链不完整
    DRC_FLOATING_INPUT,            // 浮动输入
    DRC_MULTIPLE_CLOCKS_ON_DFF,    // DFF多时钟
    DRC_GATED_CLOCK_ON_DFF         // DFF时钟被门控
} DRCViolationType;
```

---

#### ClockDomain

```c
typedef struct {
    int clock_gate_id;              // 时钟源门ID
    char clock_name[MAX_NAME_LEN];  // 时钟信号名
    int* controlled_dffs;           // 由该时钟控制的DFF
    int num_dffs;                   // DFF数量
    bool is_controllable;           // 是否从PI可控
    bool has_gating;                // 是否有门控
    bool gating_bypassable;         // 门控是否可旁路
    int gating_control_id;          // 门控控制信号ID
} ClockDomain;
```

---

#### ResetDomain

```c
typedef struct {
    int reset_gate_id;              // 复位源门ID
    char reset_name[MAX_NAME_LEN];  // 复位信号名
    int* controlled_dffs;           // 由该复位控制的DFF
    int num_dffs;                   // DFF数量
    bool is_controllable;           // 是否从PI可控
    bool is_async;                  // 是否异步复位
    bool has_control_in_test;       // 测试模式是否有控制
} ResetDomain;
```

---

#### DRCViolation

```c
typedef struct {
    DRCViolationType type;          // 违规类型
    int gate_id;                    // 违规门ID
    char gate_name[MAX_NAME_LEN];   // 门名称
    char description[512];          // 详细描述
    int severity;                   // 严重性(0=info,1=warn,2=err,3=critical)
} DRCViolation;
```

---

#### DFTDRCEngine

```c
typedef struct {
    Circuit* circuit;               // 待检查电路
    ClockDomain* clock_domains;     // 时钟域
    int num_clock_domains;          // 时钟域数量
    ResetDomain* reset_domains;     // 复位域
    int num_reset_domains;          // 复位域数量
    DRCViolation* violations;       // 违规列表
    int num_violations;             // 违规数量
    int capacity_violations;        // 违规数组容量
    int num_errors;                 // 错误数量
    int num_warnings;               // 警告数量
    int num_info;                   // 信息数量
} DFTDRCEngine;
```

### 6.3 API函数

#### dft_drc_create

```c
DFTDRCEngine* dft_drc_create(Circuit* circuit);
```

**功能**: 创建DFT DRC引擎

---

#### dft_drc_free

```c
void dft_drc_free(DFTDRCEngine* drc);
```

**功能**: 释放DRC引擎

---

#### dft_drc_check_all

```c
bool dft_drc_check_all(DFTDRCEngine* drc);
```

**功能**: 运行所有DRC检查

**返回值**: 
- true: 全部通过
- false: 有错误

**说明**: 依次调用所有检查函数

**示例**:
```c
DFTDRCEngine* drc = dft_drc_create(circuit);
bool passed = dft_drc_check_all(drc);
dft_drc_print_report(drc);
```

---

#### dft_drc_check_clock_controllability

```c
bool dft_drc_check_clock_controllability(DFTDRCEngine* drc);
```

**功能**: 检查时钟可控性

**算法**:
1. 识别所有时钟域
2. 对每个时钟域，BFS反向追踪到主输入
3. 如果无法到达PI，报告违规

---

#### dft_drc_check_reset_controllability

```c
bool dft_drc_check_reset_controllability(DFTDRCEngine* drc);
```

**功能**: 检查复位可控性

---

#### dft_drc_check_combinational_loops

```c
bool dft_drc_check_combinational_loops(DFTDRCEngine* drc);
```

**功能**: 检查组合逻辑环路

**算法**: DFS检测环路（不穿越DFF）

---

#### dft_drc_check_dff_connectivity

```c
bool dft_drc_check_dff_connectivity(DFTDRCEngine* drc);
```

**功能**: 检查DFF连接性

**检查项**:
- DFF是否有数据输入
- DFF是否有扇出或为PO

---

#### dft_drc_check_clock_gating

```c
bool dft_drc_check_clock_gating(DFTDRCEngine* drc);
```

**功能**: 检查时钟门控

**检查**: 驱动DFF的逻辑门是否有测试模式旁路

---

#### dft_drc_check_tristate

```c
bool dft_drc_check_tristate(DFTDRCEngine* drc);
```

**功能**: 检查三态逻辑

---

#### dft_drc_print_report

```c
void dft_drc_print_report(const DFTDRCEngine* drc);
```

**功能**: 打印DRC报告到控制台

**输出示例**:
```
╔══════════════════════════════════════════╗
║         DFT DRC Report                   ║
╚══════════════════════════════════════════╝

Statistics:
  Total violations: 12576
  Errors:           12564
  Warnings:         12
  Info:             0

Violations:
ERROR    DFF No Clock    branch_q    DFF 'branch_q' has no identifiable clock input
...

❌ DFT DRC FAILED - 12564 error(s) found
```

---

#### dft_drc_save_report

```c
bool dft_drc_save_report(const DFTDRCEngine* drc, const char* filename);
```

**功能**: 保存DRC报告到文件

---

#### dft_drc_is_controllable_from_pi

```c
bool dft_drc_is_controllable_from_pi(Circuit* circuit, int gate_id);
```

**功能**: 检查门是否从主输入可控

**算法**: BFS反向追踪输入，看是否能到达PI

---

#### dft_drc_identify_clock_domains

```c
int dft_drc_identify_clock_domains(DFTDRCEngine* drc);
```

**功能**: 识别所有时钟域

**返回值**: 时钟域数量

---

#### dft_drc_identify_reset_domains

```c
int dft_drc_identify_reset_domains(DFTDRCEngine* drc);
```

**功能**: 识别所有复位域

---

## 附录: 完整使用示例

### 示例1: 扫描链插入

```c
#include "circuit.h"
#include "parser.h"
#include "scan_insert.h"

int main(int argc, char** argv) {
    // 1. 解析电路
    Circuit* circuit = parse_bench_file("design.bench");
    if (!circuit) return -1;
    
    // 2. 创建扫描引擎
    ScanEngine* engine = scan_create(circuit);
    
    // 3. 查找DFF
    int num_dffs = scan_find_dffs(engine);
    printf("Found %d DFFs\n", num_dffs);
    
    // 4. 插入扫描链
    if (!scan_insert_chains(engine, 16)) {
        fprintf(stderr, "Failed to insert scan chains\n");
        return -1;
    }
    
    // 5. 保存结果
    scan_save_scandef(engine, "scan.def");
    scan_print_stats(engine);
    
    // 6. 清理
    scan_free(engine);
    circuit_free(circuit);
    
    return 0;
}
```

### 示例2: ATPG生成

```c
#include "circuit.h"
#include "parser.h"
#include "atpg.h"

int main(int argc, char** argv) {
    // 1. 解析电路
    Circuit* circuit = parse_bench_file("design_scan.bench");
    if (!circuit) return -1;
    
    // 2. 创建ATPG引擎
    ATPGEngine* atpg = atpg_create(circuit, ATPG_D_ALGORITHM);
    atpg->max_backtracks = 100;
    atpg->timeout_ms = 60000;
    
    // 3. 生成故障
    atpg_generate_faults(atpg);
    printf("Generated %d faults\n", atpg->num_faults);
    
    // 4. 运行ATPG
    if (!atpg_run(atpg)) {
        fprintf(stderr, "ATPG failed\n");
        return -1;
    }
    
    // 5. 打印统计
    atpg_print_stats(atpg);
    
    // 6. 保存测试向量
    atpg_save_patterns(atpg, "test_vectors.pat");
    
    // 7. 清理
    atpg_free(atpg);
    circuit_free(circuit);
    
    return 0;
}
```

### 示例3: DFT DRC检查

```c
#include "circuit.h"
#include "parser.h"
#include "dft_drc.h"

int main(int argc, char** argv) {
    // 1. 解析电路
    Circuit* circuit = parse_bench_file("design.bench");
    if (!circuit) return -1;
    
    // 2. 创建DRC引擎
    DFTDRCEngine* drc = dft_drc_create(circuit);
    
    // 3. 运行所有检查
    bool passed = dft_drc_check_all(drc);
    
    // 4. 打印报告
    dft_drc_print_report(drc);
    
    // 5. 保存报告
    dft_drc_save_report(drc, "drc_report.txt");
    
    // 6. 清理
    dft_drc_free(drc);
    circuit_free(circuit);
    
    return passed ? 0 : 1;
}
```

---

**文档版本**: 2.0  
**最后更新**: 2026-02-28
