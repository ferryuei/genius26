// Replicates the lossless FIFO/parser/Cell assembly path for every receive port.
`timescale 1ns/1ps

module switch2_ingress_pipeline
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

    output logic [PORTS-1:0] cell_valid,
    input  logic [PORTS-1:0] cell_ready,
    output assembled_cell_t assembled_cell [PORTS-1:0],

    output logic [PORTS-1:0] metadata_valid,
    input  logic [PORTS-1:0] metadata_ready,
    output parsed_packet_t metadata [PORTS-1:0],
    output logic [PORTS-1:0] protocol_error
);

    logic [PORTS-1:0] fifo_valid;
    logic [PORTS-1:0] fifo_ready;
    logic [PORTS-1:0] fifo_sop;
    logic [PORTS-1:0] fifo_eop;
    logic [PORT_DATA_WIDTH-1:0] fifo_data [PORTS-1:0];
    logic [PORT_EMPTY_WIDTH-1:0] fifo_empty [PORTS-1:0];
    logic [PORTS-1:0] parser_valid;
    logic [PORTS-1:0] parser_ready;
    logic [PORTS-1:0] parser_sop;
    logic [PORTS-1:0] parser_eop;
    logic [PORT_DATA_WIDTH-1:0] parser_data [PORTS-1:0];
    logic [PORT_EMPTY_WIDTH-1:0] parser_empty [PORTS-1:0];
    logic [PORTS-1:0] parser_error;
    logic [PORTS-1:0] assembler_error;

    switch2_ingress_frontend #(
        .PORTS(PORTS),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_frontend (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_valid   (rx_valid),
        .rx_ready   (rx_ready),
        .rx_sop     (rx_sop),
        .rx_eop     (rx_eop),
        .rx_data    (rx_data),
        .rx_empty   (rx_empty),
        .lane_valid (fifo_valid),
        .lane_ready (fifo_ready),
        .lane_sop   (fifo_sop),
        .lane_eop   (fifo_eop),
        .lane_data  (fifo_data),
        .lane_empty (fifo_empty)
    );

    generate
        for (genvar port = 0; port < PORTS; port++) begin : gen_port_parser
            switch2_frame_parser #(
                .PORT_INDEX(port)
            ) u_parser (
                .clk            (clk),
                .rst_n          (rst_n),
                .s_valid        (fifo_valid[port]),
                .s_ready        (fifo_ready[port]),
                .s_sop          (fifo_sop[port]),
                .s_eop          (fifo_eop[port]),
                .s_data         (fifo_data[port]),
                .s_empty        (fifo_empty[port]),
                .m_valid        (parser_valid[port]),
                .m_ready        (parser_ready[port]),
                .m_sop          (parser_sop[port]),
                .m_eop          (parser_eop[port]),
                .m_data         (parser_data[port]),
                .m_empty        (parser_empty[port]),
                .meta_valid     (metadata_valid[port]),
                .meta_ready     (metadata_ready[port]),
                .meta           (metadata[port]),
                .protocol_error (parser_error[port])
            );

            switch2_cell_assembler #(
                .PORT_INDEX(port)
            ) u_cell_assembler (
                .clk            (clk),
                .rst_n          (rst_n),
                .s_valid        (parser_valid[port]),
                .s_ready        (parser_ready[port]),
                .s_sop          (parser_sop[port]),
                .s_eop          (parser_eop[port]),
                .s_data         (parser_data[port]),
                .s_empty        (parser_empty[port]),
                .cell_valid     (cell_valid[port]),
                .cell_ready     (cell_ready[port]),
                .assembled_cell (assembled_cell[port]),
                .protocol_error (assembler_error[port])
            );

            assign protocol_error[port] = parser_error[port] |
                                                   assembler_error[port];
        end
    endgenerate

endmodule : switch2_ingress_pipeline
