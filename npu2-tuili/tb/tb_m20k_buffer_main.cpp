// Verilator C++ wrapper with proper initialization
#include "Vtb_m20k_buffer.h"
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
    Vtb_m20k_buffer* top = new Vtb_m20k_buffer;
    
    // Initialize trace (always enable for debugging)
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("run/waves/tb_m20k_buffer.vcd");
    
    // Run simulation
    vluint64_t sim_time = 0;
    while (!Verilated::gotFinish() && sim_time < 500000) {
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
