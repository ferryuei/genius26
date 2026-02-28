#!/usr/bin/env python3
"""
ATPG Performance Benchmark - 比较原始版本和优化版本

Usage:
    python atpg_benchmark.py <bench_file> [--max-patterns N] [--target-coverage N]
"""

import sys
import os
import time
import argparse

# 添加软件目录到路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from atpg import Circuit, NetlistParser, ATPG
from atpg_optimized import OptimizedATPG, HAS_NUMBA


def benchmark_original(circuit, max_patterns: int, target_coverage: float):
    """测试原始ATPG"""
    print("\n" + "="*60)
    print("ORIGINAL ATPG")
    print("="*60)
    
    start = time.time()
    
    atpg = ATPG(algorithm="auto")
    atpg.circuit = circuit
    atpg.generate_faults(collapse=True)
    atpg.run_atpg(max_patterns=max_patterns, target_coverage=target_coverage, use_parallel=False)
    
    elapsed = time.time() - start
    
    detected = len([f for f in atpg.faults if f.detected])
    total = len(atpg.faults)
    coverage = detected / total * 100 if total > 0 else 0
    
    return {
        'time': elapsed,
        'patterns': len(atpg.patterns),
        'detected': detected,
        'total': total,
        'coverage': coverage
    }


def benchmark_optimized(circuit, max_patterns: int, target_coverage: float):
    """测试优化ATPG"""
    print("\n" + "="*60)
    print("OPTIMIZED ATPG")
    print("="*60)
    
    start = time.time()
    
    atpg = OptimizedATPG(circuit)
    patterns, coverage = atpg.run(max_patterns=max_patterns, target_coverage=target_coverage)
    
    elapsed = time.time() - start
    
    detected = int(atpg.detected.sum())
    total = len(atpg.fault_list)
    
    return {
        'time': elapsed,
        'patterns': len(patterns),
        'detected': detected,
        'total': total,
        'coverage': coverage
    }


def main():
    parser = argparse.ArgumentParser(description='ATPG Performance Benchmark')
    parser.add_argument('bench_file', help='Input BENCH file')
    parser.add_argument('--max-patterns', '-n', type=int, default=100,
                       help='Maximum test patterns (default: 100)')
    parser.add_argument('--target-coverage', '-c', type=float, default=90.0,
                       help='Target coverage %% (default: 90)')
    parser.add_argument('--skip-original', action='store_true',
                       help='Skip original ATPG benchmark')
    
    args = parser.parse_args()
    
    print("="*60)
    print("ATPG PERFORMANCE BENCHMARK")
    print("="*60)
    print(f"Input: {args.bench_file}")
    print(f"Max patterns: {args.max_patterns}")
    print(f"Target coverage: {args.target_coverage}%")
    print(f"Numba JIT: {'Enabled' if HAS_NUMBA else 'Disabled'}")
    
    # 加载电路
    print("\nLoading circuit...")
    circuit = NetlistParser.parse_bench(args.bench_file)
    print(f"  Inputs: {len(circuit.inputs)}")
    print(f"  Outputs: {len(circuit.outputs)}")
    print(f"  Gates: {len(circuit.gates)}")
    
    results = {}
    
    # 运行优化版本
    results['optimized'] = benchmark_optimized(circuit, args.max_patterns, args.target_coverage)
    
    # 运行原始版本 (如果不跳过)
    if not args.skip_original:
        results['original'] = benchmark_original(circuit, args.max_patterns, args.target_coverage)
    
    # 比较结果
    print("\n" + "="*60)
    print("BENCHMARK RESULTS")
    print("="*60)
    
    print(f"\n{'Metric':<20} {'Optimized':>15}", end='')
    if 'original' in results:
        print(f" {'Original':>15} {'Speedup':>10}")
    else:
        print()
    
    print("-"*60)
    
    opt = results['optimized']
    print(f"{'Time (s)':<20} {opt['time']:>15.2f}", end='')
    if 'original' in results:
        orig = results['original']
        speedup = orig['time'] / opt['time'] if opt['time'] > 0 else 0
        print(f" {orig['time']:>15.2f} {speedup:>9.1f}x")
    else:
        print()
    
    print(f"{'Patterns':<20} {opt['patterns']:>15}", end='')
    if 'original' in results:
        print(f" {orig['patterns']:>15}")
    else:
        print()
    
    print(f"{'Coverage (%)':<20} {opt['coverage']:>15.1f}", end='')
    if 'original' in results:
        print(f" {orig['coverage']:>15.1f}")
    else:
        print()
    
    print(f"{'Detected/Total':<20} {opt['detected']}/{opt['total']:>10}", end='')
    if 'original' in results:
        print(f" {orig['detected']}/{orig['total']:>10}")
    else:
        print()
    
    print("="*60)
    
    if not HAS_NUMBA:
        print("\nTIP: Install Numba for additional 10-100x speedup:")
        print("  pip install numba")


if __name__ == "__main__":
    main()
