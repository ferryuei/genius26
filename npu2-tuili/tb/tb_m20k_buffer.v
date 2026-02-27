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
        #(CLK_PERIOD * 5000);
        $display("");
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
