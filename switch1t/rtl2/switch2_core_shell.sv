// RTL2 integration shell, currently ending at four concentrated Cell lanes.
`timescale 1ns/1ps

module switch2_core_shell
    import switch2_pkg::*;
(
    input logic clk,
    input logic rst_n,

    input  logic [NUM_PORTS-1:0] port_rx_valid,
    output logic [NUM_PORTS-1:0] port_rx_ready,
    input  logic [NUM_PORTS-1:0] port_rx_sop,
    input  logic [NUM_PORTS-1:0] port_rx_eop,
    input  logic [PORT_DATA_WIDTH-1:0] port_rx_data [NUM_PORTS-1:0],
    input  logic [PORT_EMPTY_WIDTH-1:0] port_rx_empty [NUM_PORTS-1:0],

    input  logic [INGRESS_CELL_LANES-1:0] cell_commit_accept,
    input  port_id_t cell_commit_src_port [INGRESS_CELL_LANES-1:0],
    output logic [NUM_PORTS-1:0] ingress_port_inflight,
    output logic ingress_ordering_error,

    output logic [INGRESS_CELL_LANES-1:0] ingress_cell_valid,
    input  logic [INGRESS_CELL_LANES-1:0] ingress_cell_ready,
    output assembled_cell_t ingress_cell [INGRESS_CELL_LANES-1:0],

    output logic [NUM_PORTS-1:0] ingress_metadata_valid,
    input  logic [NUM_PORTS-1:0] ingress_metadata_ready,
    output parsed_packet_t ingress_metadata [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0] ingress_protocol_error
);

    logic [NUM_PORTS-1:0] per_port_cell_valid;
    logic [NUM_PORTS-1:0] per_port_cell_ready;
    assembled_cell_t per_port_cell [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] per_port_cell_eligible;
    logic [NUM_PORTS-1:0] per_port_cell_accept;

    switch2_ingress_pipeline u_ingress_pipeline (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_valid   (port_rx_valid),
        .rx_ready   (port_rx_ready),
        .rx_sop     (port_rx_sop),
        .rx_eop     (port_rx_eop),
        .rx_data    (port_rx_data),
        .rx_empty   (port_rx_empty),
        .cell_valid     (per_port_cell_valid),
        .cell_ready     (per_port_cell_ready),
        .assembled_cell (per_port_cell),
        .metadata_valid (ingress_metadata_valid),
        .metadata_ready (ingress_metadata_ready),
        .metadata       (ingress_metadata),
        .protocol_error (ingress_protocol_error)
    );

    switch2_cell_arbiter u_cell_arbiter (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (per_port_cell_valid),
        .in_eligible (per_port_cell_eligible),
        .in_ready  (per_port_cell_ready),
        .in_cell   (per_port_cell),
        .out_valid (ingress_cell_valid),
        .out_ready (ingress_cell_ready),
        .out_cell  (ingress_cell)
    );

    assign per_port_cell_accept = per_port_cell_valid & per_port_cell_ready;

    switch2_port_inflight_guard u_port_inflight_guard (
        .clk             (clk),
        .rst_n           (rst_n),
        .source_accept   (per_port_cell_accept),
        .commit_accept   (cell_commit_accept),
        .commit_src_port (cell_commit_src_port),
        .source_eligible (per_port_cell_eligible),
        .source_inflight (ingress_port_inflight),
        .ordering_error  (ingress_ordering_error)
    );

endmodule : switch2_core_shell
