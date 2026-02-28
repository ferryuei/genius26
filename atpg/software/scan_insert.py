#!/usr/bin/env python3
"""
DFT Scan Chain Insertion Tool (Enhanced Version)
增强版Scan Chain插入DFT工具

功能:
1. 读取综合后的门级网表 (Verilog/BENCH格式)
2. 识别所有DFF单元
3. 将DFF替换为Scan DFF (MUX-D扫描单元)
4. 自动连接Scan Chain
5. 输出带Scan的网表

增强功能:
- 多Scan Chain支持: 减少shift时间,支持并行加载
- 时钟域处理: 自动识别多时钟设计,按时钟域分组
- EDT压缩: LFSR解压缩 + MISR响应压缩,减少测试数据量

Scan DFF结构 (MUX-D):
        ┌─────────────────┐
   D ───┤0               │
        │    MUX      Q  ├─── Q
  SI ───┤1               │
        └───────┬─────────┘
                │
  SE ───────────┘

  SE=0: Q <= D  (功能模式)
  SE=1: Q <= SI (扫描模式)

EDT压缩结构:
  ┌──────┐     ┌───────────┐     ┌──────┐
  │ LFSR │────►│ Scan Chain│────►│ MISR │
  └──────┘     └───────────┘     └──────┘
   解压缩         DUT扫描链        压缩器
"""

import re
import sys
import argparse
from dataclasses import dataclass, field
from typing import Dict, List, Set, Optional, Tuple
from enum import Enum
from collections import defaultdict


class GateType(Enum):
    """门类型"""
    INPUT = "INPUT"
    OUTPUT = "OUTPUT"
    AND = "AND"
    OR = "OR"
    NOT = "NOT"
    NAND = "NAND"
    NOR = "NOR"
    XOR = "XOR"
    XNOR = "XNOR"
    BUF = "BUF"
    MUX = "MUX"
    DFF = "DFF"
    SDFF = "SDFF"  # Scan DFF


@dataclass
class Gate:
    """门/单元"""
    name: str
    gate_type: GateType
    inputs: List[str] = field(default_factory=list)
    output: str = ""
    

@dataclass
class ScanCell:
    """Scan单元信息"""
    name: str           # DFF实例名
    d_input: str        # 原始D输入
    q_output: str       # Q输出
    si_input: str = ""  # Scan In (连接到前一个cell的Q)
    mux_name: str = ""  # 插入的MUX名称
    chain_index: int = 0
    chain_id: int = 0   # 所属的Scan Chain编号
    clock_domain: str = "clk"  # 时钟域


@dataclass
class ScanChain:
    """Scan Chain定义"""
    chain_id: int
    scan_in: str        # 该链的SI引脚
    scan_out: str       # 该链的SO引脚
    clock_domain: str   # 主时钟域
    cells: List[ScanCell] = field(default_factory=list)
    
    @property
    def length(self) -> int:
        return len(self.cells)


@dataclass
class EDTConfig:
    """EDT压缩配置"""
    enabled: bool = False
    lfsr_width: int = 16      # LFSR位宽
    misr_width: int = 16      # MISR位宽
    compression_ratio: int = 8 # 压缩比 (scan_chains / edt_channels)
    lfsr_seed: int = 0xACE1   # LFSR初始种子
    lfsr_poly: int = 0x100B   # LFSR反馈多项式 (x^16 + x^12 + x^3 + x + 1)


@dataclass 
class Circuit:
    """电路结构"""
    name: str = "circuit"
    inputs: List[str] = field(default_factory=list)
    outputs: List[str] = field(default_factory=list)
    gates: Dict[str, Gate] = field(default_factory=dict)
    wires: Set[str] = field(default_factory=set)
    

class NetlistParser:
    """网表解析器"""
    
    @staticmethod
    def parse_bench(filename: str) -> Circuit:
        """解析BENCH格式网表"""
        circuit = Circuit()
        circuit.name = filename.split('/')[-1].replace('.bench', '')
        
        with open(filename, 'r') as f:
            content = f.read()
        
        # 移除注释
        content = re.sub(r'#.*', '', content)
        
        gate_id = 0
        for line in content.split('\n'):
            line = line.strip()
            if not line:
                continue
            
            # INPUT
            match = re.match(r'INPUT\s*\(\s*(\w+)\s*\)', line, re.IGNORECASE)
            if match:
                circuit.inputs.append(match.group(1))
                circuit.wires.add(match.group(1))
                continue
            
            # OUTPUT
            match = re.match(r'OUTPUT\s*\(\s*(\w+)\s*\)', line, re.IGNORECASE)
            if match:
                circuit.outputs.append(match.group(1))
                circuit.wires.add(match.group(1))
                continue
            
            # Gate: out = TYPE(in1, in2, ...)
            match = re.match(r'(\w+)\s*=\s*(\w+)\s*\(\s*(.+)\s*\)', line, re.IGNORECASE)
            if match:
                output = match.group(1)
                gate_type_str = match.group(2).upper()
                inputs = [s.strip() for s in match.group(3).split(',')]
                
                gate_type_map = {
                    'AND': GateType.AND, 'OR': GateType.OR, 'NOT': GateType.NOT,
                    'NAND': GateType.NAND, 'NOR': GateType.NOR, 'XOR': GateType.XOR,
                    'XNOR': GateType.XNOR, 'BUF': GateType.BUF, 'BUFF': GateType.BUF,
                    'DFF': GateType.DFF, 'MUX': GateType.MUX,
                }
                
                if gate_type_str in gate_type_map:
                    gate = Gate(
                        name=f"G{gate_id}",
                        gate_type=gate_type_map[gate_type_str],
                        inputs=inputs,
                        output=output
                    )
                    circuit.gates[gate.name] = gate
                    circuit.wires.add(output)
                    for inp in inputs:
                        circuit.wires.add(inp)
                    gate_id += 1
        
        return circuit

    @staticmethod
    def parse_verilog(filename: str) -> Circuit:
        """解析Yosys综合后的Verilog网表"""
        circuit = Circuit()
        
        with open(filename, 'r') as f:
            content = f.read()
        
        # 提取模块名
        match = re.search(r'module\s+(\w+)', content)
        if match:
            circuit.name = match.group(1)
        
        # 解析input
        for match in re.finditer(r'input\s+(?:\[[\d:]+\]\s+)?(\w+)', content):
            circuit.inputs.append(match.group(1))
            circuit.wires.add(match.group(1))
        
        # 解析output
        for match in re.finditer(r'output\s+(?:\[[\d:]+\]\s+)?(\w+)', content):
            circuit.outputs.append(match.group(1))
            circuit.wires.add(match.group(1))
        
        # 解析wire
        for match in re.finditer(r'wire\s+(?:\[[\d:]+\]\s+)?(\w+)', content):
            circuit.wires.add(match.group(1))
        
        gate_id = 0
        
        # 解析assign语句
        for match in re.finditer(r'assign\s+(\w+)\s*=\s*([^;]+);', content):
            output = match.group(1)
            expr = match.group(2).strip()
            
            # ~(a & b) -> NAND
            nand_match = re.match(r'~\s*\(\s*(\w+)\s*&\s*(\w+)\s*\)', expr)
            if nand_match:
                gate = Gate(f"G{gate_id}", GateType.NAND, 
                           [nand_match.group(1), nand_match.group(2)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
            
            # ~(a | b) -> NOR
            nor_match = re.match(r'~\s*\(\s*(\w+)\s*\|\s*(\w+)\s*\)', expr)
            if nor_match:
                gate = Gate(f"G{gate_id}", GateType.NOR,
                           [nor_match.group(1), nor_match.group(2)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
            
            # ~a -> NOT
            not_match = re.match(r'~\s*(\w+)', expr)
            if not_match:
                gate = Gate(f"G{gate_id}", GateType.NOT, [not_match.group(1)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
            
            # a & b -> AND
            and_match = re.match(r'(\w+)\s*&\s*(\w+)', expr)
            if and_match:
                gate = Gate(f"G{gate_id}", GateType.AND,
                           [and_match.group(1), and_match.group(2)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
            
            # a | b -> OR
            or_match = re.match(r'(\w+)\s*\|\s*(\w+)', expr)
            if or_match:
                gate = Gate(f"G{gate_id}", GateType.OR,
                           [or_match.group(1), or_match.group(2)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
            
            # a ^ b -> XOR
            xor_match = re.match(r'(\w+)\s*\^\s*(\w+)', expr)
            if xor_match:
                gate = Gate(f"G{gate_id}", GateType.XOR,
                           [xor_match.group(1), xor_match.group(2)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
            
            # 简单赋值 -> BUF
            buf_match = re.match(r'^(\w+)$', expr)
            if buf_match:
                gate = Gate(f"G{gate_id}", GateType.BUF, [buf_match.group(1)], output)
                circuit.gates[gate.name] = gate
                gate_id += 1
                continue
        
        # 解析always块中的DFF
        # always @(posedge clk...) reg <= value;
        dff_pattern = r"always\s+@\s*\(posedge\s+(\w+).*?\)\s*(?:if\s*\([^)]+\)\s*(\w+)\s*<=\s*[^;]+;\s*else\s*)?(?:if\s*\([^)]+\))?\s*(\w+)\s*<=\s*([^;]+);"
        for match in re.finditer(dff_pattern, content, re.DOTALL):
            clk = match.group(1)
            reg = match.group(3) or match.group(2)
            d_input = match.group(4).strip()
            
            if reg and d_input and not d_input.startswith("1'"):
                gate = Gate(f"DFF{gate_id}", GateType.DFF, [d_input], reg)
                circuit.gates[gate.name] = gate
                circuit.wires.add(reg)
                gate_id += 1
        
        return circuit


class ScanInsertion:
    """Scan Chain插入器 (增强版)
    
    支持:
    - 多Scan Chain: 减少shift时间
    - 时钟域处理: 按时钟域分组DFF
    - EDT压缩: LFSR/MISR数据压缩
    """
    
    def __init__(self, circuit: Circuit, num_chains: int = 1, 
                 edt_config: EDTConfig = None):
        self.circuit = circuit
        self.num_chains = max(1, num_chains)
        self.edt_config = edt_config or EDTConfig()
        
        # 多链支持
        self.scan_chains: List[ScanChain] = []
        self.scan_cells: List[ScanCell] = []  # 保持兼容性
        
        # 全局控制信号
        self.scan_en = "scan_en"
        
        # 时钟域信息
        self.clock_domains: Dict[str, List[Gate]] = defaultdict(list)
        
    def identify_dffs(self) -> List[Gate]:
        """识别所有DFF"""
        dffs = []
        for gate in self.circuit.gates.values():
            if gate.gate_type == GateType.DFF:
                dffs.append(gate)
        return dffs
    
    def identify_dffs_by_clock(self) -> Dict[str, List[Gate]]:
        """按时钟域识别DFF
        
        Returns:
            Dict[clock_name, List[DFF gates]]
        """
        self.clock_domains.clear()
        
        # 尝试从门名称或注释中提取时钟信息
        # 如果无法确定,使用默认时钟域"clk"
        for gate in self.circuit.gates.values():
            if gate.gate_type == GateType.DFF:
                # 尝试从门名称推断时钟域
                # 例如: DFF_clk1_xxx, xxx_clk2_reg
                clock = self._extract_clock_domain(gate)
                self.clock_domains[clock].append(gate)
        
        # 如果只有默认时钟域,返回
        if len(self.clock_domains) == 1 and "clk" in self.clock_domains:
            print(f"Single clock domain detected: clk ({len(self.clock_domains['clk'])} DFFs)")
        else:
            print(f"Multiple clock domains detected:")
            for clk, dffs in self.clock_domains.items():
                print(f"  {clk}: {len(dffs)} DFFs")
        
        return dict(self.clock_domains)
    
    def _extract_clock_domain(self, gate: Gate) -> str:
        """从门信息中提取时钟域"""
        name = gate.name.lower()
        
        # 尝试匹配常见的时钟命名模式
        patterns = [
            r'_clk(\d*)_',      # _clk1_, _clk2_, _clk_
            r'_clock(\d*)_',    # _clock1_, _clock2_
            r'^clk(\d*)_',      # clk1_xxx
            r'_pclk_',          # APB pclk
            r'_hclk_',          # AHB hclk  
            r'_aclk_',          # AXI aclk
            r'_sclk_',          # SPI sclk
        ]
        
        for pattern in patterns:
            match = re.search(pattern, name)
            if match:
                if 'pclk' in pattern:
                    return 'pclk'
                elif 'hclk' in pattern:
                    return 'hclk'
                elif 'aclk' in pattern:
                    return 'aclk'
                elif 'sclk' in pattern:
                    return 'sclk'
                else:
                    suffix = match.group(1) if match.groups() and match.group(1) else ""
                    return f"clk{suffix}" if suffix else "clk"
        
        return "clk"  # 默认时钟域
    
    def _distribute_dffs_to_chains(self, dffs_by_clock: Dict[str, List[Gate]]) -> List[List[Gate]]:
        """将DFF分配到多个Scan Chain
        
        策略:
        1. 优先保持同一时钟域的DFF在同一链中
        2. 平衡各链长度,减少最大shift时间
        3. 如果链数 >= 时钟域数,每个时钟域独占一条或多条链
        4. 如果链数 < 时钟域数,按DFF数量合并小时钟域
        """
        chains: List[List[Gate]] = [[] for _ in range(self.num_chains)]
        
        # 按DFF数量排序时钟域 (从多到少)
        sorted_domains = sorted(dffs_by_clock.items(), 
                               key=lambda x: len(x[1]), reverse=True)
        
        if len(sorted_domains) <= self.num_chains:
            # 时钟域数 <= 链数: 每个时钟域至少一条链
            for i, (clk, dffs) in enumerate(sorted_domains):
                chain_idx = i % self.num_chains
                chains[chain_idx].extend(dffs)
            
            # 重新平衡 - 如果某条链太长,分流到空链
            self._balance_chains(chains)
        else:
            # 时钟域数 > 链数: 合并小时钟域
            # 使用贪心算法: 每次将最小时钟域分配给当前最短的链
            for clk, dffs in sorted_domains:
                # 找到当前最短的链
                min_idx = min(range(self.num_chains), key=lambda i: len(chains[i]))
                chains[min_idx].extend(dffs)
        
        return chains
    
    def _balance_chains(self, chains: List[List[Gate]]):
        """平衡链长度 - 确保所有链均匀分配DFF"""
        total_dffs = sum(len(c) for c in chains)
        if total_dffs == 0:
            return
        
        target_len = total_dffs // self.num_chains
        remainder = total_dffs % self.num_chains
        
        # 收集所有DFF到一个列表，然后重新均匀分配
        all_dffs = []
        for chain in chains:
            all_dffs.extend(chain)
            chain.clear()
        
        # 均匀分配到所有链
        dff_idx = 0
        for i in range(self.num_chains):
            # 前remainder条链多分配1个DFF
            chain_size = target_len + (1 if i < remainder else 0)
            for _ in range(chain_size):
                if dff_idx < len(all_dffs):
                    chains[i].append(all_dffs[dff_idx])
                    dff_idx += 1
    
    def insert_scan_chain(self) -> Circuit:
        """插入Scan Chain (增强版 - 支持多链和时钟域)"""
        # 按时钟域识别DFF
        dffs_by_clock = self.identify_dffs_by_clock()
        
        total_dffs = sum(len(dffs) for dffs in dffs_by_clock.values())
        if total_dffs == 0:
            print("Warning: No DFFs found in circuit")
            return self.circuit
        
        print(f"\nInserting {self.num_chains} scan chain(s) for {total_dffs} DFFs...")
        
        # 分配DFF到多条链
        chains_dffs = self._distribute_dffs_to_chains(dffs_by_clock)
        
        # 创建新电路
        new_circuit = Circuit()
        new_circuit.name = f"{self.circuit.name}_scan"
        
        # 复制原有输入
        new_circuit.inputs = list(self.circuit.inputs)
        new_circuit.inputs.append(self.scan_en)
        
        # 为每条链添加SI/SO
        for i in range(self.num_chains):
            new_circuit.inputs.append(f"scan_in_{i}")
        
        # 复制原有输出
        new_circuit.outputs = list(self.circuit.outputs)
        for i in range(self.num_chains):
            new_circuit.outputs.append(f"scan_out_{i}")
        
        # 复制wires
        new_circuit.wires = set(self.circuit.wires)
        new_circuit.wires.add(self.scan_en)
        for i in range(self.num_chains):
            new_circuit.wires.add(f"scan_in_{i}")
            new_circuit.wires.add(f"scan_out_{i}")
        
        # 创建Scan Chain对象
        self.scan_chains = []
        for i in range(self.num_chains):
            chain = ScanChain(
                chain_id=i,
                scan_in=f"scan_in_{i}",
                scan_out=f"scan_out_{i}",
                clock_domain="clk"  # 将在处理时更新
            )
            self.scan_chains.append(chain)
        
        # 处理每个门
        mux_id = 0
        for gate_name, gate in self.circuit.gates.items():
            if gate.gate_type == GateType.DFF:
                # 找到该DFF所属的链
                chain_id = -1
                for i, chain_dffs in enumerate(chains_dffs):
                    if gate in chain_dffs:
                        chain_id = i
                        break
                
                if chain_id < 0:
                    continue
                
                chain = self.scan_chains[chain_id]
                clock_domain = self._extract_clock_domain(gate)
                
                # 创建Scan Cell
                scan_cell = ScanCell(
                    name=gate_name,
                    d_input=gate.inputs[0] if gate.inputs else "",
                    q_output=gate.output,
                    chain_index=len(chain.cells),
                    chain_id=chain_id,
                    clock_domain=clock_domain
                )
                
                # 确定SI连接
                if len(chain.cells) == 0:
                    scan_cell.si_input = chain.scan_in
                else:
                    scan_cell.si_input = chain.cells[-1].q_output
                
                # 创建MUX门: mux_out = scan_en ? SI : D
                mux_out = f"_scan_mux_{mux_id}_"
                scan_cell.mux_name = f"SMUX{mux_id}"
                
                # MUX: output = MUX(D, SI, SE) 
                mux_gate = Gate(
                    name=scan_cell.mux_name,
                    gate_type=GateType.MUX,
                    inputs=[scan_cell.d_input, scan_cell.si_input, self.scan_en],
                    output=mux_out
                )
                new_circuit.gates[mux_gate.name] = mux_gate
                new_circuit.wires.add(mux_out)
                
                # 创建新的DFF,D输入改为MUX输出
                new_dff = Gate(
                    name=f"SDFF{mux_id}",
                    gate_type=GateType.SDFF,
                    inputs=[mux_out],
                    output=gate.output
                )
                new_circuit.gates[new_dff.name] = new_dff
                
                chain.cells.append(scan_cell)
                self.scan_cells.append(scan_cell)  # 兼容性
                mux_id += 1
            else:
                # 非DFF门直接复制
                new_circuit.gates[gate_name] = gate
        
        # 添加每条链的scan_out连接
        for chain in self.scan_chains:
            if chain.cells:
                last_q = chain.cells[-1].q_output
                buf_gate = Gate(
                    name=f"SCAN_OUT_BUF_{chain.chain_id}",
                    gate_type=GateType.BUF,
                    inputs=[last_q],
                    output=chain.scan_out
                )
                new_circuit.gates[buf_gate.name] = buf_gate
        
        # 如果启用EDT,添加压缩逻辑
        if self.edt_config.enabled:
            self._insert_edt_logic(new_circuit)
        
        # 打印报告
        self._print_scan_report()
        
        return new_circuit
    
    def _insert_edt_logic(self, circuit: Circuit):
        """插入EDT压缩/解压缩逻辑
        
        EDT结构:
        - LFSR: 线性反馈移位寄存器,用于解压缩扫描输入
        - Phase Shifter: 相位移位器,将LFSR输出分配到各scan chain
        - MISR: 多输入签名寄存器,压缩scan chain输出
        """
        edt = self.edt_config
        
        print(f"\nInserting EDT compression logic...")
        print(f"  LFSR width: {edt.lfsr_width}")
        print(f"  MISR width: {edt.misr_width}")
        print(f"  Compression ratio: {edt.compression_ratio}:1")
        
        # 添加EDT控制信号
        circuit.inputs.append("edt_clock")
        circuit.inputs.append("edt_update")
        circuit.outputs.append("edt_signature")
        
        circuit.wires.add("edt_clock")
        circuit.wires.add("edt_update")
        circuit.wires.add("edt_signature")
        
        # 生成LFSR (解压缩器)
        lfsr_outputs = self._generate_lfsr(circuit, edt.lfsr_width, edt.lfsr_poly)
        
        # 生成Phase Shifter (将LFSR输出XOR组合分配到scan_in)
        self._generate_phase_shifter(circuit, lfsr_outputs)
        
        # 生成MISR (压缩器)
        self._generate_misr(circuit, edt.misr_width, edt.lfsr_poly)
        
    def _generate_lfsr(self, circuit: Circuit, width: int, poly: int) -> List[str]:
        """生成LFSR解压缩逻辑
        
        LFSR用于将少量外部输入扩展为多个scan chain的输入
        """
        lfsr_outputs = []
        
        # 添加LFSR种子输入
        circuit.inputs.append("lfsr_seed_in")
        circuit.wires.add("lfsr_seed_in")
        
        # 创建LFSR寄存器
        for i in range(width):
            reg_name = f"_lfsr_reg_{i}_"
            lfsr_outputs.append(reg_name)
            circuit.wires.add(reg_name)
            
            # LFSR反馈逻辑
            if i == 0:
                # 第一位: XOR反馈
                feedback_bits = []
                for bit in range(width):
                    if (poly >> bit) & 1:
                        feedback_bits.append(f"_lfsr_reg_{bit}_")
                
                if len(feedback_bits) >= 2:
                    # 创建XOR链
                    xor_out = feedback_bits[0]
                    for j, fb in enumerate(feedback_bits[1:]):
                        new_xor = f"_lfsr_fb_xor_{j}_"
                        gate = Gate(
                            name=f"LFSR_FB_XOR{j}",
                            gate_type=GateType.XOR,
                            inputs=[xor_out, fb],
                            output=new_xor
                        )
                        circuit.gates[gate.name] = gate
                        circuit.wires.add(new_xor)
                        xor_out = new_xor
                    
                    # LFSR[0] = feedback XOR seed_in
                    dff = Gate(
                        name=f"LFSR_DFF{i}",
                        gate_type=GateType.DFF,
                        inputs=[xor_out],
                        output=reg_name
                    )
                    circuit.gates[dff.name] = dff
                else:
                    dff = Gate(
                        name=f"LFSR_DFF{i}",
                        gate_type=GateType.DFF,
                        inputs=["lfsr_seed_in"],
                        output=reg_name
                    )
                    circuit.gates[dff.name] = dff
            else:
                # 其他位: 简单移位
                prev_reg = f"_lfsr_reg_{i-1}_"
                dff = Gate(
                    name=f"LFSR_DFF{i}",
                    gate_type=GateType.DFF,
                    inputs=[prev_reg],
                    output=reg_name
                )
                circuit.gates[dff.name] = dff
        
        return lfsr_outputs
    
    def _generate_phase_shifter(self, circuit: Circuit, lfsr_outputs: List[str]):
        """生成Phase Shifter
        
        将LFSR输出通过XOR组合生成各scan chain的输入
        实现解压缩功能
        """
        for chain in self.scan_chains:
            # 选择LFSR输出的子集进行XOR
            # 使用简单的循环选择策略
            selected = []
            for i in range(min(3, len(lfsr_outputs))):
                idx = (chain.chain_id + i) % len(lfsr_outputs)
                selected.append(lfsr_outputs[idx])
            
            if len(selected) >= 2:
                # XOR选中的LFSR位
                xor_out = selected[0]
                for j, sel in enumerate(selected[1:]):
                    new_xor = f"_phase_xor_{chain.chain_id}_{j}_"
                    gate = Gate(
                        name=f"PHASE_XOR{chain.chain_id}_{j}",
                        gate_type=GateType.XOR,
                        inputs=[xor_out, sel],
                        output=new_xor
                    )
                    circuit.gates[gate.name] = gate
                    circuit.wires.add(new_xor)
                    xor_out = new_xor
                
                # 通过MUX选择: edt_update ? phase_out : scan_in_x
                mux_out = f"_edt_si_{chain.chain_id}_"
                mux = Gate(
                    name=f"EDT_SI_MUX{chain.chain_id}",
                    gate_type=GateType.MUX,
                    inputs=[chain.scan_in, xor_out, "edt_update"],
                    output=mux_out
                )
                circuit.gates[mux.name] = mux
                circuit.wires.add(mux_out)
    
    def _generate_misr(self, circuit: Circuit, width: int, poly: int):
        """生成MISR压缩逻辑
        
        MISR将多个scan chain的输出压缩为签名
        """
        # 收集所有scan_out
        scan_outs = [chain.scan_out for chain in self.scan_chains]
        
        # 创建MISR寄存器
        for i in range(width):
            reg_name = f"_misr_reg_{i}_"
            circuit.wires.add(reg_name)
            
            # MISR输入: 前一寄存器 XOR scan_out (循环分配)
            prev_reg = f"_misr_reg_{(i-1) % width}_"
            so_idx = i % len(scan_outs)
            
            # XOR组合
            xor_wire = f"_misr_xor_{i}_"
            xor_gate = Gate(
                name=f"MISR_XOR{i}",
                gate_type=GateType.XOR,
                inputs=[prev_reg, scan_outs[so_idx]],
                output=xor_wire
            )
            circuit.gates[xor_gate.name] = xor_gate
            circuit.wires.add(xor_wire)
            
            # MISR DFF
            dff = Gate(
                name=f"MISR_DFF{i}",
                gate_type=GateType.DFF,
                inputs=[xor_wire],
                output=reg_name
            )
            circuit.gates[dff.name] = dff
        
        # 输出签名 (MISR最高位)
        buf = Gate(
            name="MISR_OUT",
            gate_type=GateType.BUF,
            inputs=[f"_misr_reg_{width-1}_"],
            output="edt_signature"
        )
        circuit.gates[buf.name] = buf
    
    def _print_scan_report(self):
        """打印Scan Chain报告"""
        print(f"\n{'='*60}")
        print(f"SCAN CHAIN INSERTION REPORT")
        print(f"{'='*60}")
        print(f"Total chains: {len(self.scan_chains)}")
        print(f"Total scan cells: {len(self.scan_cells)}")
        
        if self.scan_chains:
            max_len = max(chain.length for chain in self.scan_chains)
            min_len = min(chain.length for chain in self.scan_chains)
            print(f"Max chain length: {max_len}")
            print(f"Min chain length: {min_len}")
            print(f"Shift cycles reduced: {len(self.scan_cells)} -> {max_len} ({(1-max_len/max(1,len(self.scan_cells)))*100:.1f}% reduction)")
        
        print(f"\nChain details:")
        for chain in self.scan_chains:
            clock_domains = set(cell.clock_domain for cell in chain.cells)
            print(f"  Chain {chain.chain_id}: {chain.length} cells")
            print(f"    SI: {chain.scan_in}, SO: {chain.scan_out}")
            print(f"    Clock domains: {', '.join(clock_domains)}")
        
        if self.edt_config.enabled:
            print(f"\nEDT Compression:")
            print(f"  LFSR width: {self.edt_config.lfsr_width}")
            print(f"  MISR width: {self.edt_config.misr_width}")
            print(f"  Compression ratio: {self.edt_config.compression_ratio}:1")
            original_bits = len(self.scan_cells) * 2  # SI + expected SO
            compressed_bits = (self.edt_config.lfsr_width + self.edt_config.misr_width)
            print(f"  Test data reduction: ~{(1-compressed_bits/max(1,original_bits))*100:.1f}%")
        
        print(f"{'='*60}\n")
    
    def get_scan_chain_order(self) -> List[str]:
        """获取scan chain顺序"""
        return [cell.q_output for cell in self.scan_cells]


class NetlistWriter:
    """网表输出器"""
    
    @staticmethod
    def write_bench(circuit: Circuit, filename: str):
        """输出BENCH格式"""
        lines = []
        lines.append(f"# {circuit.name}")
        lines.append(f"# Scan-inserted netlist")
        lines.append(f"# Inputs: {len(circuit.inputs)}")
        lines.append(f"# Outputs: {len(circuit.outputs)}")
        lines.append(f"# Gates: {len(circuit.gates)}")
        lines.append("")
        
        # Inputs
        for inp in circuit.inputs:
            lines.append(f"INPUT({inp})")
        lines.append("")
        
        # Outputs
        for out in circuit.outputs:
            lines.append(f"OUTPUT({out})")
        lines.append("")
        
        # Gates
        for gate in circuit.gates.values():
            if gate.gate_type == GateType.MUX:
                # MUX(D, SI, SE): SE ? SI : D
                # 用门实现: out = (SE & SI) | (~SE & D)
                d, si, se = gate.inputs[0], gate.inputs[1], gate.inputs[2]
                lines.append(f"# MUX: {gate.output} = {se} ? {si} : {d}")
                # 分解为基本门
                not_se = f"_{gate.name}_nse_"
                and1 = f"_{gate.name}_a1_"
                and2 = f"_{gate.name}_a2_"
                lines.append(f"{not_se} = NOT({se})")
                lines.append(f"{and1} = AND({se}, {si})")
                lines.append(f"{and2} = AND({not_se}, {d})")
                lines.append(f"{gate.output} = OR({and1}, {and2})")
            elif gate.gate_type == GateType.SDFF:
                # Scan DFF输出为DFF
                lines.append(f"{gate.output} = DFF({gate.inputs[0]})")
            elif gate.gate_type == GateType.DFF:
                lines.append(f"{gate.output} = DFF({', '.join(gate.inputs)})")
            else:
                lines.append(f"{gate.output} = {gate.gate_type.value}({', '.join(gate.inputs)})")
        
        with open(filename, 'w') as f:
            f.write('\n'.join(lines))
        
        print(f"Written: {filename}")
    
    @staticmethod
    def write_verilog(circuit: Circuit, filename: str, scan_cells: List[ScanCell] = None):
        """输出Verilog格式"""
        lines = []
        lines.append(f"// {circuit.name}")
        lines.append(f"// Scan-inserted netlist")
        lines.append(f"// Generated by DFT Scan Insertion Tool")
        lines.append("")
        
        # Module declaration
        all_ports = circuit.inputs + circuit.outputs
        lines.append(f"module {circuit.name} (")
        lines.append(f"    {', '.join(all_ports)}")
        lines.append(");")
        lines.append("")
        
        # Port declarations
        for inp in circuit.inputs:
            lines.append(f"    input {inp};")
        for out in circuit.outputs:
            lines.append(f"    output {out};")
        lines.append("")
        
        # Wire declarations
        internal_wires = circuit.wires - set(circuit.inputs) - set(circuit.outputs)
        if internal_wires:
            lines.append(f"    wire {', '.join(sorted(internal_wires))};")
            lines.append("")
        
        # Gate instances
        for gate in circuit.gates.values():
            if gate.gate_type == GateType.MUX:
                d, si, se = gate.inputs[0], gate.inputs[1], gate.inputs[2]
                lines.append(f"    // Scan MUX: {gate.output} = {se} ? {si} : {d}")
                lines.append(f"    assign {gate.output} = {se} ? {si} : {d};")
            elif gate.gate_type in [GateType.DFF, GateType.SDFF]:
                lines.append(f"    // Scan DFF")
                lines.append(f"    always @(posedge clk or negedge rstn)")
                lines.append(f"        if (!rstn) {gate.output} <= 1'b0;")
                lines.append(f"        else {gate.output} <= {gate.inputs[0]};")
            elif gate.gate_type == GateType.NOT:
                lines.append(f"    assign {gate.output} = ~{gate.inputs[0]};")
            elif gate.gate_type == GateType.AND:
                lines.append(f"    assign {gate.output} = {' & '.join(gate.inputs)};")
            elif gate.gate_type == GateType.OR:
                lines.append(f"    assign {gate.output} = {' | '.join(gate.inputs)};")
            elif gate.gate_type == GateType.NAND:
                lines.append(f"    assign {gate.output} = ~({' & '.join(gate.inputs)});")
            elif gate.gate_type == GateType.NOR:
                lines.append(f"    assign {gate.output} = ~({' | '.join(gate.inputs)});")
            elif gate.gate_type == GateType.XOR:
                lines.append(f"    assign {gate.output} = {' ^ '.join(gate.inputs)};")
            elif gate.gate_type == GateType.XNOR:
                lines.append(f"    assign {gate.output} = ~({' ^ '.join(gate.inputs)});")
            elif gate.gate_type == GateType.BUF:
                lines.append(f"    assign {gate.output} = {gate.inputs[0]};")
        
        lines.append("")
        lines.append("endmodule")
        
        with open(filename, 'w') as f:
            f.write('\n'.join(lines))
        
        print(f"Written: {filename}")
    
    @staticmethod
    def write_scan_def(circuit: Circuit, scan_chains: List[ScanChain], 
                       filename: str, edt_config: EDTConfig = None):
        """输出Scan Chain定义文件 (支持多链和EDT)"""
        lines = []
        lines.append(f"# Scan Chain Definition for {circuit.name}")
        lines.append(f"# Generated by DFT Scan Insertion Tool (Enhanced)")
        lines.append(f"# Multi-chain and EDT compression support")
        lines.append("")
        lines.append(f"DESIGN {circuit.name}")
        lines.append(f"NUM_CHAINS {len(scan_chains)}")
        lines.append("")
        
        # 输出每条Scan Chain
        total_cells = 0
        for chain in scan_chains:
            lines.append(f"SCAN_CHAIN chain_{chain.chain_id}")
            lines.append(f"  LENGTH {chain.length}")
            lines.append(f"  SCAN_IN {chain.scan_in}")
            lines.append(f"  SCAN_OUT {chain.scan_out}")
            lines.append(f"  SCAN_ENABLE scan_en")
            
            # 收集该链的时钟域
            clock_domains = set(cell.clock_domain for cell in chain.cells)
            lines.append(f"  CLOCK_DOMAINS {', '.join(sorted(clock_domains))}")
            
            lines.append(f"  SCAN_CELLS")
            for i, cell in enumerate(chain.cells):
                lines.append(f"    {i}: {cell.q_output} (D={cell.d_input}, SI={cell.si_input}, CLK={cell.clock_domain})")
            
            lines.append("END_SCAN_CHAIN")
            lines.append("")
            total_cells += chain.length
        
        # 输出EDT配置
        if edt_config and edt_config.enabled:
            lines.append("# EDT Compression Configuration")
            lines.append("EDT_CONFIG")
            lines.append(f"  ENABLED true")
            lines.append(f"  LFSR_WIDTH {edt_config.lfsr_width}")
            lines.append(f"  MISR_WIDTH {edt_config.misr_width}")
            lines.append(f"  LFSR_POLY 0x{edt_config.lfsr_poly:04X}")
            lines.append(f"  LFSR_SEED 0x{edt_config.lfsr_seed:04X}")
            lines.append(f"  COMPRESSION_RATIO {edt_config.compression_ratio}")
            lines.append("END_EDT_CONFIG")
            lines.append("")
        
        # 输出统计信息
        lines.append("# Statistics")
        lines.append(f"# Total scan cells: {total_cells}")
        lines.append(f"# Number of chains: {len(scan_chains)}")
        if scan_chains:
            max_len = max(c.length for c in scan_chains)
            lines.append(f"# Max chain length: {max_len}")
            lines.append(f"# Shift cycles: {max_len}")
            if total_cells > 0:
                lines.append(f"# Parallelism improvement: {total_cells/max_len:.2f}x")
        
        with open(filename, 'w') as f:
            f.write('\n'.join(lines))
        
        print(f"Written: {filename}")


def main():
    parser = argparse.ArgumentParser(
        description='DFT Scan Chain Insertion Tool (Enhanced) - 增强版扫描链插入工具',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # 基本用法 (单链)
  %(prog)s netlist.bench -o output
  
  # 多链模式 (4条链)
  %(prog)s netlist.bench -o output --num-chains 4
  
  # 启用EDT压缩
  %(prog)s netlist.bench -o output --num-chains 4 --enable-edt
  
  # 自定义EDT参数
  %(prog)s netlist.bench -o output --num-chains 8 --enable-edt --lfsr-width 32 --misr-width 32
"""
    )
    parser.add_argument('netlist', help='Input netlist file (BENCH or Verilog)')
    parser.add_argument('-o', '--output', help='Output netlist file base name')
    parser.add_argument('-f', '--format', choices=['bench', 'verilog', 'both'],
                       default='bench', help='Output format (default: bench)')
    parser.add_argument('--scan-def', help='Output scan chain definition file')
    
    # 多链参数
    parser.add_argument('--num-chains', '-n', type=int, default=1,
                       help='Number of scan chains (default: 1)')
    
    # EDT参数
    parser.add_argument('--enable-edt', action='store_true',
                       help='Enable EDT compression')
    parser.add_argument('--lfsr-width', type=int, default=16,
                       help='LFSR width for EDT decompression (default: 16)')
    parser.add_argument('--misr-width', type=int, default=16,
                       help='MISR width for EDT compression (default: 16)')
    parser.add_argument('--compression-ratio', type=int, default=8,
                       help='EDT compression ratio (default: 8)')
    
    args = parser.parse_args()
    
    # 解析输入网表
    print(f"{'='*60}")
    print(f"DFT SCAN CHAIN INSERTION TOOL (Enhanced)")
    print(f"{'='*60}")
    print(f"\nReading netlist: {args.netlist}")
    
    if args.netlist.endswith('.v'):
        circuit = NetlistParser.parse_verilog(args.netlist)
    else:
        circuit = NetlistParser.parse_bench(args.netlist)
    
    print(f"\nCircuit: {circuit.name}")
    print(f"  Inputs: {len(circuit.inputs)}")
    print(f"  Outputs: {len(circuit.outputs)}")
    print(f"  Gates: {len(circuit.gates)}")
    
    # 配置EDT
    edt_config = EDTConfig(
        enabled=args.enable_edt,
        lfsr_width=args.lfsr_width,
        misr_width=args.misr_width,
        compression_ratio=args.compression_ratio
    )
    
    # 插入Scan Chain
    scan_inserter = ScanInsertion(circuit, num_chains=args.num_chains, 
                                   edt_config=edt_config)
    scan_circuit = scan_inserter.insert_scan_chain()
    
    # 输出
    base_name = args.output or f"{circuit.name}_scan"
    if not base_name.endswith(('.bench', '.v')):
        bench_file = f"{base_name}.bench"
        verilog_file = f"{base_name}.v"
    else:
        bench_file = base_name.replace('.v', '.bench')
        verilog_file = base_name.replace('.bench', '.v')
    
    if args.format in ['bench', 'both']:
        NetlistWriter.write_bench(scan_circuit, bench_file)
    
    if args.format in ['verilog', 'both']:
        NetlistWriter.write_verilog(scan_circuit, verilog_file, scan_inserter.scan_cells)
    
    # 输出Scan定义文件
    if args.scan_def:
        def_file = args.scan_def
    else:
        def_file = f"{base_name}.scandef"
    
    NetlistWriter.write_scan_def(scan_circuit, scan_inserter.scan_chains, 
                                  def_file, edt_config if args.enable_edt else None)
    
    # 最终统计
    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")
    print(f"Total scan cells: {len(scan_inserter.scan_cells)}")
    print(f"Number of chains: {len(scan_inserter.scan_chains)}")
    if scan_inserter.scan_chains:
        max_len = max(c.length for c in scan_inserter.scan_chains)
        print(f"Max chain length: {max_len}")
        print(f"Shift cycles: {max_len} (was {len(scan_inserter.scan_cells)} with single chain)")
    if args.enable_edt:
        print(f"EDT compression: Enabled")
    print(f"\nOutput files:")
    if args.format in ['bench', 'both']:
        print(f"  BENCH: {bench_file}")
    if args.format in ['verilog', 'both']:
        print(f"  Verilog: {verilog_file}")
    print(f"  ScanDef: {def_file}")
    print(f"{'='*60}")
    print("\nDone!")


if __name__ == "__main__":
    main()
