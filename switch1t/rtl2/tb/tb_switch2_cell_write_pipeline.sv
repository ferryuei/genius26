`timescale 1ns/1ps

module tb_switch2_cell_write_pipeline;
    import switch2_pkg::*;

    localparam int unsigned LANES = 4;
    localparam int unsigned TEST_CELLS = 64;
    localparam int unsigned PAYLOAD_BITS = $bits(assembled_cell_t);
    localparam int unsigned COMMIT_BITS = $bits(committed_cell_t);

    logic clk;
    logic rst_n;
    logic pipeline_ready;
    logic [CELL_ID_WIDTH:0] free_count;
    logic [LANES-1:0] in_valid;
    logic [LANES-1:0] in_ready;
    assembled_cell_t in_payload [LANES-1:0];
    logic [PAYLOAD_BITS-1:0] in_bits [LANES-1:0];
    logic [LANES-1:0] commit_valid;
    logic [LANES-1:0] commit_ready;
    committed_cell_t commit [LANES-1:0];
    logic [COMMIT_BITS-1:0] commit_bits [LANES-1:0];
    logic [COMMIT_BITS-1:0] held_commit [LANES-1:0];
    cell_id_t committed_id [LANES-1:0];
    logic [LANES-1:0] free_valid;
    logic [LANES-1:0] free_ready;
    cell_id_t free_cell_id [LANES-1:0];
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
    logic ownership_error;
    logic store_protocol_error;
    logic [TEST_CELLS-1:0] seen_ids;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_alias
            assign in_payload[lane] = in_bits[lane];
            assign commit_bits[lane] = commit[lane];
            assign read_rsp_bits[lane] = read_rsp_payload[lane];
        end
    endgenerate

    switch2_cell_write_pipeline #(
        .LANES(LANES),
        .TOTAL_CELLS_PARAM(TEST_CELLS)
    ) dut (.*);

    always #1 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        in_valid = '0;
        commit_ready = '0;
        free_valid = '0;
        link_valid = '0;
        invalidate_valid = '0;
        read_req_valid = '0;
        read_rsp_ready = '0;
        seen_ids = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            in_bits[lane] = '0;
            in_bits[lane][PORT_ID_WIDTH-1:0] = PORT_ID_WIDTH'(lane + 20);
            in_bits[lane][PORT_ID_WIDTH+2 +: CELL_VALID_BYTES_WIDTH] =
                CELL_VALID_BYTES_WIDTH'(CELL_BYTES);
            in_bits[lane][PAYLOAD_BITS-1 -: 64] =
                64'hF000_0000_0000_0000 + lane;
            free_cell_id[lane] = '0;
            link_cell_id[lane] = '0;
            link_next_cell[lane] = '0;
            invalidate_cell_id[lane] = '0;
            read_req_cell_id[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (pipeline_ready);
        @(negedge clk);

        in_valid = '1;
        #0;
        if (in_ready !== '1) $fatal(1, "four input Cells were not accepted");
        @(posedge clk);
        @(negedge clk);
        in_valid = '0;

        wait (commit_valid == 4'b1111);
        @(negedge clk);
        if (free_count !== TEST_CELLS - LANES)
            $fatal(1, "allocation/write pipeline free count mismatch");
        for (int lane = 0; lane < LANES; lane++) begin
            committed_id[lane] =
                commit_bits[lane][COMMIT_BITS-1 -: CELL_ID_WIDTH];
            if (seen_ids[committed_id[lane]])
                $fatal(1, "duplicate committed Cell ID");
            seen_ids[committed_id[lane]] = 1'b1;
            if (commit_bits[lane][PORT_ID_WIDTH-1:0] !==
                PORT_ID_WIDTH'(lane + 20))
                $fatal(1, "committed payload/source mismatch");
            held_commit[lane] = commit_bits[lane];
        end

        repeat (3) begin
            @(posedge clk);
            @(negedge clk);
            for (int lane = 0; lane < LANES; lane++) begin
                if (!commit_valid[lane] || commit_bits[lane] !== held_commit[lane])
                    $fatal(1, "commit changed under backpressure");
            end
        end

        commit_ready = '1;
        @(posedge clk);
        @(negedge clk);
        commit_ready = '0;
        if (commit_valid !== '0) $fatal(1, "commits did not drain");

        // Read back exactly the IDs published by the commit interface.
        for (int lane = 0; lane < LANES; lane++)
            read_req_cell_id[lane] = committed_id[lane];
        read_req_valid = '1;
        #0;
        if (read_req_ready !== '1) $fatal(1, "readback requests not accepted");
        @(posedge clk);
        @(negedge clk);
        read_req_valid = '0;
        if (read_rsp_valid !== '1) $fatal(1, "readback responses missing");
        for (int lane = 0; lane < LANES; lane++) begin
            if (read_rsp_bits[lane][PAYLOAD_BITS-1 -: 64] !==
                (64'hF000_0000_0000_0000 + lane))
                $fatal(1, "readback payload mismatch");
        end
        if (ownership_error || store_protocol_error)
            $fatal(1, "valid atomic writes raised an error");

        $display("PASS: atomic four-lane Cell allocation, store and commit");
        $finish;
    end

endmodule : tb_switch2_cell_write_pipeline
