#!/bin/bash
#============================================================================
# Verilator Build and Run Script with Coverage
# 1.2Tbps 48x25G L2 Switch Core
#============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 默认参数
BUILD_DIR="obj_dir"
TRACE=0
COVERAGE=0
QUICK=0
CLEAN=0

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --trace)
            TRACE=1
            shift
            ;;
        --coverage)
            COVERAGE=1
            shift
            ;;
        --quick)
            QUICK=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --trace      Enable VCD waveform dump"
            echo "  --coverage   Enable code coverage collection"
            echo "  --quick      Run quick test only"
            echo "  --clean      Clean build directory first"
            echo "  --help       Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# 清理
if [ $CLEAN -eq 1 ]; then
    echo "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

# 构建Verilator选项
VERILATOR_OPTS="--cc --exe --build --timing -j 4"
VERILATOR_OPTS="$VERILATOR_OPTS -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-PINCONNECTEMPTY"
VERILATOR_OPTS="$VERILATOR_OPTS -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC"
VERILATOR_OPTS="$VERILATOR_OPTS -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN"

if [ $TRACE -eq 1 ]; then
    VERILATOR_OPTS="$VERILATOR_OPTS --trace"
    echo "Trace: ENABLED"
fi

if [ $COVERAGE -eq 1 ]; then
    VERILATOR_OPTS="$VERILATOR_OPTS --coverage"
    echo "Coverage: ENABLED"
fi

echo "============================================"
echo "Building 1.2Tbps Switch Core Simulation"
echo "============================================"

# 编译
verilator $VERILATOR_OPTS \
    -f filelist.f \
    sim_main.cpp \
    --top-module switch_core \
    --Mdir "$BUILD_DIR"

echo ""
echo "Build complete!"
echo ""

# 运行
echo "============================================"
echo "Running Simulation"
echo "============================================"

RUN_OPTS=""
if [ $TRACE -eq 1 ]; then
    RUN_OPTS="$RUN_OPTS --trace"
fi
if [ $QUICK -eq 1 ]; then
    RUN_OPTS="$RUN_OPTS --quick"
fi

"./$BUILD_DIR/Vswitch_core" $RUN_OPTS

# 覆盖率报告
if [ $COVERAGE -eq 1 ] && [ -f "coverage.dat" ]; then
    echo ""
    echo "============================================"
    echo "Coverage Report"
    echo "============================================"
    
    # 生成覆盖率报告 (如果verilator_coverage可用)
    if command -v verilator_coverage &> /dev/null; then
        verilator_coverage --annotate coverage_annotate coverage.dat
        echo "Coverage annotation written to: coverage_annotate/"
        
        # 生成汇总报告
        verilator_coverage --rank coverage.dat > coverage_summary.txt
        echo "Coverage summary written to: coverage_summary.txt"
        cat coverage_summary.txt
    else
        echo "verilator_coverage not found, skipping report generation"
        echo "Coverage data available in: coverage.dat"
    fi
fi

echo ""
echo "Simulation complete!"
