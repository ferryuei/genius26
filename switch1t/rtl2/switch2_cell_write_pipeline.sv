// Couples Cell-ID allocation to payload storage and publishes a commit only
// after both operations have completed. One pending transaction per lane still
// sustains one Cell/lane/cycle through simultaneous response-pop/request-push.
`timescale 1ns/1ps

module switch2_cell_write_pipeline
    import switch2_pkg::*;
#(
    parameter int unsigned LANES = INGRESS_CELL_LANES,
    parameter int unsigned TOTAL_CELLS_PARAM = TOTAL_CELLS
) (
    input logic clk,
    input logic rst_n,

    output logic pipeline_ready,
    output logic [CELL_ID_WIDTH:0] free_count,

    input  logic [LANES-1:0] in_valid,
    output logic [LANES-1:0] in_ready,
    input  assembled_cell_t in_payload [LANES-1:0],

    output logic [LANES-1:0] commit_valid,
    input  logic [LANES-1:0] commit_ready,
    output committed_cell_t commit [LANES-1:0],

    input  logic [LANES-1:0] free_valid,
    output logic [LANES-1:0] free_ready,
    input  cell_id_t free_cell_id [LANES-1:0],

    input  logic [LANES-1:0] link_valid,
    output logic [LANES-1:0] link_ready,
    input  cell_id_t link_cell_id [LANES-1:0],
    input  cell_id_t link_next_cell [LANES-1:0],

    input  logic [LANES-1:0] invalidate_valid,
    output logic [LANES-1:0] invalidate_ready,
    input  cell_id_t invalidate_cell_id [LANES-1:0],

    input  logic [LANES-1:0] read_req_valid,
    output logic [LANES-1:0] read_req_ready,
    input  cell_id_t read_req_cell_id [LANES-1:0],
    output logic [LANES-1:0] read_rsp_valid,
    input  logic [LANES-1:0] read_rsp_ready,
    output assembled_cell_t read_rsp_payload [LANES-1:0],
    output cell_metadata_t read_rsp_metadata [LANES-1:0],

    output logic ownership_error,
    output logic store_protocol_error
);

    logic pool_ready;
    logic cell_store_ready;
    logic [LANES-1:0] alloc_req_valid;
    logic [LANES-1:0] alloc_req_ready;
    logic [LANES-1:0] alloc_rsp_valid;
    logic [LANES-1:0] alloc_rsp_ready;
    cell_id_t allocated_cell_id [LANES-1:0];
    logic [LANES-1:0] pending_valid;
    assembled_cell_t pending_payload [LANES-1:0];
    logic [LANES-1:0] pending_slot_available;
    logic [LANES-1:0] commit_slot_available;
    logic [LANES-1:0] write_valid;
    logic [LANES-1:0] write_ready;
    logic [LANES-1:0] write_fire;
    cell_id_t write_cell_id [LANES-1:0];
    assembled_cell_t write_payload [LANES-1:0];

    assign pipeline_ready = pool_ready && cell_store_ready;
    assign commit_slot_available = ~commit_valid | commit_ready;
    assign write_valid = pending_valid & alloc_rsp_valid &
                         commit_slot_available;
    assign alloc_rsp_ready = pending_valid & write_ready &
                             commit_slot_available;
    assign write_fire = write_valid & write_ready;
    assign pending_slot_available = ~pending_valid | write_fire;
    assign alloc_req_valid = in_valid & pending_slot_available;
    assign in_ready = alloc_req_ready & pending_slot_available;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_write_lane
            assign write_cell_id[lane] = allocated_cell_id[lane];
            assign write_payload[lane] = pending_payload[lane];
        end
    endgenerate

    switch2_cell_pool #(
        .LANES(LANES),
        .TOTAL_CELLS_PARAM(TOTAL_CELLS_PARAM)
    ) u_cell_pool (
        .clk             (clk),
        .rst_n           (rst_n),
        .pool_ready      (pool_ready),
        .free_count      (free_count),
        .alloc_req_valid (alloc_req_valid),
        .alloc_req_ready (alloc_req_ready),
        .alloc_rsp_valid (alloc_rsp_valid),
        .alloc_rsp_ready (alloc_rsp_ready),
        .alloc_cell_id   (allocated_cell_id),
        .free_valid      (free_valid),
        .free_ready      (free_ready),
        .free_cell_id    (free_cell_id),
        .ownership_error (ownership_error)
    );

    switch2_cell_store #(
        .LANES(LANES),
        .TOTAL_CELLS_PARAM(TOTAL_CELLS_PARAM)
    ) u_cell_store (
        .clk                (clk),
        .rst_n              (rst_n),
        .store_ready        (cell_store_ready),
        .write_valid        (write_valid),
        .write_ready        (write_ready),
        .write_cell_id      (write_cell_id),
        .write_payload      (write_payload),
        .link_valid         (link_valid),
        .link_ready         (link_ready),
        .link_cell_id       (link_cell_id),
        .link_next_cell     (link_next_cell),
        .invalidate_valid   (invalidate_valid),
        .invalidate_ready   (invalidate_ready),
        .invalidate_cell_id (invalidate_cell_id),
        .read_req_valid     (read_req_valid),
        .read_req_ready     (read_req_ready),
        .read_req_cell_id   (read_req_cell_id),
        .read_rsp_valid     (read_rsp_valid),
        .read_rsp_ready     (read_rsp_ready),
        .read_rsp_payload   (read_rsp_payload),
        .read_rsp_metadata  (read_rsp_metadata),
        .protocol_error     (store_protocol_error)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid <= '0;
            commit_valid <= '0;
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                pending_payload[lane] <= '0;
                commit[lane] <= '0;
            end
        end else begin
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                case ({in_valid[lane] && in_ready[lane], write_fire[lane]})
                    2'b01: pending_valid[lane] <= 1'b0;
                    2'b10: begin
                        pending_valid[lane] <= 1'b1;
                        pending_payload[lane] <= in_payload[lane];
                    end
                    2'b11: begin
                        pending_valid[lane] <= 1'b1;
                        pending_payload[lane] <= in_payload[lane];
                    end
                    default: pending_valid[lane] <= pending_valid[lane];
                endcase

                if (commit_slot_available[lane]) begin
                    if (write_fire[lane]) begin
                        commit_valid[lane] <= 1'b1;
                        commit[lane] <= {
                            allocated_cell_id[lane], pending_payload[lane]
                        };
                    end else begin
                        commit_valid[lane] <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        if (LANES != INGRESS_CELL_LANES)
            $error("switch2_cell_write_pipeline currently requires four lanes");
    end

endmodule : switch2_cell_write_pipeline
