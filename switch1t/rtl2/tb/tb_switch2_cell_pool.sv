`timescale 1ns/1ps

module tb_switch2_cell_pool;
    import switch2_pkg::*;

    localparam int unsigned LANES = 4;
    localparam int unsigned TEST_CELLS = 64;

    logic clk;
    logic rst_n;
    logic pool_ready;
    logic [CELL_ID_WIDTH:0] free_count;
    logic [LANES-1:0] alloc_req_valid;
    logic [LANES-1:0] alloc_req_ready;
    logic [LANES-1:0] alloc_rsp_valid;
    logic [LANES-1:0] alloc_rsp_ready;
    cell_id_t alloc_cell_id [LANES-1:0];
    logic [LANES-1:0] free_valid;
    logic [LANES-1:0] free_ready;
    cell_id_t free_cell_id [LANES-1:0];
    logic ownership_error;
    cell_id_t saved_id [LANES-1:0];
    logic [TEST_CELLS-1:0] seen;

    switch2_cell_pool #(
        .LANES(LANES),
        .TOTAL_CELLS_PARAM(TEST_CELLS)
    ) dut (.*);

    always #1 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        alloc_req_valid = '0;
        alloc_rsp_ready = '0;
        free_valid = '0;
        seen = '0;
        for (int lane = 0; lane < LANES; lane++) free_cell_id[lane] = '0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (pool_ready);
        @(negedge clk);
        if (free_count !== TEST_CELLS)
            $fatal(1, "pool initialization count mismatch");

        alloc_req_valid = '1;
        @(posedge clk);
        @(negedge clk);
        alloc_req_valid = '0;
        if (alloc_rsp_valid !== '1) $fatal(1, "four allocations not returned");
        if (free_count !== TEST_CELLS - LANES)
            $fatal(1, "allocation count mismatch");
        for (int lane = 0; lane < LANES; lane++) begin
            if (seen[alloc_cell_id[lane]]) $fatal(1, "duplicate Cell ID allocated");
            seen[alloc_cell_id[lane]] = 1'b1;
            saved_id[lane] = alloc_cell_id[lane];
        end

        alloc_rsp_ready = '1;
        @(posedge clk);
        @(negedge clk);
        alloc_rsp_ready = '0;
        if (alloc_rsp_valid !== '0) $fatal(1, "allocation responses did not drain");

        // The four first IDs are in distinct banks and can return together.
        for (int lane = 0; lane < LANES; lane++) free_cell_id[lane] = saved_id[lane];
        free_valid = '1;
        @(posedge clk);
        @(negedge clk);
        if (free_ready !== '1) $fatal(1, "valid releases were not accepted");
        free_valid = '0;
        if (free_count !== TEST_CELLS)
            $fatal(1, "release count mismatch");
        if (ownership_error) $fatal(1, "valid releases raised ownership_error");

        // Releasing an already-free ID is consumed, reported, and not counted.
        free_cell_id[0] = saved_id[0];
        free_valid[0] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        free_valid = '0;
        if (!ownership_error) $fatal(1, "double free was not detected");
        if (free_count !== TEST_CELLS)
            $fatal(1, "double free corrupted the free count");

        $display("PASS: 16-bank Cell allocation, release and double-free detection");
        $finish;
    end

endmodule : tb_switch2_cell_pool
