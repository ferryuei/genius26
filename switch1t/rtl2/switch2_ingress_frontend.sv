// Per-port elastic buffering. No port is acknowledged on behalf of another.
`timescale 1ns/1ps

module switch2_ingress_frontend
    import switch2_pkg::*;
#(
    parameter int unsigned PORTS = NUM_PORTS,
    parameter int unsigned FIFO_DEPTH = 4
) (
    input logic clk,
    input logic rst_n,

    input  logic [PORTS-1:0] rx_valid,
    output logic [PORTS-1:0] rx_ready,
    input  logic [PORTS-1:0] rx_sop,
    input  logic [PORTS-1:0] rx_eop,
    input  logic [PORT_DATA_WIDTH-1:0] rx_data [PORTS-1:0],
    input  logic [PORT_EMPTY_WIDTH-1:0] rx_empty [PORTS-1:0],

    output logic [PORTS-1:0] lane_valid,
    input  logic [PORTS-1:0] lane_ready,
    output logic [PORTS-1:0] lane_sop,
    output logic [PORTS-1:0] lane_eop,
    output logic [PORT_DATA_WIDTH-1:0] lane_data [PORTS-1:0],
    output logic [PORT_EMPTY_WIDTH-1:0] lane_empty [PORTS-1:0]
);

    localparam int unsigned BEAT_WIDTH =
        PORT_DATA_WIDTH + PORT_EMPTY_WIDTH + 2;

    logic [BEAT_WIDTH-1:0] fifo_input [PORTS-1:0];
    logic [BEAT_WIDTH-1:0] fifo_output [PORTS-1:0];

    generate
        for (genvar port = 0; port < PORTS; port++) begin : gen_port_fifo
            assign fifo_input[port] = {
                rx_sop[port], rx_eop[port], rx_empty[port], rx_data[port]
            };
            assign {
                lane_sop[port], lane_eop[port], lane_empty[port], lane_data[port]
            } = fifo_output[port];

            switch2_sync_fifo #(
                .WIDTH(BEAT_WIDTH),
                .DEPTH(FIFO_DEPTH)
            ) u_fifo (
                .clk       (clk),
                .rst_n     (rst_n),
                .in_valid  (rx_valid[port]),
                .in_ready  (rx_ready[port]),
                .in_data   (fifo_input[port]),
                .out_valid (lane_valid[port]),
                .out_ready (lane_ready[port]),
                .out_data  (fifo_output[port]),
                .occupancy ()
            );
        end
    endgenerate

endmodule : switch2_ingress_frontend
