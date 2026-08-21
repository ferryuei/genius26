// Lossless, round-robin concentration from per-port Cell streams to write lanes.
// Each output lane owns a holding register so its transaction cannot change
// while downstream ready is low.
`timescale 1ns/1ps

module switch2_cell_arbiter
    import switch2_pkg::*;
#(
    parameter int unsigned INPUTS = NUM_PORTS,
    parameter int unsigned LANES = INGRESS_CELL_LANES
) (
    input logic clk,
    input logic rst_n,

    input  logic [INPUTS-1:0] in_valid,
    input  logic [INPUTS-1:0] in_eligible,
    output logic [INPUTS-1:0] in_ready,
    input  assembled_cell_t in_cell [INPUTS-1:0],

    output logic [LANES-1:0] out_valid,
    input  logic [LANES-1:0] out_ready,
    output assembled_cell_t out_cell [LANES-1:0]
);

    localparam int unsigned INPUT_INDEX_WIDTH =
        (INPUTS <= 1) ? 1 : $clog2(INPUTS);

    logic [INPUT_INDEX_WIDTH-1:0] rr_pointer;
    logic [INPUT_INDEX_WIDTH-1:0] next_rr_pointer;
    logic [LANES-1:0] grant_valid;
    logic [INPUT_INDEX_WIDTH-1:0] grant_index [LANES-1:0];
    logic [INPUTS-1:0] selected;
    integer lane;
    integer offset;
    integer candidate;
    integer search_start;
    logic found;

    always_comb begin
        in_ready = '0;
        grant_valid = '0;
        selected = '0;
        next_rr_pointer = rr_pointer;
        candidate = 0;
        search_start = int'(rr_pointer);
        found = 1'b0;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            grant_index[lane] = '0;
            if (!out_valid[lane] || out_ready[lane]) begin
                found = 1'b0;
                for (offset = 0; offset < INPUTS; offset = offset + 1) begin
                    candidate = search_start + offset;
                    if (candidate >= INPUTS) candidate = candidate - INPUTS;
                    if (!found && in_valid[candidate] && in_eligible[candidate] &&
                        !selected[candidate]) begin
                        grant_valid[lane] = 1'b1;
                        grant_index[lane] = INPUT_INDEX_WIDTH'(candidate);
                        selected[candidate] = 1'b1;
                        in_ready[candidate] = 1'b1;
                        found = 1'b1;
                        if (candidate == INPUTS - 1)
                            search_start = 0;
                        else
                            search_start = candidate + 1;
                        next_rr_pointer = INPUT_INDEX_WIDTH'(search_start);
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_pointer <= '0;
            out_valid <= '0;
            for (int unsigned output_lane = 0;
                 output_lane < LANES; output_lane++) begin
                out_cell[output_lane] <= '0;
            end
        end else begin
            rr_pointer <= next_rr_pointer;
            for (int unsigned output_lane = 0;
                 output_lane < LANES; output_lane++) begin
                if (!out_valid[output_lane] || out_ready[output_lane]) begin
                    if (grant_valid[output_lane]) begin
                        out_valid[output_lane] <= 1'b1;
                        out_cell[output_lane] <= in_cell[grant_index[output_lane]];
                    end else begin
                        out_valid[output_lane] <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        if (INPUTS == 0) $error("switch2_cell_arbiter requires INPUTS > 0");
        if (LANES == 0) $error("switch2_cell_arbiter requires LANES > 0");
        if (LANES > INPUTS)
            $error("switch2_cell_arbiter LANES cannot exceed INPUTS");
    end

endmodule : switch2_cell_arbiter
