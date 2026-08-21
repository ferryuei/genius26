// One independently initialized free-ID stack per Cell memory bank.
// The ownership bitmap detects double-free and allocator corruption.
`timescale 1ns/1ps

module switch2_cell_bank_pool
    import switch2_pkg::*;
#(
    parameter int unsigned BANK_INDEX = 0,
    parameter int unsigned BANKS = NUM_MEMORY_BANKS,
    parameter int unsigned TOTAL_CELLS_PARAM = TOTAL_CELLS
) (
    input logic clk,
    input logic rst_n,

    output logic initialized,

    output logic alloc_valid,
    input  logic alloc_ready,
    output cell_id_t alloc_cell_id,

    input  logic free_valid,
    output logic free_ready,
    input  cell_id_t free_cell_id,

    output logic [$clog2(TOTAL_CELLS_PARAM / BANKS + 1)-1:0] free_count,
    output logic ownership_error
);

    localparam int unsigned LOCAL_CELLS = TOTAL_CELLS_PARAM / BANKS;
    localparam int unsigned LOCAL_INDEX_WIDTH =
        (LOCAL_CELLS <= 1) ? 1 : $clog2(LOCAL_CELLS);
    localparam int unsigned COUNT_WIDTH = $clog2(LOCAL_CELLS + 1);

    logic [LOCAL_INDEX_WIDTH-1:0] free_stack [LOCAL_CELLS-1:0];
    logic [LOCAL_CELLS-1:0] allocated_bitmap;
    logic [LOCAL_INDEX_WIDTH-1:0] init_index;
    logic [LOCAL_INDEX_WIDTH-1:0] alloc_local_index;
    logic [LOCAL_INDEX_WIDTH-1:0] free_local_index;
    logic alloc_fire;
    logic free_accept;
    logic valid_free_fire;
    logic free_is_owned;

    assign alloc_valid = initialized && (free_count != '0);
    assign alloc_fire = alloc_valid && alloc_ready;
    assign free_local_index = LOCAL_INDEX_WIDTH'(free_cell_id / BANKS);
    assign free_is_owned = allocated_bitmap[free_local_index];

    // An invalid release is accepted and reported so a broken producer cannot
    // deadlock the entire return path by holding the same request forever.
    assign free_ready = initialized &&
        (!free_is_owned || (free_count < COUNT_WIDTH'(LOCAL_CELLS)) || alloc_fire);
    assign free_accept = free_valid && free_ready;
    assign valid_free_fire = free_accept && free_is_owned;

    always_comb begin
        alloc_local_index = '0;
        alloc_cell_id = '0;
        if (initialized && (free_count != '0)) begin
            alloc_local_index =
                free_stack[LOCAL_INDEX_WIDTH'(free_count - 1'b1)];
            alloc_cell_id = cell_id_t'(
                (int'(alloc_local_index) * BANKS) + BANK_INDEX
            );
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            initialized <= 1'b0;
            init_index <= '0;
            free_count <= '0;
            ownership_error <= 1'b0;
        end else begin
            ownership_error <= 1'b0;

            if (!initialized) begin
                free_stack[init_index] <= init_index;
                allocated_bitmap[init_index] <= 1'b0;
                free_count <= free_count + 1'b1;
                if (init_index == LOCAL_INDEX_WIDTH'(LOCAL_CELLS - 1)) begin
                    initialized <= 1'b1;
                    init_index <= '0;
                end else begin
                    init_index <= init_index + 1'b1;
                end
            end else begin
                if (alloc_fire && allocated_bitmap[alloc_local_index]) begin
                    ownership_error <= 1'b1;
                end
                if (free_accept && !free_is_owned) begin
                    ownership_error <= 1'b1;
                end

                case ({alloc_fire, valid_free_fire})
                    2'b01: begin
                        free_stack[LOCAL_INDEX_WIDTH'(free_count)] <=
                            free_local_index;
                        free_count <= free_count + 1'b1;
                    end
                    2'b10: begin
                        free_count <= free_count - 1'b1;
                    end
                    2'b11: begin
                        // Pop the allocated ID and replace it with the return.
                        free_stack[LOCAL_INDEX_WIDTH'(free_count - 1'b1)] <=
                            free_local_index;
                    end
                    default: free_count <= free_count;
                endcase

                if (alloc_fire) allocated_bitmap[alloc_local_index] <= 1'b1;
                if (valid_free_fire) allocated_bitmap[free_local_index] <= 1'b0;
            end
        end
    end

    initial begin
        if (BANKS == 0) $error("BANKS must be non-zero");
        if (TOTAL_CELLS_PARAM % BANKS != 0)
            $error("TOTAL_CELLS_PARAM must divide evenly across BANKS");
        if (BANK_INDEX >= BANKS) $error("BANK_INDEX is out of range");
    end

endmodule : switch2_cell_bank_pool
