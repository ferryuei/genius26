// Integrated RTL2 ingress milestone:
// 48 MAC lanes -> parse/Cell assembly -> 4-lane allocation/store -> Cell chains
// -> metadata join and descriptor-tagged packet admission.
`timescale 1ns/1ps

module switch2_ingress_storage
    import switch2_pkg::*;
#(
    parameter int unsigned TOTAL_CELLS_PARAM = TOTAL_CELLS,
    parameter int unsigned DESCRIPTOR_COUNT_PARAM = DESCRIPTOR_COUNT
) (
    input logic clk,
    input logic rst_n,

    output logic datapath_ready,
    output logic [CELL_ID_WIDTH:0] free_cell_count,
    output logic [DESCRIPTOR_ID_WIDTH:0] free_descriptor_count,

    input  logic [NUM_PORTS-1:0] port_rx_valid,
    output logic [NUM_PORTS-1:0] port_rx_ready,
    input  logic [NUM_PORTS-1:0] port_rx_sop,
    input  logic [NUM_PORTS-1:0] port_rx_eop,
    input  logic [PORT_DATA_WIDTH-1:0] port_rx_data [NUM_PORTS-1:0],
    input  logic [PORT_EMPTY_WIDTH-1:0] port_rx_empty [NUM_PORTS-1:0],

    output logic [LOOKUP_LANES-1:0] admitted_valid,
    input  logic [LOOKUP_LANES-1:0] admitted_ready,
    output admitted_packet_t admitted [LOOKUP_LANES-1:0],

    input  logic [EGRESS_CELL_LANES-1:0] cell_release_valid,
    output logic [EGRESS_CELL_LANES-1:0] cell_release_ready,
    input  cell_id_t cell_release_id [EGRESS_CELL_LANES-1:0],

    input  logic [LOOKUP_LANES-1:0] descriptor_free_valid,
    output logic [LOOKUP_LANES-1:0] descriptor_free_ready,
    input  descriptor_id_t descriptor_free_id [LOOKUP_LANES-1:0],

    input  logic [EGRESS_CELL_LANES-1:0] read_req_valid,
    output logic [EGRESS_CELL_LANES-1:0] read_req_ready,
    input  cell_id_t read_req_cell_id [EGRESS_CELL_LANES-1:0],
    output logic [EGRESS_CELL_LANES-1:0] read_rsp_valid,
    input  logic [EGRESS_CELL_LANES-1:0] read_rsp_ready,
    output assembled_cell_t read_rsp_payload [EGRESS_CELL_LANES-1:0],
    output cell_metadata_t read_rsp_metadata [EGRESS_CELL_LANES-1:0],

    output logic [NUM_PORTS-1:0] ingress_protocol_error,
    output logic ordering_error,
    output logic chain_protocol_error,
    output logic admission_protocol_error,
    output logic cell_ownership_error,
    output logic store_protocol_error,
    output logic descriptor_ownership_error
);

    logic [NUM_PORTS-1:0] gated_rx_valid;
    logic [NUM_PORTS-1:0] core_rx_ready;
    logic [INGRESS_CELL_LANES-1:0] ingress_cell_valid;
    logic [INGRESS_CELL_LANES-1:0] ingress_cell_ready;
    assembled_cell_t ingress_cell [INGRESS_CELL_LANES-1:0];
    logic [NUM_PORTS-1:0] metadata_valid;
    logic [NUM_PORTS-1:0] metadata_ready;
    parsed_packet_t metadata [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] ingress_port_inflight;

    logic cell_pipeline_ready;
    logic packet_admission_ready;
    logic [INGRESS_CELL_LANES-1:0] cell_commit_valid;
    logic [INGRESS_CELL_LANES-1:0] cell_commit_ready;
    committed_cell_t cell_commit [INGRESS_CELL_LANES-1:0];
    logic [INGRESS_CELL_LANES-1:0] source_release_valid;
    port_id_t cell_commit_src_port [INGRESS_CELL_LANES-1:0];

    logic [INGRESS_CELL_LANES-1:0] link_valid;
    logic [INGRESS_CELL_LANES-1:0] link_ready;
    cell_id_t link_cell_id [INGRESS_CELL_LANES-1:0];
    cell_id_t link_next_cell [INGRESS_CELL_LANES-1:0];
    logic [LOOKUP_LANES-1:0] chain_complete_valid;
    logic [LOOKUP_LANES-1:0] chain_complete_ready;
    packet_cell_chain_t chain_complete [LOOKUP_LANES-1:0];

    logic [EGRESS_CELL_LANES-1:0] pool_free_valid;
    logic [EGRESS_CELL_LANES-1:0] pool_free_ready;
    cell_id_t pool_free_cell_id [EGRESS_CELL_LANES-1:0];
    logic [EGRESS_CELL_LANES-1:0] store_invalidate_valid;
    logic [EGRESS_CELL_LANES-1:0] store_invalidate_ready;
    cell_id_t store_invalidate_cell_id [EGRESS_CELL_LANES-1:0];

    assign datapath_ready = cell_pipeline_ready && packet_admission_ready;
    assign gated_rx_valid = port_rx_valid & {NUM_PORTS{datapath_ready}};
    assign port_rx_ready = core_rx_ready & {NUM_PORTS{datapath_ready}};
    switch2_core_shell u_ingress_core (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .port_rx_valid          (gated_rx_valid),
        .port_rx_ready          (core_rx_ready),
        .port_rx_sop            (port_rx_sop),
        .port_rx_eop            (port_rx_eop),
        .port_rx_data           (port_rx_data),
        .port_rx_empty          (port_rx_empty),
        .cell_commit_accept     (source_release_valid),
        .cell_commit_src_port   (cell_commit_src_port),
        .ingress_port_inflight  (ingress_port_inflight),
        .ingress_ordering_error (ordering_error),
        .ingress_cell_valid     (ingress_cell_valid),
        .ingress_cell_ready     (ingress_cell_ready),
        .ingress_cell           (ingress_cell),
        .ingress_metadata_valid (metadata_valid),
        .ingress_metadata_ready (metadata_ready),
        .ingress_metadata       (metadata),
        .ingress_protocol_error (ingress_protocol_error)
    );

    switch2_cell_write_pipeline #(
        .TOTAL_CELLS_PARAM(TOTAL_CELLS_PARAM)
    ) u_cell_write_pipeline (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .pipeline_ready        (cell_pipeline_ready),
        .free_count            (free_cell_count),
        .in_valid              (ingress_cell_valid),
        .in_ready              (ingress_cell_ready),
        .in_payload            (ingress_cell),
        .commit_valid          (cell_commit_valid),
        .commit_ready          (cell_commit_ready),
        .commit                (cell_commit),
        .free_valid            (pool_free_valid),
        .free_ready            (pool_free_ready),
        .free_cell_id          (pool_free_cell_id),
        .link_valid            (link_valid),
        .link_ready            (link_ready),
        .link_cell_id          (link_cell_id),
        .link_next_cell        (link_next_cell),
        .invalidate_valid      (store_invalidate_valid),
        .invalidate_ready      (store_invalidate_ready),
        .invalidate_cell_id    (store_invalidate_cell_id),
        .read_req_valid        (read_req_valid),
        .read_req_ready        (read_req_ready),
        .read_req_cell_id      (read_req_cell_id),
        .read_rsp_valid        (read_rsp_valid),
        .read_rsp_ready        (read_rsp_ready),
        .read_rsp_payload      (read_rsp_payload),
        .read_rsp_metadata     (read_rsp_metadata),
        .ownership_error       (cell_ownership_error),
        .store_protocol_error  (store_protocol_error)
    );

    switch2_packet_chain_tracker u_packet_chain_tracker (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .commit_valid          (cell_commit_valid),
        .commit_ready          (cell_commit_ready),
        .commit                (cell_commit),
        .link_valid            (link_valid),
        .link_ready            (link_ready),
        .link_cell_id          (link_cell_id),
        .link_next_cell        (link_next_cell),
        .packet_complete_valid (chain_complete_valid),
        .packet_complete_ready (chain_complete_ready),
        .packet_complete       (chain_complete),
        .source_release_valid  (source_release_valid),
        .source_release_port   (cell_commit_src_port),
        .protocol_error        (chain_protocol_error)
    );

    switch2_packet_admission #(
        .DESCRIPTOR_COUNT_PARAM(DESCRIPTOR_COUNT_PARAM)
    ) u_packet_admission (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .admission_ready       (packet_admission_ready),
        .free_descriptor_count (free_descriptor_count),
        .chain_valid           (chain_complete_valid),
        .chain_ready           (chain_complete_ready),
        .chain                 (chain_complete),
        .metadata_valid        (metadata_valid),
        .metadata_ready        (metadata_ready),
        .metadata              (metadata),
        .admitted_valid        (admitted_valid),
        .admitted_ready        (admitted_ready),
        .admitted              (admitted),
        .descriptor_free_valid (descriptor_free_valid),
        .descriptor_free_ready (descriptor_free_ready),
        .descriptor_free_id    (descriptor_free_id),
        .ownership_error       (descriptor_ownership_error),
        .protocol_error        (admission_protocol_error)
    );

    switch2_cell_release_fanout u_cell_release_fanout (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .release_valid            (cell_release_valid),
        .release_ready            (cell_release_ready),
        .release_cell_id          (cell_release_id),
        .pool_free_valid          (pool_free_valid),
        .pool_free_ready          (pool_free_ready),
        .pool_free_cell_id        (pool_free_cell_id),
        .store_invalidate_valid   (store_invalidate_valid),
        .store_invalidate_ready   (store_invalidate_ready),
        .store_invalidate_cell_id (store_invalidate_cell_id)
    );

endmodule : switch2_ingress_storage
