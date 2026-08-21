// Descriptor IDs use the same tested banked ownership engine as Cell IDs.
// RTL2 deliberately provisions one 16-bit descriptor per 16-bit Cell ID.
`timescale 1ns/1ps

module switch2_descriptor_pool
    import switch2_pkg::*;
#(
    parameter int unsigned LANES = LOOKUP_LANES,
    parameter int unsigned DESCRIPTOR_COUNT_PARAM = DESCRIPTOR_COUNT
) (
    input logic clk,
    input logic rst_n,

    output logic pool_ready,
    output logic [DESCRIPTOR_ID_WIDTH:0] free_count,

    input  logic [LANES-1:0] alloc_req_valid,
    output logic [LANES-1:0] alloc_req_ready,
    output logic [LANES-1:0] alloc_rsp_valid,
    input  logic [LANES-1:0] alloc_rsp_ready,
    output descriptor_id_t alloc_descriptor_id [LANES-1:0],

    input  logic [LANES-1:0] free_valid,
    output logic [LANES-1:0] free_ready,
    input  descriptor_id_t free_descriptor_id [LANES-1:0],

    output logic ownership_error
);

    cell_id_t alloc_cell_id [LANES-1:0];
    cell_id_t free_cell_id [LANES-1:0];
    logic [CELL_ID_WIDTH:0] cell_pool_free_count;

    assign free_count = cell_pool_free_count;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_id_alias
            assign alloc_descriptor_id[lane] = alloc_cell_id[lane];
            assign free_cell_id[lane] = free_descriptor_id[lane];
        end
    endgenerate

    switch2_cell_pool #(
        .LANES(LANES),
        .TOTAL_CELLS_PARAM(DESCRIPTOR_COUNT_PARAM)
    ) u_descriptor_id_pool (
        .clk             (clk),
        .rst_n           (rst_n),
        .pool_ready      (pool_ready),
        .free_count      (cell_pool_free_count),
        .alloc_req_valid (alloc_req_valid),
        .alloc_req_ready (alloc_req_ready),
        .alloc_rsp_valid (alloc_rsp_valid),
        .alloc_rsp_ready (alloc_rsp_ready),
        .alloc_cell_id   (alloc_cell_id),
        .free_valid      (free_valid),
        .free_ready      (free_ready),
        .free_cell_id    (free_cell_id),
        .ownership_error (ownership_error)
    );

    initial begin
        if (DESCRIPTOR_ID_WIDTH != CELL_ID_WIDTH)
            $error("shared ID-pool engine requires equal Cell/descriptor widths");
        if (DESCRIPTOR_COUNT_PARAM > (1 << DESCRIPTOR_ID_WIDTH))
            $error("descriptor count exceeds descriptor ID width");
    end

endmodule : switch2_descriptor_pool
