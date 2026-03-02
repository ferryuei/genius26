//******************************************************************************
// Testbench for M20K Buffer
// Description: Tests dual-port memory operations
// Tool: Verilator
//******************************************************************************

`timescale 1ns / 1ps

module tb_m20k_buffer;

    // Parameters
    parameter ADDR_WIDTH = 10;  // Reduced for simulation
    parameter DATA_WIDTH = 32;
    parameter DEPTH = 1024;
    parameter CLK_PERIOD = 1.667;
    
    // Clock and Reset
    reg clk;
    reg rst_n;
    
    // Write Port
    reg [ADDR_WIDTH-1:0] waddr;
    reg [DATA_WIDTH-1:0] wdata;
    reg we;
    
    // Read Port
    reg [ADDR_WIDTH-1:0] raddr;
    wire [DATA_WIDTH-1:0] rdata;
    reg re;
    
    // Test statistics
    integer test_count;
    integer pass_count;
    integer fail_count;
    
    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    
    m20k_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .waddr(waddr),
        .wdata(wdata),
        .we(we),
        .raddr(raddr),
        .rdata(rdata),
        .re(re)
    );
    
    //==========================================================================
    // Clock Generation
    //==========================================================================
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    //==========================================================================
    // Waveform Dump
    // - For Icarus Verilog: uses $dumpfile/$dumpvars
    // - For Verilator: handled by C++ wrapper
    //==========================================================================
    
    initial begin
        `ifdef IVERILOG
            $dumpfile("waves/tb_m20k_buffer.vcd");
            $dumpvars(0, tb_m20k_buffer);
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
        waddr = 0;
        wdata = 0;
        we = 0;
        raddr = 0;
        re = 0;
        
        // Reset
        #(CLK_PERIOD * 10);
        rst_n = 1;
        #(CLK_PERIOD * 5);
        
        $display("========================================");
        $display("  M20K Buffer Testbench");
        $display("========================================");
        $display("");
        
        // Test 1: Single write and read
        test_single_write_read();
        
        // Test 2: Sequential write/read
        test_sequential_access();
        
        // Test 3: Simultaneous read/write (dual-port)
        test_dual_port();
        
        // Test 4: Read-after-write (1 cycle latency)
        test_read_after_write();
        
        // Test 5: Boundary addresses (addr 0 and max addr)
        test_boundary_addresses();
        
        // Test 6: Special data patterns
        test_data_patterns();
        
        // Test 7: Overwrite same address
        test_overwrite();
        
        // Test 8: Large sequential access (64 locations)
        test_large_sequential();
        
        // Test 9: Read-enable gate (rdata stable when re=0)
        test_re_gate();
        
        // Summary
        #(CLK_PERIOD * 10);
        $display("");
        $display("========================================");
        $display("  Test Summary");
        $display("========================================");
        $display("Total tests: %0d", test_count);
        $display("Passed:      %0d", pass_count);
        $display("Failed:      %0d", fail_count);
        $display("");
        
        if (fail_count == 0) begin
            $display("*** ALL TESTS PASSED ***");
        end else begin
            $display("*** SOME TESTS FAILED ***");
        end
        
        $finish;
    end
    
    //==========================================================================
    // Test Tasks
    //==========================================================================
    
    task test_single_write_read;
        reg [DATA_WIDTH-1:0] test_data;
        reg [ADDR_WIDTH-1:0] test_addr;
        begin
            $display("Test 1: Single Write and Read");
            $display("------------------------------");
            
            test_addr = 10'h100;
            test_data = 32'hDEADBEEF;
            
            // Write
            @(posedge clk);
            waddr <= test_addr;
            wdata <= test_data;
            we <= 1;
            
            @(posedge clk);
            we <= 0;
            
            // Wait a cycle
            @(posedge clk);
            
            // Read
            raddr <= test_addr;
            re <= 1;
            
            @(posedge clk);
            re <= 0;
            
            // Wait for read data (1 cycle latency)
            @(posedge clk);
            
            test_count = test_count + 1;
            if (rdata == test_data) begin
                $display("  PASS: Write 0x%h to addr 0x%h, read back 0x%h", 
                         test_data, test_addr, rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: Write 0x%h to addr 0x%h, read back 0x%h (expected 0x%h)", 
                         test_data, test_addr, rdata, test_data);
                fail_count = fail_count + 1;
            end
            
            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask
    
    task test_sequential_access;
        integer i;
        reg [DATA_WIDTH-1:0] expected;
        integer errors;
        begin
            $display("Test 2: Sequential Write/Read");
            $display("------------------------------");
            
            errors = 0;
            
            // Write 16 locations
            for (i = 0; i < 16; i = i + 1) begin
                @(posedge clk);
                waddr <= i[ADDR_WIDTH-1:0];
                wdata <= (i * 100);
                we <= 1;
            end
            
            @(posedge clk);
            we <= 0;
            #(CLK_PERIOD * 2);
            
            // Read back
            for (i = 0; i < 16; i = i + 1) begin
                @(posedge clk);
                raddr <= i[ADDR_WIDTH-1:0];
                re <= 1;
                
                @(posedge clk);
                @(posedge clk);  // Wait for read latency
                
                expected = (i * 100);
                if (rdata != expected) begin
                    $display("  ERROR at addr %0d: got 0x%h, expected 0x%h", 
                             i, rdata, expected);
                    errors = errors + 1;
                end
            end
            
            re <= 0;
            
            test_count = test_count + 1;
            if (errors == 0) begin
                $display("  PASS: 16 sequential writes and reads");
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0d errors in sequential access", errors);
                fail_count = fail_count + 1;
            end
            
            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask
    
    task test_dual_port;
        begin
            $display("Test 3: Dual-Port Simultaneous Access");
            $display("--------------------------------------");
            
            // Simultaneous write and read to different addresses
            @(posedge clk);
            waddr <= 10'h200;
            wdata <= 32'hCAFEBABE;
            we <= 1;
            raddr <= 10'h100;  // Read from previous test
            re <= 1;
            
            @(posedge clk);
            we <= 0;
            re <= 0;
            
            @(posedge clk);  // Wait for read latency
            
            test_count = test_count + 1;
            if (rdata == 32'hDEADBEEF) begin
                $display("  PASS: Dual-port access works");
                $display("        Read 0x%h while writing to different address", rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: Dual-port read failed");
                fail_count = fail_count + 1;
            end
            
            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask
    
    task test_read_after_write;
        begin
            $display("Test 4: Read-After-Write Latency");
            $display("---------------------------------");
            
            // Write
            @(posedge clk);
            waddr <= 10'h300;
            wdata <= 32'h12345678;
            we <= 1;
            
            // Immediately read same address
            @(posedge clk);
            we <= 0;
            raddr <= 10'h300;
            re <= 1;
            
            @(posedge clk);
            re <= 0;
            
            // Check after read latency
            @(posedge clk);
            
            test_count = test_count + 1;
            if (rdata == 32'h12345678) begin
                $display("  PASS: Read-after-write returns correct data");
                $display("        Data: 0x%h", rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: Read-after-write failed");
                $display("        Got 0x%h, expected 0x12345678", rdata);
                fail_count = fail_count + 1;
            end
            
            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask
    
    //==========================================================================
    // Timeout
    //==========================================================================
    
    initial begin
        #(CLK_PERIOD * 20000);
        $display("");
        $display("ERROR: Simulation timeout!");
        $finish;
    end

    //==========================================================================
    // Test 5: Boundary Addresses (addr 0 and max addr = DEPTH-1 = 10'h3FF)
    //==========================================================================

    task test_boundary_addresses;
        reg [DATA_WIDTH-1:0] test_data0, test_data_max;
        begin
            $display("Test 5: Boundary Addresses (addr 0 and max)");
            $display("--------------------------------------------");

            test_data0   = 32'hA5A5A5A5;
            test_data_max = 32'h5A5A5A5A;

            // Write to addr 0
            @(posedge clk); waddr <= 0; wdata <= test_data0; we <= 1;
            @(posedge clk); we <= 0;
            @(posedge clk);

            // Read from addr 0
            raddr <= 0; re <= 1;
            @(posedge clk); re <= 0;
            @(posedge clk);

            test_count = test_count + 1;
            if (rdata == test_data0) begin
                $display("  PASS: addr 0: write 0x%h, read back 0x%h", test_data0, rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: addr 0: write 0x%h, read back 0x%h", test_data0, rdata);
                fail_count = fail_count + 1;
            end

            // Write to max addr (DEPTH-1 = 10'h3FF)
            @(posedge clk); waddr <= {ADDR_WIDTH{1'b1}}; wdata <= test_data_max; we <= 1;
            @(posedge clk); we <= 0;
            @(posedge clk);

            // Read from max addr
            raddr <= {ADDR_WIDTH{1'b1}}; re <= 1;
            @(posedge clk); re <= 0;
            @(posedge clk);

            test_count = test_count + 1;
            if (rdata == test_data_max) begin
                $display("  PASS: addr 0x%h (max): write 0x%h, read back 0x%h",
                         {ADDR_WIDTH{1'b1}}, test_data_max, rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: addr 0x%h (max): write 0x%h, read back 0x%h",
                         {ADDR_WIDTH{1'b1}}, test_data_max, rdata);
                fail_count = fail_count + 1;
            end

            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask

    //==========================================================================
    // Test 6: Special Data Patterns
    //==========================================================================

    task test_data_patterns;
        reg [DATA_WIDTH-1:0] patterns [0:2];
        integer p;
        begin
            $display("Test 6: Special Data Patterns");
            $display("------------------------------");

            patterns[0] = 32'h00000000;  // All zeros
            patterns[1] = 32'hFFFFFFFF;  // All ones
            patterns[2] = 32'hAA55AA55;  // Alternating

            for (p = 0; p < 3; p = p + 1) begin
                // Write
                @(posedge clk);
                waddr <= 10'h010 + p;
                wdata <= patterns[p];
                we <= 1;
                @(posedge clk); we <= 0;
                @(posedge clk);

                // Read
                raddr <= 10'h010 + p; re <= 1;
                @(posedge clk); re <= 0;
                @(posedge clk);

                test_count = test_count + 1;
                if (rdata == patterns[p]) begin
                    $display("  PASS: pattern 0x%h at addr 0x%h", patterns[p], 10'h010 + p);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  FAIL: pattern 0x%h -> read 0x%h at addr 0x%h",
                             patterns[p], rdata, 10'h010 + p);
                    fail_count = fail_count + 1;
                end
            end

            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask

    //==========================================================================
    // Test 7: Overwrite Same Address
    //==========================================================================

    task test_overwrite;
        begin
            $display("Test 7: Overwrite Same Address");
            $display("-------------------------------");

            // First write
            @(posedge clk); waddr <= 10'h050; wdata <= 32'hDEADC0DE; we <= 1;
            @(posedge clk); we <= 0;
            @(posedge clk);

            // Overwrite with new value
            @(posedge clk); waddr <= 10'h050; wdata <= 32'hBAADF00D; we <= 1;
            @(posedge clk); we <= 0;
            @(posedge clk);

            // Read back - should see the second (overwritten) value
            raddr <= 10'h050; re <= 1;
            @(posedge clk); re <= 0;
            @(posedge clk);

            test_count = test_count + 1;
            if (rdata == 32'hBAADF00D) begin
                $display("  PASS: Overwrite: read 0x%h (latest written value)", rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: Overwrite: read 0x%h (expected 0xBAADF00D)", rdata);
                fail_count = fail_count + 1;
            end

            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask

    //==========================================================================
    // Test 8: Large Sequential Access (64 locations)
    //==========================================================================

    task test_large_sequential;
        integer i;
        reg [DATA_WIDTH-1:0] expected;
        integer errors;
        begin
            $display("Test 8: Large Sequential Access (64 locations)");
            $display("------------------------------------------------");

            errors = 0;

            // Write 64 locations starting at 0x060
            for (i = 0; i < 64; i = i + 1) begin
                @(posedge clk);
                waddr <= 10'h060 + i;
                wdata <= 32'hA0000000 | i;  // Distinctive pattern per address
                we <= 1;
            end
            @(posedge clk); we <= 0;
            #(CLK_PERIOD * 2);

            // Read back all 64 and verify
            for (i = 0; i < 64; i = i + 1) begin
                @(posedge clk); raddr <= 10'h060 + i; re <= 1;
                @(posedge clk); @(posedge clk); // 1-cycle read latency + margin

                expected = 32'hA0000000 | i;
                if (rdata != expected) begin
                    $display("  ERROR at addr 0x%h: got 0x%h, expected 0x%h",
                             10'h060 + i, rdata, expected);
                    errors = errors + 1;
                end
            end
            re <= 0;

            test_count = test_count + 1;
            if (errors == 0) begin
                $display("  PASS: 64 sequential writes and reads verified");
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0d errors in 64-location sequential access", errors);
                fail_count = fail_count + 1;
            end

            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask

    //==========================================================================
    // Test 9: Read-Enable Gate (rdata stable when re=0)
    //==========================================================================

    task test_re_gate;
        reg [DATA_WIDTH-1:0] captured;
        begin
            $display("Test 9: Read-Enable Gate (rdata stable when re=0)");
            $display("--------------------------------------------------");

            // Write known data to two addresses
            @(posedge clk); waddr <= 10'h0F0; wdata <= 32'h11223344; we <= 1;
            @(posedge clk); waddr <= 10'h0F1; wdata <= 32'h55667788; we <= 1;
            @(posedge clk); we <= 0;
            @(posedge clk);

            // Read addr 0xF0 with re=1
            raddr <= 10'h0F0; re <= 1;
            @(posedge clk); re <= 0;
            @(posedge clk);
            captured = rdata;  // Should be 0x11223344

            // Now point raddr at 0xF1 but keep re=0 for several cycles
            raddr <= 10'h0F1;
            re <= 0;
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);

            test_count = test_count + 1;
            if (rdata == captured && captured == 32'h11223344) begin
                $display("  PASS: rdata held at 0x%h with re=0 (addr changed, data stable)",
                         rdata);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: rdata=0x%h (captured=0x%h); expected no update with re=0",
                         rdata, captured);
                fail_count = fail_count + 1;
            end

            #(CLK_PERIOD * 2);
            $display("");
        end
    endtask

endmodule
