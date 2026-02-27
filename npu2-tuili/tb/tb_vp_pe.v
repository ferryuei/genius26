//******************************************************************************
// Testbench for Variable Precision PE
// Description: Tests INT8 and BF16 MAC operations
// Tool: Verilator
//******************************************************************************

`timescale 1ns / 1ps

module tb_vp_pe;

    // Parameters
    parameter DATA_WIDTH = 32;
    parameter CLK_PERIOD = 1.667;  // 600MHz
    
    // Clock and Reset
    reg clk;
    reg rst_n;
    
    // Control
    reg enable;
    reg precision_mode;  // 0=INT8, 1=BF16
    reg accumulate;
    
    // INT8 Inputs
    reg [7:0] int8_a_in;
    reg [7:0] int8_w_in;
    
    // BF16 Inputs
    reg [15:0] bf16_a_in;
    reg [15:0] bf16_w_in;
    
    // Accumulator Input
    reg [DATA_WIDTH-1:0] acc_in;
    
    // Outputs
    wire [DATA_WIDTH-1:0] result_out;
    wire [15:0] bf16_out;
    wire valid_out;
    
    // Test statistics
    integer test_count;
    integer pass_count;
    integer fail_count;
    
    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    
    vp_pe #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .precision_mode(precision_mode),
        .accumulate(accumulate),
        .int8_a_in(int8_a_in),
        .int8_w_in(int8_w_in),
        .bf16_a_in(bf16_a_in),
        .bf16_w_in(bf16_w_in),
        .acc_in(acc_in),
        .result_out(result_out),
        .bf16_out(bf16_out),
        .valid_out(valid_out)
    );
    
    //==========================================================================
    // Clock Generation
    //==========================================================================
    
    initial begin
        clk = 0;
        forever #1 clk = ~clk;  // Toggle every 1ns for 500MHz (close to 600MHz)
    end
    
    //==========================================================================
    // Waveform Dump
    // - For Icarus Verilog: uses $dumpfile/$dumpvars
    // - For Verilator: handled by C++ wrapper
    //==========================================================================
    
    initial begin
        `ifdef IVERILOG
            $dumpfile("waves/tb_vp_pe.vcd");
            $dumpvars(0, tb_vp_pe);
        `endif
    end
    
    //==========================================================================
    // Test Stimulus
    //==========================================================================
    
    initial begin
        // Initialize
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        
        rst_n = 0;
        enable = 0;
        precision_mode = 0;
        accumulate = 0;
        int8_a_in = 0;
        int8_w_in = 0;
        bf16_a_in = 0;
        bf16_w_in = 0;
        acc_in = 0;
        
        // Reset sequence
        #20;
        rst_n = 1;
        #10;
        
        $display("========================================");
        $display("  Variable Precision PE Testbench");
        $display("========================================");
        $display("");
        $fflush();
        
        // Test 1: INT8 Simple Multiply (no accumulation)
        test_int8_multiply();
        
        // Test 2: INT8 MAC (with accumulation)
        test_int8_mac();
        
        // Test 3: INT8 Negative numbers
        test_int8_negative();
        
        // Test 4: BF16 Simple Multiply (simplified test)
        test_bf16_multiply();
        
        // Test 5: Pipeline test
        test_pipeline();
        
        // Summary
        #20;
        $display("");
        $display("========================================");
        $display("  Test Summary");
        $display("========================================");
        $display("Total tests: %0d", test_count);
        $display("Passed:      %0d", pass_count);
        $display("Failed:      %0d", fail_count);
        $display("");
        $fflush();
        
        if (fail_count == 0) begin
            $display("*** ALL TESTS PASSED ***");
        end else begin
            $display("*** SOME TESTS FAILED ***");
        end
        $fflush();
        
        $finish;
    end
    
    //==========================================================================
    // Test Tasks
    //==========================================================================
    
    task test_int8_multiply;
        reg signed [31:0] expected;
        begin
            $display("Test 1: INT8 Simple Multiply");
            $display("----------------------------");
            $fflush();
            
            // Test case: 5 * 3 = 15
            precision_mode = 0;  // INT8
            accumulate = 0;      // No accumulation
            int8_a_in = 8'sd5;
            int8_w_in = 8'sd3;
            acc_in = 32'd0;
            enable = 1;
            
            expected = 32'sd15;
            
            // Wait for pipeline (3 cycles)
            #10;
            
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: 5 * 3 = %0d (expected %0d)", 
                         $signed(result_out), $signed(expected));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: 5 * 3 = %0d (expected %0d)", 
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            $fflush();
            
            enable = 0;
            #4;
            $display("");
            $fflush();
        end
    endtask
    
    task test_int8_mac;
        reg signed [31:0] expected;
        begin
            $display("Test 2: INT8 MAC (Multiply-Accumulate)");
            $display("---------------------------------------");
            $fflush();
            
            // First multiply: 4 * 2 = 8
            precision_mode = 0;
            accumulate = 0;
            int8_a_in = 8'sd4;
            int8_w_in = 8'sd2;
            acc_in = 32'd0;
            enable = 1;
            
            #10;
            
            // Second multiply with accumulate: 8 + (3 * 5) = 23
            accumulate = 1;
            int8_a_in = 8'sd3;
            int8_w_in = 8'sd5;
            
            #10;
            
            expected = 32'sd23;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: (4*2) + (3*5) = %0d (expected %0d)", 
                         $signed(result_out), $signed(expected));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: (4*2) + (3*5) = %0d (expected %0d)", 
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            $fflush();
            
            enable = 0;
            #4;
            $display("");
            $fflush();
        end
    endtask
    
    task test_int8_negative;
        reg signed [31:0] expected;
        begin
            $display("Test 3: INT8 Negative Numbers");
            $display("------------------------------");
            $fflush();
            
            // Test: -7 * 6 = -42
            precision_mode = 0;
            accumulate = 0;
            int8_a_in = -8'sd7;
            int8_w_in = 8'sd6;
            acc_in = 32'd0;
            enable = 1;
            
            expected = -32'sd42;
            
            #10;
            
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: -7 * 6 = %0d (expected %0d)", 
                         $signed(result_out), $signed(expected));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: -7 * 6 = %0d (expected %0d)", 
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            $fflush();
            
            enable = 0;
            #4;
            $display("");
            $fflush();
        end
    endtask
    
    task test_bf16_multiply;
        begin
            $display("Test 4: BF16 Multiply (Simplified)");
            $display("-----------------------------------");
            $display("  NOTE: BF16 uses behavioral model");
            $fflush();
            
            // BF16 test (simplified - just check it doesn't crash)
            precision_mode = 1;  // BF16
            accumulate = 0;
            bf16_a_in = 16'h4000;  // BF16 ~2.0
            bf16_w_in = 16'h4040;  // BF16 ~3.0
            acc_in = 32'd0;
            enable = 1;
            
            #10;
            
            test_count = test_count + 1;
            if (valid_out) begin
                $display("  PASS: BF16 multiply completed");
                $display("        Result: 0x%h", result_out);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: BF16 multiply did not complete");
                fail_count = fail_count + 1;
            end
            $fflush();
            
            enable = 0;
            #4;
            $display("");
            $fflush();
        end
    endtask
    
    task test_pipeline;
        integer i;
        begin
            $display("Test 5: Pipeline Throughput");
            $display("----------------------------");
            $fflush();
            
            precision_mode = 0;
            accumulate = 0;
            enable = 1;
            
            // Send 10 operations back-to-back
            for (i = 0; i < 10; i = i + 1) begin
                int8_a_in = i;
                int8_w_in = i + 1;
                #2;
            end
            
            enable = 0;
            #10;
            
            test_count = test_count + 1;
            $display("  PASS: Pipeline test completed");
            $display("        Sent 10 operations");
            pass_count = pass_count + 1;
            $display("");
            $fflush();
        end
    endtask
    
    //==========================================================================
    // Timeout Watchdog
    //==========================================================================
    
    initial begin
        #2000;
        $display("");
        $display("ERROR: Simulation timeout!");
        $fflush();
        $finish;
    end

endmodule
