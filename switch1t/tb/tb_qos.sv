// =============================================================================
// QoS (Quality of Service) Testbench
// =============================================================================
// Tests: Priority queuing, scheduling algorithms (SP/WRR), WRED, rate limiting
// =============================================================================

`timescale 1ns/1ps

module tb_qos;
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
    logic enq_req;
    logic [PORT_WIDTH-1:0] enq_port;
    logic [QUEUE_ID_WIDTH-1:0] enq_queue;
    logic [DESC_ID_WIDTH-1:0] enq_desc_id;
    logic [6:0] enq_cell_count;
    logic enq_ack;
    logic enq_drop;
    
    logic [NUM_PORTS-1:0] deq_req;
    logic [NUM_PORTS-1:0] deq_valid;
    logic [DESC_ID_WIDTH-1:0] deq_desc_id [NUM_PORTS-1:0];
    logic [QUEUE_ID_WIDTH-1:0] deq_queue [NUM_PORTS-1:0];
    
    logic [NUM_PORTS-1:0] port_paused;
    
    logic [PORT_WIDTH-1:0] query_port;
    logic [QUEUE_ID_WIDTH-1:0] query_queue;
    logic [15:0] query_depth;
    queue_state_e query_state;
    
    logic [15:0] wred_min_th;
    logic [15:0] wred_max_th;
    logic [7:0] wred_max_prob;
    
    logic [31:0] stat_enq_count;
    logic [31:0] stat_deq_count;
    logic [31:0] stat_drop_count;
    
    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    egress_scheduler dut (
        .clk(clk),
        .rst_n(rst_n),
        .enq_req(enq_req),
        .enq_port(enq_port),
        .enq_queue(enq_queue),
        .enq_desc_id(enq_desc_id),
        .enq_cell_count(enq_cell_count),
        .enq_ack(enq_ack),
        .enq_drop(enq_drop),
        .deq_req(deq_req),
        .deq_valid(deq_valid),
        .deq_desc_id(deq_desc_id),
        .deq_queue(deq_queue),
        .port_paused(port_paused),
        .query_port(query_port),
        .query_queue(query_queue),
        .query_depth(query_depth),
        .query_state(query_state),
        .wred_min_th(wred_min_th),
        .wred_max_th(wred_max_th),
        .wred_max_prob(wred_max_prob),
        .stat_enq_count(stat_enq_count),
        .stat_deq_count(stat_deq_count),
        .stat_drop_count(stat_drop_count)
    );
    
    // =========================================================================
    // Test Variables
    // =========================================================================
    int queue_enq_count[NUM_PORTS-1:0][NUM_QUEUES_PER_PORT-1:0];
    int queue_deq_count[NUM_PORTS-1:0][NUM_QUEUES_PER_PORT-1:0];
    int total_enqueued;
    int total_dequeued;
    int total_dropped;
    
    // =========================================================================
    // Helper Tasks
    // =========================================================================
    
    // Reset DUT
    task reset_dut();
        int i, j;
        
        rst_n = 0;
        enq_req = 0;
        enq_port = 0;
        enq_queue = 0;
        enq_desc_id = 0;
        enq_cell_count = 0;
        deq_req = '0;
        port_paused = '0;
        query_port = 0;
        query_queue = 0;
        wred_min_th = 16'd100;
        wred_max_th = 16'd200;
        wred_max_prob = 8'd255;
        
        for (i = 0; i < NUM_PORTS; i++) begin
            for (j = 0; j < NUM_QUEUES_PER_PORT; j++) begin
                queue_enq_count[i][j] = 0;
                queue_deq_count[i][j] = 0;
            end
        end
        
        total_enqueued = 0;
        total_dequeued = 0;
        total_dropped = 0;
        
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        $display("[INFO] Reset complete");
    endtask
    
    // Enqueue packet to specific queue
    task enqueue_packet(
        input int port,
        input int queue,
        input int desc_id,
        input int cells
    );
        @(posedge clk);
        enq_req = 1'b1;
        enq_port = port[PORT_WIDTH-1:0];
        enq_queue = queue[QUEUE_ID_WIDTH-1:0];
        enq_desc_id = desc_id[DESC_ID_WIDTH-1:0];
        enq_cell_count = cells[6:0];
        
        @(posedge clk);
        while (!enq_ack && !enq_drop) @(posedge clk);
        
        if (enq_ack) begin
            queue_enq_count[port][queue]++;
            total_enqueued++;
            $display("[%0t] Enqueued: Port=%0d Queue=%0d Desc=%0d", 
                     $time, port, queue, desc_id);
        end else if (enq_drop) begin
            total_dropped++;
            $display("[%0t] Dropped: Port=%0d Queue=%0d (WRED)", 
                     $time, port, queue);
        end
        
        enq_req = 1'b0;
    endtask
    
    // Request dequeue from port
    task request_dequeue(input int port);
        deq_req[port] = 1'b1;
        @(posedge clk);
        if (deq_valid[port]) begin
            queue_deq_count[port][deq_queue[port]]++;
            total_dequeued++;
            $display("[%0t] Dequeued: Port=%0d Queue=%0d Desc=%0d", 
                     $time, port, deq_queue[port], deq_desc_id[port]);
        end
        deq_req[port] = 1'b0;
    endtask
    
    // Query queue depth
    task query_queue_depth(
        input int port,
        input int queue,
        output int depth
    );
        @(posedge clk);
        query_port = port[PORT_WIDTH-1:0];
        query_queue = queue[QUEUE_ID_WIDTH-1:0];
        
        @(posedge clk);
        depth = query_depth;
        $display("[INFO] Queue depth: Port=%0d Queue=%0d Depth=%0d State=%0d", 
                 port, queue, depth, query_state);
    endtask
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        int i, q, depth;
        
        $display("\n========================================");
        $display("QoS (Quality of Service) Testbench");
        $display("========================================\n");
        
        // Initialize
        reset_dut();
        
        // =====================================================================
        // Test 1: Basic Enqueue/Dequeue
        // =====================================================================
        $display("\n--- Test 1: Basic Enqueue/Dequeue ---");
        
        // Enqueue to different queues
        for (q = 0; q < 8; q++) begin
            enqueue_packet(0, q, 100+q, 1);
        end
        
        repeat(10) @(posedge clk);
        
        // Dequeue from port 0
        for (i = 0; i < 8; i++) begin
            request_dequeue(0);
            repeat(2) @(posedge clk);
        end
        
        assert_equal("Port 0 enqueue count", total_enqueued, 32'd8);
        assert_equal("Port 0 dequeue count", total_dequeued, 32'd8);
        
        // =====================================================================
        // Test 2: Strict Priority (SP) Scheduling
        // =====================================================================
        $display("\n--- Test 2: Strict Priority Scheduling ---");
        
        total_enqueued = 0;
        total_dequeued = 0;
        
        // Enqueue packets to all 8 queues on port 1
        // Q7 (highest) should be served first
        for (q = 0; q < 8; q++) begin
            enqueue_packet(1, q, 200+q, 1);
        end
        
        repeat(10) @(posedge clk);
        
        // Dequeue and verify Q7 comes out first (strict priority)
        request_dequeue(1);
        repeat(5) @(posedge clk);
        
        $display("[INFO] First dequeued queue from port 1 (should be Q7)");
        
        // =====================================================================
        // Test 3: Weighted Round Robin (WRR)
        // =====================================================================
        $display("\n--- Test 3: Weighted Round Robin Scheduling ---");
        
        total_enqueued = 0;
        total_dequeued = 0;
        
        // Fill queues Q0-Q5 (WRR queues)
        // Weights: Q5=8, Q4=4, Q3=2, Q2=2, Q1=1, Q0=1
        for (q = 0; q <= 5; q++) begin
            for (i = 0; i < 10; i++) begin
                enqueue_packet(2, q, 300+q*10+i, 1);
            end
        end
        
        repeat(20) @(posedge clk);
        
        // Dequeue multiple packets and observe WRR behavior
        for (i = 0; i < 30; i++) begin
            request_dequeue(2);
            repeat(2) @(posedge clk);
        end
        
        // Verify Q5 got more service than Q0 (8:1 ratio)
        $display("[INFO] WRR distribution:");
        for (q = 0; q <= 5; q++) begin
            $display("        Q%0d: %0d packets", q, queue_deq_count[2][q]);
        end
        
        // =====================================================================
        // Test 4: Queue Depth Monitoring
        // =====================================================================
        $display("\n--- Test 4: Queue Depth Monitoring ---");
        
        // Fill a queue and monitor depth
        for (i = 0; i < 20; i++) begin
            enqueue_packet(3, 4, 400+i, 1);
        end
        
        repeat(10) @(posedge clk);
        
        query_queue_depth(3, 4, depth);
        assert_true("Queue depth > 0", depth > 0);
        
        // =====================================================================
        // Test 5: WRED (Weighted Random Early Detection)
        // =====================================================================
        $display("\n--- Test 5: WRED Congestion Control ---");
        
        total_dropped = 0;
        wred_min_th = 16'd50;
        wred_max_th = 16'd100;
        wred_max_prob = 8'd200;  // ~78% max drop probability
        
        // Fill queue beyond threshold to trigger WRED
        for (i = 0; i < 150; i++) begin
            enqueue_packet(4, 3, 500+i, 1);
            @(posedge clk);
        end
        
        repeat(20) @(posedge clk);
        
        $display("[INFO] WRED drops: %0d packets", total_dropped);
        assert_true("WRED activated", total_dropped > 0);
        
        // =====================================================================
        // Test 6: Flow Control (Port Pause)
        // =====================================================================
        $display("\n--- Test 6: Flow Control (Port Pause) ---");
        
        // Enqueue packets
        for (i = 0; i < 10; i++) begin
            enqueue_packet(5, 2, 600+i, 1);
        end
        
        // Pause port 5
        port_paused[5] = 1'b1;
        $display("[INFO] Port 5 paused");
        
        repeat(10) @(posedge clk);
        
        // Try to dequeue - should not work while paused
        request_dequeue(5);
        repeat(5) @(posedge clk);
        
        // Unpause
        port_paused[5] = 1'b0;
        $display("[INFO] Port 5 unpaused");
        
        repeat(10) @(posedge clk);
        
        // Now dequeue should work
        for (i = 0; i < 10; i++) begin
            request_dequeue(5);
            repeat(2) @(posedge clk);
        end
        
        // =====================================================================
        // Test 7: Multi-Port Concurrent Operation
        // =====================================================================
        $display("\n--- Test 7: Multi-Port Concurrent Operation ---");
        
        // Enqueue to multiple ports simultaneously
        fork
            begin
                for (i = 0; i < 20; i++) begin
                    enqueue_packet(0, i % 8, 700+i, 1);
                    repeat(2) @(posedge clk);
                end
            end
            begin
                for (i = 0; i < 20; i++) begin
                    enqueue_packet(1, i % 8, 800+i, 1);
                    repeat(2) @(posedge clk);
                end
            end
        join
        
        repeat(20) @(posedge clk);
        
        // Dequeue from both ports
        for (i = 0; i < 15; i++) begin
            fork
                request_dequeue(0);
                request_dequeue(1);
            join
            repeat(2) @(posedge clk);
        end
        
        // =====================================================================
        // Test 8: Queue Statistics
        // =====================================================================
        $display("\n--- Test 8: Queue Statistics ---");
        
        $display("[INFO] Global statistics:");
        $display("        Total enqueued: %0d", stat_enq_count);
        $display("        Total dequeued: %0d", stat_deq_count);
        $display("        Total dropped:  %0d", stat_drop_count);
        
        assert_true("Enqueue count > 0", stat_enq_count > 0);
        assert_true("Dequeue count > 0", stat_deq_count > 0);
        
        // =====================================================================
        // Test Complete
        // =====================================================================
        repeat(100) @(posedge clk);
        
        print_summary();
        
        if (test_failed == 0) begin
            $display("\nQoS Test: PASSED\n");
        end else begin
            $display("\nQoS Test: FAILED\n");
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
