#!/usr/bin/env python3
"""
Test Circuit Generator for DFT/ATPG Performance Evaluation

Generates parameterized BENCH format netlists with:
- Configurable number of DFFs (for testing multi-chain scan insertion)
- Configurable combinational logic depth
- Configurable fanin/fanout
- Optional multi-clock domain support

Usage:
    python gen_test_circuit.py --num-dff 1000 --output big_circuit.bench
    python gen_test_circuit.py --num-dff 2000 --clock-domains 4 --output multi_clk.bench
"""

import argparse
import random
import sys
from typing import List, Tuple, Set


def generate_circuit(
    num_dff: int = 1000,
    num_pi: int = 32,
    num_po: int = 16,
    logic_depth: int = 5,
    fanin_avg: int = 3,
    clock_domains: int = 1,
    seed: int = 42
) -> str:
    """Generate a BENCH format netlist with specified parameters."""
    
    random.seed(seed)
    
    lines = []
    lines.append(f"# Synthetic Test Circuit")
    lines.append(f"# DFFs: {num_dff}")
    lines.append(f"# Primary Inputs: {num_pi}")
    lines.append(f"# Primary Outputs: {num_po}")
    lines.append(f"# Logic Depth: {logic_depth}")
    lines.append(f"# Clock Domains: {clock_domains}")
    lines.append("")
    
    # Primary Inputs
    pi_names = [f"pi_{i}" for i in range(num_pi)]
    for pi in pi_names:
        lines.append(f"INPUT({pi})")
    lines.append("")
    
    # Primary Outputs
    po_names = [f"po_{i}" for i in range(num_po)]
    for po in po_names:
        lines.append(f"OUTPUT({po})")
    lines.append("")
    
    # Track available signals for each level
    available_signals: List[str] = list(pi_names)
    all_gates: List[str] = []
    gate_id = 0
    
    # Generate DFFs with clock domain prefixes
    dff_outputs = []
    for i in range(num_dff):
        clk_domain = i % clock_domains
        if clock_domains > 1:
            dff_name = f"dff_clk{clk_domain}_{i}"
        else:
            dff_name = f"dff_{i}"
        dff_outputs.append(dff_name)
    
    # First, create combinational logic layers before DFFs
    # This creates logic from PIs to DFF inputs
    
    gate_types = ['AND', 'OR', 'NAND', 'NOR', 'XOR']
    
    # Layer 0: directly from PIs
    layer_signals = list(pi_names)
    
    # Create multiple logic layers
    for layer in range(logic_depth):
        new_layer_signals = []
        num_gates_in_layer = max(num_dff // logic_depth, 50)
        
        for g in range(num_gates_in_layer):
            gate_type = random.choice(gate_types)
            
            # Choose random fanin (2-4)
            fanin = random.randint(2, min(4, len(layer_signals)))
            inputs = random.sample(layer_signals, fanin)
            
            output_name = f"g{gate_id}_L{layer}"
            gate_id += 1
            
            lines.append(f"{output_name} = {gate_type}({', '.join(inputs)})")
            new_layer_signals.append(output_name)
            all_gates.append(output_name)
        
        # Add previous layer signals to available pool
        layer_signals = layer_signals + new_layer_signals
        
        # Keep layer signals from growing too large
        if len(layer_signals) > num_dff * 2:
            layer_signals = random.sample(layer_signals, num_dff * 2)
    
    lines.append("")
    lines.append("# DFFs")
    
    # Create DFFs - each DFF takes input from logic layer
    for i, dff_out in enumerate(dff_outputs):
        if layer_signals:
            d_input = random.choice(layer_signals)
        else:
            d_input = random.choice(pi_names)
        
        lines.append(f"{dff_out} = DFF({d_input})")
        available_signals.append(dff_out)
    
    lines.append("")
    lines.append("# Feedback and Output Logic")
    
    # Create logic from DFF outputs (feedback paths and to POs)
    feedback_signals = list(dff_outputs)
    
    # Create some feedback logic
    num_feedback_gates = num_dff // 2
    for g in range(num_feedback_gates):
        gate_type = random.choice(gate_types)
        
        fanin = random.randint(2, min(3, len(feedback_signals)))
        inputs = random.sample(feedback_signals, fanin)
        
        output_name = f"fb{g}"
        gate_id += 1
        
        lines.append(f"{output_name} = {gate_type}({', '.join(inputs)})")
        feedback_signals.append(output_name)
        all_gates.append(output_name)
    
    lines.append("")
    lines.append("# Primary Output Drivers")
    
    # Connect to primary outputs
    for i, po in enumerate(po_names):
        if feedback_signals:
            src = random.choice(feedback_signals)
        else:
            src = random.choice(dff_outputs)
        
        lines.append(f"{po} = BUF({src})")
    
    lines.append("")
    
    # Statistics
    total_gates = gate_id + num_dff + num_po
    lines.append(f"# Statistics:")
    lines.append(f"# Total Gates: {total_gates}")
    lines.append(f"# Combinational Gates: {len(all_gates)}")
    lines.append(f"# DFFs: {num_dff}")
    lines.append(f"# Estimated Scan Chains (balanced): {num_dff // 50} to {num_dff // 20}")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description='Generate synthetic test circuits for DFT/ATPG evaluation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate 1000 DFF circuit (good for 20 chains)
  %(prog)s --num-dff 1000 -o test_1k.bench
  
  # Generate 2000 DFF circuit (good for 40 chains)
  %(prog)s --num-dff 2000 -o test_2k.bench
  
  # Multi-clock domain (4 domains, 500 DFF)
  %(prog)s --num-dff 500 --clock-domains 4 -o multi_clk.bench
  
  # Deep logic circuit
  %(prog)s --num-dff 1000 --depth 10 -o deep_logic.bench
"""
    )
    
    parser.add_argument('--num-dff', '-d', type=int, default=1000,
                       help='Number of DFFs (default: 1000)')
    parser.add_argument('--num-pi', type=int, default=32,
                       help='Number of primary inputs (default: 32)')
    parser.add_argument('--num-po', type=int, default=16,
                       help='Number of primary outputs (default: 16)')
    parser.add_argument('--depth', type=int, default=5,
                       help='Combinational logic depth (default: 5)')
    parser.add_argument('--clock-domains', '-c', type=int, default=1,
                       help='Number of clock domains (default: 1)')
    parser.add_argument('--seed', type=int, default=42,
                       help='Random seed for reproducibility')
    parser.add_argument('--output', '-o', required=True,
                       help='Output BENCH file')
    
    args = parser.parse_args()
    
    print(f"Generating synthetic circuit:")
    print(f"  DFFs: {args.num_dff}")
    print(f"  Primary Inputs: {args.num_pi}")
    print(f"  Primary Outputs: {args.num_po}")
    print(f"  Logic Depth: {args.depth}")
    print(f"  Clock Domains: {args.clock_domains}")
    
    circuit = generate_circuit(
        num_dff=args.num_dff,
        num_pi=args.num_pi,
        num_po=args.num_po,
        logic_depth=args.depth,
        clock_domains=args.clock_domains,
        seed=args.seed
    )
    
    with open(args.output, 'w') as f:
        f.write(circuit)
    
    print(f"\nGenerated: {args.output}")
    
    # Print recommended test parameters
    recommended_chains = args.num_dff // 50
    print(f"\nRecommended test commands:")
    print(f"  # Single chain (baseline)")
    print(f"  python scan_insert.py {args.output} -o test_out --num-chains 1")
    print(f"  ")
    print(f"  # {recommended_chains} chains (balanced)")
    print(f"  python scan_insert.py {args.output} -o test_out --num-chains {recommended_chains}")
    print(f"  ")
    print(f"  # {recommended_chains * 2} chains (more parallel)")
    print(f"  python scan_insert.py {args.output} -o test_out --num-chains {recommended_chains * 2}")
    print(f"  ")
    print(f"  # With EDT compression")
    print(f"  python scan_insert.py {args.output} -o test_out --num-chains {recommended_chains} --enable-edt")


if __name__ == "__main__":
    main()
