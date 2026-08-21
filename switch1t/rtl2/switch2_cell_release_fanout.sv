// Stages each release until both the ownership pool and store invalidation have
// accepted it. This prevents partial release when either downstream path stalls.
`timescale 1ns/1ps

module switch2_cell_release_fanout
    import switch2_pkg::*;
#(
    parameter int unsigned LANES = EGRESS_CELL_LANES
) (
    input logic clk,
    input logic rst_n,

    input  logic [LANES-1:0] release_valid,
    output logic [LANES-1:0] release_ready,
    input  cell_id_t release_cell_id [LANES-1:0],

    output logic [LANES-1:0] pool_free_valid,
    input  logic [LANES-1:0] pool_free_ready,
    output cell_id_t pool_free_cell_id [LANES-1:0],

    output logic [LANES-1:0] store_invalidate_valid,
    input  logic [LANES-1:0] store_invalidate_ready,
    output cell_id_t store_invalidate_cell_id [LANES-1:0]
);

    logic [LANES-1:0] slot_valid;
    logic [LANES-1:0] pool_pending;
    logic [LANES-1:0] store_pending;
    logic [LANES-1:0] current_done;
    logic [LANES-1:0] release_accept;
    cell_id_t held_cell_id [LANES-1:0];

    assign pool_free_valid = slot_valid & pool_pending;
    assign store_invalidate_valid = slot_valid & store_pending;
    assign current_done = slot_valid &
        (~pool_pending | pool_free_ready) &
        (~store_pending | store_invalidate_ready);
    assign release_ready = ~slot_valid | current_done;
    assign release_accept = release_valid & release_ready;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_release_lane
            assign pool_free_cell_id[lane] = held_cell_id[lane];
            assign store_invalidate_cell_id[lane] = held_cell_id[lane];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_valid <= '0;
            pool_pending <= '0;
            store_pending <= '0;
            for (int unsigned lane = 0; lane < LANES; lane++)
                held_cell_id[lane] <= '0;
        end else begin
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                if (release_accept[lane]) begin
                    slot_valid[lane] <= 1'b1;
                    pool_pending[lane] <= 1'b1;
                    store_pending[lane] <= 1'b1;
                    held_cell_id[lane] <= release_cell_id[lane];
                end else begin
                    if (pool_free_valid[lane] && pool_free_ready[lane])
                        pool_pending[lane] <= 1'b0;
                    if (store_invalidate_valid[lane] &&
                        store_invalidate_ready[lane])
                        store_pending[lane] <= 1'b0;
                    if (current_done[lane]) begin
                        slot_valid[lane] <= 1'b0;
                        pool_pending[lane] <= 1'b0;
                        store_pending[lane] <= 1'b0;
                    end
                end
            end
        end
    end

endmodule : switch2_cell_release_fanout
