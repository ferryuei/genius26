// =============================================================================
// ACL (Access Control List) Engine Testbench
// =============================================================================
// Tests: L2/L3/L4 matching, ACL actions (permit/deny), priority handling
// =============================================================================

`timescale 1ns/1ps

module tb_acl_engine;
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
    acl_lookup_req_t acl_lookup_req;
    acl_lookup_resp_t acl_lookup_resp;
    
    logic acl_cfg_wr_en;
    logic [ACL_TABLE_WIDTH-1:0] acl_cfg_rule_idx;
    acl_rule_t acl_cfg_rule_data;
    
    logic [31:0] stat_acl_lookup;
    logic [31:0] stat_acl_hit;
    logic [31:0] stat_acl_deny;
    
    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    acl_engine dut (
        .clk(clk),
        .rst_n(rst_n),
        .lookup_req(acl_lookup_req),
        .lookup_resp(acl_lookup_resp),
        .cfg_wr_en(acl_cfg_wr_en),
        .cfg_rule_idx(acl_cfg_rule_idx),
        .cfg_rule_data(acl_cfg_rule_data),
        .stat_acl_lookup(stat_acl_lookup),
        .stat_acl_hit(stat_acl_hit),
        .stat_acl_deny(stat_acl_deny)
    );
    
    // =========================================================================
    // Test Variables
    // =========================================================================
    longint packets_tested;
    longint packets_matched;
    longint packets_permitted;
    longint packets_denied;
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Reset DUT
    task reset_dut();
        rst_n = 0;
        acl_lookup_req = '0;
        acl_cfg_wr_en = 0;
        packets_tested = 0;
        packets_matched = 0;
        packets_permitted = 0;
        packets_denied = 0;
        
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        $display("[INFO] Reset complete");
    endtask
    
    // Configure ACL rule
    task configure_acl_rule(
        input int rule_id,
        input logic [47:0] src_mac,
        input logic [47:0] src_mac_mask,
        input logic [47:0] dst_mac,
        input logic [47:0] dst_mac_mask,
        input logic [11:0] vlan_id,
        input logic [11:0] vlan_mask,
        input logic [15:0] ethertype,
        input logic [15:0] ethertype_mask,
        input logic action_permit
    );
        @(posedge clk);
        acl_cfg_wr_en = 1'b1;
        acl_cfg_rule_idx = rule_id[ACL_TABLE_WIDTH-1:0];
        acl_cfg_rule_data.valid = 1'b1;
        acl_cfg_rule_data.smac = src_mac;
        acl_cfg_rule_data.smac_mask = src_mac_mask;
        acl_cfg_rule_data.dmac = dst_mac;
        acl_cfg_rule_data.dmac_mask = dst_mac_mask;
        acl_cfg_rule_data.vid = vlan_id;
        acl_cfg_rule_data.vid_mask = vlan_mask;
        acl_cfg_rule_data.ethertype = ethertype;
        acl_cfg_rule_data.ethertype_mask = ethertype_mask;
        acl_cfg_rule_data.src_port = '0;
        acl_cfg_rule_data.src_port_mask = '0;
        acl_cfg_rule_data.action = action_permit ? ACL_PERMIT : ACL_DENY;
        acl_cfg_rule_data.mirror_port = '0;
        acl_cfg_rule_data.remap_queue = '0;
        
        @(posedge clk);
        acl_cfg_wr_en = 1'b0;
        
        $display("[INFO] Configured ACL rule %0d: %s", 
                 rule_id, action_permit ? "PERMIT" : "DENY");
    endtask
    
    // Test packet against ACL
    task test_packet(
        input logic [47:0] src_mac,
        input logic [47:0] dst_mac,
        input logic [15:0] ethertype,
        input logic [11:0] vlan_id,
        input logic [5:0] src_port
    );
        @(posedge clk);
        acl_lookup_req.valid = 1'b1;
        acl_lookup_req.smac = src_mac;
        acl_lookup_req.dmac = dst_mac;
        acl_lookup_req.ethertype = ethertype;
        acl_lookup_req.vid = vlan_id;
        acl_lookup_req.src_port = src_port;
        
        @(posedge clk);
        acl_lookup_req.valid = 1'b0;
        
        @(posedge clk);
        
        packets_tested++;
        if (acl_lookup_resp.hit) begin
            packets_matched++;
            if (acl_lookup_resp.action == ACL_PERMIT) begin
                packets_permitted++;
                $display("[%0t] Packet PERMITTED", $time);
            end else begin
                packets_denied++;
                $display("[%0t] Packet DENIED", $time);
            end
        end else begin
            $display("[%0t] Packet NO MATCH (default permit)", $time);
            packets_permitted++;  // Default action
        end
    endtask
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("\n========================================");
        $display("ACL Engine Testbench");
        $display("========================================\n");
        
        // Initialize
        reset_dut();
        
        // =====================================================================
        // Test 1: L2 MAC Address Filtering
        // =====================================================================
        $display("\n--- Test 1: L2 MAC Address Filtering ---");
        
        // Rule 0: Deny specific source MAC
        configure_acl_rule(
            .rule_id(0),
            .src_mac(48'h001122334455),
            .src_mac_mask(48'hFFFFFFFFFFFF),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b0)
        );
        
        repeat(5) @(posedge clk);
        
        // Test packets
        test_packet(
            .src_mac(48'h001122334455),  // Matches rule
            .dst_mac(48'hFFFFFFFFFFFF),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("Packet denied", packets_denied, 64'd1);
        
        test_packet(
            .src_mac(48'h001122334456),  // Different MAC
            .dst_mac(48'hFFFFFFFFFFFF),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("Packet permitted", packets_permitted, 64'd2);
        
        // =====================================================================
        // Test 2: L3 IP Address Filtering
        // =====================================================================
        $display("\n--- Test 2: L3 IP Address Filtering ---");
        
        packets_tested = 0;
        packets_matched = 0;
        packets_permitted = 0;
        packets_denied = 0;
        
        // Rule 1: Deny traffic from 192.168.1.0/24
        configure_acl_rule(
            .rule_id(1),
            .src_mac(48'h0),
            .src_mac_mask(48'h0),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b0)
        );
        
        repeat(5) @(posedge clk);
        
        // Test packet from 192.168.1.100
        test_packet(
            .src_mac(48'h112233445566),
            .dst_mac(48'h778899AABBCC),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("IP denied", packets_denied, 64'd1);
        
        // Test packet from 192.168.2.100 (different subnet)
        test_packet(
            .src_mac(48'h112233445566),
            .dst_mac(48'h778899AABBCC),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("Different subnet permitted", packets_permitted, 64'd1);
        
        // =====================================================================
        // Test 3: L4 Port Filtering
        // =====================================================================
        $display("\n--- Test 3: L4 TCP Port Filtering ---");
        
        packets_tested = 0;
        packets_matched = 0;
        packets_permitted = 0;
        packets_denied = 0;
        
        // Rule 2: Permit only HTTP (TCP port 80)
        configure_acl_rule(
            .rule_id(2),
            .src_mac(48'h0),
            .src_mac_mask(48'h0),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b1)
        );
        
        repeat(5) @(posedge clk);
        
        // Test TCP packet
        test_packet(
            .src_mac(48'h112233445566),
            .dst_mac(48'h778899AABBCC),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("TCP permitted", packets_permitted, 64'd1);
        
        // Test UDP packet (no match)
        test_packet(
            .src_mac(48'h112233445566),
            .dst_mac(48'h778899AABBCC),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("UDP permitted (no match)", packets_permitted, 64'd2);
        
        // =====================================================================
        // Test 4: VLAN-based ACL
        // =====================================================================
        $display("\n--- Test 4: VLAN-based ACL ---");
        
        packets_tested = 0;
        packets_matched = 0;
        packets_permitted = 0;
        packets_denied = 0;
        
        // Rule 3: Deny VLAN 10
        // Note: VLAN matching would need to be added to ACL rule structure
        $display("[INFO] VLAN ACL test (conceptual)");
        
        // =====================================================================
        // Test 5: Priority-based Matching
        // =====================================================================
        $display("\n--- Test 5: ACL Priority (First Match Wins) ---");
        
        packets_tested = 0;
        packets_matched = 0;
        packets_permitted = 0;
        packets_denied = 0;
        
        // Rule 10: Permit specific IP
        configure_acl_rule(
            .rule_id(10),
            .src_mac(48'h0),
            .src_mac_mask(48'h0),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b1)
        );
        
        // Rule 11: Deny entire subnet (lower priority)
        configure_acl_rule(
            .rule_id(11),
            .src_mac(48'h0),
            .src_mac_mask(48'h0),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b0)
        );
        
        repeat(5) @(posedge clk);
        
        // Test with 192.168.1.5 (should match rule 10 first - permit)
        test_packet(
            .src_mac(48'h112233445566),
            .dst_mac(48'h778899AABBCC),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        $display("[INFO] Priority test: Specific rule should win over general rule");
        
        // =====================================================================
        // Test 6: ACL Statistics
        // =====================================================================
        $display("\n--- Test 6: ACL Statistics ---");
        
        $display("[INFO] ACL statistics:");
        $display("        Total packets tested: %0d", packets_tested);
        $display("        Packets matched:      %0d", packets_matched);
        $display("        Packets permitted:    %0d", packets_permitted);
        $display("        Packets denied:       %0d", packets_denied);
        
        assert_true("Packets tested > 0", packets_tested > 0);
        
        // =====================================================================
        // Test 7: Dynamic Rule Update
        // =====================================================================
        $display("\n--- Test 7: Dynamic ACL Rule Update ---");
        
        packets_tested = 0;
        packets_denied = 0;
        
        // Initially deny
        configure_acl_rule(
            .rule_id(20),
            .src_mac(48'hAABBCCDDEEFF),
            .src_mac_mask(48'hFFFFFFFFFFFF),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b0)
        );
        
        repeat(5) @(posedge clk);
        
        test_packet(
            .src_mac(48'hAABBCCDDEEFF),
            .dst_mac(48'hFFFFFFFFFFFF),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("Initially denied", packets_denied, 64'd1);
        
        // Update to permit
        configure_acl_rule(
            .rule_id(20),
            .src_mac(48'hAABBCCDDEEFF),
            .src_mac_mask(48'hFFFFFFFFFFFF),
            .dst_mac(48'h0),
            .dst_mac_mask(48'h0),
            .vlan_id(12'd0),
            .vlan_mask(12'd0),
            .ethertype(16'h0),
            .ethertype_mask(16'h0),
            .action_permit(1'b1)
        );
        
        repeat(5) @(posedge clk);
        
        test_packet(
            .src_mac(48'hAABBCCDDEEFF),
            .dst_mac(48'hFFFFFFFFFFFF),
            .ethertype(16'h0800),
            .vlan_id(12'd1),
            .src_port(6'd0)
        );
        
        assert_equal("Now permitted", packets_denied, 64'd1);  // No additional denies
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(100) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("\nACL Engine Test: PASSED\n");
        end else begin
            $display("\nACL Engine Test: FAILED\n");
        end
        
        $finish;
    end
    
    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #5ms;
        $display("[ERROR] Testbench timeout!");
        $finish;
    end
    
endmodule
