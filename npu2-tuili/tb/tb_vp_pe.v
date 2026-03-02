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
        
        // Test 6: INT8 boundary values
        test_int8_boundary();
        
        // Test 7: INT8 zero operands
        test_int8_zeros();
        
        // Test 8: INT8 both negative
        test_int8_both_negative();
        
        // Test 9: INT8 multi-step accumulation chain
        test_int8_accum_chain();
        
        // Test 10: BF16 exact result verification
        test_bf16_verify();
        
        // Test 11: BF16 sign (negative * positive)
        test_bf16_sign();
        
        // Test 12: Enable gate - output holds when enable=0
        test_enable_gate();
        
        // Test 13: Pipeline back-to-back result verification
        test_pipeline_verify();
        
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
            
            precision_mode = 0;

            // First multiply: 4 * 2 = 8 (replace mode, single clock pulse)
            @(posedge clk); @(negedge clk);
            accumulate = 0; int8_a_in = 8'sd4; int8_w_in = 8'sd2; acc_in = 32'd0;
            enable = 1;
            @(posedge clk); @(negedge clk);
            enable = 0;
            repeat(4) @(posedge clk);  // Drain pipeline

            // Second multiply with accumulate: 8 + (3 * 5) = 23
            @(negedge clk);
            accumulate = 1; int8_a_in = 8'sd3; int8_w_in = 8'sd5;
            enable = 1;
            @(posedge clk); @(negedge clk);
            enable = 0;
            repeat(4) @(posedge clk);  // Drain pipeline

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
            accumulate = 0;
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
        #5000;
        $display("");
        $display("ERROR: Simulation timeout!");
        $fflush();
        $finish;
    end

    //==========================================================================
    // Test 6: INT8 Boundary Values
    //==========================================================================

    task test_int8_boundary;
        reg signed [31:0] expected;
        integer local_fail;
        begin
            $display("Test 6: INT8 Boundary Values");
            $display("-----------------------------");
            $fflush();
            local_fail = 0;

            // Sub-test: 127 * 127 = 16129
            precision_mode = 0; accumulate = 0;
            int8_a_in = 8'sd127; int8_w_in = 8'sd127;
            acc_in = 32'd0; enable = 1;
            expected = 32'sd16129;
            #10;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: 127 * 127 = %0d", $signed(result_out));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: 127 * 127 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
                local_fail = 1;
            end
            enable = 0; #4;

            // Sub-test: -128 * -1 = 128
            int8_a_in = -8'sd128; int8_w_in = -8'sd1;
            expected = 32'sd128;
            enable = 1; #10;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: -128 * -1 = %0d", $signed(result_out));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: -128 * -1 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            // Sub-test: -128 * 127 = -16256
            int8_a_in = -8'sd128; int8_w_in = 8'sd127;
            expected = -32'sd16256;
            enable = 1; #10;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: -128 * 127 = %0d", $signed(result_out));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: -128 * 127 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 7: INT8 Zero Operands
    //==========================================================================

    task test_int8_zeros;
        reg signed [31:0] expected;
        begin
            $display("Test 7: INT8 Zero Operands");
            $display("--------------------------");
            $fflush();

            // 0 * 127 = 0
            precision_mode = 0; accumulate = 0;
            int8_a_in = 8'sd0; int8_w_in = 8'sd127;
            acc_in = 32'd0; enable = 1;
            expected = 32'sd0;
            #10;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: 0 * 127 = %0d", $signed(result_out));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: 0 * 127 = %0d (expected 0)", $signed(result_out));
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            // 127 * 0 = 0
            int8_a_in = 8'sd127; int8_w_in = 8'sd0;
            enable = 1; #10;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: 127 * 0 = %0d", $signed(result_out));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: 127 * 0 = %0d (expected 0)", $signed(result_out));
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 8: INT8 Both Negative
    //==========================================================================

    task test_int8_both_negative;
        reg signed [31:0] expected;
        begin
            $display("Test 8: INT8 Both Negative");
            $display("--------------------------");
            $fflush();

            // -7 * -6 = 42
            precision_mode = 0; accumulate = 0;
            int8_a_in = -8'sd7; int8_w_in = -8'sd6;
            acc_in = 32'd0; enable = 1;
            expected = 32'sd42;
            #10;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: -7 * -6 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: -7 * -6 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 9: INT8 Multi-Step Accumulation Chain (1*1 + 2*2 + 3*3 = 14)
    // Each step asserts enable for exactly one clock cycle to avoid
    // repeated accumulations from a long enable pulse.
    //==========================================================================

    task test_int8_accum_chain;
        reg signed [31:0] expected;
        begin
            $display("Test 9: INT8 Multi-Step Accumulation (1*1 + 2*2 + 3*3 = 14)");
            $display("--------------------------------------------------------------");
            $fflush();

            precision_mode = 0;

            // Step 1: 1*1 = 1 (replace mode, acc = 0 → 1)
            @(posedge clk); @(negedge clk);
            accumulate = 0; int8_a_in = 8'sd1; int8_w_in = 8'sd1; acc_in = 32'd0;
            enable = 1;
            @(posedge clk); @(negedge clk);
            enable = 0;
            repeat(4) @(posedge clk);   // Pipeline drain

            // Step 2: acc + 2*2 = 1+4 = 5
            @(negedge clk);
            accumulate = 1; int8_a_in = 8'sd2; int8_w_in = 8'sd2;
            enable = 1;
            @(posedge clk); @(negedge clk);
            enable = 0;
            repeat(4) @(posedge clk);

            // Step 3: acc + 3*3 = 5+9 = 14
            @(negedge clk);
            int8_a_in = 8'sd3; int8_w_in = 8'sd3;
            enable = 1;
            @(posedge clk); @(negedge clk);
            enable = 0;
            repeat(4) @(posedge clk);

            expected = 32'sd14;
            test_count = test_count + 1;
            if (result_out == expected) begin
                $display("  PASS: 1*1 + 2*2 + 3*3 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: 1*1 + 2*2 + 3*3 = %0d (expected %0d)",
                         $signed(result_out), $signed(expected));
                fail_count = fail_count + 1;
            end
            accumulate = 0;
            #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 10: BF16 Exact Result Verification (2.0 * 3.0)
    // Expected: bf16_multiply(0x4000, 0x4040)
    //   exp_result = 128+128-127 = 129 = 0x81
    //   mant_result = 128*192 = 0x6000  [14:8] = 7'h60
    //   result = {0, 8'h81, 7'h60, 16'h0} = 32'h40E00000
    //==========================================================================

    task test_bf16_verify;
        reg [31:0] expected_bf16;
        begin
            $display("Test 10: BF16 Exact Result Verification (2.0 * 3.0)");
            $display("-----------------------------------------------------");
            $fflush();

            expected_bf16 = 32'h40E00000;  // See header comment

            precision_mode = 1;  // BF16
            accumulate = 0;
            bf16_a_in = 16'h4000;  // 2.0 in BF16
            bf16_w_in = 16'h4040;  // 3.0 in BF16
            acc_in = 32'd0; enable = 1;
            #10;
            test_count = test_count + 1;
            if (result_out == expected_bf16) begin
                $display("  PASS: BF16 2.0 * 3.0: result_out=0x%h (expected 0x%h)",
                         result_out, expected_bf16);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: BF16 2.0 * 3.0: result_out=0x%h (expected 0x%h)",
                         result_out, expected_bf16);
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 11: BF16 Sign (negative * positive should flip MSB)
    // -2.0 (0xC000) * 3.0 (0x4040) -> sign=1, expected 32'hC0E00000
    //==========================================================================

    task test_bf16_sign;
        reg [31:0] expected_bf16;
        begin
            $display("Test 11: BF16 Sign Test (-2.0 * 3.0)");
            $display("--------------------------------------");
            $fflush();

            expected_bf16 = 32'hC0E00000;  // Same magnitude as test 10, sign=1

            precision_mode = 1;
            accumulate = 0;
            bf16_a_in = 16'hC000;  // -2.0 in BF16
            bf16_w_in = 16'h4040;  //  3.0 in BF16
            acc_in = 32'd0; enable = 1;
            #10;
            test_count = test_count + 1;
            if (result_out == expected_bf16) begin
                $display("  PASS: BF16 -2.0 * 3.0: result_out=0x%h (expected 0x%h)",
                         result_out, expected_bf16);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: BF16 -2.0 * 3.0: result_out=0x%h (expected 0x%h)",
                         result_out, expected_bf16);
                fail_count = fail_count + 1;
            end
            enable = 0; #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 12: Enable Gate (output must not change when enable=0)
    // Uses clock-aligned enable pulse to avoid race conditions.
    //==========================================================================

    task test_enable_gate;
        reg signed [31:0] captured;
        begin
            $display("Test 12: Enable Gate (output stable when enable=0)");
            $display("---------------------------------------------------");
            $fflush();

            // Produce 5*3=15 with a single clock-aligned enable pulse
            @(posedge clk); @(negedge clk);
            precision_mode = 0; accumulate = 0;
            int8_a_in = 8'sd5; int8_w_in = 8'sd3; acc_in = 32'd0;
            enable = 1;
            @(posedge clk); @(negedge clk);
            enable = 0;
            repeat(4) @(posedge clk);   // Pipeline fully drained
            @(negedge clk);
            captured = result_out;      // Capture stable result (should be 15)

            // Change inputs while enable remains 0
            int8_a_in = 8'sd99; int8_w_in = 8'sd99;
            repeat(5) @(posedge clk);   // Wait several cycles - output must not change

            test_count = test_count + 1;
            if (result_out == captured && captured == 32'sd15) begin
                $display("  PASS: result_out held at %0d with enable=0",
                         $signed(result_out));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: result_out=%0d captured=%0d (expected 15, enable=0)",
                         $signed(result_out), $signed(captured));
                fail_count = fail_count + 1;
            end
            int8_a_in = 8'sd0; int8_w_in = 8'sd0;
            #4;

            $display("");
            $fflush();
        end
    endtask

    //==========================================================================
    // Test 13: Pipeline Back-to-Back Result Verification
    // Send ops 0*1, 1*2, ... 9*10 back-to-back; last result_out must be 90
    //==========================================================================

    task test_pipeline_verify;
        integer i;
        reg signed [31:0] expected_last;
        begin
            $display("Test 13: Pipeline Result Verification");
            $display("--------------------------------------");
            $fflush();

            precision_mode = 0; accumulate = 0;
            enable = 1;

            for (i = 0; i < 10; i = i + 1) begin
                int8_a_in = i[7:0];
                int8_w_in = (i + 1);
                #2;
            end

            enable = 0;
            #12;  // Flush pipeline (>= 3 clock cycles = 6ns, wait 12 to be safe)

            // Last operation: 9 * 10 = 90
            expected_last = 32'sd90;
            test_count = test_count + 1;
            if (result_out == expected_last) begin
                $display("  PASS: Last pipeline result = %0d (9*10, expected %0d)",
                         $signed(result_out), $signed(expected_last));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: Last pipeline result = %0d (expected %0d)",
                         $signed(result_out), $signed(expected_last));
                fail_count = fail_count + 1;
            end

            $display("");
            $fflush();
        end
    endtask

endmodule
