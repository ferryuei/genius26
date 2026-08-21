// Small ready/valid FIFO used at clock-domain-local transaction boundaries.
`timescale 1ns/1ps

module switch2_sync_fifo #(
    parameter int unsigned WIDTH = 8,
    parameter int unsigned DEPTH = 4
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             in_valid,
    output logic             in_ready,
    input  logic [WIDTH-1:0] in_data,

    output logic             out_valid,
    input  logic             out_ready,
    output logic [WIDTH-1:0] out_data,

    output logic [$clog2(DEPTH+1)-1:0] occupancy
);

    localparam int unsigned PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int unsigned COUNT_WIDTH = $clog2(DEPTH + 1);

    logic [WIDTH-1:0] memory [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] write_pointer;
    logic [PTR_WIDTH-1:0] read_pointer;
    logic [COUNT_WIDTH-1:0] count;
    logic push;
    logic pop;

    function automatic logic [PTR_WIDTH-1:0] next_pointer(
        input logic [PTR_WIDTH-1:0] pointer
    );
        if (pointer == PTR_WIDTH'(DEPTH - 1)) begin
            next_pointer = '0;
        end else begin
            next_pointer = pointer + 1'b1;
        end
    endfunction

    assign out_valid = (count != '0);
    assign out_data = memory[read_pointer];
    assign in_ready = (count != COUNT_WIDTH'(DEPTH)) || (out_valid && out_ready);
    assign push = in_valid && in_ready;
    assign pop = out_valid && out_ready;
    assign occupancy = count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer <= '0;
            read_pointer <= '0;
            count <= '0;
        end else begin
            if (push) begin
                memory[write_pointer] <= in_data;
                write_pointer <= next_pointer(write_pointer);
            end

            if (pop) begin
                read_pointer <= next_pointer(read_pointer);
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    initial begin
        if (WIDTH == 0) $error("switch2_sync_fifo WIDTH must be positive");
        if (DEPTH < 2) $error("switch2_sync_fifo DEPTH must be at least two");
    end

endmodule : switch2_sync_fifo
