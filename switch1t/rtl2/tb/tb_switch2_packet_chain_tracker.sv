`timescale 1ns/1ps

module tb_switch2_packet_chain_tracker;
    import switch2_pkg::*;

    localparam int unsigned LANES = 4;
    localparam int unsigned COMMIT_BITS = $bits(committed_cell_t);
    localparam int unsigned CHAIN_BITS = $bits(packet_cell_chain_t);

    logic clk;
    logic rst_n;
    logic [LANES-1:0] commit_valid;
    logic [LANES-1:0] commit_ready;
    committed_cell_t commit [LANES-1:0];
    logic [COMMIT_BITS-1:0] commit_bits [LANES-1:0];
    logic [LANES-1:0] link_valid;
    logic [LANES-1:0] link_ready;
    cell_id_t link_cell_id [LANES-1:0];
    cell_id_t link_next_cell [LANES-1:0];
    logic [LANES-1:0] packet_complete_valid;
    logic [LANES-1:0] packet_complete_ready;
    packet_cell_chain_t packet_complete [LANES-1:0];
    logic [CHAIN_BITS-1:0] packet_complete_bits [LANES-1:0];
    logic protocol_error;
    logic [LANES-1:0] source_release_valid;
    port_id_t source_release_port [LANES-1:0];
    integer source_release_count;
    port_id_t last_released_port;
    logic [CHAIN_BITS-1:0] held_complete;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_alias
            assign commit[lane] = commit_bits[lane];
            assign packet_complete_bits[lane] = packet_complete[lane];
        end
    endgenerate

    switch2_packet_chain_tracker dut (.*);

    always #1 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            source_release_count <= 0;
            last_released_port <= '0;
        end else begin
            for (int lane = 0; lane < LANES; lane++) begin
                if (source_release_valid[lane]) begin
                    source_release_count <= source_release_count + 1;
                    last_released_port <= source_release_port[lane];
                end
            end
        end
    end

    task automatic send_commit(
        input int lane,
        input cell_id_t cell_id,
        input port_id_t src_port,
        input logic first_cell,
        input logic last_cell
    );
        @(negedge clk);
        commit_bits[lane] = '0;
        commit_bits[lane][COMMIT_BITS-1 -: CELL_ID_WIDTH] = cell_id;
        commit_bits[lane][PORT_ID_WIDTH-1:0] = src_port;
        commit_bits[lane][PORT_ID_WIDTH] = last_cell;
        commit_bits[lane][PORT_ID_WIDTH+1] = first_cell;
        commit_valid[lane] = 1'b1;
        do @(posedge clk); while (!commit_ready[lane]);
        @(negedge clk);
        commit_valid[lane] = 1'b0;
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        commit_valid = '0;
        link_ready = '0;
        packet_complete_ready = '0;
        for (int lane = 0; lane < LANES; lane++) commit_bits[lane] = '0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        send_commit(0, cell_id_t'(1), port_id_t'(5), 1'b1, 1'b0);
        if (source_release_count !== 1 || last_released_port !== port_id_t'(5))
            $fatal(1, "first Cell did not release its source");
        if (link_valid != '0 || packet_complete_valid != '0)
            $fatal(1, "first non-final Cell emitted a transaction");

        send_commit(2, cell_id_t'(17), port_id_t'(5), 1'b0, 1'b0);
        if (!link_valid[2] || link_cell_id[2] !== cell_id_t'(1) ||
            link_next_cell[2] !== cell_id_t'(17))
            $fatal(1, "middle Cell link mismatch");
        repeat (2) @(posedge clk);
        if (!link_valid[2]) $fatal(1, "link changed under backpressure");
        if (source_release_count !== 1)
            $fatal(1, "source released before middle link was accepted");
        @(negedge clk);
        link_ready[2] = 1'b1;
        #0;
        if (!source_release_valid[2])
            $fatal(1, "middle link release pulse was not asserted");
        @(posedge clk);
        @(negedge clk);
        if (source_release_count !== 2 || last_released_port !== port_id_t'(5))
            $fatal(1, "middle link acceptance did not release source: count=%0d port=%0d",
                   source_release_count, last_released_port);
        link_ready = '0;
        if (link_valid[2]) $fatal(1, "middle link did not drain");

        send_commit(1, cell_id_t'(33), port_id_t'(5), 1'b0, 1'b1);
        if (!link_valid[1]) $fatal(1, "final forward link missing");
        if (packet_complete_valid[1])
            $fatal(1, "packet completed before final link write");
        link_ready[1] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        link_ready = '0;
        if (!packet_complete_valid[1])
            $fatal(1, "packet completion missing after final link");
        if (packet_complete_bits[1] !== {
            cell_id_t'(1), cell_id_t'(33), CELL_COUNT_WIDTH'(3), port_id_t'(5)
        }) $fatal(1, "three-Cell chain summary mismatch");

        held_complete = packet_complete_bits[1];
        repeat (2) begin
            @(posedge clk);
            if (!packet_complete_valid[1] ||
                packet_complete_bits[1] !== held_complete)
                $fatal(1, "packet completion changed under backpressure");
        end
        packet_complete_ready[1] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        packet_complete_ready = '0;
        if (packet_complete_valid[1]) $fatal(1, "completion did not drain");
        if (protocol_error) $fatal(1, "legal Cell chain raised protocol_error");

        $display("PASS: per-port Cell chaining and link-before-complete ordering");
        $finish;
    end

endmodule : tb_switch2_packet_chain_tracker
