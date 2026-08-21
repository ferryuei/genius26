// One physical Cell bank: one payload write, one link update, one invalidation,
// and one synchronous read response per cycle.
`timescale 1ns/1ps

module switch2_cell_store_bank
    import switch2_pkg::*;
#(
    parameter int unsigned BANK_INDEX = 0,
    parameter int unsigned BANKS = NUM_MEMORY_BANKS,
    parameter int unsigned LANES = INGRESS_CELL_LANES,
    parameter int unsigned TOTAL_CELLS_PARAM = TOTAL_CELLS
) (
    input logic clk,
    input logic rst_n,

    output logic initialized,

    input  logic write_valid,
    output logic write_ready,
    input  cell_id_t write_cell_id,
    input  assembled_cell_t write_payload,

    input  logic link_valid,
    output logic link_ready,
    input  cell_id_t link_cell_id,
    input  cell_id_t link_next_cell,

    input  logic invalidate_valid,
    output logic invalidate_ready,
    input  cell_id_t invalidate_cell_id,

    input  logic read_valid,
    output logic read_ready,
    input  cell_id_t read_cell_id,
    input  logic [$clog2(LANES)-1:0] read_lane,

    output logic rsp_valid,
    input  logic rsp_ready,
    output logic [$clog2(LANES)-1:0] rsp_lane,
    output assembled_cell_t rsp_payload,
    output cell_metadata_t rsp_metadata,

    output logic protocol_error
);

    localparam int unsigned LOCAL_CELLS = TOTAL_CELLS_PARAM / BANKS;
    localparam int unsigned LOCAL_INDEX_WIDTH =
        (LOCAL_CELLS <= 1) ? 1 : $clog2(LOCAL_CELLS);

    assembled_cell_t payload_mem [LOCAL_CELLS-1:0];
    cell_id_t next_cell_mem [LOCAL_CELLS-1:0];
    logic [LOCAL_CELLS-1:0] payload_valid;
    logic [LOCAL_CELLS-1:0] payload_last;
    logic [LOCAL_INDEX_WIDTH-1:0] init_index;
    logic [LOCAL_INDEX_WIDTH-1:0] write_local_index;
    logic [LOCAL_INDEX_WIDTH-1:0] link_local_index;
    logic [LOCAL_INDEX_WIDTH-1:0] invalidate_local_index;
    logic [LOCAL_INDEX_WIDTH-1:0] read_local_index;
    logic write_fire;
    logic link_fire;
    logic invalidate_fire;
    logic read_fire;

    assign write_local_index = LOCAL_INDEX_WIDTH'(write_cell_id / BANKS);
    assign link_local_index = LOCAL_INDEX_WIDTH'(link_cell_id / BANKS);
    assign invalidate_local_index =
        LOCAL_INDEX_WIDTH'(invalidate_cell_id / BANKS);
    assign read_local_index = LOCAL_INDEX_WIDTH'(read_cell_id / BANKS);

    assign write_ready = initialized;
    assign link_ready = initialized;
    assign invalidate_ready = initialized;
    assign read_ready = initialized && (!rsp_valid || rsp_ready);
    assign write_fire = write_valid && write_ready;
    assign link_fire = link_valid && link_ready;
    assign invalidate_fire = invalidate_valid && invalidate_ready;
    assign read_fire = read_valid && read_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            initialized <= 1'b0;
            init_index <= '0;
            rsp_valid <= 1'b0;
            rsp_lane <= '0;
            rsp_payload <= '0;
            rsp_metadata <= '0;
            protocol_error <= 1'b0;
        end else begin
            protocol_error <= 1'b0;

            if (!initialized) begin
                payload_valid[init_index] <= 1'b0;
                if (init_index == LOCAL_INDEX_WIDTH'(LOCAL_CELLS - 1)) begin
                    initialized <= 1'b1;
                    init_index <= '0;
                end else begin
                    init_index <= init_index + 1'b1;
                end
            end else begin
                if (write_fire) begin
                    if (payload_valid[write_local_index])
                        protocol_error <= 1'b1;
                    payload_mem[write_local_index] <= write_payload;
                    payload_last[write_local_index] <= write_payload.last_cell;
                    payload_valid[write_local_index] <= 1'b1;
                end

                if (link_fire) begin
                    if (!payload_valid[link_local_index])
                        protocol_error <= 1'b1;
                    next_cell_mem[link_local_index] <= link_next_cell;
                end

                if (invalidate_fire) begin
                    if (!payload_valid[invalidate_local_index])
                        protocol_error <= 1'b1;
                    payload_valid[invalidate_local_index] <= 1'b0;
                end

                if (write_fire && invalidate_fire &&
                    (write_local_index == invalidate_local_index)) begin
                    protocol_error <= 1'b1;
                end

                if (read_ready) begin
                    if (read_valid) begin
                        rsp_valid <= 1'b1;
                        rsp_lane <= read_lane;
                        rsp_payload <= payload_mem[read_local_index];
                        rsp_metadata.next_cell <= next_cell_mem[read_local_index];
                        rsp_metadata.eop <= payload_last[read_local_index];
                        rsp_metadata.valid <= payload_valid[read_local_index];
                        if (!payload_valid[read_local_index])
                            protocol_error <= 1'b1;
                    end else begin
                        rsp_valid <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        if (BANKS == 0 || TOTAL_CELLS_PARAM % BANKS != 0)
            $error("invalid Cell store bank geometry");
        if (BANK_INDEX >= BANKS) $error("BANK_INDEX is out of range");
        if (LANES <= 1) $error("switch2_cell_store_bank requires LANES > 1");
    end

endmodule : switch2_cell_store_bank
