// Verilator C++ wrapper with proper initialization
#include "Vtb_npu_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <iostream>

int main(int argc, char** argv) {
    // Initialize Verilator
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    
    // Unbuffer stdout for immediate output
    std::cout.setf(std::ios::unitbuf);
    
    // Create DUT
    Vtb_npu_top* top = new Vtb_npu_top;
    
    // Initialize trace (always enable for debugging)
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("run/waves/tb_npu_top.vcd");
    
    // Run simulation
    vluint64_t sim_time = 0;
    while (!Verilated::gotFinish() && sim_time < 1000000) {
        top->eval();
        tfp->dump(sim_time);
        sim_time++;
    }
    
    // Cleanup
    tfp->close();
    delete tfp;
    delete top;
    
    // Explicit return code
    return Verilated::gotFinish() ? 0 : 1;
}
