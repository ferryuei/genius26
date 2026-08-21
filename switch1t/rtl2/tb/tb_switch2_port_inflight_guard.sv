`timescale 1ns/1ps

module tb_switch2_port_inflight_guard;
    import switch2_pkg::*;

    logic clk;
    logic rst_n;
    logic [NUM_PORTS-1:0] source_accept;
    logic [INGRESS_CELL_LANES-1:0] commit_accept;
    port_id_t commit_src_port [INGRESS_CELL_LANES-1:0];
    logic [NUM_PORTS-1:0] source_eligible;
    logic [NUM_PORTS-1:0] source_inflight;
    logic ordering_error;

    switch2_port_inflight_guard dut (.*);

    always #1 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        source_accept = '0;
        commit_accept = '0;
        for (int lane = 0; lane < INGRESS_CELL_LANES; lane++)
            commit_src_port[lane] = '0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        if (source_eligible !== {NUM_PORTS{1'b1}})
            $fatal(1, "ports were not initially eligible");

        source_accept[3] = 1'b1;
        source_accept[9] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        source_accept = '0;
        if (!source_inflight[3] || !source_inflight[9])
            $fatal(1, "accepted sources did not become in-flight");
        if (source_eligible[3] || source_eligible[9])
            $fatal(1, "in-flight sources remained eligible");

        commit_src_port[0] = PORT_ID_WIDTH'(3);
        commit_accept[0] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        commit_accept = '0;
        if (source_inflight[3] || !source_eligible[3])
            $fatal(1, "commit did not release source 3");
        if (!source_inflight[9])
            $fatal(1, "unrelated source was released");
        if (ordering_error) $fatal(1, "legal release raised ordering_error");

        // A duplicate/non-owned completion must be visible immediately.
        commit_accept[0] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        commit_accept = '0;
        if (!ordering_error) $fatal(1, "duplicate release was not detected");

        $display("PASS: per-port Cell in-flight ordering guard");
        $finish;
    end

endmodule : tb_switch2_port_inflight_guard
