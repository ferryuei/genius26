// Verilator C++ wrapper with proper clock driving
#include "Vtb_vp_pe.h"
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
    Vtb_vp_pe* top = new Vtb_vp_pe;
    
    // Initialize trace (always enable for debugging)
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("waves/tb_vp_pe.vcd");
    
    // Run simulation with clock driving
    vluint64_t sim_time = 0;
    const vluint64_t max_sim_time = 200000; // 200K time units
    
    while (!Verilated::gotFinish() && sim_time < max_sim_time) {
        // Toggle clock every time unit
        if ((sim_time % 2) == 0) {
            top->clk = 0;
        } else {
            top->clk = 1;
        }
        
        // Evaluate model
        top->eval();
        
        // Dump trace
        tfp->dump(sim_time);
        
        sim_time++;
    }
    
    // Check if simulation finished normally
    if (!Verilated::gotFinish()) {
        std::cout << "\nWARNING: Simulation reached maximum time without $finish\n";
    }
    
    // Cleanup
    tfp->close();
    delete tfp;
    delete top;
    
    // Explicit return code
    return Verilated::gotFinish() ? 0 : 1;
}
