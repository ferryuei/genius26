`timescale 1ns/1ps

module tb_switch2_cell_store;
    import switch2_pkg::*;

    localparam int unsigned LANES = 4;
    localparam int unsigned TEST_CELLS = 64;
    localparam int unsigned PAYLOAD_BITS = $bits(assembled_cell_t);
    localparam int unsigned META_BITS = $bits(cell_metadata_t);

    logic clk;
    logic rst_n;
    logic store_ready;
    logic [LANES-1:0] write_valid;
    logic [LANES-1:0] write_ready;
    cell_id_t write_cell_id [LANES-1:0];
    assembled_cell_t write_payload [LANES-1:0];
    logic [PAYLOAD_BITS-1:0] write_bits [LANES-1:0];
    logic [LANES-1:0] link_valid;
    logic [LANES-1:0] link_ready;
    cell_id_t link_cell_id [LANES-1:0];
    cell_id_t link_next_cell [LANES-1:0];
    logic [LANES-1:0] invalidate_valid;
    logic [LANES-1:0] invalidate_ready;
    cell_id_t invalidate_cell_id [LANES-1:0];
    logic [LANES-1:0] read_req_valid;
    logic [LANES-1:0] read_req_ready;
    cell_id_t read_req_cell_id [LANES-1:0];
    logic [LANES-1:0] read_rsp_valid;
    logic [LANES-1:0] read_rsp_ready;
    assembled_cell_t read_rsp_payload [LANES-1:0];
    cell_metadata_t read_rsp_metadata [LANES-1:0];
    logic [PAYLOAD_BITS-1:0] read_rsp_bits [LANES-1:0];
    logic [META_BITS-1:0] read_meta_bits [LANES-1:0];
    logic protocol_error;
    logic [LANES-1:0] first_conflict_grant;
    logic [PAYLOAD_BITS-1:0] held_response;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_alias
            assign write_payload[lane] = write_bits[lane];
            assign read_rsp_bits[lane] = read_rsp_payload[lane];
            assign read_meta_bits[lane] = read_rsp_metadata[lane];
        end
    endgenerate

    switch2_cell_store #(
        .LANES(LANES),
        .TOTAL_CELLS_PARAM(TEST_CELLS)
    ) dut (.*);

    always #1 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        write_valid = '0;
        link_valid = '0;
        invalidate_valid = '0;
        read_req_valid = '0;
        read_rsp_ready = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            write_cell_id[lane] = '0;
            write_bits[lane] = '0;
            link_cell_id[lane] = '0;
            link_next_cell[lane] = '0;
            invalidate_cell_id[lane] = '0;
            read_req_cell_id[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (store_ready);
        @(negedge clk);

        // Four distinct banks must accept four payloads in one cycle.
        for (int lane = 0; lane < LANES; lane++) begin
            write_cell_id[lane] = cell_id_t'(lane);
            write_bits[lane][PORT_ID_WIDTH-1:0] = PORT_ID_WIDTH'(lane + 8);
            write_bits[lane][PORT_ID_WIDTH] = (lane == LANES - 1);
            write_bits[lane][PORT_ID_WIDTH+1] = (lane == 0);
            write_bits[lane][PORT_ID_WIDTH+2 +: CELL_VALID_BYTES_WIDTH] =
                CELL_VALID_BYTES_WIDTH'(CELL_BYTES);
            write_bits[lane][PAYLOAD_BITS-1 -: 64] =
                64'hD000_0000_0000_0000 + lane;
        end
        write_valid = '1;
        @(posedge clk);
        @(negedge clk);
        if (write_ready !== '1) $fatal(1, "distinct-bank writes did not issue");
        write_valid = '0;
        if (protocol_error) $fatal(1, "valid writes raised protocol_error");

        // Link Cell 0 to Cell 16 using the independent metadata port.
        link_cell_id[0] = cell_id_t'(0);
        link_next_cell[0] = cell_id_t'(16);
        link_valid[0] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (!link_ready[0]) $fatal(1, "link update was not accepted");
        link_valid = '0;
        if (protocol_error) $fatal(1, "valid link update raised protocol_error");

        // Synchronous reads return one response per lane and hold under stall.
        for (int lane = 0; lane < LANES; lane++)
            read_req_cell_id[lane] = cell_id_t'(lane);
        read_req_valid = '1;
        #0;
        if (read_req_ready !== '1) $fatal(1, "distinct-bank reads did not issue");
        @(posedge clk);
        @(negedge clk);
        read_req_valid = '0;
        if (read_rsp_valid !== '1) $fatal(1, "read responses missing");
        for (int lane = 0; lane < LANES; lane++) begin
            if (read_rsp_bits[lane][PAYLOAD_BITS-1 -: 64] !==
                (64'hD000_0000_0000_0000 + lane))
                $fatal(1, "payload data mismatch on lane %0d", lane);
            if (!read_meta_bits[lane][0])
                $fatal(1, "stored-valid bit missing on lane %0d", lane);
        end
        if (read_meta_bits[0][CELL_ID_WIDTH+1:2] !== cell_id_t'(16))
            $fatal(1, "forward link was not stored");
        held_response = read_rsp_bits[0];
        repeat (2) begin
            @(posedge clk);
            @(negedge clk);
            if (!read_rsp_valid[0] || read_rsp_bits[0] !== held_response)
                $fatal(1, "read response changed under backpressure");
        end
        read_rsp_ready = '1;
        @(posedge clk);
        @(negedge clk);
        read_rsp_ready = '0;
        if (read_rsp_valid !== '0) $fatal(1, "read responses did not drain");

        // Two writes to bank 0 must be serialized, not dropped.
        write_cell_id[0] = cell_id_t'(16);
        write_cell_id[1] = cell_id_t'(32);
        write_bits[0][PAYLOAD_BITS-1 -: 64] = 64'hE000_0000_0000_0010;
        write_bits[1][PAYLOAD_BITS-1 -: 64] = 64'hE000_0000_0000_0020;
        write_valid = 4'b0011;
        #0;
        first_conflict_grant = write_ready;
        if (!((first_conflict_grant & write_valid) == 4'b0001 ||
              (first_conflict_grant & write_valid) == 4'b0010 ||
              (first_conflict_grant & write_valid) == 4'b0100 ||
              (first_conflict_grant & write_valid) == 4'b1000))
            $fatal(1, "same-bank conflict did not select exactly one write: ready=%b valid=%b",
                   first_conflict_grant, write_valid);
        @(posedge clk);
        @(negedge clk);
        write_valid = write_valid & ~first_conflict_grant;
        #0;
        if (!((write_ready & write_valid) == 4'b0001 ||
              (write_ready & write_valid) == 4'b0010 ||
              (write_ready & write_valid) == 4'b0100 ||
              (write_ready & write_valid) == 4'b1000))
            $fatal(1, "losing same-bank write was not retried");
        @(posedge clk);
        @(negedge clk);
        write_valid = '0;
        if (protocol_error) $fatal(1, "serialized writes raised protocol_error");

        // Reading an unwritten allocated address is reported with valid=0.
        read_req_cell_id[0] = cell_id_t'(63);
        read_req_valid[0] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        read_req_valid = '0;
        if (!read_rsp_valid[0] || read_meta_bits[0][0])
            $fatal(1, "unwritten read validity mismatch");
        if (!protocol_error) $fatal(1, "unwritten read was not reported");

        $display("PASS: banked Cell store, links, conflicts and read backpressure");
        $finish;
    end

endmodule : tb_switch2_cell_store
