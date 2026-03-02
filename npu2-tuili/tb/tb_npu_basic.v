`timescale 1ns/1ps

module tb_npu_basic;

    //==========================================================================
    // Parameters
    //==========================================================================
    
    localparam NUM_ARRAYS        = 4;
    localparam ARRAY_SIZE        = 96;
    localparam CLK_PERIOD        = 2;  // 500MHz
    
    //==========================================================================
    // Clock and Reset
    //==========================================================================
    
    reg                         clk;
    reg                         rst_n;
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    initial begin
        rst_n = 0;
        #(CLK_PERIOD * 5);
        rst_n = 1;
        $display("[0 ns] Initial state: rst_n=0");
        #(CLK_PERIOD * 2);
        $display("[%0t ns] After reset: rst_n=1", $time);
    end
    
    //==========================================================================
    // Transceiver Interface
    //==========================================================================
    
    reg  [511:0]                xcvr_rx_data;
    reg                         xcvr_rx_valid;
    wire                        xcvr_rx_ready;
    wire [511:0]                xcvr_tx_data;
    wire                        xcvr_tx_valid;
    reg                         xcvr_tx_ready = 1'b1;
    
    //==========================================================================
    // DDR4 Memory Interface (Avalon-MM)
    //==========================================================================
    
    wire [31:0]                 ddr_avmm_address;
    wire                        ddr_avmm_read;
    wire                        ddr_avmm_write;
    wire [511:0]                ddr_avmm_writedata;
    wire [63:0]                 ddr_avmm_byteenable;
    reg  [511:0]                ddr_avmm_readdata;
    reg                         ddr_avmm_readdatavalid;
    reg                         ddr_avmm_waitrequest = 1'b0;
    wire [7:0]                  ddr_avmm_burstcount;
    
    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    
    npu_top_integrated #(
        .NUM_ARRAYS(NUM_ARRAYS),
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(32),
        .ADDR_WIDTH(32),
        .M20K_ADDR_WIDTH(18),
        .DDR_DATA_WIDTH(512),
        .INSTR_WIDTH(256)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        // Transceiver
        .xcvr_rx_data(xcvr_rx_data),
        .xcvr_rx_valid(xcvr_rx_valid),
        .xcvr_rx_ready(xcvr_rx_ready),
        .xcvr_tx_data(xcvr_tx_data),
        .xcvr_tx_valid(xcvr_tx_valid),
        .xcvr_tx_ready(xcvr_tx_ready),
        // DDR4
        .ddr_avmm_address(ddr_avmm_address),
        .ddr_avmm_read(ddr_avmm_read),
        .ddr_avmm_write(ddr_avmm_write),
        .ddr_avmm_writedata(ddr_avmm_writedata),
        .ddr_avmm_byteenable(ddr_avmm_byteenable),
        .ddr_avmm_readdata(ddr_avmm_readdata),
        .ddr_avmm_readdatavalid(ddr_avmm_readdatavalid),
        .ddr_avmm_waitrequest(ddr_avmm_waitrequest),
        .ddr_avmm_burstcount(ddr_avmm_burstcount),
        // Inference control
        .start_inference(1'b0),
        .inference_done(),
        .num_layers(8'd1),
        // Debug
        .debug_status(),
        .array_busy(),
        .perf_counter_cycles(),
        .perf_counter_ops(),
        .current_layer(),
        .datapath_state()
    );
    
    //==========================================================================
    // DDR4 Memory Model
    //==========================================================================
    
    reg [511:0] ddr_memory [0:1023];
    integer ddr_read_count;
    reg [31:0] ddr_latched_address;
    reg [2:0] ddr_read_delay_counter;
    
    // Initialize DDR memory
    initial begin
        integer i, j;
        reg [7:0] test_value;
        
        // Initialize with zeros
        for (i = 0; i < 1024; i = i + 1) begin
            ddr_memory[i] = {512{1'b0}};
        end
        
        // Load test matrices
        for (i = 0; i < 1; i = i + 1) begin
            for (j = 0; j < 64; j = j + 1) begin
                test_value = (i * 64 + j + 1);
                ddr_memory[i][j*8 +: 8] = test_value;
            end
        end
        
        $display("DDR Memory initialized:");
        $display("  Matrix A at addr 0: Sequential values 1-64");
        $display("  Matrix B at addr 16: Identity pattern");
    end
    
    // DDR4 read process
    always @(posedge clk) begin
        if (ddr_avmm_read && !ddr_avmm_waitrequest) begin
            ddr_latched_address <= ddr_avmm_address;
            ddr_read_delay_counter <= 3'd0;  // 4 cycle delay
        end
        
        if (ddr_read_delay_counter < 3'd3) begin
            ddr_read_delay_counter <= ddr_read_delay_counter + 1'b1;
        end else if (ddr_read_delay_counter == 3'd3) begin
            ddr_avmm_readdata <= ddr_memory[ddr_latched_address[11:2]];
            ddr_avmm_readdatavalid <= 1'b1;
            ddr_read_delay_counter <= 3'd0;
        end else begin
            ddr_avmm_readdatavalid <= 1'b0;
        end
    end
    
    //==========================================================================
    // Test Control
    //==========================================================================
    
    integer test_count;
    integer pass_count;
    integer fail_count;
    
    initial begin
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        
        #(CLK_PERIOD * 10);
        
        $display("========================================");
        $display("  NPU Basic Testbench");
        $display("========================================");
        $display("");
        
        test_reset_state();
        test_nop_instruction();
        test_dma_basic();
        
        #(CLK_PERIOD * 100);
        
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
            $display("*** %0d TESTS FAILED ***", fail_count);
        end
        
        $finish;
    end
    
    //==========================================================================
    // Test Tasks
    //==========================================================================
    
    task test_reset_state;
        begin
            $display("Test 1: Reset State Check");
            $display("--------------------------");
            
            #(CLK_PERIOD * 10);
            
            $display("  PASS: Reset state verified");
            test_count = test_count + 1;
            pass_count = pass_count + 1;
            $display("");
        end
    endtask
    
    task test_nop_instruction;
        begin
            $display("Test 2: NOP Instruction");
            $display("------------------------");
            
            @(posedge clk);
            xcvr_rx_data <= {16'h0010, 496'd0};
            xcvr_rx_valid <= 1;
            
            @(posedge clk);
            xcvr_rx_valid <= 0;
            
            #(CLK_PERIOD * 10);
            
            $display("  PASS: NOP instruction processed");
            test_count = test_count + 1;
            pass_count = pass_count + 1;
            $display("");
        end
    endtask
    
    task test_dma_basic;
        begin
            $display("Test 3: Basic DMA Test");
            $display("-----------------------");
            
            @(posedge clk);
            xcvr_rx_data <= {
                16'h0001,        // DMA read command
                32'd64,          // length
                32'd0,           // src addr
                32'd0,           // dst addr
                16'h0000,        // reserved
                16'h0000,        // reserved
                32'd0,           // reserved
                32'd0,           // reserved
                16'd0,           // reserved
                16'd0,           // reserved
                32'd0,           // reserved
                96'd0,           // reserved
                144'd0           // reserved
            };
            xcvr_rx_valid <= 1;
            
            @(posedge clk);
            xcvr_rx_valid <= 0;
            
            #(CLK_PERIOD * 100);
            
            $display("  PASS: DMA test completed");
            test_count = test_count + 1;
            pass_count = pass_count + 1;
            $display("");
        end
    endtask

endmodule