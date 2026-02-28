#!/usr/bin/env python3
"""
Convert Yosys synthesized Verilog to BENCH format for ATPG
Handles assign statements with operators and always blocks for DFFs
"""

import re
import sys

def sanitize(name):
    """Sanitize signal names - replace [] with _ consistently"""
    name = name.strip()
    # Remove backslash escape
    name = name.replace('\\', '')
    # Handle 2D array with space: ram_q[1] [33] -> ram_q_1__33_
    name = re.sub(r'\[(\d+)\]\s*\[(\d+)\]', r'_\1__\2_', name)
    # Replace [n] with _n_
    name = re.sub(r'\[(\d+)\]', r'_\1_', name)
    name = name.replace('.', '_').replace(' ', '')
    return name


def sanitize_expr(expr):
    """Sanitize an entire expression, handling escaped names and arrays"""
    result = expr
    
    # Handle escaped names with 2D arrays: \name[i] [j] -> name_i__j_
    result = re.sub(r'\\([\w.]+)\[(\d+)\]\s*\[(\d+)\]', 
                    lambda m: m.group(1).replace('.', '_') + '_' + m.group(2) + '__' + m.group(3) + '_', 
                    result)
    
    # Handle escaped names with 1D arrays: \name[i] -> name_i_
    result = re.sub(r'\\([\w.]+)\s*\[(\d+)\]', 
                    lambda m: m.group(1).replace('.', '_') + '_' + m.group(2) + '_', 
                    result)
    
    # Handle escaped names without arrays: \name -> name
    result = re.sub(r'\\([\w.]+)\s*', 
                    lambda m: m.group(1).replace('.', '_'), 
                    result)
    
    # Handle remaining arrays: name[i] -> name_i_
    result = re.sub(r'(\w+)\[(\d+)\]', r'\1_\2_', result)
    
    # Clean up dots and spaces
    result = result.replace('.', '_').replace(' ', '')
    
    return result

def parse_yosys_verilog(filename):
    """Parse Yosys output Verilog and convert to BENCH format"""
    
    with open(filename, 'r') as f:
        content = f.read()
    
    inputs = []
    outputs = []
    gates = []
    dffs = []
    
    # Parse input declarations
    for match in re.finditer(r'input\s+(?:\[(\d+):(\d+)\]\s+)?(\w+)', content):
        high, low, name = match.groups()
        if high and low:
            for i in range(int(low), int(high)+1):
                inputs.append(f"{name}_{i}_")
        else:
            inputs.append(name)
    
    # Parse output declarations  
    for match in re.finditer(r'output\s+(?:\[(\d+):(\d+)\]\s+)?(\w+)', content):
        high, low, name = match.groups()
        if high and low:
            for i in range(int(low), int(high)+1):
                outputs.append(f"{name}_{i}_")
        else:
            outputs.append(name)
    
    # Parse always blocks for DFFs
    # Yosys format: always @(posedge clk, posedge rst) if (rst) reg <= reset; else reg <= d;
    # Also handles: always @(posedge clk) if (!rst) reg <= reset; else reg <= d;
    dff_patterns = [
        # Yosys async reset format (most common):
        # always @(posedge clk_i, posedge rst_i)
        #     if (rst_i) \reg[n]  <= 1'h0;
        #     else \reg[n]  <= d_input;
        r"always\s*@\s*\([^)]+\)\s*if\s*\(\s*\w+\s*\)\s*(\\?[\w.\[\]\s]+?)\s*<=\s*[^;]+;\s*else\s+\1\s*<=\s*([^;]+);",
    ]
    
    seen_dffs = set()
    const_dffs = []  # DFFs with constant D input (reg, const_val)
    
    for pattern in dff_patterns:
        for match in re.finditer(pattern, content, re.DOTALL | re.MULTILINE):
            reg = sanitize(match.group(1))
            d_input = sanitize(match.group(2))
            if reg not in seen_dffs:
                # Check for constant D input
                const_match = re.match(r"^\d+'[hbd]([01]+)$", d_input.replace('_', ''))
                if const_match:
                    # Constant D input - determine value (0 or 1)
                    const_val = 1 if '1' in const_match.group(1) else 0
                    const_dffs.append((reg, const_val))
                    seen_dffs.add(reg)
                else:
                    dffs.append((reg, d_input))
                    seen_dffs.add(reg)
    
    # Alternative: scan line by line for DFF patterns  
    # This is more robust for Yosys output with escaped names
    lines = content.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        # Match: always @(posedge clk..., posedge rst...)
        if line.startswith('always @'):
            # Look for the if/else pattern in subsequent lines
            if i + 2 < len(lines):
                if_line = lines[i + 1].strip()
                else_line = lines[i + 2].strip()
                
                # Match: if (rst) reg <= reset_val;
                if_match = re.match(r"if\s*\(\s*\w+\s*\)\s*(\\?[\w.\[\]\s]+?)\s*<=\s*[^;]+;", if_line)
                
                # Match two formats:
                # 1. else reg <= d_input;
                # 2. else if (enable) reg <= d_input;
                else_match = re.match(r"else\s+(?:if\s*\([^)]+\)\s*)?(\\?[\w.\[\]\s]+?)\s*<=\s*([^;]+);", else_line)
                
                if if_match and else_match:
                    reg1 = sanitize(if_match.group(1))
                    reg2 = sanitize(else_match.group(1))
                    d_input = sanitize(else_match.group(2))
                    
                    # Verify same register in both branches
                    if reg1 == reg2 and reg1 not in seen_dffs:
                        # Check for constant D input
                        const_match = re.match(r"^\d+'[hbd]([01]+)$", d_input.replace('_', ''))
                        if const_match:
                            const_val = 1 if '1' in const_match.group(1) else 0
                            const_dffs.append((reg1, const_val))
                            seen_dffs.add(reg1)
                        else:
                            dffs.append((reg1, d_input))
                            seen_dffs.add(reg1)
                    i += 2  # Skip processed lines
        i += 1
    
    gate_id = 0
    
    # Parse assign statements
    # Handle both simple names and escaped names with spaces: \name [index]
    for match in re.finditer(r'assign\s+(\\[\w.]+(?:\s*\[\d+\])?|\S+)\s*=\s*([^;]+);', content):
        output_raw = match.group(1).strip()
        expr_raw = match.group(2).strip()
        
        output = sanitize(output_raw)
        
        # Skip constant assignments
        if re.match(r"^\d+'[hbd]", expr_raw):
            continue
        
        # Use sanitize_expr to handle all escaped names and arrays
        expr = sanitize_expr(expr_raw)
        
        # MUX: sel ? a : b -> expand to basic gates
        # MUX(sel, a, b) = OR(AND(sel, a), AND(NOT(sel), b))
        mux_match = re.match(r'^(.+?)\s*\?\s*(.+?)\s*:\s*(.+)$', expr)
        if mux_match:
            sel, a, b = mux_match.groups()
            sel = sel.strip()
            a = a.strip()
            b = b.strip()
            if sel and a and b and '?' not in sel and '?' not in a:
                # Generate unique intermediate signal names
                mux_id = len([g for g in gates if '_mux_' in g])
                not_sel = f"_mux_{mux_id}_not_sel"
                and_a = f"_mux_{mux_id}_and_a"
                and_b = f"_mux_{mux_id}_and_b"
                gates.append(f"{not_sel} = NOT({sel})")
                gates.append(f"{and_a} = AND({sel}, {a})")
                gates.append(f"{and_b} = AND({not_sel}, {b})")
                gates.append(f"{output} = OR({and_a}, {and_b})")
                continue
        
        # NAND: ~(a & b & ...) - check this BEFORE simple NOT
        nand_match = re.match(r'^~\s*\(\s*([^()]+)\s*\)$', expr)
        if nand_match:
            inner = nand_match.group(1)
            if '&' in inner and '|' not in inner and '^' not in inner:
                operands = [x.strip() for x in inner.split('&')]
                gates.append(f"{output} = NAND({', '.join(operands)})")
                continue
            elif '|' in inner and '&' not in inner and '^' not in inner:
                operands = [x.strip() for x in inner.split('|')]
                gates.append(f"{output} = NOR({', '.join(operands)})")
                continue
            elif '^' in inner and '&' not in inner and '|' not in inner:
                operands = [x.strip() for x in inner.split('^')]
                gates.append(f"{output} = XNOR({', '.join(operands)})")
                continue
        
        # Simple NOT: ~signal (only match simple signal names without parentheses)
        not_match = re.match(r'^~\s*([a-zA-Z_][a-zA-Z0-9_]*)$', expr)
        if not_match:
            gates.append(f"{output} = NOT({not_match.group(1)})")
            continue
        
        # AND: a & b & ...
        if '&' in expr and '|' not in expr and '^' not in expr and '~' not in expr:
            operands = [x.strip() for x in expr.split('&')]
            gates.append(f"{output} = AND({', '.join(operands)})")
            continue
        
        # OR: a | b | ...
        if '|' in expr and '&' not in expr and '^' not in expr and '~' not in expr:
            operands = [x.strip() for x in expr.split('|')]
            gates.append(f"{output} = OR({', '.join(operands)})")
            continue
        
        # XOR: a ^ b
        if '^' in expr and '&' not in expr and '|' not in expr and '~' not in expr:
            operands = [x.strip() for x in expr.split('^')]
            gates.append(f"{output} = XOR({', '.join(operands)})")
            continue
        
        # Buffer/wire assignment
        if re.match(r'^(\w+)$', expr):
            gates.append(f"{output} = BUF({expr})")
            continue
        
        # Complex expressions with ~ - decompose
        if '~' in expr:
            expr_work = expr
            for inv_match in re.finditer(r'~(\w+)', expr):
                inv_sig = inv_match.group(1)
                int_name = f"_n{gate_id}_"
                gate_id += 1
                gates.append(f"{int_name} = NOT({inv_sig})")
                expr_work = expr_work.replace(f"~{inv_sig}", int_name, 1)
            
            if '&' in expr_work and '|' not in expr_work:
                operands = [x.strip() for x in expr_work.split('&')]
                gates.append(f"{output} = AND({', '.join(operands)})")
            elif '|' in expr_work and '&' not in expr_work:
                operands = [x.strip() for x in expr_work.split('|')]
                gates.append(f"{output} = OR({', '.join(operands)})")
            elif '^' in expr_work:
                operands = [x.strip() for x in expr_work.split('^')]
                gates.append(f"{output} = XOR({', '.join(operands)})")
    
    # Check if we need constant inputs for const-D DFFs
    needs_const_0 = any(v == 0 for _, v in const_dffs)
    needs_const_1 = any(v == 1 for _, v in const_dffs)
    
    # Generate BENCH output
    bench = []
    
    total_inputs = len(inputs) + (1 if needs_const_0 else 0) + (1 if needs_const_1 else 0)
    
    bench.append(f"# Converted from Yosys synthesis: apb_uart")
    bench.append(f"# Inputs: {total_inputs}")
    bench.append(f"# Outputs: {len(outputs)}")
    bench.append(f"# DFFs: {len(dffs)}")
    bench.append(f"# Const DFFs: {len(const_dffs)}")
    bench.append(f"# Gates: {len(gates)}")
    bench.append("")
    
    for inp in inputs:
        bench.append(f"INPUT({inp})")
    
    # Add constant inputs if needed
    if needs_const_0:
        bench.append("INPUT(const_0)")
    if needs_const_1:
        bench.append("INPUT(const_1)")
    bench.append("")
    
    for out in outputs:
        bench.append(f"OUTPUT({out})")
    bench.append("")
    
    # Regular DFFs
    for reg, d_input in dffs:
        bench.append(f"{reg} = DFF({d_input})")
    if dffs:
        bench.append("")
    
    # Constant-D DFFs as BUF from constant inputs
    for reg, const_val in const_dffs:
        const_input = "const_1" if const_val else "const_0"
        bench.append(f"{reg} = BUF({const_input})")
    if const_dffs:
        bench.append("")
    
    for gate in gates:
        bench.append(gate)
    
    return "\n".join(bench)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.v> [output.bench]")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    bench = parse_yosys_verilog(input_file)
    
    if output_file:
        with open(output_file, 'w') as f:
            f.write(bench)
        print(f"Converted: {output_file}")
    else:
        print(bench)


if __name__ == "__main__":
    main()
