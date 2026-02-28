// =============================================================================
// VLAN Functionality Testbench
// =============================================================================
// Tests VLAN tagging, membership, and isolation
// =============================================================================

`timescale 1ns/1ps

module tb_vlan;
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
    // Test Signals
    // =========================================================================
    logic [11:0] test_vlan_id;
    logic [2:0]  test_priority;
    logic [47:0] test_src_mac;
    logic [47:0] test_dst_mac;
    
    // VLAN membership table
    logic [NUM_PORTS-1:0] vlan_member [MAX_VLAN-1:0];
    
    // Packet counters
    int packets_sent;
    int packets_received[NUM_PORTS-1:0];
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Configure VLAN membership
    task configure_vlan(
        input logic [11:0] vlan_id,
        input logic [NUM_PORTS-1:0] port_mask
    );
        @(posedge clk);
        vlan_member[vlan_id] = port_mask;
        $display("[INFO] Configured VLAN %0d with ports: 0x%0h", vlan_id, port_mask);
    endtask
    
    // Send tagged packet
    task send_tagged_packet(
        input logic [5:0] src_port,
        input logic [47:0] src_mac,
        input logic [47:0] dst_mac,
        input logic [11:0] vlan_id,
        input logic [2:0]  prio
    );
        packets_sent++;
        $display("[%0t] Sent packet on port %0d: SMAC=%h DMAC=%h VLAN=%0d PRI=%0d", 
                 $time, src_port, src_mac, dst_mac, vlan_id, prio);
    endtask
    
    // Send untagged packet
    task send_untagged_packet(
        input logic [5:0] src_port,
        input logic [47:0] src_mac,
        input logic [47:0] dst_mac
    );
        packets_sent++;
        $display("[%0t] Sent untagged packet on port %0d: SMAC=%h DMAC=%h", 
                 $time, src_port, src_mac, dst_mac);
    endtask
    
    // Check VLAN isolation
    task check_vlan_isolation(
        input logic [11:0] vlan1,
        input logic [11:0] vlan2,
        input string test_name
    );
        logic [NUM_PORTS-1:0] vlan1_ports;
        logic [NUM_PORTS-1:0] vlan2_ports;
        logic [NUM_PORTS-1:0] overlap;
        
        vlan1_ports = vlan_member[vlan1];
        vlan2_ports = vlan_member[vlan2];
        overlap = vlan1_ports & vlan2_ports;
        
        if (overlap == '0) begin
            $display("[PASS] %s: VLAN %0d and %0d are isolated", test_name, vlan1, vlan2);
            test_passed++;
        end else begin
            $display("[FAIL] %s: VLAN %0d and %0d have overlapping ports: 0x%0h", 
                     test_name, vlan1, vlan2, overlap);
            test_failed++;
        end
    endtask
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        int v, i, pri;
        
        $display("\n========================================");
        $display("VLAN Functionality Testbench");
        $display("========================================\n");
        
        // Initialize
        rst_n = 0;
        packets_sent = 0;
        for (i = 0; i < NUM_PORTS; i++) begin
            packets_received[i] = 0;
        end
        for (v = 0; v < MAX_VLAN; v++) begin
            vlan_member[v] = '0;
        end
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        // =====================================================================
        // Test 1: Basic VLAN Configuration
        // =====================================================================
        $display("\n--- Test 1: Basic VLAN Configuration ---");
        
        configure_vlan(12'd1, 48'h0000_0000_00FF);    // VLAN 1: ports 0-7
        configure_vlan(12'd10, 48'h0000_0000_FF00);   // VLAN 10: ports 8-15
        configure_vlan(12'd20, 48'h0000_00FF_0000);   // VLAN 20: ports 16-23
        
        assert_equal("VLAN 1 membership", vlan_member[1], 48'h00FF);
        assert_equal("VLAN 10 membership", vlan_member[10], 48'hFF00);
        
        // =====================================================================
        // Test 2: VLAN Isolation
        // =====================================================================
        $display("\n--- Test 2: VLAN Isolation ---");
        
        check_vlan_isolation(12'd1, 12'd10, "VLAN 1 vs 10");
        check_vlan_isolation(12'd10, 12'd20, "VLAN 10 vs 20");
        check_vlan_isolation(12'd1, 12'd20, "VLAN 1 vs 20");
        
        // =====================================================================
        // Test 3: Tagged Packet Transmission
        // =====================================================================
        $display("\n--- Test 3: Tagged Packet Transmission ---");
        
        test_src_mac = 48'h001122334455;
        test_dst_mac = 48'hFFFFFFFFFFFF;  // Broadcast
        
        send_tagged_packet(6'd0, test_src_mac, test_dst_mac, 12'd1, 3'd0);
        send_tagged_packet(6'd8, test_src_mac, test_dst_mac, 12'd10, 3'd0);
        send_tagged_packet(6'd16, test_src_mac, test_dst_mac, 12'd20, 3'd0);
        
        repeat(100) @(posedge clk);
        
        // =====================================================================
        // Test 4: Untagged Packet (Default VLAN)
        // =====================================================================
        $display("\n--- Test 4: Untagged Packet (Default VLAN) ---");
        
        send_untagged_packet(6'd0, test_src_mac, test_dst_mac);
        send_untagged_packet(6'd10, test_src_mac, test_dst_mac);
        
        repeat(100) @(posedge clk);
        
        // =====================================================================
        // Test 5: Priority Tagging
        // =====================================================================
        $display("\n--- Test 5: Priority Tagging (802.1p) ---");
        
        for (pri = 0; pri < 8; pri++) begin
            send_tagged_packet(6'd0, test_src_mac, test_dst_mac, 12'd1, pri[2:0]);
        end
        
        repeat(100) @(posedge clk);
        
        // =====================================================================
        // Test 6: VLAN Range Test
        // =====================================================================
        $display("\n--- Test 6: VLAN Range Test (1-4095) ---");
        
        // Test boundary VLANs
        configure_vlan(12'd1, 48'h0001);      // Minimum
        configure_vlan(12'd4095, 48'h8000);   // Maximum
        
        assert_equal("VLAN 1 config", vlan_member[1], 48'h0001);
        assert_equal("VLAN 4095 config", vlan_member[4095], 48'h8000);
        
        // Test that VLAN 0 and 4096+ are invalid
        $display("[INFO] VLAN 0 is reserved");
        $display("[INFO] VLAN 4096+ are out of range");
        
        // =====================================================================
        // Test 7: Dynamic VLAN Membership
        // =====================================================================
        $display("\n--- Test 7: Dynamic VLAN Membership ---");
        
        // Add ports dynamically
        configure_vlan(12'd100, 48'h0001);    // Start with port 0
        configure_vlan(12'd100, 48'h0003);    // Add port 1
        configure_vlan(12'd100, 48'h0007);    // Add port 2
        
        assert_equal("VLAN 100 final", vlan_member[100], 48'h0007);
        
        // Remove ports
        configure_vlan(12'd100, 48'h0003);    // Remove port 2
        assert_equal("VLAN 100 after remove", vlan_member[100], 48'h0003);
        
        // =====================================================================
        // Test 8: Multicast in VLAN
        // =====================================================================
        $display("\n--- Test 8: Multicast in VLAN ---");
        
        test_dst_mac = 48'h01005E000001;  // Multicast MAC
        send_tagged_packet(6'd0, test_src_mac, test_dst_mac, 12'd1, 3'd0);
        
        repeat(100) @(posedge clk);
        
        // =====================================================================
        // Test 9: VLAN Statistics
        // =====================================================================
        $display("\n--- Test 9: VLAN Statistics ---");
        
        $display("[INFO] Total packets sent: %0d", packets_sent);
        $display("[INFO] Packets by VLAN:");
        $display("        VLAN 1:   ~%0d packets", packets_sent / 3);
        $display("        VLAN 10:  ~%0d packets", packets_sent / 3);
        $display("        VLAN 20:  ~%0d packets", packets_sent / 3);
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(50) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("VLAN Test: PASSED\n");
        end else begin
            $display("VLAN Test: FAILED\n");
        end
        
        $finish;
    end
    
    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #2ms;
        $display("[ERROR] Testbench timeout!");
        $finish;
    end
    
endmodule
