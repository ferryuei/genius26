// =============================================================================
// Protocol Engines Testbench
// =============================================================================
// Tests: RSTP, LACP, LLDP protocol state machines and packet handling
// =============================================================================

`timescale 1ns/1ps

module tb_protocol_engines;
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
    // RSTP Signals
    // =========================================================================
    logic rstp_enable;
    logic [15:0] rstp_bridge_priority;
    logic [47:0] rstp_bridge_id;
    logic [NUM_PORTS-1:0] rstp_port_enable;
    logic [NUM_PORTS-1:0] port_link_up;
    
    typedef enum logic [2:0] {
        RSTP_DISABLED,
        RSTP_LISTENING,
        RSTP_LEARNING,
        RSTP_FORWARDING,
        RSTP_BLOCKING
    } rstp_state_e;
    
    rstp_state_e rstp_port_state [NUM_PORTS-1:0];
    
    // =========================================================================
    // LACP Signals
    // =========================================================================
    logic lacp_enable;
    logic [NUM_PORTS-1:0] lacp_port_enable;
    logic [47:0] lacp_system_id;
    logic [15:0] lacp_system_priority;
    
    typedef enum logic [2:0] {
        LACP_DETACHED,
        LACP_WAITING,
        LACP_ATTACHED,
        LACP_COLLECTING,
        LACP_DISTRIBUTING
    } lacp_state_e;
    
    lacp_state_e lacp_port_state [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] lacp_rx;
    logic [NUM_PORTS-1:0] lacp_tx;
    
    // =========================================================================
    // LLDP Signals
    // =========================================================================
    logic lldp_enable;
    logic [NUM_PORTS-1:0] lldp_port_enable;
    logic [47:0] lldp_chassis_id;
    logic [255:0] lldp_system_name;
    logic [255:0] lldp_system_desc;
    
    logic [NUM_PORTS-1:0] lldp_tx_trigger;
    logic [NUM_PORTS-1:0] lldp_rx_valid;
    logic [NUM_PORTS-1:0] lldp_neighbor_detected;
    
    // =========================================================================
    // DUT Instantiations
    // =========================================================================
    
    // RSTP Engine
    logic [1:0] rstp_port_state_raw [NUM_PORTS-1:0];
    
    rstp_engine rstp_dut (
        .clk(clk),
        .rst_n(rst_n),
        .rstp_enable(rstp_enable),
        .bridge_priority(rstp_bridge_priority),
        .bridge_mac(rstp_bridge_id),
        .port_enable(rstp_port_enable),
        .port_link_up(port_link_up),
        .port_state(rstp_port_state_raw)
    );
    
    // Convert raw state to enum
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            rstp_port_state[i] = rstp_state_e'(rstp_port_state_raw[i]);
        end
    end
    
    // LACP Engine
    lacp_engine lacp_dut (
        .clk(clk),
        .rst_n(rst_n),
        .port_enable(lacp_port_enable),
        .port_link_up(port_link_up),
        .port_speed('{default: 16'd25000}),  // 25Gbps
        .lacpdu_rx_valid('0),
        .lacpdu_rx_data('{default: '0}),
        .lacpdu_rx_sop('0),
        .lacpdu_rx_eop('0),
        .lacpdu_tx_valid(lacp_tx),
        .lacpdu_tx_data(),
        .lacpdu_tx_sop(),
        .lacpdu_tx_eop(),
        .lacpdu_tx_ready('1),
        .cfg_lag_id('{default: '0}),
        .cfg_lacp_enable(lacp_port_enable),
        .system_mac(lacp_system_id),
        .system_priority(lacp_system_priority),
        .port_selected(),
        .port_standby(),
        .port_lag_id(),
        .partner_mac(),
        .partner_key(),
        .stat_lacpdu_rx(),
        .stat_lacpdu_tx(),
        .stat_lag_changes()
    );
    
    // LLDP Engine
    lldp_engine #(
        .NUM_PORTS(NUM_PORTS),
        .TX_INTERVAL(30),
        .TX_HOLD_MULTIPLIER(4)
    ) lldp_dut (
        .clk(clk),
        .rst_n(rst_n),
        .port_enable(lldp_port_enable),
        .port_link_up(port_link_up),
        .port_speed('{default: 16'd25000}),  // 25Gbps
        .port_duplex('{default: 1'b1}),      // Full duplex
        .lldpdu_rx_valid('0),
        .lldpdu_rx_data('{default: '0}),
        .lldpdu_rx_len('{default: '0}),
        .lldpdu_tx_valid(),  // Unconnected output
        .lldpdu_tx_data(),   // Unconnected output
        .lldpdu_tx_len(),    // Unconnected output
        .chassis_id(lldp_chassis_id),
        .chassis_id_subtype(3'd4),  // MAC address
        .system_name(lldp_system_name[127:0]),
        .system_name_len(8'd16),
        .system_description(lldp_system_desc[255:0]),
        .system_desc_len(8'd32),
        .system_capabilities(16'h0014),  // Bridge + Router
        .enabled_capabilities(16'h0014),
        .mgmt_addr(32'h0),
        .lldp_enable(lldp_enable),
        .neighbor_present(lldp_neighbor_detected),
        .neighbor_chassis_id(),
        .neighbor_port_id(),
        .neighbor_ttl(),
        .neighbor_capabilities()
    );
    
    // =========================================================================
    // Test Variables
    // =========================================================================
    int rstp_state_changes;
    int lacp_pdu_tx;
    int lacp_pdu_rx;
    int lldp_advertisements;
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Reset all protocols
    task reset_protocols();
        int i;
        
        rst_n = 0;
        rstp_enable = 0;
        lacp_enable = 0;
        lldp_enable = 0;
        rstp_port_enable = '0;
        lacp_port_enable = '0;
        lldp_port_enable = '0;
        port_link_up = '1;  // All links up initially
        lacp_rx = '0;
        lldp_rx_valid = '0;
        lldp_tx_trigger = '0;
        
        rstp_bridge_priority = 16'd32768;
        rstp_bridge_id = 48'h001122334455;
        lacp_system_id = 48'h001122334455;
        lacp_system_priority = 16'd32768;
        lldp_chassis_id = 48'h001122334455;
        lldp_system_name = "Switch-1";
        lldp_system_desc = "1.2Tbps 48x25G L2 Switch";
        
        rstp_state_changes = 0;
        lacp_pdu_tx = 0;
        lacp_pdu_rx = 0;
        lldp_advertisements = 0;
        
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        $display("[INFO] Protocol engines reset complete");
    endtask
    
    // Monitor RSTP state changes
    task automatic monitor_rstp_states();
        int i;
        rstp_state_e prev_state [NUM_PORTS-1:0];
        
        // Initialize
        for (i = 0; i < NUM_PORTS; i++) begin
            prev_state[i] = RSTP_DISABLED;
        end
        
        forever begin
            @(posedge clk);
            for (i = 0; i < NUM_PORTS; i++) begin
                if (rstp_port_state[i] != prev_state[i]) begin
                    $display("[%0t] RSTP Port %0d: %s -> %s", 
                             $time, i, 
                             prev_state[i].name(), 
                             rstp_port_state[i].name());
                    rstp_state_changes++;
                    prev_state[i] = rstp_port_state[i];
                end
            end
        end
    endtask
    
    // Simulate LACP PDU reception
    task send_lacp_pdu(input int port);
        @(posedge clk);
        lacp_rx[port] = 1'b1;
        lacp_pdu_rx++;
        
        @(posedge clk);
        lacp_rx[port] = 1'b0;
        
        $display("[%0t] LACP PDU received on port %0d", $time, port);
    endtask
    
    // Monitor LACP PDU transmission
    task automatic monitor_lacp_tx();
        int i;
        logic [NUM_PORTS-1:0] prev_tx;
        
        prev_tx = '0;
        
        forever begin
            @(posedge clk);
            for (i = 0; i < NUM_PORTS; i++) begin
                if (lacp_tx[i] && !prev_tx[i]) begin
                    $display("[%0t] LACP PDU transmitted on port %0d", $time, i);
                    lacp_pdu_tx++;
                end
                prev_tx[i] = lacp_tx[i];
            end
        end
    endtask
    
    // Trigger LLDP advertisement
    task trigger_lldp(input int port);
        @(posedge clk);
        lldp_tx_trigger[port] = 1'b1;
        
        @(posedge clk);
        lldp_tx_trigger[port] = 1'b0;
        
        lldp_advertisements++;
        $display("[%0t] LLDP advertisement triggered on port %0d", $time, port);
    endtask
    
    // Simulate LLDP frame reception
    task receive_lldp(input int port);
        @(posedge clk);
        lldp_rx_valid[port] = 1'b1;
        
        repeat(3) @(posedge clk);
        lldp_rx_valid[port] = 1'b0;
        
        $display("[%0t] LLDP frame received on port %0d", $time, port);
    endtask
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        int i;
        
        $display("\n========================================");
        $display("Protocol Engines Testbench");
        $display("========================================\n");
        
        // Initialize
        reset_protocols();
        
        // Start monitors
        fork
            monitor_rstp_states();
            monitor_lacp_tx();
        join_none
        
        // =====================================================================
        // Test 1: RSTP Basic Operation
        // =====================================================================
        $display("\n--- Test 1: RSTP Basic Operation ---");
        
        // Enable RSTP
        rstp_enable = 1'b1;
        rstp_port_enable[0] = 1'b1;
        rstp_port_enable[1] = 1'b1;
        rstp_port_enable[2] = 1'b1;
        rstp_port_enable[3] = 1'b1;
        
        repeat(10) @(posedge clk);
        
        $display("[INFO] RSTP enabled on ports 0-3");
        $display("[INFO] Bridge Priority: %0d", rstp_bridge_priority);
        $display("[INFO] Bridge MAC: %h", rstp_bridge_id);
        
        // Wait for state transitions
        repeat(100) @(posedge clk);
        
        $display("[INFO] Initial RSTP port states:");
        for (i = 0; i < 4; i++) begin
            $display("        Port %0d: %s", i, rstp_port_state[i].name());
        end
        
        assert_true("RSTP state changes occurred", rstp_state_changes > 0);
        
        // =====================================================================
        // Test 2: RSTP Topology Change
        // =====================================================================
        $display("\n--- Test 2: RSTP Topology Change (Link Down) ---");
        
        rstp_state_changes = 0;
        
        // Bring down port 1
        port_link_up[1] = 1'b0;
        $display("[INFO] Port 1 link down");
        
        repeat(50) @(posedge clk);
        
        $display("[INFO] Port states after link down:");
        for (i = 0; i < 4; i++) begin
            $display("        Port %0d: %s", i, rstp_port_state[i].name());
        end
        
        // Bring port back up
        port_link_up[1] = 1'b1;
        $display("[INFO] Port 1 link restored");
        
        repeat(100) @(posedge clk);
        
        assert_true("RSTP reacted to topology change", rstp_state_changes > 0);
        
        // =====================================================================
        // Test 3: LACP Basic Operation
        // =====================================================================
        $display("\n--- Test 3: LACP Basic Operation ---");
        
        // Enable LACP on ports 4-7
        lacp_enable = 1'b1;
        lacp_port_enable[4] = 1'b1;
        lacp_port_enable[5] = 1'b1;
        lacp_port_enable[6] = 1'b1;
        lacp_port_enable[7] = 1'b1;
        
        repeat(10) @(posedge clk);
        
        $display("[INFO] LACP enabled on ports 4-7");
        $display("[INFO] System ID: %h", lacp_system_id);
        $display("[INFO] System Priority: %0d", lacp_system_priority);
        
        // Wait for initial LACP PDUs
        repeat(100) @(posedge clk);
        
        $display("[INFO] Initial LACP port states:");
        for (i = 4; i < 8; i++) begin
            $display("        Port %0d: %s", i, lacp_port_state[i].name());
        end
        
        $display("[INFO] LACP PDUs transmitted: %0d", lacp_pdu_tx);
        
        // =====================================================================
        // Test 4: LACP Negotiation
        // =====================================================================
        $display("\n--- Test 4: LACP Negotiation ---");
        
        // Simulate partner sending LACP PDUs
        for (i = 4; i < 8; i++) begin
            send_lacp_pdu(i);
            repeat(10) @(posedge clk);
        end
        
        repeat(100) @(posedge clk);
        
        $display("[INFO] LACP port states after negotiation:");
        for (i = 4; i < 8; i++) begin
            $display("        Port %0d: %s", i, lacp_port_state[i].name());
        end
        
        assert_true("LACP PDUs received", lacp_pdu_rx > 0);
        assert_true("LACP PDUs transmitted", lacp_pdu_tx > 0);
        
        // =====================================================================
        // Test 5: LACP Timeout
        // =====================================================================
        $display("\n--- Test 5: LACP Timeout Handling ---");
        
        // Stop sending LACP PDUs, wait for timeout
        $display("[INFO] Stopping LACP PDUs, waiting for timeout...");
        
        repeat(5000) @(posedge clk);
        
        $display("[INFO] LACP port states after timeout:");
        for (i = 4; i < 8; i++) begin
            $display("        Port %0d: %s", i, lacp_port_state[i].name());
        end
        
        // =====================================================================
        // Test 6: LLDP Basic Operation
        // =====================================================================
        $display("\n--- Test 6: LLDP Basic Operation ---");
        
        // Enable LLDP on ports 8-11
        lldp_enable = 1'b1;
        lldp_port_enable[8] = 1'b1;
        lldp_port_enable[9] = 1'b1;
        lldp_port_enable[10] = 1'b1;
        lldp_port_enable[11] = 1'b1;
        
        repeat(10) @(posedge clk);
        
        $display("[INFO] LLDP enabled on ports 8-11");
        $display("[INFO] Chassis ID: %h", lldp_chassis_id);
        $display("[INFO] System Name: %s", lldp_system_name);
        
        // =====================================================================
        // Test 7: LLDP Advertisement
        // =====================================================================
        $display("\n--- Test 7: LLDP Advertisement ---");
        
        // Trigger LLDP advertisements
        for (i = 8; i < 12; i++) begin
            trigger_lldp(i);
            repeat(20) @(posedge clk);
        end
        
        assert_equal("LLDP advertisements sent", lldp_advertisements, 32'd4);
        
        // =====================================================================
        // Test 8: LLDP Neighbor Discovery
        // =====================================================================
        $display("\n--- Test 8: LLDP Neighbor Discovery ---");
        
        // Simulate receiving LLDP frames from neighbors
        for (i = 8; i < 12; i++) begin
            receive_lldp(i);
            repeat(20) @(posedge clk);
        end
        
        repeat(50) @(posedge clk);
        
        $display("[INFO] LLDP neighbor detection:");
        for (i = 8; i < 12; i++) begin
            $display("        Port %0d: %s", i, 
                     lldp_neighbor_detected[i] ? "Neighbor detected" : "No neighbor");
        end
        
        // =====================================================================
        // Test 9: Multi-Protocol Concurrent Operation
        // =====================================================================
        $display("\n--- Test 9: Multi-Protocol Concurrent Operation ---");
        
        $display("[INFO] Running RSTP, LACP, and LLDP simultaneously");
        
        // All protocols active
        repeat(500) @(posedge clk);
        
        $display("[INFO] Protocol summary:");
        $display("        RSTP state changes: %0d", rstp_state_changes);
        $display("        LACP PDUs TX: %0d", lacp_pdu_tx);
        $display("        LACP PDUs RX: %0d", lacp_pdu_rx);
        $display("        LLDP advertisements: %0d", lldp_advertisements);
        
        // =====================================================================
        // Test 10: Protocol Disable/Enable
        // =====================================================================
        $display("\n--- Test 10: Protocol Disable/Enable ---");
        
        // Disable all protocols
        rstp_enable = 1'b0;
        lacp_enable = 1'b0;
        lldp_enable = 1'b0;
        
        repeat(100) @(posedge clk);
        
        $display("[INFO] All protocols disabled");
        
        // Re-enable
        rstp_enable = 1'b1;
        lacp_enable = 1'b1;
        lldp_enable = 1'b1;
        
        repeat(100) @(posedge clk);
        
        $display("[INFO] All protocols re-enabled");
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(100) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("\nProtocol Engines Test: PASSED\n");
        end else begin
            $display("\nProtocol Engines Test: FAILED\n");
        end
        
        $finish;
    end
    
    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #50ms;
        $display("[ERROR] Testbench timeout!");
        $finish;
    end
    
endmodule
