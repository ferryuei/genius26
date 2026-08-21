`timescale 1ns/1ps

module tb_switch2_ingress_frontend;
    import switch2_pkg::*;

    localparam int unsigned TEST_PORTS = 4;

    logic clk;
    logic rst_n;
    logic [TEST_PORTS-1:0] rx_valid;
    logic [TEST_PORTS-1:0] rx_ready;
    logic [TEST_PORTS-1:0] rx_sop;
    logic [TEST_PORTS-1:0] rx_eop;
    logic [PORT_DATA_WIDTH-1:0] rx_data [TEST_PORTS-1:0];
    logic [PORT_EMPTY_WIDTH-1:0] rx_empty [TEST_PORTS-1:0];
    logic [TEST_PORTS-1:0] lane_valid;
    logic [TEST_PORTS-1:0] lane_ready;
    logic [TEST_PORTS-1:0] lane_sop;
    logic [TEST_PORTS-1:0] lane_eop;
    logic [PORT_DATA_WIDTH-1:0] lane_data [TEST_PORTS-1:0];
    logic [PORT_EMPTY_WIDTH-1:0] lane_empty [TEST_PORTS-1:0];

    switch2_ingress_frontend #(
        .PORTS(TEST_PORTS),
        .FIFO_DEPTH(4)
    ) dut (
        .clk,
        .rst_n,
        .rx_valid,
        .rx_ready,
        .rx_sop,
        .rx_eop,
        .rx_data,
        .rx_empty,
        .lane_valid,
        .lane_ready,
        .lane_sop,
        .lane_eop,
        .lane_data,
        .lane_empty
    );

    always #1 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        rx_valid = '0;
        rx_sop = '0;
        rx_eop = '0;
        lane_ready = '0;
        for (int port = 0; port < TEST_PORTS; port++) begin
            rx_data[port] = '0;
            rx_empty[port] = '0;
        end

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        if (rx_ready !== '1) $fatal(1, "all independent ingress FIFOs must be ready");

        // Two ports handshake in the same cycle. Neither may be discarded.
        @(negedge clk);
        rx_valid[0] = 1'b1;
        rx_sop[0] = 1'b1;
        rx_eop[0] = 1'b1;
        rx_data[0] = 64'h0011_2233_4455_6677;
        rx_valid[1] = 1'b1;
        rx_sop[1] = 1'b1;
        rx_eop[1] = 1'b1;
        rx_data[1] = 64'h8899_AABB_CCDD_EEFF;
        @(negedge clk);
        rx_valid = '0;
        rx_sop = '0;
        rx_eop = '0;

        if (!lane_valid[0] || !lane_valid[1])
            $fatal(1, "simultaneous port beats were not retained");
        if (lane_data[0] !== 64'h0011_2233_4455_6677)
            $fatal(1, "port 0 data mismatch");
        if (lane_data[1] !== 64'h8899_AABB_CCDD_EEFF)
            $fatal(1, "port 1 data mismatch");

        // Consume only port 0 and prove port 1 remains stable under backpressure.
        lane_ready[0] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        lane_ready[0] = 1'b0;
        if (lane_valid[0]) $fatal(1, "port 0 FIFO did not pop");
        if (!lane_valid[1]) $fatal(1, "port 1 beat was lost while stalled");
        if (lane_data[1] !== 64'h8899_AABB_CCDD_EEFF)
            $fatal(1, "port 1 data changed under backpressure");

        lane_ready[1] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (lane_valid[1]) $fatal(1, "port 1 FIFO did not pop");

        $display("PASS: independent simultaneous ingress and backpressure");
        $finish;
    end

endmodule : tb_switch2_ingress_frontend
