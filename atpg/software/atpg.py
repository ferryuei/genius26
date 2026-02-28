#!/usr/bin/env python3
"""
ATPG - Automatic Test Pattern Generation Tool (Enhanced)
增强版自动测试向量生成工具

支持功能:
- Stuck-at Fault: 固定型故障 (s-a-0, s-a-1)
- Transition Fault: 跳变故障 (STR, STF) 用于at-speed测试
- 多种ATPG算法: D-Algorithm, PODEM, FAN
- 冗余故障识别: 准确报告可测/不可测故障
- 并行故障模拟: 位并行技术提高效率
- Scan-based ATPG: 扫描链测试支持
"""

import re
import sys
import json
import argparse
from enum import Enum, auto
from typing import Dict, List, Set, Tuple, Optional, Union
from dataclasses import dataclass, field
from collections import defaultdict
import random
from concurrent.futures import ThreadPoolExecutor
import time


# =============================================================================
# Logic Values for 5-valued logic (D-algorithm)
# =============================================================================

class Logic(Enum):
    """5-valued logic for D-algorithm"""
    ZERO = 0      # Logic 0
    ONE = 1       # Logic 1
    X = 2         # Unknown
    D = 3         # 1 in good circuit, 0 in faulty circuit (fault detected)
    D_BAR = 4     # 0 in good circuit, 1 in faulty circuit (fault detected)
    
    def __str__(self):
        return {
            Logic.ZERO: '0',
            Logic.ONE: '1',
            Logic.X: 'X',
            Logic.D: 'D',
            Logic.D_BAR: "D'"
        }[self]
    
    @staticmethod
    def from_str(s):
        mapping = {'0': Logic.ZERO, '1': Logic.ONE, 'X': Logic.X, 'x': Logic.X,
                   'D': Logic.D, "D'": Logic.D_BAR, 'DB': Logic.D_BAR}
        return mapping.get(s, Logic.X)


def logic_not(a: Logic) -> Logic:
    """Invert logic value"""
    return {
        Logic.ZERO: Logic.ONE,
        Logic.ONE: Logic.ZERO,
        Logic.X: Logic.X,
        Logic.D: Logic.D_BAR,
        Logic.D_BAR: Logic.D
    }[a]


def logic_and(a: Logic, b: Logic) -> Logic:
    """AND operation"""
    if a == Logic.ZERO or b == Logic.ZERO:
        return Logic.ZERO
    if a == Logic.ONE:
        return b
    if b == Logic.ONE:
        return a
    if a == Logic.X or b == Logic.X:
        return Logic.X
    if a == b:
        return a
    # D AND D' = 0
    return Logic.ZERO


def logic_or(a: Logic, b: Logic) -> Logic:
    """OR operation"""
    if a == Logic.ONE or b == Logic.ONE:
        return Logic.ONE
    if a == Logic.ZERO:
        return b
    if b == Logic.ZERO:
        return a
    if a == Logic.X or b == Logic.X:
        return Logic.X
    if a == b:
        return a
    # D OR D' = 1
    return Logic.ONE


def logic_xor(a: Logic, b: Logic) -> Logic:
    """XOR operation"""
    if a == Logic.X or b == Logic.X:
        return Logic.X
    if a == Logic.ZERO:
        return b
    if b == Logic.ZERO:
        return a
    if a == Logic.ONE:
        return logic_not(b)
    if b == Logic.ONE:
        return logic_not(a)
    if a == b:
        return Logic.ZERO
    return Logic.ONE


# =============================================================================
# Gate Types
# =============================================================================

class GateType(Enum):
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
    DFF = "DFF"      # D Flip-Flop (non-scan)
    SDFF = "SDFF"    # Scan D Flip-Flop with SE, SI


# =============================================================================
# Scan Chain Support
# =============================================================================

@dataclass 
class ScanCell:
    """Represents a scan cell (Scan DFF)"""
    name: str           # DFF instance name
    d_input: str        # D input net
    q_output: str       # Q output net
    si_input: str = None    # Scan In (connected to previous cell's Q or scan_in port)
    se_signal: str = None   # Scan Enable signal
    scan_order: int = -1    # Position in scan chain

@dataclass
class ScanChain:
    """Represents a scan chain"""
    name: str = "scan_chain_0"
    scan_in: str = "scan_in"      # Primary scan input
    scan_out: str = "scan_out"    # Primary scan output  
    scan_enable: str = "scan_en"  # Scan enable signal
    cells: List[ScanCell] = field(default_factory=list)
    
    def get_length(self) -> int:
        return len(self.cells)


# =============================================================================
# Circuit Elements
# =============================================================================

@dataclass
class Net:
    """Represents a wire/net in the circuit"""
    name: str
    value: Logic = Logic.X
    driver: Optional['Gate'] = None
    loads: List['Gate'] = field(default_factory=list)


@dataclass
class Gate:
    """Represents a logic gate"""
    name: str
    gate_type: GateType
    inputs: List[Net] = field(default_factory=list)
    output: Optional[Net] = None
    level: int = -1  # Topological level
    
    def evaluate(self) -> Logic:
        """Evaluate gate output based on inputs"""
        # Handle INPUT pseudo-gate first
        if self.gate_type == GateType.INPUT:
            return self.output.value if self.output else Logic.X
            
        if not self.inputs:
            return Logic.X
            
        if self.gate_type == GateType.NOT or self.gate_type == GateType.BUF:
            val = self.inputs[0].value
            return logic_not(val) if self.gate_type == GateType.NOT else val
            
        # Multi-input gates
        result = self.inputs[0].value
        for inp in self.inputs[1:]:
            if self.gate_type in [GateType.AND, GateType.NAND]:
                result = logic_and(result, inp.value)
            elif self.gate_type in [GateType.OR, GateType.NOR]:
                result = logic_or(result, inp.value)
            elif self.gate_type in [GateType.XOR, GateType.XNOR]:
                result = logic_xor(result, inp.value)
                
        # Invert for NAND, NOR, XNOR
        if self.gate_type in [GateType.NAND, GateType.NOR, GateType.XNOR]:
            result = logic_not(result)
            
        return result


# =============================================================================
# Fault Model
# =============================================================================

class FaultType(Enum):
    """故障类型"""
    STUCK_AT_0 = "s-a-0"     # 固定0故障
    STUCK_AT_1 = "s-a-1"     # 固定1故障
    SLOW_TO_RISE = "STR"     # 慢上升 (Transition Fault)
    SLOW_TO_FALL = "STF"     # 慢下降 (Transition Fault)


class FaultStatus(Enum):
    """故障状态"""
    UNTESTED = auto()        # 未测试
    DETECTED = auto()        # 已检测
    REDUNDANT = auto()       # 冗余故障 (不可测)
    ATPG_UNTESTABLE = auto() # ATPG无法生成向量
    NOT_DETECTED = auto()    # 未检测到


@dataclass
class Fault:
    """Represents a stuck-at or transition fault"""
    net_name: str
    stuck_at: int  # 0 or 1 for stuck-at; for transition: 0=STR(0->1), 1=STF(1->0)
    fault_type: FaultType = FaultType.STUCK_AT_0
    status: FaultStatus = FaultStatus.UNTESTED
    detected: bool = False
    test_pattern: Optional[Dict[str, int]] = None
    backtrack_count: int = 0  # 用于识别冗余故障
    
    def __post_init__(self):
        if self.fault_type == FaultType.STUCK_AT_0 or self.fault_type == FaultType.STUCK_AT_1:
            pass
        elif self.stuck_at == 0:
            self.fault_type = FaultType.SLOW_TO_RISE
        else:
            self.fault_type = FaultType.SLOW_TO_FALL
    
    def __str__(self):
        if self.fault_type in [FaultType.STUCK_AT_0, FaultType.STUCK_AT_1]:
            return f"{self.net_name}/s-a-{self.stuck_at}"
        else:
            return f"{self.net_name}/{self.fault_type.value}"
    
    def __hash__(self):
        return hash((self.net_name, self.stuck_at, self.fault_type))
    
    def __eq__(self, other):
        return (self.net_name == other.net_name and 
                self.stuck_at == other.stuck_at and
                self.fault_type == other.fault_type)
    
    def mark_detected(self, pattern: Dict[str, int]):
        """标记故障已检测"""
        self.detected = True
        self.status = FaultStatus.DETECTED
        self.test_pattern = pattern.copy()
    
    def mark_redundant(self):
        """标记故障为冗余(不可测)"""
        self.status = FaultStatus.REDUNDANT
    
    def mark_untestable(self):
        """标记ATPG无法生成向量"""
        self.status = FaultStatus.ATPG_UNTESTABLE


# =============================================================================
# Circuit Class
# =============================================================================

class Circuit:
    """Represents the complete circuit with scan chain support"""
    
    def __init__(self):
        self.name = "circuit"
        self.nets: Dict[str, Net] = {}
        self.gates: Dict[str, Gate] = {}
        self.inputs: List[str] = []
        self.outputs: List[str] = []
        self.gate_list: List[Gate] = []  # Topologically sorted
        # Scan chain support
        self.scan_chains: List[ScanChain] = []
        self.scan_cells: List[ScanCell] = []
        self.has_scan: bool = False
        
    def add_net(self, name: str) -> Net:
        if name not in self.nets:
            self.nets[name] = Net(name)
        return self.nets[name]
    
    def add_gate(self, name: str, gate_type: GateType, 
                 input_names: List[str], output_name: str) -> Gate:
        gate = Gate(name, gate_type)
        
        # Connect inputs
        for inp_name in input_names:
            net = self.add_net(inp_name)
            gate.inputs.append(net)
            net.loads.append(gate)
            
        # Connect output
        out_net = self.add_net(output_name)
        gate.output = out_net
        out_net.driver = gate
        
        self.gates[name] = gate
        return gate
    
    def levelize(self):
        """Compute topological levels for all gates"""
        # Initialize input levels
        for inp_name in self.inputs:
            if inp_name in self.nets:
                net = self.nets[inp_name]
                if net.driver:
                    net.driver.level = 0
                    
        # BFS to assign levels
        changed = True
        while changed:
            changed = False
            for gate in self.gates.values():
                if gate.level >= 0:
                    continue
                    
                # Check if all input drivers have levels
                max_level = -1
                all_ready = True
                for inp_net in gate.inputs:
                    if inp_net.driver:
                        if inp_net.driver.level < 0:
                            all_ready = False
                            break
                        max_level = max(max_level, inp_net.driver.level)
                    else:
                        # Primary input
                        max_level = max(max_level, 0)
                        
                if all_ready:
                    gate.level = max_level + 1
                    changed = True
                    
        # Sort gates by level
        self.gate_list = sorted(
            [g for g in self.gates.values() if g.level >= 0],
            key=lambda g: g.level
        )
        
    def reset_values(self):
        """Reset all net values to X"""
        for net in self.nets.values():
            net.value = Logic.X
            
    def set_input(self, name: str, value: Logic):
        """Set primary input value"""
        if name in self.nets:
            self.nets[name].value = value
            
    def simulate(self) -> Dict[str, Logic]:
        """Forward simulation"""
        for gate in self.gate_list:
            if gate.output:
                gate.output.value = gate.evaluate()
                
        return {name: net.value for name, net in self.nets.items()}
    
    def get_output_values(self) -> Dict[str, Logic]:
        """Get primary output values"""
        return {name: self.nets[name].value for name in self.outputs if name in self.nets}


# =============================================================================
# Netlist Parser
# =============================================================================

class NetlistParser:
    """Parse simple gate-level netlist"""
    
    GATE_PATTERNS = {
        'AND': r'(\w+)\s*=\s*AND\s*\(\s*(.+)\s*\)',
        'OR': r'(\w+)\s*=\s*OR\s*\(\s*(.+)\s*\)',
        'NOT': r'(\w+)\s*=\s*NOT\s*\(\s*(\w+)\s*\)',
        'NAND': r'(\w+)\s*=\s*NAND\s*\(\s*(.+)\s*\)',
        'NOR': r'(\w+)\s*=\s*NOR\s*\(\s*(.+)\s*\)',
        'XOR': r'(\w+)\s*=\s*XOR\s*\(\s*(.+)\s*\)',
        'XNOR': r'(\w+)\s*=\s*XNOR\s*\(\s*(.+)\s*\)',
        'BUF': r'(\w+)\s*=\s*BUF\s*\(\s*(\w+)\s*\)',
        'SDFF': r'(\w+)\s*=\s*SDFF\s*\(\s*(.+)\s*\)',  # Scan DFF: Q = SDFF(D, SI, SE)
    }
    
    @staticmethod
    def parse(filename: str) -> Circuit:
        """Parse netlist file"""
        circuit = Circuit()
        
        with open(filename, 'r') as f:
            content = f.read()
            
        # Remove comments
        content = re.sub(r'//.*', '', content)
        content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
        content = re.sub(r'#.*', '', content)
        
        lines = content.split('\n')
        gate_count = 0
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            # Parse INPUT declaration
            match = re.match(r'INPUT\s*\(\s*(.+)\s*\)', line, re.IGNORECASE)
            if match:
                inputs = [s.strip() for s in match.group(1).split(',')]
                for inp in inputs:
                    circuit.inputs.append(inp)
                    circuit.add_net(inp)
                    # Create pseudo-gate for input
                    gate = Gate(f"_INPUT_{inp}", GateType.INPUT)
                    gate.output = circuit.nets[inp]
                    circuit.nets[inp].driver = gate
                    gate.level = 0
                    circuit.gates[gate.name] = gate
                continue
                
            # Parse OUTPUT declaration
            match = re.match(r'OUTPUT\s*\(\s*(.+)\s*\)', line, re.IGNORECASE)
            if match:
                outputs = [s.strip() for s in match.group(1).split(',')]
                circuit.outputs.extend(outputs)
                continue
                
            # Parse gate definitions
            for gate_type, pattern in NetlistParser.GATE_PATTERNS.items():
                match = re.match(pattern, line, re.IGNORECASE)
                if match:
                    output_name = match.group(1).strip()
                    inputs_str = match.group(2)
                    input_names = [s.strip() for s in inputs_str.split(',')]
                    
                    gate_name = f"G{gate_count}"
                    gate_count += 1
                    
                    # Handle Scan DFF specially
                    if gate_type == 'SDFF':
                        # SDFF(D, SI, SE) -> Q
                        # For ATPG, treat as mux: Q = SE ? SI : D
                        circuit.has_scan = True
                        d_input = input_names[0] if len(input_names) > 0 else None
                        si_input = input_names[1] if len(input_names) > 1 else None
                        se_signal = input_names[2] if len(input_names) > 2 else None
                        
                        # Create scan cell record
                        scan_cell = ScanCell(
                            name=gate_name,
                            d_input=d_input,
                            q_output=output_name,
                            si_input=si_input,
                            se_signal=se_signal,
                            scan_order=len(circuit.scan_cells)
                        )
                        circuit.scan_cells.append(scan_cell)
                        
                        # For combinational ATPG (scan mode), treat as buffer from SI
                        circuit.add_gate(gate_name, GateType.BUF, [d_input], output_name)
                    else:
                        circuit.add_gate(
                            gate_name,
                            GateType[gate_type],
                            input_names,
                            output_name
                        )
                    break
        
        # Build scan chain from scan cells
        if circuit.scan_cells:
            chain = ScanChain(name="chain_0")
            # Find scan_in and scan_enable signals
            if circuit.scan_cells:
                first_cell = circuit.scan_cells[0]
                chain.scan_in = first_cell.si_input or "scan_in"
                chain.scan_enable = first_cell.se_signal or "scan_en"
                last_cell = circuit.scan_cells[-1]
                chain.scan_out = last_cell.q_output
            chain.cells = circuit.scan_cells
            circuit.scan_chains.append(chain)
                    
        circuit.levelize()
        return circuit
    
    @staticmethod
    def parse_verilog(filename: str) -> Circuit:
        """Parse simple Verilog netlist"""
        circuit = Circuit()
        
        with open(filename, 'r') as f:
            content = f.read()
            
        # Remove comments
        content = re.sub(r'//.*', '', content)
        content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
        
        # Extract module name
        match = re.search(r'module\s+(\w+)', content)
        if match:
            circuit.name = match.group(1)
            
        # Extract inputs
        for match in re.finditer(r'input\s+(?:\[\d+:\d+\]\s+)?(\w+)', content):
            inp = match.group(1)
            circuit.inputs.append(inp)
            circuit.add_net(inp)
            gate = Gate(f"_INPUT_{inp}", GateType.INPUT)
            gate.output = circuit.nets[inp]
            circuit.nets[inp].driver = gate
            gate.level = 0
            circuit.gates[gate.name] = gate
            
        # Extract outputs
        for match in re.finditer(r'output\s+(?:\[\d+:\d+\]\s+)?(\w+)', content):
            circuit.outputs.append(match.group(1))
            
        # Extract wires
        for match in re.finditer(r'wire\s+(?:\[\d+:\d+\]\s+)?(\w+)', content):
            circuit.add_net(match.group(1))
            
        # Parse gate instances
        gate_patterns = [
            (r'and\s+(\w+)\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)', GateType.AND),
            (r'or\s+(\w+)\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)', GateType.OR),
            (r'not\s+(\w+)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)', GateType.NOT),
            (r'nand\s+(\w+)\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)', GateType.NAND),
            (r'nor\s+(\w+)\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)', GateType.NOR),
            (r'xor\s+(\w+)\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)', GateType.XOR),
            (r'xnor\s+(\w+)\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)', GateType.XNOR),
            (r'buf\s+(\w+)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)', GateType.BUF),
        ]
        
        for pattern, gate_type in gate_patterns:
            for match in re.finditer(pattern, content, re.IGNORECASE):
                gate_name = match.group(1)
                output_name = match.group(2)
                inputs_str = match.group(3)
                input_names = [s.strip() for s in inputs_str.split(',')]
                
                circuit.add_gate(gate_name, gate_type, input_names, output_name)
                
        circuit.levelize()
        return circuit

    @staticmethod
    def parse_bench(filename: str) -> Circuit:
        """Parse ISCAS bench format netlist"""
        circuit = Circuit()
        
        # Extract circuit name from filename
        import os
        circuit.name = os.path.splitext(os.path.basename(filename))[0]
        
        with open(filename, 'r') as f:
            content = f.read()
            
        # Remove comments
        content = re.sub(r'#.*', '', content)
        
        lines = content.split('\n')
        gate_count = 0
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            # Parse INPUT declaration
            match = re.match(r'INPUT\s*\(\s*(\w+)\s*\)', line, re.IGNORECASE)
            if match:
                inp = match.group(1).strip()
                circuit.inputs.append(inp)
                circuit.add_net(inp)
                gate = Gate(f"_INPUT_{inp}", GateType.INPUT)
                gate.output = circuit.nets[inp]
                circuit.nets[inp].driver = gate
                gate.level = 0
                circuit.gates[gate.name] = gate
                continue
                
            # Parse OUTPUT declaration
            match = re.match(r'OUTPUT\s*\(\s*(\w+)\s*\)', line, re.IGNORECASE)
            if match:
                out = match.group(1).strip()
                if out not in circuit.outputs:
                    circuit.outputs.append(out)
                continue
                
            # Parse gate definitions: name = gate(inputs)
            # Support: AND, OR, NAND, NOR, NOT, BUF, XOR, XNOR, DFF
            match = re.match(r'(\w+)\s*=\s*(\w+)\s*\(\s*(.+)\s*\)', line, re.IGNORECASE)
            if match:
                output_name = match.group(1).strip()
                gate_type_str = match.group(2).strip().upper()
                inputs_str = match.group(3)
                input_names = [s.strip() for s in inputs_str.split(',')]
                
                # Map gate type
                gate_type_map = {
                    'AND': GateType.AND,
                    'OR': GateType.OR,
                    'NOT': GateType.NOT,
                    'NAND': GateType.NAND,
                    'NOR': GateType.NOR,
                    'XOR': GateType.XOR,
                    'XNOR': GateType.XNOR,
                    'BUF': GateType.BUF,
                    'BUFF': GateType.BUF,
                    'DFF': GateType.DFF,
                }
                
                if gate_type_str in gate_type_map:
                    gate_name = f"G{gate_count}"
                    gate_count += 1
                    
                    gtype = gate_type_map[gate_type_str]
                    
                    # Handle DFF - create scan cell for scan-based ATPG
                    if gtype == GateType.DFF:
                        circuit.has_scan = True
                        d_input = input_names[0] if input_names else None
                        
                        # Create scan cell record
                        scan_cell = ScanCell(
                            name=gate_name,
                            d_input=d_input,
                            q_output=output_name,
                            si_input=None,  # Will be connected later
                            se_signal="scan_en",
                            scan_order=len(circuit.scan_cells)
                        )
                        circuit.scan_cells.append(scan_cell)
                        
                        # For combinational ATPG model, treat DFF Q as primary input
                        # (controllable via scan load)
                        gtype = GateType.BUF
                        input_names = input_names[:1]
                        
                    circuit.add_gate(gate_name, gtype, input_names, output_name)
        
        # Build scan chain from DFFs (for ISCAS89 sequential circuits)
        if circuit.scan_cells:
            chain = ScanChain(name="chain_0")
            chain.scan_in = "scan_in"
            chain.scan_enable = "scan_en"
            # Connect scan cells in chain order
            for i, cell in enumerate(circuit.scan_cells):
                if i == 0:
                    cell.si_input = "scan_in"
                else:
                    cell.si_input = circuit.scan_cells[i-1].q_output
            # Last cell's Q is scan_out
            chain.scan_out = circuit.scan_cells[-1].q_output
            chain.cells = circuit.scan_cells
            circuit.scan_chains.append(chain)
                    
        circuit.levelize()
        return circuit


# =============================================================================
# Fault List Generator
# =============================================================================

class FaultGenerator:
    """Generate fault list for a circuit"""
    
    @staticmethod
    def generate_all_faults(circuit: Circuit, 
                           include_transition: bool = False) -> List[Fault]:
        """Generate all stuck-at faults (and optionally transition faults)"""
        faults = []
        
        for net_name in circuit.nets:
            # Stuck-at faults
            faults.append(Fault(net_name, 0, FaultType.STUCK_AT_0))
            faults.append(Fault(net_name, 1, FaultType.STUCK_AT_1))
            
            # Transition faults (for at-speed testing)
            if include_transition:
                faults.append(Fault(net_name, 0, FaultType.SLOW_TO_RISE))
                faults.append(Fault(net_name, 1, FaultType.SLOW_TO_FALL))
            
        return faults
    
    @staticmethod
    def collapse_faults(circuit: Circuit, faults: List[Fault]) -> List[Fault]:
        """Fault collapsing to reduce fault list
        
        使用等效故障折叠:
        - 门输入s-a-0等效于门输出s-a-0 (AND门)
        - 门输入s-a-1等效于门输出s-a-1 (OR门)
        - 等等...
        """
        collapsed = []
        seen = set()
        
        # 建立等效故障映射
        equiv_map: Dict[Tuple[str, int], str] = {}  # (net, sa) -> representative
        
        for gate in circuit.gate_list:
            if gate.gate_type == GateType.INPUT or not gate.output:
                continue
            
            out_name = gate.output.name
            
            # 根据门类型建立等效关系
            if gate.gate_type == GateType.AND:
                # 任意输入s-a-0等效于输出s-a-0
                for inp in gate.inputs:
                    equiv_map[(inp.name, 0)] = out_name
            elif gate.gate_type == GateType.OR:
                # 任意输入s-a-1等效于输出s-a-1
                for inp in gate.inputs:
                    equiv_map[(inp.name, 1)] = out_name
            elif gate.gate_type == GateType.NAND:
                # 任意输入s-a-0等效于输出s-a-1
                for inp in gate.inputs:
                    if (inp.name, 0) not in equiv_map:
                        equiv_map[(inp.name, 0)] = f"{out_name}_inv"
            elif gate.gate_type == GateType.NOR:
                # 任意输入s-a-1等效于输出s-a-0
                for inp in gate.inputs:
                    if (inp.name, 1) not in equiv_map:
                        equiv_map[(inp.name, 1)] = f"{out_name}_inv"
            elif gate.gate_type in [GateType.NOT, GateType.BUF]:
                # NOT/BUF输入输出关系
                inp_name = gate.inputs[0].name if gate.inputs else None
                if inp_name:
                    if gate.gate_type == GateType.NOT:
                        equiv_map[(inp_name, 0)] = f"{out_name}_1"
                        equiv_map[(inp_name, 1)] = f"{out_name}_0"
        
        # 应用折叠
        for fault in faults:
            key = (fault.net_name, fault.stuck_at, fault.fault_type)
            if key not in seen:
                seen.add(key)
                # 检查是否有等效故障
                equiv_key = (fault.net_name, fault.stuck_at)
                if equiv_key in equiv_map:
                    # 使用代表故障
                    repr_net = equiv_map[equiv_key]
                    repr_key = (repr_net, fault.stuck_at, fault.fault_type)
                    if repr_key not in seen:
                        seen.add(repr_key)
                        collapsed.append(fault)
                else:
                    collapsed.append(fault)
                
        return collapsed
    
    @staticmethod
    def generate_checkpoint_faults(circuit: Circuit) -> List[Fault]:
        """只在检查点(PI, fanout点, PO)生成故障
        
        进一步减少故障数量
        """
        faults = []
        checkpoints = set()
        
        # PI是检查点
        checkpoints.update(circuit.inputs)
        
        # PO是检查点
        checkpoints.update(circuit.outputs)
        
        # 扇出点是检查点
        for net_name, net in circuit.nets.items():
            if len(net.loads) > 1:
                checkpoints.add(net_name)
        
        # 只在检查点生成故障
        for net_name in checkpoints:
            faults.append(Fault(net_name, 0, FaultType.STUCK_AT_0))
            faults.append(Fault(net_name, 1, FaultType.STUCK_AT_1))
        
        return faults


# =============================================================================
# ATPG Engine (D-Algorithm based)
# =============================================================================

class ATPGEngine:
    """Test pattern generation using D-algorithm with random fallback"""
    
    def __init__(self, circuit: Circuit):
        self.circuit = circuit
        self.backtracks = 0
        self.max_backtracks = 1000
        
    def generate_test(self, fault: Fault) -> Optional[Dict[str, int]]:
        """Generate test pattern for a single fault"""
        self.circuit.reset_values()
        self.backtracks = 0
        
        # Step 1: Fault activation
        if not self._activate_fault(fault):
            return None
            
        # Step 2: Fault propagation (D-frontier)
        if not self._propagate_fault(fault):
            # Fallback: try random patterns
            return self._random_test(fault)
            
        # Step 3: Justify (backward implication)
        if not self._justify():
            return self._random_test(fault)
            
        # Extract test pattern
        pattern = {}
        for inp_name in self.circuit.inputs:
            if inp_name in self.circuit.nets:
                val = self.circuit.nets[inp_name].value
                if val == Logic.ZERO:
                    pattern[inp_name] = 0
                elif val == Logic.ONE:
                    pattern[inp_name] = 1
                else:
                    pattern[inp_name] = 0  # Default unassigned to 0
                    
        return pattern
    
    def _random_test(self, fault: Fault, max_attempts: int = 16) -> Optional[Dict[str, int]]:
        """Try random patterns to detect fault"""
        import random
        
        for _ in range(max_attempts):
            # Generate random pattern
            pattern = {inp: random.randint(0, 1) for inp in self.circuit.inputs}
            
            # Quick check: good circuit simulation
            self.circuit.reset_values()
            for name, value in pattern.items():
                self.circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
            self.circuit.simulate()
            
            good_outputs = {name: self.circuit.nets[name].value 
                           for name in self.circuit.outputs if name in self.circuit.nets}
            
            # Simulate with fault - optimized inline
            self.circuit.reset_values()
            for name, value in pattern.items():
                self.circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
            
            fault_value = Logic.ONE if fault.stuck_at == 1 else Logic.ZERO
            fault_net = fault.net_name
            
            # Inject and simulate with fault
            if fault_net in self.circuit.inputs:
                self.circuit.nets[fault_net].value = fault_value
                
            for gate in self.circuit.gate_list:
                if gate.output:
                    gate.output.value = gate.evaluate()
                    if gate.output.name == fault_net:
                        gate.output.value = fault_value
                if fault_net in self.circuit.nets:
                    self.circuit.nets[fault_net].value = fault_value
            
            # Compare outputs
            for out_name in self.circuit.outputs:
                if out_name in self.circuit.nets:
                    faulty_val = self.circuit.nets[out_name].value
                    good_val = good_outputs.get(out_name, Logic.X)
                    
                    if faulty_val != good_val and faulty_val != Logic.X and good_val != Logic.X:
                        return pattern
                        
        return None
    
    def _activate_fault(self, fault: Fault) -> bool:
        """Activate the fault site"""
        if fault.net_name not in self.circuit.nets:
            return False
            
        net = self.circuit.nets[fault.net_name]
        
        # Set fault effect: D for s-a-0 (good=1, faulty=0)
        #                   D' for s-a-1 (good=0, faulty=1)
        if fault.stuck_at == 0:
            net.value = Logic.D  # Need 1 to detect s-a-0
        else:
            net.value = Logic.D_BAR  # Need 0 to detect s-a-1
            
        return True
    
    def _propagate_fault(self, fault: Fault) -> bool:
        """Propagate fault effect to primary output"""
        max_iterations = 100
        
        for _ in range(max_iterations):
            # Check if fault reached output
            for out_name in self.circuit.outputs:
                if out_name in self.circuit.nets:
                    val = self.circuit.nets[out_name].value
                    if val in [Logic.D, Logic.D_BAR]:
                        return True
                        
            # Find D-frontier (gates with D/D' on input but X on output)
            d_frontier = self._get_d_frontier()
            
            if not d_frontier:
                return False
                
            # Select a gate from D-frontier and propagate
            gate = d_frontier[0]
            if not self._propagate_through_gate(gate):
                return False
                
        return False
    
    def _get_d_frontier(self) -> List[Gate]:
        """Get gates in D-frontier"""
        frontier = []
        
        for gate in self.circuit.gate_list:
            if gate.output and gate.output.value == Logic.X:
                # Check if any input has D or D'
                has_d = any(inp.value in [Logic.D, Logic.D_BAR] for inp in gate.inputs)
                if has_d:
                    frontier.append(gate)
                    
        return frontier
    
    def _propagate_through_gate(self, gate: Gate) -> bool:
        """Set non-controlling values to propagate D through gate"""
        # Non-controlling values: AND/NAND -> 1, OR/NOR -> 0
        if gate.gate_type in [GateType.AND, GateType.NAND]:
            non_ctrl = Logic.ONE
        elif gate.gate_type in [GateType.OR, GateType.NOR]:
            non_ctrl = Logic.ZERO
        elif gate.gate_type in [GateType.XOR, GateType.XNOR]:
            # For XOR/XNOR, set other inputs to 0 to pass D through
            non_ctrl = Logic.ZERO
        else:
            non_ctrl = Logic.X
            
        # Set all non-D inputs to non-controlling value
        for inp in gate.inputs:
            if inp.value not in [Logic.D, Logic.D_BAR]:
                if inp.value == Logic.X:
                    inp.value = non_ctrl
                elif inp.value != non_ctrl and gate.gate_type not in [GateType.XOR, GateType.XNOR]:
                    return False  # Conflict (except for XOR which has different rules)
                    
        # Evaluate gate
        gate.output.value = gate.evaluate()
        return True
    
    def _justify(self) -> bool:
        """Backward justify: assign inputs to achieve required values"""
        max_iterations = 100
        
        for _ in range(max_iterations):
            # Find unjustified gates
            unjustified = self._get_unjustified_gates()
            
            if not unjustified:
                return True
                
            gate = unjustified[0]
            if not self._justify_gate(gate):
                self.backtracks += 1
                if self.backtracks > self.max_backtracks:
                    return False
                    
        return False
    
    def _get_unjustified_gates(self) -> List[Gate]:
        """Find gates whose output is set but inputs don't justify it"""
        unjustified = []
        
        for gate in self.circuit.gate_list:
            if gate.gate_type == GateType.INPUT:
                continue
                
            if gate.output and gate.output.value not in [Logic.X]:
                # Check if any input is X
                has_x = any(inp.value == Logic.X for inp in gate.inputs)
                if has_x:
                    unjustified.append(gate)
                    
        return unjustified
    
    def _justify_gate(self, gate: Gate) -> bool:
        """Justify a single gate"""
        target = gate.output.value
        
        if gate.gate_type in [GateType.NOT, GateType.BUF]:
            if gate.inputs[0].value == Logic.X:
                if gate.gate_type == GateType.NOT:
                    gate.inputs[0].value = logic_not(target)
                else:
                    gate.inputs[0].value = target
            return True
            
        # For AND: if output is 1, all inputs must be 1
        if gate.gate_type == GateType.AND:
            if target == Logic.ONE:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ONE
            elif target == Logic.ZERO:
                # Set first X input to 0
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ZERO
                        break
            return True
            
        # For OR: if output is 0, all inputs must be 0
        if gate.gate_type == GateType.OR:
            if target == Logic.ZERO:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ZERO
            elif target == Logic.ONE:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ONE
                        break
            return True
            
        # For NAND: if output is 0, all inputs must be 1
        if gate.gate_type == GateType.NAND:
            if target == Logic.ZERO:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ONE
            elif target == Logic.ONE:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ZERO
                        break
            return True
            
        # For NOR: if output is 1, all inputs must be 0
        if gate.gate_type == GateType.NOR:
            if target == Logic.ONE:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ZERO
            elif target == Logic.ZERO:
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        inp.value = Logic.ONE
                        break
            return True
            
        return True


# =============================================================================
# PODEM Algorithm - Path-Oriented Decision Making
# =============================================================================

class PODEMEngine:
    """PODEM (Path-Oriented Decision Making) ATPG算法
    
    优点:
    - 从PI向fault site backtrace,减少无效搜索
    - 目标导向的决策过程
    - 比D-Algorithm更高效
    """
    
    def __init__(self, circuit: Circuit):
        self.circuit = circuit
        self.backtracks = 0
        self.max_backtracks = 5000
        self.implication_stack: List[Tuple[str, Logic]] = []
        
        # 预计算每个net到PI的路径
        self._compute_controllability()
        
    def _compute_controllability(self):
        """计算可控性指标 (CC0, CC1)"""
        self.cc0: Dict[str, int] = {}  # 控制到0的难度
        self.cc1: Dict[str, int] = {}  # 控制到1的难度
        
        # PI的可控性最低
        for pi in self.circuit.inputs:
            self.cc0[pi] = 1
            self.cc1[pi] = 1
        
        # 按拓扑顺序计算
        for gate in self.circuit.gate_list:
            if gate.gate_type == GateType.INPUT or not gate.output:
                continue
                
            out_name = gate.output.name
            input_cc0 = [self.cc0.get(inp.name, 999) for inp in gate.inputs]
            input_cc1 = [self.cc1.get(inp.name, 999) for inp in gate.inputs]
            
            if gate.gate_type == GateType.NOT:
                self.cc0[out_name] = input_cc1[0] + 1
                self.cc1[out_name] = input_cc0[0] + 1
            elif gate.gate_type == GateType.BUF:
                self.cc0[out_name] = input_cc0[0] + 1
                self.cc1[out_name] = input_cc1[0] + 1
            elif gate.gate_type == GateType.AND:
                self.cc0[out_name] = min(input_cc0) + 1
                self.cc1[out_name] = sum(input_cc1) + 1
            elif gate.gate_type == GateType.OR:
                self.cc0[out_name] = sum(input_cc0) + 1
                self.cc1[out_name] = min(input_cc1) + 1
            elif gate.gate_type == GateType.NAND:
                self.cc0[out_name] = sum(input_cc1) + 1
                self.cc1[out_name] = min(input_cc0) + 1
            elif gate.gate_type == GateType.NOR:
                self.cc0[out_name] = min(input_cc1) + 1
                self.cc1[out_name] = sum(input_cc0) + 1
            elif gate.gate_type in [GateType.XOR, GateType.XNOR]:
                self.cc0[out_name] = min(input_cc0) + min(input_cc1) + 1
                self.cc1[out_name] = min(input_cc0) + min(input_cc1) + 1
            else:
                self.cc0[out_name] = 999
                self.cc1[out_name] = 999
    
    def generate_test(self, fault: Fault) -> Optional[Dict[str, int]]:
        """使用PODEM生成测试向量 (迭代版本)"""
        self.circuit.reset_values()
        self.backtracks = 0
        
        # 初始objective: 激活故障
        initial_obj = self._get_initial_objective(fault)
        if not initial_obj:
            return None
        
        # 使用迭代而非递归避免栈溢出
        result = self._podem_iterative(fault)
        
        if result:
            # 提取测试向量
            pattern = {}
            for inp_name in self.circuit.inputs:
                if inp_name in self.circuit.nets:
                    val = self.circuit.nets[inp_name].value
                    if val == Logic.ZERO:
                        pattern[inp_name] = 0
                    elif val == Logic.ONE:
                        pattern[inp_name] = 1
                    else:
                        pattern[inp_name] = random.randint(0, 1)
            return pattern
        
        fault.backtrack_count = self.backtracks
        return None
    
    def _podem_iterative(self, fault: Fault) -> bool:
        """PODEM迭代主过程 (避免递归栈溢出)"""
        # 决策栈: [(pi_name, current_value, tried_both)]
        decision_stack: List[Tuple[str, Logic, bool]] = []
        max_iterations = 50000
        
        for iteration in range(max_iterations):
            # 前向蕴含
            self._imply()
            
            # 检查是否已检测到故障
            if self._fault_detected_at_output(fault):
                return True
            
            # 检查是否已失败
            if self._test_impossible(fault):
                # 需要回溯
                if not self._backtrack(decision_stack):
                    return False
                continue
            
            # 获取objective
            objective = self._get_objective(fault)
            if not objective:
                # 无法获取objective,尝试回溯
                if not self._backtrack(decision_stack):
                    return False
                continue
            
            obj_net, obj_value = objective
            
            # Backtrace到PI
            pi, pi_value = self._backtrace(obj_net, obj_value)
            
            if pi is None:
                if not self._backtrack(decision_stack):
                    return False
                continue
            
            # 检查该PI是否已赋值
            current_val = self.circuit.nets[pi].value
            if current_val not in [Logic.X]:
                # PI已有值,检查是否冲突
                if current_val != pi_value:
                    if not self._backtrack(decision_stack):
                        return False
                continue
            
            # 设置PI值并记录决策
            self.circuit.nets[pi].value = pi_value
            decision_stack.append((pi, pi_value, False))
            
            if len(decision_stack) > 100:
                # 决策太深,可能是难以测试的故障
                return False
        
        return False
    
    def _backtrack(self, decision_stack: List[Tuple[str, Logic, bool]]) -> bool:
        """回溯到上一个未尝试完的决策点"""
        self.backtracks += 1
        
        if self.backtracks > self.max_backtracks:
            return False
        
        while decision_stack:
            pi, value, tried_both = decision_stack.pop()
            
            if not tried_both:
                # 尝试相反值
                alt_value = logic_not(value)
                self.circuit.nets[pi].value = alt_value
                decision_stack.append((pi, alt_value, True))
                
                # 重置后续PI的值
                # (不需要显式重置,因为simulate会重新计算)
                return True
            else:
                # 两个值都试过了,继续回溯
                self.circuit.nets[pi].value = Logic.X
        
        return False
    
    def _get_initial_objective(self, fault: Fault) -> Optional[Tuple[str, Logic]]:
        """获取初始objective: 激活故障"""
        if fault.net_name not in self.circuit.nets:
            return None
        
        # s-a-0需要设置为1来激活, s-a-1需要设置为0
        target_value = Logic.ONE if fault.stuck_at == 0 else Logic.ZERO
        return (fault.net_name, target_value)
    
    def _get_objective(self, fault: Fault) -> Optional[Tuple[str, Logic]]:
        """获取当前objective"""
        fault_net = self.circuit.nets.get(fault.net_name)
        if not fault_net:
            return None
        
        # 如果故障site还没激活
        if fault_net.value not in [Logic.D, Logic.D_BAR]:
            target = Logic.ONE if fault.stuck_at == 0 else Logic.ZERO
            return (fault.net_name, target)
        
        # 故障已激活,需要传播到输出
        # 找D-frontier
        d_frontier = self._get_d_frontier()
        if not d_frontier:
            return None
        
        # 选择最容易传播的门
        gate = d_frontier[0]
        
        # 选择非D输入,设置为非控制值
        for inp in gate.inputs:
            if inp.value == Logic.X:
                if gate.gate_type in [GateType.AND, GateType.NAND]:
                    return (inp.name, Logic.ONE)
                elif gate.gate_type in [GateType.OR, GateType.NOR]:
                    return (inp.name, Logic.ZERO)
                elif gate.gate_type in [GateType.XOR, GateType.XNOR]:
                    return (inp.name, Logic.ZERO)
        
        return None
    
    def _backtrace(self, net_name: str, target_value: Logic) -> Tuple[Optional[str], Optional[Logic]]:
        """从objective回溯到PI"""
        current_net = net_name
        current_value = target_value
        
        while current_net not in self.circuit.inputs:
            net = self.circuit.nets.get(current_net)
            if not net or not net.driver:
                return (None, None)
            
            gate = net.driver
            if gate.gate_type == GateType.INPUT:
                break
            
            # 根据门类型和目标值选择输入
            if gate.gate_type == GateType.NOT:
                current_net = gate.inputs[0].name
                current_value = logic_not(current_value)
            elif gate.gate_type == GateType.BUF:
                current_net = gate.inputs[0].name
            elif gate.gate_type in [GateType.AND, GateType.NAND]:
                # 选择可控性最好的输入
                if current_value == Logic.ZERO:
                    # AND输出0只需一个输入为0
                    best_inp = min(gate.inputs, 
                                   key=lambda i: self.cc0.get(i.name, 999) if i.value == Logic.X else 999)
                    current_net = best_inp.name
                    current_value = Logic.ZERO if gate.gate_type == GateType.AND else Logic.ONE
                else:
                    # AND输出1需要所有输入为1,选择未设置的
                    for inp in gate.inputs:
                        if inp.value == Logic.X:
                            current_net = inp.name
                            current_value = Logic.ONE if gate.gate_type == GateType.AND else Logic.ZERO
                            break
            elif gate.gate_type in [GateType.OR, GateType.NOR]:
                if current_value == Logic.ONE:
                    best_inp = min(gate.inputs,
                                   key=lambda i: self.cc1.get(i.name, 999) if i.value == Logic.X else 999)
                    current_net = best_inp.name
                    current_value = Logic.ONE if gate.gate_type == GateType.OR else Logic.ZERO
                else:
                    for inp in gate.inputs:
                        if inp.value == Logic.X:
                            current_net = inp.name
                            current_value = Logic.ZERO if gate.gate_type == GateType.OR else Logic.ONE
                            break
            else:
                # XOR等复杂门
                for inp in gate.inputs:
                    if inp.value == Logic.X:
                        current_net = inp.name
                        break
        
        return (current_net, current_value)
    
    def _imply(self):
        """前向蕴含"""
        self.circuit.simulate()
    
    def _fault_detected_at_output(self, fault: Fault) -> bool:
        """检查故障是否在输出检测到"""
        for out_name in self.circuit.outputs:
            if out_name in self.circuit.nets:
                val = self.circuit.nets[out_name].value
                if val in [Logic.D, Logic.D_BAR]:
                    return True
        return False
    
    def _test_impossible(self, fault: Fault) -> bool:
        """检查测试是否不可能"""
        fault_net = self.circuit.nets.get(fault.net_name)
        if not fault_net:
            return True
        
        # 如果故障site值与所需相反,则不可能
        if fault.stuck_at == 0 and fault_net.value == Logic.ZERO:
            return True
        if fault.stuck_at == 1 and fault_net.value == Logic.ONE:
            return True
        
        # 如果有D/D'但D-frontier为空且未到达输出
        if fault_net.value in [Logic.D, Logic.D_BAR]:
            if not self._get_d_frontier() and not self._fault_detected_at_output(fault):
                return True
        
        return False
    
    def _get_d_frontier(self) -> List[Gate]:
        """获取D-frontier"""
        frontier = []
        for gate in self.circuit.gate_list:
            if gate.output and gate.output.value == Logic.X:
                has_d = any(inp.value in [Logic.D, Logic.D_BAR] for inp in gate.inputs)
                if has_d:
                    frontier.append(gate)
        return frontier


# =============================================================================
# FAN Algorithm - Fanout-Oriented Test Generation
# =============================================================================

class FANEngine:
    """FAN (Fanout-oriented) ATPG算法
    
    特点:
    - 多路回溯 (Multiple Backtrace)
    - 头线/边界线分析
    - 唯一敏化路径识别
    - 比PODEM更高效处理扇出
    """
    
    def __init__(self, circuit: Circuit):
        self.circuit = circuit
        self.backtracks = 0
        self.max_backtracks = 10000
        
        # 计算fanout信息
        self._analyze_fanout()
        self._compute_scoap()
        
    def _analyze_fanout(self):
        """分析扇出结构"""
        self.fanout_points: Set[str] = set()  # 扇出点
        self.head_lines: Set[str] = set()     # 头线
        self.bound_lines: Set[str] = set()    # 边界线
        
        # 找扇出点
        for net_name, net in self.circuit.nets.items():
            if len(net.loads) > 1:
                self.fanout_points.add(net_name)
        
        # 计算头线和边界线
        for net_name in self.fanout_points:
            self._find_bound_lines(net_name)
    
    def _find_bound_lines(self, fanout_net: str):
        """找到从扇出点开始的边界线"""
        visited = set()
        queue = [fanout_net]
        
        while queue:
            current = queue.pop(0)
            if current in visited:
                continue
            visited.add(current)
            
            net = self.circuit.nets.get(current)
            if not net:
                continue
            
            # 如果到达另一个扇出点或PI,这是边界线
            if current != fanout_net and (current in self.fanout_points or current in self.circuit.inputs):
                self.bound_lines.add(current)
                continue
            
            # 继续追踪到驱动该net的门的输入
            if net.driver and net.driver.gate_type != GateType.INPUT:
                for inp in net.driver.inputs:
                    queue.append(inp.name)
    
    def _compute_scoap(self):
        """计算SCOAP可测性指标"""
        # CC0, CC1 (可控性)
        self.cc0: Dict[str, int] = {}
        self.cc1: Dict[str, int] = {}
        
        # CO (可观测性)
        self.co: Dict[str, int] = {}
        
        # 初始化PI
        for pi in self.circuit.inputs:
            self.cc0[pi] = 1
            self.cc1[pi] = 1
        
        # 前向计算可控性
        for gate in self.circuit.gate_list:
            if gate.gate_type == GateType.INPUT or not gate.output:
                continue
            
            out_name = gate.output.name
            inp_cc0 = [self.cc0.get(i.name, 999) for i in gate.inputs]
            inp_cc1 = [self.cc1.get(i.name, 999) for i in gate.inputs]
            
            if gate.gate_type == GateType.NOT:
                self.cc0[out_name] = inp_cc1[0] + 1
                self.cc1[out_name] = inp_cc0[0] + 1
            elif gate.gate_type == GateType.BUF:
                self.cc0[out_name] = inp_cc0[0] + 1
                self.cc1[out_name] = inp_cc1[0] + 1
            elif gate.gate_type == GateType.AND:
                self.cc0[out_name] = min(inp_cc0) + 1
                self.cc1[out_name] = sum(inp_cc1) + 1
            elif gate.gate_type == GateType.OR:
                self.cc0[out_name] = sum(inp_cc0) + 1
                self.cc1[out_name] = min(inp_cc1) + 1
            elif gate.gate_type == GateType.NAND:
                self.cc0[out_name] = sum(inp_cc1) + 1
                self.cc1[out_name] = min(inp_cc0) + 1
            elif gate.gate_type == GateType.NOR:
                self.cc0[out_name] = min(inp_cc1) + 1
                self.cc1[out_name] = sum(inp_cc0) + 1
            else:
                self.cc0[out_name] = min(min(inp_cc0), min(inp_cc1)) + 1
                self.cc1[out_name] = min(min(inp_cc0), min(inp_cc1)) + 1
        
        # 初始化PO可观测性
        for po in self.circuit.outputs:
            self.co[po] = 0
        
        # 后向计算可观测性
        for gate in reversed(self.circuit.gate_list):
            if not gate.output:
                continue
            
            out_co = self.co.get(gate.output.name, 999)
            
            for i, inp in enumerate(gate.inputs):
                other_cc = 0
                if gate.gate_type in [GateType.AND, GateType.NAND]:
                    # 需要其他输入为1
                    for j, other in enumerate(gate.inputs):
                        if j != i:
                            other_cc += self.cc1.get(other.name, 0)
                elif gate.gate_type in [GateType.OR, GateType.NOR]:
                    # 需要其他输入为0
                    for j, other in enumerate(gate.inputs):
                        if j != i:
                            other_cc += self.cc0.get(other.name, 0)
                
                inp_co = out_co + other_cc + 1
                if inp.name not in self.co or inp_co < self.co[inp.name]:
                    self.co[inp.name] = inp_co
    
    def generate_test(self, fault: Fault) -> Optional[Dict[str, int]]:
        """使用FAN算法生成测试向量"""
        self.circuit.reset_values()
        self.backtracks = 0
        
        # 激活故障
        if not self._activate_fault(fault):
            return None
        
        # FAN主循环
        result = self._fan_main(fault)
        
        if result:
            pattern = {}
            for inp_name in self.circuit.inputs:
                if inp_name in self.circuit.nets:
                    val = self.circuit.nets[inp_name].value
                    if val == Logic.ZERO:
                        pattern[inp_name] = 0
                    elif val == Logic.ONE:
                        pattern[inp_name] = 1
                    else:
                        pattern[inp_name] = random.randint(0, 1)
            return pattern
        
        fault.backtrack_count = self.backtracks
        return None
    
    def _activate_fault(self, fault: Fault) -> bool:
        """激活故障"""
        if fault.net_name not in self.circuit.nets:
            return False
        
        net = self.circuit.nets[fault.net_name]
        net.value = Logic.D if fault.stuck_at == 0 else Logic.D_BAR
        return True
    
    def _fan_main(self, fault: Fault) -> bool:
        """FAN主算法 (迭代版本)"""
        # 决策栈: [(net_name, current_value, tried_both)]
        decision_stack: List[Tuple[str, Logic, bool]] = []
        max_iterations = 10000
        
        for iteration in range(max_iterations):
            # 蕴含
            self._imply()
            
            # 检查是否成功
            if self._fault_at_output():
                return True
            
            # 检查是否失败
            if self._test_impossible(fault):
                # 回溯
                if not self._fan_backtrack(decision_stack):
                    return False
                continue
            
            # 多路回溯获取objectives
            objectives = self._multiple_backtrace(fault)
            
            if not objectives:
                if not self._fan_backtrack(decision_stack):
                    return False
                continue
            
            # 选择最佳objective并尝试
            best_obj = self._select_best_objective(objectives)
            
            if best_obj:
                net_name, value = best_obj
                
                # 检查是否已赋值
                current_val = self.circuit.nets[net_name].value
                if current_val not in [Logic.X]:
                    if current_val != value:
                        if not self._fan_backtrack(decision_stack):
                            return False
                    continue
                
                # 设置值并记录决策
                self.circuit.nets[net_name].value = value
                decision_stack.append((net_name, value, False))
                
                if len(decision_stack) > 100:
                    return False
            else:
                if not self._fan_backtrack(decision_stack):
                    return False
        
        return False
    
    def _fan_backtrack(self, decision_stack: List[Tuple[str, Logic, bool]]) -> bool:
        """FAN回溯"""
        self.backtracks += 1
        
        if self.backtracks > self.max_backtracks:
            return False
        
        while decision_stack:
            net_name, value, tried_both = decision_stack.pop()
            
            if not tried_both:
                alt_value = logic_not(value)
                self.circuit.nets[net_name].value = alt_value
                decision_stack.append((net_name, alt_value, True))
                return True
            else:
                self.circuit.nets[net_name].value = Logic.X
        
        return False
    
    def _multiple_backtrace(self, fault: Fault) -> List[Tuple[str, Logic]]:
        """多路回溯"""
        objectives = []
        
        # 故障激活objective
        fault_net = self.circuit.nets.get(fault.net_name)
        if fault_net and fault_net.value not in [Logic.D, Logic.D_BAR]:
            target = Logic.ONE if fault.stuck_at == 0 else Logic.ZERO
            objectives.extend(self._backtrace_to_bound(fault.net_name, target))
        
        # 故障传播objectives
        d_frontier = self._get_d_frontier()
        for gate in d_frontier:
            for inp in gate.inputs:
                if inp.value == Logic.X:
                    if gate.gate_type in [GateType.AND, GateType.NAND]:
                        objectives.extend(self._backtrace_to_bound(inp.name, Logic.ONE))
                    elif gate.gate_type in [GateType.OR, GateType.NOR]:
                        objectives.extend(self._backtrace_to_bound(inp.name, Logic.ZERO))
                    else:
                        objectives.extend(self._backtrace_to_bound(inp.name, Logic.ZERO))
        
        return objectives
    
    def _backtrace_to_bound(self, net_name: str, target: Logic) -> List[Tuple[str, Logic]]:
        """回溯到边界线或PI"""
        result = []
        current = net_name
        value = target
        
        while current not in self.circuit.inputs:
            # 如果是边界线,返回
            if current in self.bound_lines:
                result.append((current, value))
                return result
            
            net = self.circuit.nets.get(current)
            if not net or not net.driver or net.driver.gate_type == GateType.INPUT:
                break
            
            gate = net.driver
            
            # 根据门类型回溯
            if gate.gate_type == GateType.NOT:
                current = gate.inputs[0].name
                value = logic_not(value)
            elif gate.gate_type == GateType.BUF:
                current = gate.inputs[0].name
            elif gate.gate_type in [GateType.AND, GateType.NAND]:
                # 选择可控性最好的
                best = min(gate.inputs, 
                          key=lambda i: (self.cc0 if value == Logic.ZERO else self.cc1).get(i.name, 999))
                current = best.name
                if gate.gate_type == GateType.NAND:
                    value = logic_not(value)
            elif gate.gate_type in [GateType.OR, GateType.NOR]:
                best = min(gate.inputs,
                          key=lambda i: (self.cc1 if value == Logic.ONE else self.cc0).get(i.name, 999))
                current = best.name
                if gate.gate_type == GateType.NOR:
                    value = logic_not(value)
            else:
                current = gate.inputs[0].name if gate.inputs else current
        
        if current in self.circuit.inputs:
            result.append((current, value))
        
        return result
    
    def _select_best_objective(self, objectives: List[Tuple[str, Logic]]) -> Optional[Tuple[str, Logic]]:
        """选择最佳objective"""
        if not objectives:
            return None
        
        # 优先选择PI
        pi_objectives = [(n, v) for n, v in objectives if n in self.circuit.inputs]
        if pi_objectives:
            return min(pi_objectives, 
                      key=lambda x: (self.cc0 if x[1] == Logic.ZERO else self.cc1).get(x[0], 999))
        
        # 选择可控性最好的
        return min(objectives,
                   key=lambda x: (self.cc0 if x[1] == Logic.ZERO else self.cc1).get(x[0], 999))
    
    def _imply(self):
        """前向蕴含"""
        self.circuit.simulate()
    
    def _fault_at_output(self) -> bool:
        """检查故障是否到达输出"""
        for out_name in self.circuit.outputs:
            if out_name in self.circuit.nets:
                if self.circuit.nets[out_name].value in [Logic.D, Logic.D_BAR]:
                    return True
        return False
    
    def _test_impossible(self, fault: Fault) -> bool:
        """检查测试是否不可能"""
        fault_net = self.circuit.nets.get(fault.net_name)
        if not fault_net:
            return True
        
        if fault.stuck_at == 0 and fault_net.value == Logic.ZERO:
            return True
        if fault.stuck_at == 1 and fault_net.value == Logic.ONE:
            return True
        
        if fault_net.value in [Logic.D, Logic.D_BAR]:
            if not self._get_d_frontier() and not self._fault_at_output():
                return True
        
        return False
    
    def _get_d_frontier(self) -> List[Gate]:
        """获取D-frontier"""
        frontier = []
        for gate in self.circuit.gate_list:
            if gate.output and gate.output.value == Logic.X:
                if any(inp.value in [Logic.D, Logic.D_BAR] for inp in gate.inputs):
                    frontier.append(gate)
        return frontier


# =============================================================================
# Parallel Fault Simulator (Bit-Parallel)
# =============================================================================

class ParallelFaultSimulator:
    """位并行故障模拟器
    
    使用64位整数并行模拟多个故障,显著提高效率
    """
    
    WORD_SIZE = 64  # 每次并行模拟64个故障
    
    def __init__(self, circuit: Circuit):
        self.circuit = circuit
        self.gate_list = circuit.gate_list
        
        # 预分配仿真数组
        self._init_simulation_arrays()
    
    def _init_simulation_arrays(self):
        """初始化仿真数组"""
        self.net_values: Dict[str, int] = {}  # 64位并行值
        for net_name in self.circuit.nets:
            self.net_values[net_name] = 0
    
    def simulate_batch(self, pattern: Dict[str, int], 
                       faults: List[Fault]) -> List[Fault]:
        """批量仿真一组故障"""
        if not faults:
            return []
        
        detected = []
        
        # 分批处理
        for batch_start in range(0, len(faults), self.WORD_SIZE):
            batch_end = min(batch_start + self.WORD_SIZE, len(faults))
            batch = faults[batch_start:batch_end]
            
            detected.extend(self._simulate_batch_internal(pattern, batch))
        
        return detected
    
    def _simulate_batch_internal(self, pattern: Dict[str, int], 
                                  batch: List[Fault]) -> List[Fault]:
        """内部批量仿真"""
        detected = []
        num_faults = len(batch)
        
        # 初始化: 所有位设为good circuit值
        for net_name, value in self.net_values.items():
            self.net_values[net_name] = 0
        
        # 设置PI值 (所有64位相同)
        for inp_name, value in pattern.items():
            if inp_name in self.net_values:
                self.net_values[inp_name] = (2**64 - 1) if value else 0
        
        # 注入故障 (每个故障占一位)
        fault_masks: Dict[str, Tuple[int, int]] = {}  # net -> (mask, value)
        for i, fault in enumerate(batch):
            bit_mask = 1 << i
            if fault.net_name in self.net_values:
                if fault.net_name not in fault_masks:
                    fault_masks[fault.net_name] = (0, 0)
                mask, val = fault_masks[fault.net_name]
                mask |= bit_mask
                if fault.stuck_at == 1:
                    val |= bit_mask
                fault_masks[fault.net_name] = (mask, val)
        
        # 应用故障到PI
        for net_name, (mask, val) in fault_masks.items():
            if net_name in self.circuit.inputs:
                current = self.net_values[net_name]
                self.net_values[net_name] = (current & ~mask) | val
        
        # 模拟
        for gate in self.gate_list:
            if gate.gate_type == GateType.INPUT or not gate.output:
                continue
            
            out_name = gate.output.name
            
            # 计算输出
            if gate.gate_type == GateType.NOT:
                self.net_values[out_name] = ~self.net_values[gate.inputs[0].name] & ((1 << 64) - 1)
            elif gate.gate_type == GateType.BUF:
                self.net_values[out_name] = self.net_values[gate.inputs[0].name]
            elif gate.gate_type == GateType.AND:
                result = (1 << 64) - 1
                for inp in gate.inputs:
                    result &= self.net_values[inp.name]
                self.net_values[out_name] = result
            elif gate.gate_type == GateType.OR:
                result = 0
                for inp in gate.inputs:
                    result |= self.net_values[inp.name]
                self.net_values[out_name] = result
            elif gate.gate_type == GateType.NAND:
                result = (1 << 64) - 1
                for inp in gate.inputs:
                    result &= self.net_values[inp.name]
                self.net_values[out_name] = ~result & ((1 << 64) - 1)
            elif gate.gate_type == GateType.NOR:
                result = 0
                for inp in gate.inputs:
                    result |= self.net_values[inp.name]
                self.net_values[out_name] = ~result & ((1 << 64) - 1)
            elif gate.gate_type == GateType.XOR:
                result = 0
                for inp in gate.inputs:
                    result ^= self.net_values[inp.name]
                self.net_values[out_name] = result
            elif gate.gate_type == GateType.XNOR:
                result = 0
                for inp in gate.inputs:
                    result ^= self.net_values[inp.name]
                self.net_values[out_name] = ~result & ((1 << 64) - 1)
            
            # 应用内部故障
            if out_name in fault_masks:
                mask, val = fault_masks[out_name]
                current = self.net_values[out_name]
                self.net_values[out_name] = (current & ~mask) | val
        
        # 检查输出差异
        good_mask = 1 << num_faults  # good circuit用第num_faults位
        
        for out_name in self.circuit.outputs:
            if out_name not in self.net_values:
                continue
            
            out_val = self.net_values[out_name]
            good_val = (out_val >> num_faults) & 1  # 假设good circuit是最后一位
            
            for i, fault in enumerate(batch):
                if fault.detected:
                    continue
                
                fault_val = (out_val >> i) & 1
                
                # 比较good和faulty
                # 简化: 用第一位作为参考
                ref_val = (pattern.get(out_name, 0)) if out_name in pattern else ((out_val >> (num_faults)) & 1)
                
                if fault_val != ref_val:
                    fault.mark_detected(pattern)
                    detected.append(fault)
        
        return detected


# =============================================================================
# Transition Fault ATPG
# =============================================================================

class TransitionATPG:
    """跳变故障ATPG (At-Speed Testing)
    
    支持:
    - LOC (Launch-on-Capture): V1设置状态,V2功能模式启动
    - LOS (Launch-on-Shift): V1 shift最后一位启动
    - STR (Slow-to-Rise): 0->1跳变太慢
    - STF (Slow-to-Fall): 1->0跳变太慢
    """
    
    def __init__(self, circuit: Circuit, mode: str = "LOC"):
        self.circuit = circuit
        self.mode = mode  # "LOC" or "LOS"
        self.engine = PODEMEngine(circuit)
        
    def generate_transition_faults(self) -> List[Fault]:
        """生成跳变故障列表"""
        faults = []
        for net_name in self.circuit.nets:
            # Slow-to-Rise (STR): 需要0->1跳变
            faults.append(Fault(net_name, 0, FaultType.SLOW_TO_RISE))
            # Slow-to-Fall (STF): 需要1->0跳变  
            faults.append(Fault(net_name, 1, FaultType.SLOW_TO_FALL))
        return faults
    
    def generate_test(self, fault: Fault) -> Optional[Tuple[Dict[str, int], Dict[str, int]]]:
        """生成跳变故障测试向量对 (V1, V2)
        
        Returns:
            (V1, V2) - V1初始化状态, V2启动跳变并捕获
        """
        if fault.fault_type == FaultType.SLOW_TO_RISE:
            # V1需要在fault site设置0
            # V2需要在fault site产生0->1跳变
            init_value = 0
            launch_value = 1
        else:  # SLOW_TO_FALL
            init_value = 1
            launch_value = 0
        
        # 生成V1: 初始化向量
        v1 = self._generate_init_vector(fault, init_value)
        if not v1:
            return None
        
        # 生成V2: 启动向量 + 传播路径
        v2 = self._generate_launch_vector(fault, launch_value)
        if not v2:
            return None
        
        return (v1, v2)
    
    def _generate_init_vector(self, fault: Fault, target_value: int) -> Optional[Dict[str, int]]:
        """生成初始化向量 V1"""
        # 创建一个临时stuck-at故障来生成V1
        temp_fault = Fault(fault.net_name, 1 - target_value)  # 需要设置为target_value
        pattern = self.engine.generate_test(temp_fault)
        return pattern
    
    def _generate_launch_vector(self, fault: Fault, target_value: int) -> Optional[Dict[str, int]]:
        """生成启动向量 V2"""
        # V2需要:
        # 1. 在fault site产生跳变
        # 2. 敏化从fault site到PO的路径
        
        # 使用PODEM生成传播路径
        stuck_fault = Fault(fault.net_name, 1 - target_value)  # 等效stuck-at
        pattern = self.engine.generate_test(stuck_fault)
        return pattern


# =============================================================================
# Enhanced ATPG Engine with Multiple Algorithms
# =============================================================================

class EnhancedATPGEngine:
    """增强ATPG引擎 - 组合多种算法
    
    策略:
    1. 先用D-algorithm (最稳定)
    2. D-alg失败时用PODEM
    3. 都失败时标记为难测故障
    4. 超过回溯限制标记为冗余
    """
    
    REDUNDANT_BACKTRACK_LIMIT = 5000
    
    def __init__(self, circuit: Circuit, algorithm: str = "auto"):
        self.circuit = circuit
        self.algorithm = algorithm
        
        # 初始化各算法引擎 (设置较低的回溯限制以加速)
        self.d_alg = ATPGEngine(circuit)
        self.d_alg.max_backtracks = 500
        
        self.podem = PODEMEngine(circuit)
        self.podem.max_backtracks = 1000
        
        self.fan = FANEngine(circuit)
        self.fan.max_backtracks = 1000
        
        # 统计
        self.stats = {
            'podem_success': 0,
            'fan_success': 0,
            'd_alg_success': 0,
            'random_success': 0,
            'total_backtracks': 0,
            'redundant_faults': 0
        }
    
    def generate_test(self, fault: Fault) -> Optional[Dict[str, int]]:
        """生成测试向量 - 优先使用快速算法"""
        pattern = None
        
        # 先用D-algorithm (最稳定快速)
        if self.algorithm in ["auto", "d-algorithm"]:
            pattern = self.d_alg.generate_test(fault)
            if pattern:
                self.stats['d_alg_success'] += 1
                return pattern
            self.stats['total_backtracks'] += self.d_alg.backtracks
        
        # D-alg失败,尝试PODEM
        if self.algorithm in ["auto", "podem"] and not pattern:
            pattern = self.podem.generate_test(fault)
            if pattern:
                self.stats['podem_success'] += 1
                return pattern
            self.stats['total_backtracks'] += self.podem.backtracks
        
        # PODEM也失败,尝试FAN (仅当明确指定时)
        if self.algorithm == "fan" and not pattern:
            pattern = self.fan.generate_test(fault)
            if pattern:
                self.stats['fan_success'] += 1
                return pattern
            self.stats['total_backtracks'] += self.fan.backtracks
        
        # 检查是否应标记为冗余
        total_bt = fault.backtrack_count
        if total_bt > self.REDUNDANT_BACKTRACK_LIMIT:
            fault.mark_redundant()
            self.stats['redundant_faults'] += 1
        
        return None
    
    def print_stats(self):
        """打印统计信息"""
        print("\nATPG Algorithm Statistics:")
        print(f"  PODEM success: {self.stats['podem_success']}")
        print(f"  FAN success: {self.stats['fan_success']}")
        print(f"  D-Algorithm success: {self.stats['d_alg_success']}")
        print(f"  Random success: {self.stats['random_success']}")
        print(f"  Total backtracks: {self.stats['total_backtracks']}")
        print(f"  Redundant faults identified: {self.stats['redundant_faults']}")


# =============================================================================
# Scan-based ATPG 
# =============================================================================

@dataclass
class ScanPattern:
    """Represents a scan test pattern"""
    scan_in_values: List[int]       # Values to shift into scan chain
    pi_values: Dict[str, int]       # Primary input values during capture
    expected_po: Dict[str, int]     # Expected primary output values
    expected_scan_out: List[int]    # Expected values to shift out
    
    def __str__(self):
        si = ''.join(str(v) for v in self.scan_in_values)
        return f"SI={si}, PI={self.pi_values}"


class ScanATPG:
    """Scan-based ATPG for sequential circuits"""
    
    def __init__(self, circuit: Circuit):
        self.circuit = circuit
        self.scan_patterns: List[ScanPattern] = []
        self.faults: List[Fault] = []
        
        # Validate scan chain
        if not circuit.has_scan or not circuit.scan_chains:
            raise ValueError("Circuit does not have scan chain defined")
            
        self.scan_chain = circuit.scan_chains[0]
        self.scan_length = self.scan_chain.get_length()
        
        # Identify pseudo-PIs and pseudo-POs
        self.pseudo_pi = []  # Scan cell Q outputs (controllable via scan)
        self.pseudo_po = []  # Scan cell D inputs (observable via scan)
        
        for cell in circuit.scan_cells:
            self.pseudo_pi.append(cell.q_output)
            self.pseudo_po.append(cell.d_input)
            
        # Real PIs (excluding scan control signals)
        scan_signals = {self.scan_chain.scan_in, self.scan_chain.scan_enable}
        self.real_pi = [pi for pi in circuit.inputs if pi not in scan_signals]
        
    def _create_combinational_model(self) -> Circuit:
        """Create combinational equivalent for scan ATPG
        
        In scan mode:
        - Scan cell Q outputs become pseudo-PIs (controlled via scan load)
        - Scan cell D inputs become pseudo-POs (observed via scan unload)
        - Original combinational logic remains unchanged
        """
        comb_circuit = Circuit()
        comb_circuit.name = f"{self.circuit.name}_comb"
        
        # Add real PIs
        for pi in self.real_pi:
            comb_circuit.inputs.append(pi)
            comb_circuit.add_net(pi)
            gate = Gate(f"_INPUT_{pi}", GateType.INPUT)
            gate.output = comb_circuit.nets[pi]
            comb_circuit.nets[pi].driver = gate
            gate.level = 0
            comb_circuit.gates[gate.name] = gate
            
        # Add pseudo-PIs (scan cell outputs)
        for ppi in self.pseudo_pi:
            comb_circuit.inputs.append(ppi)
            comb_circuit.add_net(ppi)
            gate = Gate(f"_INPUT_{ppi}", GateType.INPUT)
            gate.output = comb_circuit.nets[ppi]
            comb_circuit.nets[ppi].driver = gate
            gate.level = 0
            comb_circuit.gates[gate.name] = gate
            
        # Add real POs
        for po in self.circuit.outputs:
            if po not in [self.scan_chain.scan_out]:
                comb_circuit.outputs.append(po)
                
        # Add pseudo-POs (scan cell D inputs)
        for ppo in self.pseudo_po:
            if ppo not in comb_circuit.outputs:
                comb_circuit.outputs.append(ppo)
        
        # Copy combinational gates (excluding scan DFFs which are now PIs)
        for gate_name, gate in self.circuit.gates.items():
            if gate.gate_type == GateType.INPUT:
                continue
            # Skip gates that drive scan cell outputs (they're now PIs)
            if gate.output and gate.output.name in self.pseudo_pi:
                continue
                
            # Copy the gate
            if gate.output:
                input_names = [inp.name for inp in gate.inputs]
                comb_circuit.add_gate(
                    gate_name, 
                    gate.gate_type,
                    input_names,
                    gate.output.name
                )
                
        comb_circuit.levelize()
        return comb_circuit
    
    def generate_faults(self):
        """Generate faults for the combinational model"""
        # Generate faults on all nets except scan control signals
        scan_signals = {self.scan_chain.scan_in, self.scan_chain.scan_enable}
        
        for net_name in self.circuit.nets:
            if net_name not in scan_signals:
                self.faults.append(Fault(net_name, 0))
                self.faults.append(Fault(net_name, 1))
                
        print(f"Generated {len(self.faults)} faults for scan ATPG")
        
    def run(self, max_patterns: int = 200, target_coverage: float = 95.0):
        """Run scan-based ATPG"""
        import random
        
        print("Running Scan-based ATPG...")
        print(f"  Scan chain length: {self.scan_length}")
        print(f"  Real PIs: {len(self.real_pi)}")
        print(f"  Pseudo PIs (scan cells): {len(self.pseudo_pi)}")
        
        # Create combinational model
        comb_circuit = self._create_combinational_model()
        print(f"  Combinational model: {len(comb_circuit.inputs)} inputs, {len(comb_circuit.outputs)} outputs")
        
        # Generate faults if not done
        if not self.faults:
            self.generate_faults()
            
        # Create simulator for combinational model
        simulator = FaultSimulator(comb_circuit)
        engine = ATPGEngine(comb_circuit)
        
        total_faults = len(self.faults)
        undetected = list(self.faults)
        
        # Phase 1: Random patterns
        print("  Phase 1: Random pattern generation...")
        for round in range(min(50, max_patterns)):
            # Generate random values for real PIs and pseudo PIs
            pattern = {}
            for pi in self.real_pi:
                pattern[pi] = random.randint(0, 1)
            for ppi in self.pseudo_pi:
                pattern[ppi] = random.randint(0, 1)
                
            detected = simulator.simulate_pattern(pattern, undetected)
            undetected = [f for f in undetected if not f.detected]
            
            # Convert to scan pattern
            scan_in = [pattern.get(ppi, 0) for ppi in self.pseudo_pi]
            pi_values = {pi: pattern.get(pi, 0) for pi in self.real_pi}
            
            # Get expected outputs
            comb_circuit.reset_values()
            for name, value in pattern.items():
                comb_circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
            comb_circuit.simulate()
            
            expected_po = {}
            for po in self.circuit.outputs:
                if po in comb_circuit.nets:
                    val = comb_circuit.nets[po].value
                    expected_po[po] = 1 if val == Logic.ONE else 0
                    
            expected_scan_out = []
            for ppo in self.pseudo_po:
                if ppo in comb_circuit.nets:
                    val = comb_circuit.nets[ppo].value
                    expected_scan_out.append(1 if val == Logic.ONE else 0)
                else:
                    expected_scan_out.append(0)
            
            scan_pattern = ScanPattern(
                scan_in_values=scan_in,
                pi_values=pi_values,
                expected_po=expected_po,
                expected_scan_out=expected_scan_out
            )
            self.scan_patterns.append(scan_pattern)
            
            coverage = (total_faults - len(undetected)) / total_faults * 100
            if coverage >= target_coverage:
                break
                
        det_count = total_faults - len(undetected)
        print(f"    After random: {det_count}/{total_faults} ({det_count*100/total_faults:.1f}%)")
        
        # Phase 2: Targeted ATPG
        if undetected and len(self.scan_patterns) < max_patterns:
            print(f"  Phase 2: Targeted ATPG for {len(undetected)} remaining faults...")
            
            processed = 0
            for fault in list(undetected):
                if fault.detected:
                    continue
                    
                pattern = engine.generate_test(fault)
                
                if pattern:
                    detected = simulator.simulate_pattern(pattern, undetected)
                    undetected = [f for f in undetected if not f.detected]
                    
                    # Convert to scan pattern
                    scan_in = [pattern.get(ppi, 0) for ppi in self.pseudo_pi]
                    pi_values = {pi: pattern.get(pi, 0) for pi in self.real_pi}
                    
                    comb_circuit.reset_values()
                    for name, value in pattern.items():
                        comb_circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
                    comb_circuit.simulate()
                    
                    expected_po = {}
                    for po in self.circuit.outputs:
                        if po in comb_circuit.nets:
                            val = comb_circuit.nets[po].value
                            expected_po[po] = 1 if val == Logic.ONE else 0
                            
                    expected_scan_out = []
                    for ppo in self.pseudo_po:
                        if ppo in comb_circuit.nets:
                            val = comb_circuit.nets[ppo].value
                            expected_scan_out.append(1 if val == Logic.ONE else 0)
                        else:
                            expected_scan_out.append(0)
                    
                    scan_pattern = ScanPattern(
                        scan_in_values=scan_in,
                        pi_values=pi_values,
                        expected_po=expected_po,
                        expected_scan_out=expected_scan_out
                    )
                    self.scan_patterns.append(scan_pattern)
                    
                processed += 1
                if processed % 100 == 0:
                    det_count = total_faults - len(undetected)
                    print(f"    Processed {processed}: {det_count}/{total_faults}")
                    
                coverage = (total_faults - len(undetected)) / total_faults * 100
                if coverage >= target_coverage or len(self.scan_patterns) >= max_patterns:
                    break
        
        detected_count = total_faults - len(undetected)
        coverage = detected_count / total_faults * 100
        print(f"Scan ATPG complete: {detected_count}/{total_faults} ({coverage:.1f}%)")
        print(f"  Scan patterns: {len(self.scan_patterns)}")
        
        return detected_count, total_faults


# =============================================================================
# Fault Simulator
# =============================================================================

class FaultSimulator:
    """Optimized fault simulation"""
    
    def __init__(self, circuit: Circuit):
        self.circuit = circuit
        # Pre-compute gate outputs for faster access
        self._gate_outputs = {g.output.name: g for g in circuit.gate_list if g.output}
        
    def simulate_pattern(self, pattern: Dict[str, int], 
                        faults: List[Fault]) -> List[Fault]:
        """Simulate a test pattern with optimized fault dropping"""
        if not faults:
            return []
            
        detected = []
        
        # Good circuit simulation (once)
        self.circuit.reset_values()
        for name, value in pattern.items():
            self.circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
        self.circuit.simulate()
        
        good_outputs = {name: self.circuit.nets[name].value 
                       for name in self.circuit.outputs if name in self.circuit.nets}
        
        # Batch fault simulation - only check faults that can affect outputs
        for fault in faults:
            if fault.detected:
                continue
                
            # Quick simulation with fault
            self.circuit.reset_values()
            for name, value in pattern.items():
                self.circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
            
            fault_value = Logic.ONE if fault.stuck_at == 1 else Logic.ZERO
            fault_net = fault.net_name
            
            # Inject fault at input if applicable
            if fault_net in self.circuit.nets:
                self.circuit.nets[fault_net].value = fault_value
            
            # Simulate with fault injection
            for gate in self.circuit.gate_list:
                if gate.output:
                    gate.output.value = gate.evaluate()
                    if gate.output.name == fault_net:
                        gate.output.value = fault_value
            
            # Compare outputs
            fault_detected = False
            for out_name in self.circuit.outputs:
                if out_name in self.circuit.nets:
                    faulty_val = self.circuit.nets[out_name].value
                    good_val = good_outputs.get(out_name, Logic.X)
                    
                    if faulty_val != good_val and faulty_val != Logic.X and good_val != Logic.X:
                        fault.detected = True
                        fault.test_pattern = pattern.copy()
                        detected.append(fault)
                        fault_detected = True
                        break
                        
        return detected


# =============================================================================
# Coverage Report Generator
# =============================================================================

class CoverageReport:
    """Generate test coverage report"""
    
    def __init__(self, circuit: Circuit, faults: List[Fault], 
                 patterns: List[Dict[str, int]]):
        self.circuit = circuit
        self.faults = faults
        self.patterns = patterns
        
    def generate_text_report(self) -> str:
        """Generate text coverage report"""
        detected = [f for f in self.faults if f.detected]
        undetected = [f for f in self.faults if not f.detected]
        
        coverage = len(detected) / len(self.faults) * 100 if self.faults else 0
        
        report = []
        report.append("=" * 70)
        report.append("                    ATPG Coverage Report")
        report.append("=" * 70)
        report.append("")
        report.append(f"Circuit: {self.circuit.name}")
        report.append(f"Primary Inputs: {len(self.circuit.inputs)}")
        report.append(f"Primary Outputs: {len(self.circuit.outputs)}")
        report.append(f"Gates: {len([g for g in self.circuit.gates.values() if g.gate_type != GateType.INPUT])}")
        report.append(f"Nets: {len(self.circuit.nets)}")
        report.append("")
        report.append("-" * 70)
        report.append("                    Fault Coverage Summary")
        report.append("-" * 70)
        report.append(f"Total Faults:      {len(self.faults)}")
        report.append(f"Detected Faults:   {len(detected)}")
        report.append(f"Undetected Faults: {len(undetected)}")
        report.append(f"Fault Coverage:    {coverage:.2f}%")
        report.append(f"Test Patterns:     {len(self.patterns)}")
        report.append("")
        
        # Test patterns
        report.append("-" * 70)
        report.append("                    Test Patterns")
        report.append("-" * 70)
        
        if self.patterns:
            header = "Pattern | " + " | ".join(f"{inp:>4}" for inp in self.circuit.inputs)
            report.append(header)
            report.append("-" * len(header))
            
            for i, pattern in enumerate(self.patterns):
                values = " | ".join(f"{pattern.get(inp, 'X'):>4}" for inp in self.circuit.inputs)
                report.append(f"   {i:3}  | {values}")
        else:
            report.append("No test patterns generated.")
            
        report.append("")
        
        # Detected faults
        report.append("-" * 70)
        report.append("                    Detected Faults")
        report.append("-" * 70)
        
        for fault in detected[:50]:  # Limit to first 50
            report.append(f"  {fault}")
            
        if len(detected) > 50:
            report.append(f"  ... and {len(detected) - 50} more")
            
        report.append("")
        
        # Undetected faults
        if undetected:
            report.append("-" * 70)
            report.append("                    Undetected Faults")
            report.append("-" * 70)
            
            for fault in undetected[:20]:
                report.append(f"  {fault}")
                
            if len(undetected) > 20:
                report.append(f"  ... and {len(undetected) - 20} more")
                
        report.append("")
        report.append("=" * 70)
        
        return "\n".join(report)
    
    def generate_json_report(self) -> dict:
        """Generate JSON coverage report"""
        detected = [f for f in self.faults if f.detected]
        coverage = len(detected) / len(self.faults) * 100 if self.faults else 0
        
        return {
            "circuit": {
                "name": self.circuit.name,
                "inputs": self.circuit.inputs,
                "outputs": self.circuit.outputs,
                "num_gates": len([g for g in self.circuit.gates.values() 
                                 if g.gate_type != GateType.INPUT]),
                "num_nets": len(self.circuit.nets)
            },
            "coverage": {
                "total_faults": len(self.faults),
                "detected_faults": len(detected),
                "fault_coverage_percent": round(coverage, 2)
            },
            "patterns": self.patterns,
            "detected_faults": [str(f) for f in detected],
            "undetected_faults": [str(f) for f in self.faults if not f.detected]
        }

    def generate_stil_report(self) -> str:
        """Generate STIL (IEEE 1450) format test patterns for ATE with scan support"""
        from datetime import datetime
        
        detected = [f for f in self.faults if f.detected]
        coverage = len(detected) / len(self.faults) * 100 if self.faults else 0
        has_scan = self.circuit.has_scan and len(self.circuit.scan_chains) > 0
        
        stil = []
        
        # STIL Header
        stil.append("STIL 1.0 {")
        stil.append("    Design 2005;")
        if has_scan:
            stil.append("    CTL 2005;")
        stil.append("}")
        stil.append("")
        
        # Header block
        stil.append("Header {")
        stil.append(f'    Title "{self.circuit.name} Test Patterns";')
        stil.append(f'    Date "{datetime.now().strftime("%Y-%m-%d %H:%M:%S")}";')
        stil.append(f'    Source "ATPG Tool";')
        stil.append(f'    History {{')
        stil.append(f'        Ann {{* Coverage: {coverage:.2f}% *}}')
        stil.append(f'        Ann {{* Total Faults: {len(self.faults)} *}}')
        stil.append(f'        Ann {{* Detected: {len(detected)} *}}')
        stil.append(f'        Ann {{* Patterns: {len(self.patterns)} *}}')
        if has_scan:
            stil.append(f'        Ann {{* Scan Chains: {len(self.circuit.scan_chains)} *}}')
            stil.append(f'        Ann {{* Scan Cells: {len(self.circuit.scan_cells)} *}}')
        stil.append(f'    }}')
        stil.append("}")
        stil.append("")
        
        # Signals block
        stil.append("Signals {")
        for inp in self.circuit.inputs:
            stil.append(f'    "{inp}" In;')
        for out in self.circuit.outputs:
            stil.append(f'    "{out}" Out;')
        
        # Add scan signals if present
        if has_scan:
            for chain in self.circuit.scan_chains:
                stil.append(f'    "{chain.scan_in}" In {{ ScanIn; }}')
                stil.append(f'    "{chain.scan_out}" Out {{ ScanOut; }}')
                stil.append(f'    "{chain.scan_enable}" In {{ ScanEnable; }}')
        stil.append("}")
        stil.append("")
        
        # SignalGroups block
        stil.append("SignalGroups {")
        input_list = " + ".join(f'"{inp}"' for inp in self.circuit.inputs)
        output_list = " + ".join(f'"{out}"' for out in self.circuit.outputs)
        all_list = input_list + " + " + output_list if output_list else input_list
        stil.append(f'    "_pi" = \'{input_list}\';')
        stil.append(f'    "_po" = \'{output_list}\';')
        
        if has_scan:
            scan_in_list = " + ".join(f'"{c.scan_in}"' for c in self.circuit.scan_chains)
            scan_out_list = " + ".join(f'"{c.scan_out}"' for c in self.circuit.scan_chains)
            stil.append(f'    "_si" = \'{scan_in_list}\';')
            stil.append(f'    "_so" = \'{scan_out_list}\';')
            all_list += f' + {scan_in_list} + {scan_out_list}'
            
        stil.append(f'    "_all" = \'{all_list}\';')
        stil.append("}")
        stil.append("")
        
        # ScanStructures block (if scan present)
        if has_scan:
            stil.append("ScanStructures {")
            for i, chain in enumerate(self.circuit.scan_chains):
                stil.append(f'    ScanChain "{chain.name}" {{')
                stil.append(f'        ScanLength {chain.get_length()};')
                stil.append(f'        ScanIn "{chain.scan_in}";')
                stil.append(f'        ScanOut "{chain.scan_out}";')
                stil.append(f'        ScanEnable "{chain.scan_enable}";')
                stil.append(f'        ScanMasterClock "clk";')
                stil.append("    }")
            stil.append("}")
            stil.append("")
        
        # Timing block
        stil.append("Timing {")
        stil.append('    WaveformTable "_default_WFT_" {')
        stil.append("        Period '100ns';")
        stil.append("        Waveforms {")
        stil.append('            "_pi" { 01 { \'0ns\' D; }}')
        stil.append('            "_po" { LH { \'0ns\' X; \'90ns\' L/H; }}')
        if has_scan:
            stil.append('            "_si" { 01 { \'0ns\' D; }}')
            stil.append('            "_so" { LH { \'0ns\' X; \'90ns\' L/H; }}')
        stil.append("        }")
        stil.append("    }")
        stil.append("}")
        stil.append("")
        
        # PatternBurst block
        stil.append("PatternBurst \"_burst_\" {")
        stil.append('    PatList { "_pattern_" ; }')
        stil.append("}")
        stil.append("")
        
        # PatternExec block
        stil.append("PatternExec {")
        stil.append('    PatternBurst "_burst_";')
        stil.append("}")
        stil.append("")
        
        # Procedures block
        stil.append("Procedures {")
        if has_scan:
            # Scan shift procedure
            stil.append('    "load_unload" {')
            stil.append("        W \"_default_WFT_\";")
            for chain in self.circuit.scan_chains:
                stil.append(f'        Shift {{ V {{ "{chain.scan_enable}" = 1; }}')
                stil.append(f'            V {{ "_si" = #; "_so" = #; }}')
                stil.append(f'        }}')
            stil.append("    }")
            stil.append("")
            # Capture procedure  
            stil.append('    "capture" {')
            stil.append("        W \"_default_WFT_\";")
            for chain in self.circuit.scan_chains:
                stil.append(f'        V {{ "{chain.scan_enable}" = 0; }}')
            stil.append('        C { "_all" = \\r1 ; }')
            stil.append("    }")
        else:
            stil.append('    "load_unload" {')
            stil.append("        W \"_default_WFT_\";")
            stil.append("        V { \"_all\" = \\r1 # ; }")
            stil.append("    }")
        stil.append("}")
        stil.append("")
        
        # MacroDefs block
        stil.append("MacroDefs {")
        stil.append('    "test_setup" {')
        stil.append("        W \"_default_WFT_\";")
        stil.append("        V { \"_all\" = \\r1 0 ; }")
        stil.append("    }")
        stil.append("}")
        stil.append("")
        
        # Pattern block
        stil.append('Pattern "_pattern_" {')
        stil.append("    W \"_default_WFT_\";")
        stil.append("")
        
        # Generate patterns
        for i, pattern in enumerate(self.patterns):
            # Get expected outputs
            self.circuit.reset_values()
            for name, value in pattern.items():
                self.circuit.set_input(name, Logic.ONE if value else Logic.ZERO)
            self.circuit.simulate()
            
            # Build input vector
            input_vec = ''.join(str(pattern.get(inp, 0)) for inp in self.circuit.inputs)
            
            # Build expected output vector
            output_vec = ''
            for out in self.circuit.outputs:
                if out in self.circuit.nets:
                    val = self.circuit.nets[out].value
                    if val == Logic.ONE:
                        output_vec += 'H'
                    elif val == Logic.ZERO:
                        output_vec += 'L'
                    else:
                        output_vec += 'X'
                else:
                    output_vec += 'X'
            
            stil.append(f'    Ann {{* Pattern {i} *}}')
            stil.append(f'    V {{ "_pi" = {input_vec}; "_po" = {output_vec}; }}')
            stil.append("")
            
        stil.append("}")
        stil.append("")
        
        return "\n".join(stil)


# =============================================================================
# Main ATPG Tool (Enhanced)
# =============================================================================

class ATPG:
    """Main ATPG tool (Enhanced Version)
    
    增强功能:
    - 支持多种ATPG算法: D-Algorithm, PODEM, FAN
    - 并行故障模拟
    - 冗余故障识别
    - 跳变故障支持
    """
    
    def __init__(self, algorithm: str = "auto"):
        self.circuit = None
        self.faults = []
        self.patterns = []
        self.algorithm = algorithm
        self.include_transition = False
        
        # 统计信息
        self.stats = {
            'total_faults': 0,
            'detected_faults': 0,
            'redundant_faults': 0,
            'untestable_faults': 0,
            'aborted_faults': 0
        }
        
    def load_netlist(self, filename: str, format: str = "auto"):
        """Load netlist from file"""
        if format == "auto":
            if filename.endswith('.v') or filename.endswith('.verilog'):
                format = "verilog"
            elif filename.endswith('.bench'):
                format = "bench"
            else:
                format = "simple"
                
        if format == "verilog":
            self.circuit = NetlistParser.parse_verilog(filename)
        elif format == "bench":
            self.circuit = NetlistParser.parse_bench(filename)
        else:
            self.circuit = NetlistParser.parse(filename)
            
        print(f"Loaded circuit: {self.circuit.name}")
        print(f"  Inputs: {len(self.circuit.inputs)}")
        print(f"  Outputs: {len(self.circuit.outputs)}")
        print(f"  Gates: {len([g for g in self.circuit.gates.values() if g.gate_type != GateType.INPUT])}")
        
    def generate_faults(self, collapse: bool = True, 
                       include_transition: bool = False,
                       checkpoint_only: bool = False):
        """Generate fault list"""
        self.include_transition = include_transition
        
        if checkpoint_only:
            self.faults = FaultGenerator.generate_checkpoint_faults(self.circuit)
            print(f"Generated {len(self.faults)} checkpoint faults")
        else:
            self.faults = FaultGenerator.generate_all_faults(
                self.circuit, include_transition=include_transition)
            
            if collapse:
                original_count = len(self.faults)
                self.faults = FaultGenerator.collapse_faults(self.circuit, self.faults)
                print(f"Generated {len(self.faults)} faults (collapsed from {original_count})")
            else:
                print(f"Generated {len(self.faults)} faults")
        
        self.stats['total_faults'] = len(self.faults)
        
    def run_atpg(self, max_patterns: int = 500, target_coverage: float = 95.0,
                 use_parallel: bool = True):
        """Run ATPG with enhanced algorithms"""
        
        # 选择仿真器
        if use_parallel:
            simulator = ParallelFaultSimulator(self.circuit)
        else:
            simulator = FaultSimulator(self.circuit)
        
        # 选择ATPG引擎
        engine = EnhancedATPGEngine(self.circuit, algorithm=self.algorithm)
        
        total_faults = len(self.faults)
        
        print(f"\n{'='*60}")
        print(f"ENHANCED ATPG ENGINE")
        print(f"{'='*60}")
        print(f"Algorithm: {self.algorithm}")
        print(f"Parallel simulation: {use_parallel}")
        print(f"Target coverage: {target_coverage}%")
        print(f"Max patterns: {max_patterns}")
        print(f"{'='*60}\n")
        
        # Phase 1: Random patterns for quick initial coverage
        print("Phase 1: Random pattern generation...")
        undetected = list(self.faults)
        start_time = time.time()
        
        random_patterns = min(100, max_patterns)
        for round in range(random_patterns):
            pattern = {inp: random.randint(0, 1) for inp in self.circuit.inputs}
            
            if use_parallel:
                detected = simulator.simulate_batch(pattern, undetected)
            else:
                detected = simulator.simulate_pattern(pattern, undetected)
            
            undetected = [f for f in undetected if not f.detected]
            self.patterns.append(pattern)
            
            coverage = (total_faults - len(undetected)) / total_faults * 100
            if coverage >= target_coverage:
                break
        
        random_time = time.time() - start_time
        det_count = total_faults - len(undetected)
        print(f"  Random phase: {det_count}/{total_faults} ({det_count*100/total_faults:.1f}%)")
        print(f"  Time: {random_time:.2f}s, Patterns: {len(self.patterns)}")
        
        # Phase 2: Deterministic ATPG with PODEM/FAN
        if undetected and len(self.patterns) < max_patterns:
            print(f"\nPhase 2: Deterministic ATPG ({self.algorithm})...")
            print(f"  Remaining faults: {len(undetected)}")
            
            start_time = time.time()
            processed = 0
            atpg_success = 0
            
            for fault in list(undetected):
                if fault.detected:
                    continue
                    
                # Generate test using enhanced engine
                pattern = engine.generate_test(fault)
                
                if pattern:
                    atpg_success += 1
                    
                    # Simulate with new pattern
                    if use_parallel:
                        detected = simulator.simulate_batch(pattern, undetected)
                    else:
                        detected = simulator.simulate_pattern(pattern, undetected)
                    
                    undetected = [f for f in undetected if not f.detected]
                    
                    if pattern not in self.patterns:
                        self.patterns.append(pattern)
                
                processed += 1
                if processed % 50 == 0:
                    det_count = total_faults - len(undetected)
                    coverage = det_count * 100 / total_faults
                    print(f"    Processed {processed}: {det_count}/{total_faults} ({coverage:.1f}%)")
                    
                coverage = (total_faults - len(undetected)) / total_faults * 100
                if coverage >= target_coverage or len(self.patterns) >= max_patterns:
                    break
            
            atpg_time = time.time() - start_time
            print(f"  ATPG phase complete: {atpg_success} patterns generated")
            print(f"  Time: {atpg_time:.2f}s")
        
        # Phase 3: Classify remaining faults
        print(f"\nPhase 3: Fault classification...")
        self._classify_remaining_faults(undetected)
        
        # Final statistics
        self._compute_final_stats()
        self._print_final_report(engine)
        
    def _classify_remaining_faults(self, undetected: List[Fault]):
        """分类剩余未检测故障"""
        for fault in undetected:
            if fault.status == FaultStatus.REDUNDANT:
                continue
            elif fault.backtrack_count > EnhancedATPGEngine.REDUNDANT_BACKTRACK_LIMIT:
                fault.mark_redundant()
            elif fault.backtrack_count > 1000:
                fault.status = FaultStatus.ATPG_UNTESTABLE
            else:
                fault.status = FaultStatus.NOT_DETECTED
    
    def _compute_final_stats(self):
        """计算最终统计"""
        self.stats['detected_faults'] = len([f for f in self.faults if f.detected])
        self.stats['redundant_faults'] = len([f for f in self.faults 
                                              if f.status == FaultStatus.REDUNDANT])
        self.stats['untestable_faults'] = len([f for f in self.faults 
                                               if f.status == FaultStatus.ATPG_UNTESTABLE])
        self.stats['aborted_faults'] = len([f for f in self.faults 
                                            if f.status == FaultStatus.NOT_DETECTED])
    
    def _print_final_report(self, engine: EnhancedATPGEngine):
        """打印最终报告"""
        total = self.stats['total_faults']
        detected = self.stats['detected_faults']
        redundant = self.stats['redundant_faults']
        untestable = self.stats['untestable_faults']
        aborted = self.stats['aborted_faults']
        
        # 计算有效覆盖率 (排除冗余故障)
        testable = total - redundant
        effective_coverage = (detected / testable * 100) if testable > 0 else 0
        raw_coverage = (detected / total * 100) if total > 0 else 0
        
        print(f"\n{'='*60}")
        print(f"ATPG FINAL REPORT")
        print(f"{'='*60}")
        print(f"Total Faults:        {total}")
        print(f"Detected:            {detected}")
        print(f"Redundant (UNTESTABLE): {redundant}")
        print(f"ATPG Untestable:     {untestable}")
        print(f"Aborted:             {aborted}")
        print(f"")
        print(f"Raw Coverage:        {raw_coverage:.2f}%")
        print(f"Effective Coverage:  {effective_coverage:.2f}% (excluding redundant)")
        print(f"Test Patterns:       {len(self.patterns)}")
        print(f"{'='*60}")
        
        # 打印算法统计
        engine.print_stats()
        
    def generate_report(self, output_file: str = None, format: str = "text"):
        """Generate coverage report"""
        report = CoverageReport(self.circuit, self.faults, self.patterns)
        
        if format == "json":
            content = json.dumps(report.generate_json_report(), indent=2)
        elif format == "stil":
            content = report.generate_stil_report()
        else:
            content = report.generate_text_report()
            
        if output_file:
            with open(output_file, 'w') as f:
                f.write(content)
            print(f"Report saved to: {output_file}")
        else:
            print(content)
            
        return content


# =============================================================================
# Scan STIL Report Generator
# =============================================================================

def generate_scan_stil_report(circuit: Circuit, scan_atpg: ScanATPG) -> str:
    """Generate STIL format with full scan test procedures"""
    from datetime import datetime
    
    detected = [f for f in scan_atpg.faults if f.detected]
    coverage = len(detected) / len(scan_atpg.faults) * 100 if scan_atpg.faults else 0
    chain = scan_atpg.scan_chain
    
    stil = []
    
    # STIL Header
    stil.append("STIL 1.0 {")
    stil.append("    Design 2005;")
    stil.append("    CTL 2005;")
    stil.append("}")
    stil.append("")
    
    # Header block
    stil.append("Header {")
    stil.append(f'    Title "{circuit.name} Scan Test Patterns";')
    stil.append(f'    Date "{datetime.now().strftime("%Y-%m-%d %H:%M:%S")}";')
    stil.append(f'    Source "Scan ATPG Tool";')
    stil.append(f'    History {{')
    stil.append(f'        Ann {{* Scan-based ATPG *}}')
    stil.append(f'        Ann {{* Coverage: {coverage:.2f}% *}}')
    stil.append(f'        Ann {{* Total Faults: {len(scan_atpg.faults)} *}}')
    stil.append(f'        Ann {{* Detected: {len(detected)} *}}')
    stil.append(f'        Ann {{* Scan Patterns: {len(scan_atpg.scan_patterns)} *}}')
    stil.append(f'        Ann {{* Scan Chain Length: {scan_atpg.scan_length} *}}')
    stil.append(f'    }}')
    stil.append("}")
    stil.append("")
    
    # Signals block
    stil.append("Signals {")
    
    # Real primary inputs (excluding scan control)
    for pi in scan_atpg.real_pi:
        stil.append(f'    "{pi}" In;')
    
    # Primary outputs
    for po in circuit.outputs:
        if po != chain.scan_out:
            stil.append(f'    "{po}" Out;')
    
    # Scan signals
    stil.append(f'    "{chain.scan_in}" In {{ ScanIn; }}')
    stil.append(f'    "{chain.scan_out}" Out {{ ScanOut; }}')
    stil.append(f'    "{chain.scan_enable}" In {{ ScanEnable; }}')
    stil.append('    "clk" In { MasterClock; }')
    stil.append("}")
    stil.append("")
    
    # SignalGroups
    stil.append("SignalGroups {")
    pi_list = " + ".join(f'"{pi}"' for pi in scan_atpg.real_pi) if scan_atpg.real_pi else '""'
    po_list_names = [po for po in circuit.outputs if po != chain.scan_out]
    po_list = " + ".join(f'"{po}"' for po in po_list_names) if po_list_names else '""'
    stil.append(f'    "_pi" = \'{pi_list}\';')
    stil.append(f'    "_po" = \'{po_list}\';')
    stil.append(f'    "_si" = \'"{chain.scan_in}"\';')
    stil.append(f'    "_so" = \'"{chain.scan_out}"\';')
    stil.append(f'    "_se" = \'"{chain.scan_enable}"\';')
    stil.append("}")
    stil.append("")
    
    # ScanStructures
    stil.append("ScanStructures {")
    stil.append(f'    ScanChain "{chain.name}" {{')
    stil.append(f'        ScanLength {scan_atpg.scan_length};')
    stil.append(f'        ScanIn "{chain.scan_in}";')
    stil.append(f'        ScanOut "{chain.scan_out}";')
    stil.append(f'        ScanEnable "{chain.scan_enable}";')
    stil.append(f'        ScanMasterClock "clk";')
    # List scan cells in order
    stil.append(f'        ScanCells {{')
    for cell in circuit.scan_cells:
        stil.append(f'            "{cell.name}" {{ {cell.q_output}; }}')
    stil.append(f'        }}')
    stil.append("    }")
    stil.append("}")
    stil.append("")
    
    # Timing
    stil.append("Timing {")
    stil.append('    WaveformTable "_default_WFT_" {')
    stil.append("        Period '100ns';")
    stil.append("        Waveforms {")
    stil.append('            "_pi" { 01 { \'0ns\' D; }}')
    stil.append('            "_po" { LHX { \'0ns\' X; \'90ns\' L/H/X; }}')
    stil.append('            "_si" { 01 { \'0ns\' D; }}')
    stil.append('            "_so" { LHX { \'0ns\' X; \'90ns\' L/H/X; }}')
    stil.append('            "_se" { 01 { \'0ns\' D; }}')
    stil.append('            "clk" { P { \'0ns\' D; \'45ns\' U; \'55ns\' D; }}')
    stil.append("        }")
    stil.append("    }")
    stil.append("}")
    stil.append("")
    
    # Procedures
    stil.append("Procedures {")
    stil.append('    "load_unload" {')
    stil.append('        W "_default_WFT_";')
    stil.append(f'        V {{ "{chain.scan_enable}" = 1; }}')
    stil.append(f'        Shift {{')
    stil.append(f'            V {{ "{chain.scan_in}" = #; "{chain.scan_out}" = #; "clk" = P; }}')
    stil.append(f'        }}')
    stil.append("    }")
    stil.append('    "capture" {')
    stil.append('        W "_default_WFT_";')
    stil.append(f'        V {{ "{chain.scan_enable}" = 0; "clk" = P; }}')
    stil.append("    }")
    stil.append("}")
    stil.append("")
    
    # MacroDefs
    stil.append("MacroDefs {")
    stil.append('    "test_setup" {')
    stil.append('        W "_default_WFT_";')
    stil.append(f'        V {{ "{chain.scan_enable}" = 0; "clk" = 0; }}')
    stil.append("    }")
    stil.append("}")
    stil.append("")
    
    # Pattern block
    stil.append('Pattern "_pattern_" {')
    stil.append('    W "_default_WFT_";')
    stil.append('    Call "test_setup";')
    stil.append("")
    
    # Generate scan patterns
    for i, sp in enumerate(scan_atpg.scan_patterns):
        stil.append(f'    Ann {{* Scan Pattern {i} *}}')
        
        # Scan load phase
        scan_in_vec = ''.join(str(v) for v in sp.scan_in_values)
        expected_out_vec = ''.join(str(v) for v in sp.expected_scan_out) if sp.expected_scan_out else 'X' * scan_atpg.scan_length
        
        stil.append(f'    Call "load_unload" {{')
        stil.append(f'        "{chain.scan_in}" = {scan_in_vec};')
        if i > 0:  # Check previous pattern's expected output
            prev_sp = scan_atpg.scan_patterns[i-1]
            prev_out = ''.join('L' if v == 0 else 'H' for v in prev_sp.expected_scan_out) if prev_sp.expected_scan_out else 'X' * scan_atpg.scan_length
            stil.append(f'        "{chain.scan_out}" = {prev_out};')
        else:
            stil.append(f'        "{chain.scan_out}" = {"X" * scan_atpg.scan_length};')
        stil.append(f'    }}')
        
        # Apply PI and capture
        pi_vec = ''.join(str(sp.pi_values.get(pi, 0)) for pi in scan_atpg.real_pi) if scan_atpg.real_pi else ''
        po_vec = ''.join('L' if sp.expected_po.get(po, 0) == 0 else 'H' for po in po_list_names) if po_list_names else ''
        
        if pi_vec:
            stil.append(f'    V {{ "_pi" = {pi_vec}; }}')
        stil.append('    Call "capture";')
        if po_vec:
            stil.append(f'    V {{ "_po" = {po_vec}; }}')
        stil.append("")
    
    # Final unload
    if scan_atpg.scan_patterns:
        last_sp = scan_atpg.scan_patterns[-1]
        last_out = ''.join('L' if v == 0 else 'H' for v in last_sp.expected_scan_out) if last_sp.expected_scan_out else 'X' * scan_atpg.scan_length
        stil.append(f'    Ann {{* Final scan unload *}}')
        stil.append(f'    Call "load_unload" {{')
        stil.append(f'        "{chain.scan_in}" = {"0" * scan_atpg.scan_length};')
        stil.append(f'        "{chain.scan_out}" = {last_out};')
        stil.append(f'    }}')
    
    stil.append("}")
    stil.append("")
    
    return "\n".join(stil)


# =============================================================================
# CLI Interface
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='ATPG - Automatic Test Pattern Generation Tool (Enhanced)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # 基本用法
  %(prog)s netlist.bench -o output.stil -r stil

  # 使用PODEM算法
  %(prog)s netlist.bench --algorithm podem -c 95

  # 使用FAN算法,并行仿真
  %(prog)s netlist.bench --algorithm fan --parallel

  # 包含跳变故障 (at-speed测试)
  %(prog)s netlist.bench --transition -o trans.stil -r stil

  # Scan模式ATPG
  %(prog)s netlist.bench --scan -n 500 -c 98

  # 高覆盖率模式
  %(prog)s netlist.bench --algorithm auto -n 1000 -c 99 --parallel
"""
    )
    parser.add_argument('netlist', help='Input netlist file')
    parser.add_argument('-f', '--format', choices=['auto', 'simple', 'verilog', 'bench'],
                       default='auto', help='Netlist format')
    parser.add_argument('-o', '--output', help='Output report file')
    parser.add_argument('-r', '--report-format', choices=['text', 'json', 'stil'],
                       default='text', help='Report format (stil for ATE)')
    
    # 故障相关参数
    parser.add_argument('--no-collapse', action='store_true',
                       help='Disable fault collapsing')
    parser.add_argument('--checkpoint-only', action='store_true',
                       help='Only generate faults at checkpoints (PI, fanout, PO)')
    parser.add_argument('--transition', action='store_true',
                       help='Include transition faults (STR/STF) for at-speed testing')
    
    # 算法选择
    parser.add_argument('--algorithm', '-a', 
                       choices=['auto', 'podem', 'fan', 'd-algorithm'],
                       default='auto', 
                       help='ATPG algorithm (default: auto - tries PODEM, FAN, D-Algorithm)')
    
    # 仿真参数
    parser.add_argument('--parallel', action='store_true',
                       help='Enable parallel fault simulation (faster)')
    
    # Scan模式
    parser.add_argument('--scan', action='store_true',
                       help='Enable scan-based ATPG for sequential circuits')
    
    # ATPG参数
    parser.add_argument('-n', '--max-patterns', type=int, default=200,
                       help='Maximum number of test patterns (default: 200)')
    parser.add_argument('-c', '--coverage', type=float, default=95.0,
                       help='Target fault coverage percentage (default: 95.0)')
    
    args = parser.parse_args()
    
    # 创建ATPG实例
    atpg = ATPG(algorithm=args.algorithm)
    atpg.load_netlist(args.netlist, args.format)
    
    if args.scan:
        # Scan-based ATPG mode
        if not atpg.circuit.has_scan:
            print("Error: Circuit does not have scan chain. Use --scan only with scan circuits.")
            sys.exit(1)
            
        scan_atpg = ScanATPG(atpg.circuit)
        scan_atpg.generate_faults()
        detected, total = scan_atpg.run(max_patterns=args.max_patterns, 
                                         target_coverage=args.coverage)
        
        # Convert scan patterns to regular patterns for report
        atpg.faults = scan_atpg.faults
        atpg.patterns = []
        for sp in scan_atpg.scan_patterns:
            combined = dict(sp.pi_values)
            for i, ppi in enumerate(scan_atpg.pseudo_pi):
                combined[ppi] = sp.scan_in_values[i] if i < len(sp.scan_in_values) else 0
            atpg.patterns.append(combined)
            
        # Generate scan-aware STIL report
        if args.report_format == 'stil':
            content = generate_scan_stil_report(atpg.circuit, scan_atpg)
            if args.output:
                with open(args.output, 'w') as f:
                    f.write(content)
                print(f"Scan STIL report saved to: {args.output}")
            else:
                print(content)
        else:
            atpg.generate_report(args.output, args.report_format)
    else:
        # Standard combinational ATPG with enhanced features
        atpg.generate_faults(
            collapse=not args.no_collapse,
            include_transition=args.transition,
            checkpoint_only=args.checkpoint_only
        )
        atpg.run_atpg(
            max_patterns=args.max_patterns, 
            target_coverage=args.coverage,
            use_parallel=args.parallel
        )
        atpg.generate_report(args.output, args.report_format)


if __name__ == "__main__":
    main()
