// =============================================================================
// Storm Control Testbench
// =============================================================================
// Tests: Broadcast/Multicast/Unknown-unicast storm suppression, rate limiting
// =============================================================================

`timescale 1ns/1ps

module tb_storm_ctrl;
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
    // Test Variables
    // =========================================================================
    storm_ctrl_cfg_t storm_cfg [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0];
    
    longint broadcast_sent[NUM_PORTS-1:0];
    longint broadcast_passed[NUM_PORTS-1:0];
    longint broadcast_dropped[NUM_PORTS-1:0];
    
    longint multicast_sent[NUM_PORTS-1:0];
    longint multicast_passed[NUM_PORTS-1:0];
    longint multicast_dropped[NUM_PORTS-1:0];
    
    longint unknown_sent[NUM_PORTS-1:0];
    longint unknown_passed[NUM_PORTS-1:0];
    longint unknown_dropped[NUM_PORTS-1:0];
    
    // Storm control type indices
    localparam STORM_BROADCAST = 0;
    localparam STORM_MULTICAST = 1;
    localparam STORM_UNKNOWN_UC = 2;
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Reset counters
    task reset_counters();
        int i;
        for (i = 0; i < NUM_PORTS; i++) begin
            broadcast_sent[i] = 0;
            broadcast_passed[i] = 0;
            broadcast_dropped[i] = 0;
            multicast_sent[i] = 0;
            multicast_passed[i] = 0;
            multicast_dropped[i] = 0;
            unknown_sent[i] = 0;
            unknown_passed[i] = 0;
            unknown_dropped[i] = 0;
        end
    endtask
    
    // Configure storm control for a port
    task configure_storm_control(
        input int port,
        input int storm_type,
        input logic enable,
        input int rate_kbps
    );
        @(posedge clk);
        storm_cfg[port][storm_type].enabled = enable;
        storm_cfg[port][storm_type].pir = (rate_kbps * 1000) / 8;  // Convert kbps to bytes/sec
        storm_cfg[port][storm_type].cbs = (rate_kbps * 1000) / 8;  // Burst size = 1 second worth
        
        $display("[INFO] Configured storm control: Port=%0d Type=%0s Enable=%0d Rate=%0d kbps",
                 port,
                 storm_type == 0 ? "Broadcast" : 
                 storm_type == 1 ? "Multicast" : "Unknown-UC",
                 enable, rate_kbps);
    endtask
    
    // Send broadcast packet
    task send_broadcast(
        input int port,
        input int count,
        input int size_bytes
    );
        int i;
        int passed, dropped;
        
        passed = 0;
        dropped = 0;
        
        for (i = 0; i < count; i++) begin
            broadcast_sent[port]++;
            
            // Simulate packet and storm control check
            @(posedge clk);
            
            // Simple storm control model: check rate limit
            if (storm_cfg[port][STORM_BROADCAST].enabled) begin
                // Calculate if packet exceeds rate limit
                real current_rate_kbps;
                real allowed_rate_kbps;
                
                allowed_rate_kbps = storm_cfg[port][STORM_BROADCAST].pir;
                current_rate_kbps = (broadcast_sent[port] * size_bytes * 8.0) / 
                                   ($time / 1000000.0);  // Convert to kbps
                
                if (current_rate_kbps > allowed_rate_kbps * 1.1) begin
                    broadcast_dropped[port]++;
                    dropped++;
                end else begin
                    broadcast_passed[port]++;
                    passed++;
                end
            end else begin
                broadcast_passed[port]++;
                passed++;
            end
            
            // Inter-packet gap
            repeat(12) @(posedge clk);
        end
        
        $display("[%0t] Port %0d: Sent %0d broadcast packets, %0d passed, %0d dropped",
                 $time, port, count, passed, dropped);
    endtask
    
    // Send multicast packet
    task send_multicast(
        input int port,
        input int count,
        input int size_bytes
    );
        int i;
        int passed, dropped;
        
        passed = 0;
        dropped = 0;
        
        for (i = 0; i < count; i++) begin
            multicast_sent[port]++;
            
            @(posedge clk);
            
            if (storm_cfg[port][STORM_MULTICAST].enabled) begin
                real current_rate_kbps;
                real allowed_rate_kbps;
                
                allowed_rate_kbps = storm_cfg[port][STORM_MULTICAST].pir;
                current_rate_kbps = (multicast_sent[port] * size_bytes * 8.0) / 
                                   ($time / 1000000.0);
                
                if (current_rate_kbps > allowed_rate_kbps * 1.1) begin
                    multicast_dropped[port]++;
                    dropped++;
                end else begin
                    multicast_passed[port]++;
                    passed++;
                end
            end else begin
                multicast_passed[port]++;
                passed++;
            end
            
            repeat(12) @(posedge clk);
        end
        
        $display("[%0t] Port %0d: Sent %0d multicast packets, %0d passed, %0d dropped",
                 $time, port, count, passed, dropped);
    endtask
    
    // Send unknown unicast packet
    task send_unknown_unicast(
        input int port,
        input int count,
        input int size_bytes
    );
        int i;
        int passed, dropped;
        
        passed = 0;
        dropped = 0;
        
        for (i = 0; i < count; i++) begin
            unknown_sent[port]++;
            
            @(posedge clk);
            
            if (storm_cfg[port][STORM_UNKNOWN_UC].enabled) begin
                real current_rate_kbps;
                real allowed_rate_kbps;
                
                allowed_rate_kbps = storm_cfg[port][STORM_UNKNOWN_UC].pir;
                current_rate_kbps = (unknown_sent[port] * size_bytes * 8.0) / 
                                   ($time / 1000000.0);
                
                if (current_rate_kbps > allowed_rate_kbps * 1.1) begin
                    unknown_dropped[port]++;
                    dropped++;
                end else begin
                    unknown_passed[port]++;
                    passed++;
                end
            end else begin
                unknown_passed[port]++;
                passed++;
            end
            
            repeat(12) @(posedge clk);
        end
        
        $display("[%0t] Port %0d: Sent %0d unknown-UC packets, %0d passed, %0d dropped",
                 $time, port, count, passed, dropped);
    endtask
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        int i;
        
        $display("\n========================================");
        $display("Storm Control Testbench");
        $display("========================================\n");
        
        // Initialize
        rst_n = 0;
        reset_counters();
        
        // Initialize storm control configs
        for (i = 0; i < NUM_PORTS; i++) begin
            storm_cfg[i][STORM_BROADCAST].enabled = 0;
            storm_cfg[i][STORM_BROADCAST].pir = 0;
            storm_cfg[i][STORM_MULTICAST].enabled = 0;
            storm_cfg[i][STORM_MULTICAST].pir = 0;
            storm_cfg[i][STORM_UNKNOWN_UC].enabled = 0;
            storm_cfg[i][STORM_UNKNOWN_UC].pir = 0;
        end
        
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        $display("[INFO] Reset complete");
        
        // =====================================================================
        // Test 1: Broadcast Storm Control - Disabled
        // =====================================================================
        $display("\n--- Test 1: Broadcast Storm (Disabled) ---");
        
        reset_counters();
        configure_storm_control(0, STORM_BROADCAST, 0, 0);
        
        send_broadcast(0, 100, 64);
        
        assert_equal("All broadcasts passed", broadcast_passed[0], 32'd100);
        assert_equal("No broadcasts dropped", broadcast_dropped[0], 64'd0);
        
        // =====================================================================
        // Test 2: Broadcast Storm Control - Enabled
        // =====================================================================
        $display("\n--- Test 2: Broadcast Storm (Enabled, 1 Mbps limit) ---");
        
        reset_counters();
        configure_storm_control(1, STORM_BROADCAST, 1, 1000);  // 1 Mbps = 1000 kbps
        
        repeat(10) @(posedge clk);
        
        // Send high-rate broadcast traffic
        send_broadcast(1, 200, 64);
        
        $display("[INFO] Storm control statistics:");
        $display("        Sent:    %0d", broadcast_sent[1]);
        $display("        Passed:  %0d", broadcast_passed[1]);
        $display("        Dropped: %0d", broadcast_dropped[1]);
        
        assert_true("Some broadcasts dropped", broadcast_dropped[1] > 0);
        
        // =====================================================================
        // Test 3: Multicast Storm Control
        // =====================================================================
        $display("\n--- Test 3: Multicast Storm (Enabled, 2 Mbps limit) ---");
        
        reset_counters();
        configure_storm_control(2, STORM_MULTICAST, 1, 2000);  // 2 Mbps
        
        repeat(10) @(posedge clk);
        
        send_multicast(2, 300, 128);
        
        $display("[INFO] Multicast storm control:");
        $display("        Sent:    %0d", multicast_sent[2]);
        $display("        Passed:  %0d", multicast_passed[2]);
        $display("        Dropped: %0d", multicast_dropped[2]);
        
        assert_true("Some multicasts dropped", multicast_dropped[2] > 0);
        
        // =====================================================================
        // Test 4: Unknown Unicast Storm Control
        // =====================================================================
        $display("\n--- Test 4: Unknown Unicast Storm (Enabled, 5 Mbps limit) ---");
        
        reset_counters();
        configure_storm_control(3, STORM_UNKNOWN_UC, 1, 5000);  // 5 Mbps
        
        repeat(10) @(posedge clk);
        
        send_unknown_unicast(3, 500, 256);
        
        $display("[INFO] Unknown-UC storm control:");
        $display("        Sent:    %0d", unknown_sent[3]);
        $display("        Passed:  %0d", unknown_passed[3]);
        $display("        Dropped: %0d", unknown_dropped[3]);
        
        assert_true("Some unknown-UC dropped", unknown_dropped[3] > 0);
        
        // =====================================================================
        // Test 5: Multiple Storm Types on Same Port
        // =====================================================================
        $display("\n--- Test 5: Multiple Storm Types (Same Port) ---");
        
        reset_counters();
        configure_storm_control(4, STORM_BROADCAST, 1, 1000);   // 1 Mbps
        configure_storm_control(4, STORM_MULTICAST, 1, 2000);   // 2 Mbps
        configure_storm_control(4, STORM_UNKNOWN_UC, 1, 3000);  // 3 Mbps
        
        repeat(10) @(posedge clk);
        
        // Send mixed traffic
        fork
            send_broadcast(4, 100, 64);
            send_multicast(4, 100, 64);
            send_unknown_unicast(4, 100, 64);
        join
        
        $display("[INFO] Mixed storm control results:");
        $display("        Broadcast  - Sent: %0d, Dropped: %0d", 
                 broadcast_sent[4], broadcast_dropped[4]);
        $display("        Multicast  - Sent: %0d, Dropped: %0d", 
                 multicast_sent[4], multicast_dropped[4]);
        $display("        Unknown-UC - Sent: %0d, Dropped: %0d", 
                 unknown_sent[4], unknown_dropped[4]);
        
        // =====================================================================
        // Test 6: Rate Limit Accuracy
        // =====================================================================
        $display("\n--- Test 6: Rate Limit Accuracy Test ---");
        
        reset_counters();
        configure_storm_control(5, STORM_BROADCAST, 1, 10000);  // 10 Mbps
        
        repeat(10) @(posedge clk);
        
        // Send controlled burst
        send_broadcast(5, 1000, 128);
        
        // Calculate actual pass rate
        begin
            real pass_rate_mbps;
            real expected_rate_mbps;
        
        pass_rate_mbps = (broadcast_passed[5] * 128 * 8.0) / ($time / 1000.0);
        expected_rate_mbps = 10.0;
        
        $display("[INFO] Rate limit accuracy:");
        $display("        Expected: %.2f Mbps", expected_rate_mbps);
        $display("        Actual:   %.2f Mbps", pass_rate_mbps);
        $display("        Error:    %.1f%%", 
                 ((pass_rate_mbps - expected_rate_mbps) / expected_rate_mbps) * 100.0);
        end  // Test 6 block
        
        // =====================================================================
        // Test 7: Burst Tolerance
        // =====================================================================
        $display("\n--- Test 7: Burst Tolerance ---");
        
        reset_counters();
        configure_storm_control(6, STORM_BROADCAST, 1, 5000);  // 5 Mbps
        
        repeat(10) @(posedge clk);
        
        // Send short burst (should allow some burst)
        $display("[INFO] Sending short burst...");
        send_broadcast(6, 50, 512);
        
        // Wait
        repeat(1000) @(posedge clk);
        
        // Send another burst
        $display("[INFO] Sending second burst...");
        send_broadcast(6, 50, 512);
        
        $display("[INFO] Burst handling:");
        $display("        Total sent:    %0d", broadcast_sent[6]);
        $display("        Total passed:  %0d", broadcast_passed[6]);
        $display("        Total dropped: %0d", broadcast_dropped[6]);
        
        // =====================================================================
        // Test 8: Dynamic Configuration Change
        // =====================================================================
        $display("\n--- Test 8: Dynamic Rate Limit Change ---");
        
        reset_counters();
        configure_storm_control(7, STORM_BROADCAST, 1, 1000);  // Start: 1 Mbps
        
        repeat(10) @(posedge clk);
        
        send_broadcast(7, 100, 64);
        $display("[INFO] Phase 1 (1 Mbps): Dropped %0d packets", broadcast_dropped[7]);
        
        // Change rate limit
        configure_storm_control(7, STORM_BROADCAST, 1, 10000);  // Change to: 10 Mbps
        
        repeat(10) @(posedge clk);
        
        begin
            longint dropped_before;
        dropped_before = broadcast_dropped[7];
        send_broadcast(7, 100, 64);
        $display("[INFO] Phase 2 (10 Mbps): Dropped %0d additional packets", 
                 broadcast_dropped[7] - dropped_before);
        end  // Test 8 block
        
        // =====================================================================
        // Test 9: Storm Control Disable/Enable
        // =====================================================================
        $display("\n--- Test 9: Enable/Disable Storm Control ---");
        
        reset_counters();
        
        // Disabled
        configure_storm_control(8, STORM_BROADCAST, 0, 1000);
        send_broadcast(8, 50, 64);
        assert_equal("All passed (disabled)", broadcast_passed[8], 64'd50);
        
        // Enable
        configure_storm_control(8, STORM_BROADCAST, 1, 1000);
        repeat(10) @(posedge clk);
        send_broadcast(8, 100, 64);
        assert_true("Some dropped (enabled)", broadcast_dropped[8] > 0);
        
        // Disable again
        configure_storm_control(8, STORM_BROADCAST, 0, 1000);
        repeat(10) @(posedge clk);
        begin
            longint passed_before;
        passed_before = broadcast_passed[8];
        send_broadcast(8, 50, 64);
        assert_equal("Additional passed (disabled again)", 
                     broadcast_passed[8] - passed_before, 64'd50);
        end  // Test 9 block
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(100) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("\nStorm Control Test: PASSED\n");
        end else begin
            $display("\nStorm Control Test: FAILED\n");
        end
        
        $finish;
    end
    
    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #10ms;
        $display("[ERROR] Testbench timeout!");
        $finish;
    end
    
endmodule
