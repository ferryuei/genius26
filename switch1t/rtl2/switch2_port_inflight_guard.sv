// Prevents a later Cell from the same physical port entering the global write
// fabric before the preceding Cell's commit has been consumed in order.
`timescale 1ns/1ps

module switch2_port_inflight_guard
    import switch2_pkg::*;
#(
    parameter int unsigned PORTS = NUM_PORTS,
    parameter int unsigned LANES = INGRESS_CELL_LANES
) (
    input logic clk,
    input logic rst_n,

    input  logic [PORTS-1:0] source_accept,
    input  logic [LANES-1:0] commit_accept,
    input  port_id_t commit_src_port [LANES-1:0],

    output logic [PORTS-1:0] source_eligible,
    output logic [PORTS-1:0] source_inflight,
    output logic ordering_error
);

    logic [PORTS-1:0] next_source_inflight;
    logic next_ordering_error;
    logic [PORTS-1:0] released_this_cycle;

    assign source_eligible = ~source_inflight;

    always_comb begin
        next_source_inflight = source_inflight;
        next_ordering_error = 1'b0;
        released_this_cycle = '0;

        for (int unsigned lane = 0; lane < LANES; lane++) begin
            if (commit_accept[lane]) begin
                if (int'(commit_src_port[lane]) >= PORTS ||
                    !source_inflight[commit_src_port[lane]] ||
                    released_this_cycle[commit_src_port[lane]]) begin
                    next_ordering_error = 1'b1;
                end else begin
                    released_this_cycle[commit_src_port[lane]] = 1'b1;
                    next_source_inflight[commit_src_port[lane]] = 1'b0;
                end
            end
        end

        for (int unsigned port = 0; port < PORTS; port++) begin
            if (source_accept[port]) begin
                if (source_inflight[port]) begin
                    next_ordering_error = 1'b1;
                end else begin
                    next_source_inflight[port] = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            source_inflight <= '0;
            ordering_error <= 1'b0;
        end else begin
            source_inflight <= next_source_inflight;
            ordering_error <= next_ordering_error;
        end
    end

endmodule : switch2_port_inflight_guard
