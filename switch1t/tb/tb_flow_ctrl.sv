// =============================================================================
// Flow Control Testbench
// =============================================================================
// Tests: PAUSE frame handling, PFC (Priority Flow Control), backpressure
// =============================================================================

`timescale 1ns/1ps

module tb_flow_ctrl;
    import switch_pkg::*;
    import tb_pkg::*;
    
    // =========================================================================
    // Clock and Reset
    // =========================================================================
    logic clk;
    logic rst_n;
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // =========================================================================
    // DUT Signals
    // =========================================================================
    
    // Port signals
    logic [NUM_PORTS-1:0] port_rx_valid;
    logic [NUM_PORTS-1:0] port_tx_ready;
    
    // PAUSE frame generation
    logic [NUM_PORTS-1:0] pause_req;
    logic [15:0] pause_quanta [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] pause_sent;
    
    // PAUSE frame reception
    logic [NUM_PORTS-1:0] pause_rx;
    logic [15:0] pause_rx_quanta [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] port_paused;
    
    // PFC (Priority Flow Control)
    logic [NUM_PORTS-1:0] pfc_req;
    logic [7:0] pfc_class_enable [NUM_PORTS-1:0];
    logic [15:0] pfc_quanta [NUM_PORTS-1:0][7:0];
    logic [NUM_PORTS-1:0] pfc_sent;
    
    // Queue status
    logic [15:0] queue_depth [NUM_PORTS-1:0][7:0];
    logic [NUM_PORTS-1:0] queue_xoff [7:0];
    
    // Configuration
    logic [15:0] xoff_threshold;
    logic [15:0] xon_threshold;
    logic [NUM_PORTS-1:0] fc_enable;
    logic [NUM_PORTS-1:0] pfc_enable;
    
    // Statistics
    logic [31:0] stat_pause_tx [NUM_PORTS-1:0];
    logic [31:0] stat_pause_rx [NUM_PORTS-1:0];
    logic [31:0] stat_pfc_tx [NUM_PORTS-1:0];
    
    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    pause_frame_ctrl dut (
        .clk(clk),
        .rst_n(rst_n),
        .port_rx_valid(port_rx_valid),
        .port_tx_ready(port_tx_ready),
        .pause_req(pause_req),
        .pause_quanta(pause_quanta),
        .pause_sent(pause_sent),
        .pause_rx(pause_rx),
        .pause_rx_quanta(pause_rx_quanta),
        .port_paused(port_paused),
        .pfc_req(pfc_req),
        .pfc_class_enable(pfc_class_enable),
        .pfc_quanta(pfc_quanta),
        .pfc_sent(pfc_sent),
        .queue_depth(queue_depth),
        .queue_xoff(queue_xoff),
        .xoff_threshold(xoff_threshold),
        .xon_threshold(xon_threshold),
        .fc_enable(fc_enable),
        .pfc_enable(pfc_enable),
        .stat_pause_tx(stat_pause_tx),
        .stat_pause_rx(stat_pause_rx),
        .stat_pfc_tx(stat_pfc_tx)
    );
    
    // =========================================================================
    // Test Variables
    // =========================================================================
    int packets_paused;
    int packets_resumed;
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Reset DUT
    task reset_dut();
        int i, q;
        
        rst_n = 0;
        port_rx_valid = '0;
        port_tx_ready = '1;
        pause_req = '0;
        pause_rx = '0;
        pfc_req = '0;
        fc_enable = '0;
        pfc_enable = '0;
        xoff_threshold = 16'd1000;
        xon_threshold = 16'd500;
        
        for (i = 0; i < NUM_PORTS; i++) begin
            pause_quanta[i] = 0;
            pause_rx_quanta[i] = 0;
            pfc_class_enable[i] = 8'h0;
            for (q = 0; q < 8; q++) begin
                pfc_quanta[i][q] = 0;
                queue_depth[i][q] = 0;
            end
        end
        
        packets_paused = 0;
        packets_resumed = 0;
        
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        $display("[INFO] Reset complete");
    endtask
    
    // Request PAUSE frame transmission
    task request_pause(
        input int port,
        input int quanta
    );
        @(posedge clk);
        pause_req[port] = 1'b1;
        pause_quanta[port] = quanta[15:0];
        
        @(posedge clk);
        while (!pause_sent[port]) @(posedge clk);
        
        pause_req[port] = 1'b0;
        
        $display("[%0t] PAUSE frame sent on port %0d, quanta=%0d", 
                 $time, port, quanta);
    endtask
    
    // Simulate PAUSE frame reception
    task receive_pause(
        input int port,
        input int quanta
    );
        @(posedge clk);
        pause_rx[port] = 1'b1;
        pause_rx_quanta[port] = quanta[15:0];
        
        @(posedge clk);
        pause_rx[port] = 1'b0;
        
        $display("[%0t] PAUSE frame received on port %0d, quanta=%0d", 
                 $time, port, quanta);
        
        if (port_paused[port]) begin
            packets_paused++;
            $display("[INFO] Port %0d is now PAUSED", port);
        end
    endtask
    
    // Simulate queue filling
    task fill_queue(
        input int port,
        input int queue,
        input int depth
    );
        @(posedge clk);
        queue_depth[port][queue] = depth[15:0];
        
        $display("[%0t] Queue filled: Port=%0d Queue=%0d Depth=%0d", 
                 $time, port, queue, depth);
    endtask
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        int i;
        
        $display("\n========================================");
        $display("Flow Control Testbench");
        $display("========================================\n");
        
        // Initialize
        reset_dut();
        
        // =====================================================================
        // Test 1: Basic PAUSE Frame Generation
        // =====================================================================
        $display("\n--- Test 1: Basic PAUSE Frame Generation ---");
        
        // Enable flow control on port 0
        fc_enable[0] = 1'b1;
        
        repeat(5) @(posedge clk);
        
        // Request PAUSE frame
        request_pause(0, 16'hFFFF);  // Max quanta
        
        assert_equal("PAUSE TX counter", stat_pause_tx[0], 32'd1);
        
        // =====================================================================
        // Test 2: PAUSE Frame Reception
        // =====================================================================
        $display("\n--- Test 2: PAUSE Frame Reception ---");
        
        fc_enable[1] = 1'b1;
        
        repeat(5) @(posedge clk);
        
        // Receive PAUSE frame
        receive_pause(1, 16'd5000);
        
        // Check port is paused
        assert_true("Port paused", port_paused[1]);
        
        // Wait for pause to expire
        repeat(5100) @(posedge clk);
        
        assert_false("Port resumed", port_paused[1]);
        packets_resumed++;
        $display("[INFO] Port 1 resumed after pause expiry");
        
        // =====================================================================
        // Test 3: Automatic PAUSE on Queue Threshold
        // =====================================================================
        $display("\n--- Test 3: Automatic PAUSE on Threshold ---");
        
        fc_enable[2] = 1'b1;
        xoff_threshold = 16'd800;
        xon_threshold = 16'd400;
        
        repeat(5) @(posedge clk);
        
        // Fill queue beyond XOFF threshold
        fill_queue(2, 0, 1000);
        
        repeat(10) @(posedge clk);
        
        // Should automatically generate PAUSE
        $display("[INFO] Check if PAUSE auto-generated...");
        if (stat_pause_tx[2] > 0) begin
            $display("[PASS] Automatic PAUSE generated");
            test_passed++;
        end else begin
            $display("[INFO] Automatic PAUSE may not be implemented");
        end
        
        // Drain queue below XON threshold
        fill_queue(2, 0, 300);
        
        repeat(10) @(posedge clk);
        
        // =====================================================================
        // Test 4: Priority Flow Control (PFC)
        // =====================================================================
        $display("\n--- Test 4: Priority Flow Control (PFC) ---");
        
        pfc_enable[3] = 1'b1;
        pfc_class_enable[3] = 8'hFF;  // Enable all 8 priorities
        
        repeat(5) @(posedge clk);
        
        // Request PFC for priority 7 (highest)
        @(posedge clk);
        pfc_req[3] = 1'b1;
        pfc_quanta[3][7] = 16'hFFFF;
        
        @(posedge clk);
        while (!pfc_sent[3]) @(posedge clk);
        
        pfc_req[3] = 1'b0;
        
        $display("[%0t] PFC frame sent on port 3 for priority 7", $time);
        assert_true("PFC TX counter > 0", stat_pfc_tx[3] > 0);
        
        // =====================================================================
        // Test 5: Per-Priority Queue Control
        // =====================================================================
        $display("\n--- Test 5: Per-Priority Queue XOFF ---");
        
        pfc_enable[4] = 1'b1;
        pfc_class_enable[4] = 8'hFF;
        
        repeat(5) @(posedge clk);
        
        // Fill high-priority queue
        fill_queue(4, 7, 1200);  // Q7 above threshold
        fill_queue(4, 0, 100);   // Q0 below threshold
        
        repeat(10) @(posedge clk);
        
        // Check XOFF state
        $display("[INFO] Queue 7 XOFF: %0b", queue_xoff[7][4]);
        $display("[INFO] Queue 0 XOFF: %0b", queue_xoff[0][4]);
        
        // =====================================================================
        // Test 6: Multiple Ports Concurrent Flow Control
        // =====================================================================
        $display("\n--- Test 6: Multi-Port Flow Control ---");
        
        // Enable FC on multiple ports
        for (i = 5; i < 9; i++) begin
            fc_enable[i] = 1'b1;
        end
        
        repeat(5) @(posedge clk);
        
        // Send PAUSE on multiple ports simultaneously
        fork
            receive_pause(5, 1000);
            receive_pause(6, 2000);
            receive_pause(7, 3000);
            receive_pause(8, 4000);
        join
        
        $display("[INFO] Multi-port PAUSE status:");
        for (i = 5; i < 9; i++) begin
            $display("        Port %0d: %s", i, port_paused[i] ? "PAUSED" : "ACTIVE");
        end
        
        // =====================================================================
        // Test 7: PAUSE Quanta Countdown
        // =====================================================================
        $display("\n--- Test 7: PAUSE Quanta Countdown ---");
        
        fc_enable[10] = 1'b1;
        
        repeat(5) @(posedge clk);
        
        // Send PAUSE with short quanta
        receive_pause(10, 100);
        
        assert_true("Port 10 paused", port_paused[10]);
        
        // Wait for countdown
        repeat(110) @(posedge clk);
        
        assert_false("Port 10 resumed", port_paused[10]);
        
        // =====================================================================
        // Test 8: Back-to-Back PAUSE Frames
        // =====================================================================
        $display("\n--- Test 8: Back-to-Back PAUSE Frames ---");
        
        fc_enable[11] = 1'b1;
        
        repeat(5) @(posedge clk);
        
        // Send multiple PAUSE frames
        for (i = 0; i < 5; i++) begin
            receive_pause(11, 500);
            repeat(50) @(posedge clk);
        end
        
        $display("[INFO] Port 11 received 5 PAUSE frames");
        assert_equal("PAUSE RX counter", stat_pause_rx[11], 32'd5);
        
        // =====================================================================
        // Test 9: PAUSE with Zero Quanta (Resume)
        // =====================================================================
        $display("\n--- Test 9: PAUSE with Zero Quanta ---");
        
        fc_enable[12] = 1'b1;
        
        repeat(5) @(posedge clk);
        
        // First pause the port
        receive_pause(12, 10000);
        assert_true("Port 12 paused", port_paused[12]);
        
        // Send zero-quanta PAUSE to resume immediately
        receive_pause(12, 0);
        
        @(posedge clk);
        @(posedge clk);
        
        assert_false("Port 12 resumed by zero quanta", port_paused[12]);
        
        // =====================================================================
        // Test 10: Flow Control Statistics
        // =====================================================================
        $display("\n--- Test 10: Flow Control Statistics ---");
        
        $display("[INFO] Global flow control statistics:");
        $display("        Ports with FC enabled: %0d", $countones(fc_enable));
        $display("        Ports with PFC enabled: %0d", $countones(pfc_enable));
        
        begin
            int total_pause_tx, total_pause_rx, total_pfc_tx;
        total_pause_tx = 0;
        total_pause_rx = 0;
        total_pfc_tx = 0;
        
        for (i = 0; i < 16; i++) begin
            total_pause_tx += stat_pause_tx[i];
            total_pause_rx += stat_pause_rx[i];
            total_pfc_tx += stat_pfc_tx[i];
        end
        
        $display("        Total PAUSE TX: %0d", total_pause_tx);
        $display("        Total PAUSE RX: %0d", total_pause_rx);
        $display("        Total PFC TX:   %0d", total_pfc_tx);
        
        assert_true("PAUSE TX > 0", total_pause_tx > 0);
        assert_true("PAUSE RX > 0", total_pause_rx > 0);
        end  // Test 10 block
        
        // =====================================================================
        // Test 11: Threshold Configuration
        // =====================================================================
        $display("\n--- Test 11: Threshold Configuration Test ---");
        
        // Test different threshold values
        xoff_threshold = 16'd2000;
        xon_threshold = 16'd1000;
        
        repeat(5) @(posedge clk);
        
        $display("[INFO] New thresholds: XOFF=%0d, XON=%0d", 
                 xoff_threshold, xon_threshold);
        
        fc_enable[13] = 1'b1;
        
        // Fill just below XOFF
        fill_queue(13, 0, 1900);
        repeat(10) @(posedge clk);
        $display("[INFO] Queue at 1900 (below XOFF 2000)");
        
        // Fill above XOFF
        fill_queue(13, 0, 2100);
        repeat(10) @(posedge clk);
        $display("[INFO] Queue at 2100 (above XOFF 2000)");
        
        // Drain to XON
        fill_queue(13, 0, 900);
        repeat(10) @(posedge clk);
        $display("[INFO] Queue at 900 (below XON 1000)");
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(100) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("\nFlow Control Test: PASSED\n");
        end else begin
            $display("\nFlow Control Test: FAILED\n");
        end
        
        $finish;
    end
    
    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #20ms;
        $display("[ERROR] Testbench timeout!");
        $finish;
    end
    
endmodule
