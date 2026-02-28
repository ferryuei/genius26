#!/bin/bash
# =============================================================================
# Simulation Script for Switch1T Testbenches
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directories
RTL_DIR="../rtl"
TB_DIR="."
SIM_DIR="../sim"

# Create sim directory if it doesn't exist
mkdir -p $SIM_DIR

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Function to run a test
run_test() {
    local testname=$1
    local toplevel=$2
    
    print_info "=========================================="
    print_info "Running test: $testname"
    print_info "=========================================="
    
    cd $SIM_DIR
    
    # Compile with Verilator
    print_info "Compiling with Verilator..."
    verilator --binary --trace \
        -Wall -Wno-fatal \
        --top-module $toplevel \
        -I$RTL_DIR \
        $RTL_DIR/switch_pkg.sv \
        $RTL_DIR/mac_table.sv \
        $TB_DIR/$testname.sv \
        2>&1 | tee ${testname}_compile.log
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        print_info "Compilation successful"
        
        # Run simulation
        print_info "Running simulation..."
        if [ -f "./obj_dir/V$toplevel" ]; then
            ./obj_dir/V$toplevel 2>&1 | tee ${testname}_sim.log
            
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                print_info "Simulation completed"
                
                # Check for test results
                if grep -q "PASSED" ${testname}_sim.log; then
                    print_info "${GREEN}TEST PASSED${NC}"
                    return 0
                elif grep -q "FAILED" ${testname}_sim.log; then
                    print_error "${RED}TEST FAILED${NC}"
                    return 1
                else
                    print_warning "Test result unclear"
                    return 2
                fi
            else
                print_error "Simulation failed"
                return 1
            fi
        else
            print_error "Executable not found"
            return 1
        fi
    else
        print_error "Compilation failed"
        return 1
    fi
    
    cd - > /dev/null
}

# Main execution
main() {
    print_info "Switch1T Simulation Suite"
    print_info "=========================================="
    
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    # Test 1: MAC Table
    print_info "\n--- Test 1: MAC Table ---"
    total_tests=$((total_tests + 1))
    if run_test "tb_mac_table" "tb_mac_table"; then
        passed_tests=$((passed_tests + 1))
    else
        failed_tests=$((failed_tests + 1))
    fi
    
    # Summary
    print_info ""
    print_info "=========================================="
    print_info "Simulation Summary"
    print_info "=========================================="
    print_info "Total tests:  $total_tests"
    print_info "Passed tests: $passed_tests"
    print_info "Failed tests: $failed_tests"
    print_info "=========================================="
    
    if [ $failed_tests -eq 0 ]; then
        print_info "${GREEN}ALL TESTS PASSED!${NC}"
        exit 0
    else
        print_error "${RED}SOME TESTS FAILED!${NC}"
        exit 1
    fi
}

# Run main
main
