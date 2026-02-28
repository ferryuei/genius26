// =============================================================================
// Testbench Package - Common Utilities and Types
// =============================================================================
// Description:
//   Provides common utilities, tasks, and types for all testbenches
// =============================================================================

package tb_pkg;
    
    // =========================================================================
    // Test Status
    // =========================================================================
    int test_passed = 0;
    int test_failed = 0;
    int test_warnings = 0;
    
    // =========================================================================
    // Timing Parameters
    // =========================================================================
    time CLK_PERIOD = 6.4ns;  // 156.25MHz
    time RESET_TIME = 100ns;
    
    // =========================================================================
    // Ethernet Packet Types
    // =========================================================================
    typedef struct {
        logic [47:0] dst_mac;
        logic [47:0] src_mac;
        logic [15:0] ethertype;
        logic [11:0] vlan_id;
        logic [2:0]  vlan_pcp;
        logic        has_vlan;
        logic [15:0] payload_len;
        logic [7:0]  payload [$];
    } eth_packet_t;
    
    // =========================================================================
    // Test Utilities
    // =========================================================================
    
    // Generate random MAC address
    function automatic logic [47:0] random_mac();
        return {$random, $random} & 48'hFFFF_FFFF_FFFF;
    endfunction
    
    // Generate unicast MAC
    function automatic logic [47:0] random_unicast_mac();
        logic [47:0] mac;
        mac = random_mac();
        mac[40] = 1'b0;  // Clear multicast bit
        return mac;
    endfunction
    
    // Generate multicast MAC
    function automatic logic [47:0] random_multicast_mac();
        logic [47:0] mac;
        mac = random_mac();
        mac[40] = 1'b1;  // Set multicast bit
        return mac;
    endfunction
    
    // Build Ethernet frame
    function automatic void build_eth_frame(
        ref logic [63:0] data_queue [$],
        input eth_packet_t pkt
    );
        logic [63:0] word;
        int byte_idx;
        
        data_queue.delete();
        byte_idx = 0;
        word = '0;
        
        // Destination MAC (6 bytes)
        for (int i = 0; i < 6; i++) begin
            word[63-(byte_idx*8) -: 8] = pkt.dst_mac[(5-i)*8 +: 8];
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
        end
        
        // Source MAC (6 bytes)
        for (int i = 0; i < 6; i++) begin
            word[63-(byte_idx*8) -: 8] = pkt.src_mac[(5-i)*8 +: 8];
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
        end
        
        // VLAN tag (4 bytes) if present
        if (pkt.has_vlan) begin
            // TPID (0x8100)
            word[63-(byte_idx*8) -: 8] = 8'h81;
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
            
            word[63-(byte_idx*8) -: 8] = 8'h00;
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
            
            // TCI (PCP + DEI + VID)
            word[63-(byte_idx*8) -: 8] = {pkt.vlan_pcp, 1'b0, pkt.vlan_id[11:8]};
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
            
            word[63-(byte_idx*8) -: 8] = pkt.vlan_id[7:0];
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
        end
        
        // EtherType (2 bytes)
        word[63-(byte_idx*8) -: 8] = pkt.ethertype[15:8];
        byte_idx++;
        if (byte_idx == 8) begin
            data_queue.push_back(word);
            word = '0;
            byte_idx = 0;
        end
        
        word[63-(byte_idx*8) -: 8] = pkt.ethertype[7:0];
        byte_idx++;
        if (byte_idx == 8) begin
            data_queue.push_back(word);
            word = '0;
            byte_idx = 0;
        end
        
        // Payload
        foreach (pkt.payload[i]) begin
            word[63-(byte_idx*8) -: 8] = pkt.payload[i];
            byte_idx++;
            if (byte_idx == 8) begin
                data_queue.push_back(word);
                word = '0;
                byte_idx = 0;
            end
        end
        
        // Push last partial word
        if (byte_idx > 0) begin
            data_queue.push_back(word);
        end
    endfunction
    
    // =========================================================================
    // Assertion Macros
    // =========================================================================
    
    task assert_equal(
        input string name,
        input logic [63:0] actual,
        input logic [63:0] expected
    );
        if (actual === expected) begin
            $display("[PASS] %s: actual=0x%0h, expected=0x%0h", name, actual, expected);
            test_passed++;
        end else begin
            $display("[FAIL] %s: actual=0x%0h, expected=0x%0h", name, actual, expected);
            test_failed++;
        end
    endtask
    
    task assert_true(
        input string name,
        input logic condition
    );
        if (condition === 1'b1) begin
            $display("[PASS] %s", name);
            test_passed++;
        end else begin
            $display("[FAIL] %s: condition is false", name);
            test_failed++;
        end
    endtask
    
    task assert_false(
        input string name,
        input logic condition
    );
        if (condition === 1'b0) begin
            $display("[PASS] %s", name);
            test_passed++;
        end else begin
            $display("[FAIL] %s: condition is true", name);
            test_failed++;
        end
    endtask
    
    task print_summary();
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("PASSED: %0d", test_passed);
        $display("FAILED: %0d", test_failed);
        $display("WARNINGS: %0d", test_warnings);
        $display("========================================");
        if (test_failed == 0) begin
            $display("ALL TESTS PASSED!");
        end else begin
            $display("SOME TESTS FAILED!");
        end
        $display("========================================\n");
    endtask
    
    // =========================================================================
    // Wait Tasks
    // =========================================================================
    
    task wait_cycles(input int cycles);
        repeat(cycles) @(posedge tb_pkg::CLK_PERIOD);
    endtask
    
    task wait_ns(input time delay);
        #delay;
    endtask
    
endpackage
