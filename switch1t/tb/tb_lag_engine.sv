// =============================================================================
// LAG Engine Testbench
// =============================================================================
// Tests Link Aggregation Group functionality including load balancing
// =============================================================================

`timescale 1ns/1ps

module tb_lag_engine;
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
    logic lookup_req;
    logic [PORT_WIDTH-1:0] lookup_port;
    logic lookup_valid;
    logic is_lag_port;
    logic [2:0] lag_id;
    
    logic distribute_req;
    logic [2:0] dist_lag_id;
    logic [47:0] dist_smac;
    logic [47:0] dist_dmac;
    logic [VLAN_ID_WIDTH-1:0] dist_vid;
    logic distribute_valid;
    logic [PORT_WIDTH-1:0] selected_port;
    
    logic cfg_wr_en;
    logic [2:0] cfg_lag_id;
    logic [NUM_PORTS-1:0] cfg_member_mask;
    logic cfg_enabled;
    logic [1:0] cfg_hash_mode;
    
    logic [NUM_PORTS-1:0] port_link_up;
    
    logic [31:0] stat_lag_rx [7:0];
    logic [31:0] stat_lag_tx [7:0];
    
    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    lag_engine dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req     (lookup_req),
        .lookup_port    (lookup_port),
        .lookup_valid   (lookup_valid),
        .is_lag_port    (is_lag_port),
        .lag_id         (lag_id),
        .distribute_req (distribute_req),
        .dist_lag_id    (dist_lag_id),
        .dist_smac      (dist_smac),
        .dist_dmac      (dist_dmac),
        .dist_vid       (dist_vid),
        .distribute_valid(distribute_valid),
        .selected_port  (selected_port),
        .cfg_wr_en      (cfg_wr_en),
        .cfg_lag_id     (cfg_lag_id),
        .cfg_member_mask(cfg_member_mask),
        .cfg_enabled    (cfg_enabled),
        .cfg_hash_mode  (cfg_hash_mode),
        .port_link_up   (port_link_up),
        .stat_lag_rx    (stat_lag_rx),
        .stat_lag_tx    (stat_lag_tx)
    );
    
    // =========================================================================
    // Test Variables
    // =========================================================================
    int port_distribution[NUM_PORTS-1:0];
    int total_distributions;
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Reset DUT
    task reset_dut();
        rst_n = 0;
        lookup_req = 0;
        distribute_req = 0;
        cfg_wr_en = 0;
        port_link_up = '1;  // All links up
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        $display("[INFO] Reset complete");
    endtask
    
    // Configure LAG group
    task configure_lag(
        input logic [2:0] lag_id,
        input logic [NUM_PORTS-1:0] member_mask,
        input logic [1:0] hash_mode
    );
        @(posedge clk);
        cfg_wr_en = 1;
        cfg_lag_id = lag_id;
        cfg_member_mask = member_mask;
        cfg_enabled = 1;
        cfg_hash_mode = hash_mode;
        
        @(posedge clk);
        cfg_wr_en = 0;
        
        $display("[INFO] Configured LAG %0d: members=0x%0h, mode=%0d", 
                 lag_id, member_mask, hash_mode);
    endtask
    
    // Lookup if port is in LAG
    task lookup_lag_port(
        input logic [PORT_WIDTH-1:0] port,
        output logic is_lag,
        output logic [2:0] group_id
    );
        @(posedge clk);
        lookup_req = 1;
        lookup_port = port;
        
        @(posedge clk);
        lookup_req = 0;
        
        wait(lookup_valid);
        @(posedge clk);
        
        is_lag = is_lag_port;
        group_id = lag_id;
        
        if (is_lag) begin
            $display("[INFO] Port %0d is in LAG %0d", port, group_id);
        end else begin
            $display("[INFO] Port %0d is not in any LAG", port);
        end
    endtask
    
    // Distribute traffic to LAG
    task distribute_traffic(
        input logic [2:0] lag_group,
        input logic [47:0] smac,
        input logic [47:0] dmac,
        input logic [11:0] vid,
        output logic [PORT_WIDTH-1:0] selected
    );
        @(posedge clk);
        distribute_req = 1;
        dist_lag_id = lag_group;
        dist_smac = smac;
        dist_dmac = dmac;
        dist_vid = vid;
        
        @(posedge clk);
        distribute_req = 0;
        
        wait(distribute_valid);
        @(posedge clk);
        
        selected = selected_port;
        port_distribution[selected]++;
        total_distributions++;
        
        $display("[INFO] LAG %0d selected port %0d for SMAC=%h DMAC=%h", 
                 lag_group, selected, smac, dmac);
    endtask
    
    // =========================================================================
    // Main Test
    // =========================================================================
    initial begin
        logic is_lag;
        logic [2:0] group_id;
        logic [PORT_WIDTH-1:0] selected_port_test;
        int i;
        
        $display("\n========================================");
        $display("LAG Engine Testbench");
        $display("========================================\n");
        
        // Initialize
        reset_dut();
        total_distributions = 0;
        for (i = 0; i < NUM_PORTS; i++) begin
            port_distribution[i] = 0;
        end
        
        // =====================================================================
        // Test 1: LAG Group Configuration
        // =====================================================================
        $display("\n--- Test 1: LAG Group Configuration ---");
        
        // Configure LAG 1 with ports 0-3
        configure_lag(3'd1, 48'h000F, 2'd2);  // L2+L3+L4 hash
        
        // Configure LAG 2 with ports 4-7
        configure_lag(3'd2, 48'h00F0, 2'd2);
        
        repeat(10) @(posedge clk);
        
        // =====================================================================
        // Test 2: LAG Port Lookup
        // =====================================================================
        $display("\n--- Test 2: LAG Port Lookup ---");
        
        // Check ports in LAG 1
        lookup_lag_port(6'd0, is_lag, group_id);
        assert_true("Port 0 in LAG", is_lag);
        assert_equal("Port 0 LAG ID", group_id, 3'd1);
        
        lookup_lag_port(6'd3, is_lag, group_id);
        assert_true("Port 3 in LAG", is_lag);
        assert_equal("Port 3 LAG ID", group_id, 3'd1);
        
        // Check ports in LAG 2
        lookup_lag_port(6'd4, is_lag, group_id);
        assert_true("Port 4 in LAG", is_lag);
        assert_equal("Port 4 LAG ID", group_id, 3'd2);
        
        // Check port not in any LAG
        lookup_lag_port(6'd10, is_lag, group_id);
        assert_false("Port 10 not in LAG", is_lag);
        
        // =====================================================================
        // Test 3: Load Balancing - L2 Hash
        // =====================================================================
        $display("\n--- Test 3: Load Balancing - L2 Hash ---");
        begin
            logic [47:0] smac, dmac;
            int p;
            real percentage;
            
            // Reconfigure with L2 hash only
            configure_lag(3'd1, 48'h000F, 2'd0);  // L2 hash mode
            
            // Send 100 flows with different MAC addresses
            for (i = 0; i < 100; i++) begin
                smac = {32'h00112233, i[15:0]};
                dmac = {32'h44556677, i[15:0]};
                distribute_traffic(3'd1, smac, dmac, 12'd1, selected_port_test);
            end
            
            // Analyze distribution
            $display("\n[INFO] Load distribution for LAG 1 (100 flows):");
            for (p = 0; p < 4; p++) begin
                percentage = (port_distribution[p] * 100.0) / 100.0;
                $display("        Port %0d: %0d flows (%.1f%%)", 
                         p, port_distribution[p], percentage);
            end
            
            // Check if distribution is reasonable (each port should get 15-35%)
            for (p = 0; p < 4; p++) begin
                if (port_distribution[p] < 15 || port_distribution[p] > 35) begin
                    $display("[WARN] Port %0d distribution outside expected range", p);
                    test_warnings++;
                end
            end
        end
        
        // =====================================================================
        // Test 4: Link Failure Handling
        // =====================================================================
        $display("\n--- Test 4: Link Failure Handling ---");
        begin
            logic [47:0] smac, dmac;
            int p;
            
            // Clear distribution counters
            for (i = 0; i < NUM_PORTS; i++) begin
                port_distribution[i] = 0;
            end
            
            // Bring down port 0
            port_link_up[0] = 1'b0;
            $display("[INFO] Port 0 link down");
            
            repeat(10) @(posedge clk);
            
            // Send 60 flows - should only use ports 1-3 now
            for (i = 0; i < 60; i++) begin
                smac = {32'h00112233, i[15:0]};
                dmac = {32'h44556677, i[15:0]};
                distribute_traffic(3'd1, smac, dmac, 12'd1, selected_port_test);
            end
            
            $display("\n[INFO] Distribution after port 0 failure:");
            for (p = 0; p < 4; p++) begin
                $display("        Port %0d: %0d flows", p, port_distribution[p]);
            end
            
            assert_equal("Port 0 not used", port_distribution[0], 32'd0);
            assert_true("Port 1 used", port_distribution[1] > 0);
            
            // Bring port 0 back up
            port_link_up[0] = 1'b1;
            $display("[INFO] Port 0 link restored");
        end
        
        // =====================================================================
        // Test 5: Hash Mode Comparison
        // =====================================================================
        $display("\n--- Test 5: Hash Mode Comparison ---");
        begin
            int p;
            
            // Test L2 mode
            for (i = 0; i < NUM_PORTS; i++) port_distribution[i] = 0;
            configure_lag(3'd1, 48'h000F, 2'd0);  // L2 only
            
            for (i = 0; i < 40; i++) begin
                distribute_traffic(3'd1, 
                                  {32'h00112233, i[15:0]},
                                  {32'h44556677, i[15:0]},
                                  12'd1, selected_port_test);
            end
            
            $display("\n[INFO] L2 Hash Mode:");
            for (p = 0; p < 4; p++) begin
                $display("        Port %0d: %0d flows", p, port_distribution[p]);
            end
            
            // Test L3 mode
            for (i = 0; i < NUM_PORTS; i++) port_distribution[i] = 0;
            configure_lag(3'd1, 48'h000F, 2'd1);  // L2+L3
            
            for (i = 0; i < 40; i++) begin
                distribute_traffic(3'd1,
                                  {32'h00112233, i[15:0]},
                                  {32'h44556677, i[15:0]},
                                  12'd1, selected_port_test);
            end
            
            $display("\n[INFO] L2+L3 Hash Mode:");
            for (p = 0; p < 4; p++) begin
                $display("        Port %0d: %0d flows", p, port_distribution[p]);
            end
        end
        
        // =====================================================================
        // Test 6: Multiple LAG Groups
        // =====================================================================
        $display("\n--- Test 6: Multiple LAG Groups ---");
        begin
            int lag;
            
            // Configure 3 LAG groups
            configure_lag(3'd1, 48'h000F, 2'd2);  // Ports 0-3
            configure_lag(3'd2, 48'h00F0, 2'd2);  // Ports 4-7
            configure_lag(3'd3, 48'h0F00, 2'd2);  // Ports 8-11
            
            // Test each LAG
            for (lag = 1; lag <= 3; lag++) begin
                $display("\n[INFO] Testing LAG %0d", lag);
                for (i = 0; i < 10; i++) begin
                    distribute_traffic(lag[2:0],
                                      random_unicast_mac(),
                                      random_unicast_mac(),
                                      12'd1, selected_port_test);
                end
            end
        end
        
        // =====================================================================
        // Test 7: LAG Statistics
        // =====================================================================
        $display("\n--- Test 7: LAG Statistics ---");
        begin
            int stat_idx;
            
            $display("\n[INFO] LAG Rx/Tx Statistics:");
            for (stat_idx = 0; stat_idx < 3; stat_idx++) begin
                $display("        LAG %0d: Rx=%0d Tx=%0d", 
                         stat_idx, stat_lag_rx[stat_idx], stat_lag_tx[stat_idx]);
            end
        end
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(50) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("LAG Engine Test: PASSED\n");
        end else begin
            $display("LAG Engine Test: FAILED\n");
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
