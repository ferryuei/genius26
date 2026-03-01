// Verilator C++ wrapper with proper clock driving
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
    tfp->open("waves/tb_npu_top.vcd");
    
    // Run simulation with clock driving
    // Time unit: 1 time unit = 1 ps (to match Verilog timescale 1ns/1ps)
    // Clock period = 1.667 ns = 1667 ps = 1667 time units
    vluint64_t sim_time = 0;
    const vluint64_t max_sim_time = 100000000; // 100M ps = 100 ms
    
    // Initialize clock
    top->clk = 0;
    
    // Set context time for proper $time in Verilog
    Verilated::time(sim_time);
    
    while (!Verilated::gotFinish() && sim_time < max_sim_time) {
        // Toggle clock every 833.5 ps (half of 1.667ns period)
        // Simplified: toggle every 834 time units
        bool prev_clk = top->clk;
        if ((sim_time % 1667) < 834) {
            top->clk = 0;
        } else {
            top->clk = 1;
        }
        
        // Update context time
        Verilated::time(sim_time);
        
        // Evaluate model
        top->eval();
        
        // Dump trace
        tfp->dump(sim_time);
        
        // Flush trace periodically to see progress
        if (sim_time % 100000 == 0) {
            tfp->flush();
        }
        
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
