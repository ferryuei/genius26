// Joins a completed Cell chain with the held parser metadata for that source,
// allocates exactly one descriptor, and emits a tagged admission transaction.
`timescale 1ns/1ps

module switch2_packet_admission
    import switch2_pkg::*;
#(
    parameter int unsigned PORTS = NUM_PORTS,
    parameter int unsigned LANES = LOOKUP_LANES,
    parameter int unsigned DESCRIPTOR_COUNT_PARAM = DESCRIPTOR_COUNT
) (
    input logic clk,
    input logic rst_n,

    output logic admission_ready,
    output logic [DESCRIPTOR_ID_WIDTH:0] free_descriptor_count,

    input  logic [LANES-1:0] chain_valid,
    output logic [LANES-1:0] chain_ready,
    input  packet_cell_chain_t chain [LANES-1:0],

    input  logic [PORTS-1:0] metadata_valid,
    output logic [PORTS-1:0] metadata_ready,
    input  parsed_packet_t metadata [PORTS-1:0],

    output logic [LANES-1:0] admitted_valid,
    input  logic [LANES-1:0] admitted_ready,
    output admitted_packet_t admitted [LANES-1:0],

    input  logic [LANES-1:0] descriptor_free_valid,
    output logic [LANES-1:0] descriptor_free_ready,
    input  descriptor_id_t descriptor_free_id [LANES-1:0],

    output logic ownership_error,
    output logic protocol_error
);

    localparam int unsigned CHAIN_WIDTH = $bits(packet_cell_chain_t);
    localparam int unsigned META_WIDTH = $bits(parsed_packet_t);

    logic [CHAIN_WIDTH-1:0] chain_bits [LANES-1:0];
    port_id_t chain_src_port [LANES-1:0];
    logic [META_WIDTH-1:0] metadata_bits [PORTS-1:0];
    logic [LANES-1:0] metadata_available;
    logic [LANES-1:0] alloc_req_valid;
    logic [LANES-1:0] alloc_req_ready;
    logic [LANES-1:0] alloc_rsp_valid;
    logic [LANES-1:0] alloc_rsp_ready;
    descriptor_id_t allocated_descriptor_id [LANES-1:0];
    logic [LANES-1:0] pending_valid;
    packet_cell_chain_t pending_chain [LANES-1:0];
    parsed_packet_t pending_metadata [LANES-1:0];
    logic [LANES-1:0] pending_slot_available;
    logic [LANES-1:0] admitted_slot_available;
    logic [LANES-1:0] admission_fire;

    assign admitted_slot_available = ~admitted_valid | admitted_ready;
    assign alloc_rsp_ready = pending_valid & admitted_slot_available;
    assign admission_fire = alloc_rsp_valid & alloc_rsp_ready;
    assign pending_slot_available = ~pending_valid | admission_fire;

    generate
        for (genvar port = 0; port < PORTS; port++) begin : gen_meta_alias
            assign metadata_bits[port] = metadata[port];
        end
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_chain_decode
            assign chain_bits[lane] = chain[lane];
            assign chain_src_port[lane] = chain_bits[lane][PORT_ID_WIDTH-1:0];
            assign metadata_available[lane] = chain_valid[lane] &&
                metadata_valid[chain_src_port[lane]];
            assign alloc_req_valid[lane] = metadata_available[lane] &&
                                           pending_slot_available[lane];
            assign chain_ready[lane] = metadata_valid[chain_src_port[lane]] &&
                                       pending_slot_available[lane] &&
                                       alloc_req_ready[lane];
        end
    endgenerate

    always_comb begin
        metadata_ready = '0;
        for (int unsigned lane = 0; lane < LANES; lane++) begin
            if (chain_valid[lane] && chain_ready[lane])
                metadata_ready[chain_src_port[lane]] = 1'b1;
        end
    end

    switch2_descriptor_pool #(
        .LANES(LANES),
        .DESCRIPTOR_COUNT_PARAM(DESCRIPTOR_COUNT_PARAM)
    ) u_descriptor_pool (
        .clk                 (clk),
        .rst_n               (rst_n),
        .pool_ready          (admission_ready),
        .free_count          (free_descriptor_count),
        .alloc_req_valid     (alloc_req_valid),
        .alloc_req_ready     (alloc_req_ready),
        .alloc_rsp_valid     (alloc_rsp_valid),
        .alloc_rsp_ready     (alloc_rsp_ready),
        .alloc_descriptor_id (allocated_descriptor_id),
        .free_valid          (descriptor_free_valid),
        .free_ready          (descriptor_free_ready),
        .free_descriptor_id  (descriptor_free_id),
        .ownership_error     (ownership_error)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid <= '0;
            admitted_valid <= '0;
            protocol_error <= 1'b0;
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                pending_chain[lane] <= '0;
                pending_metadata[lane] <= '0;
                admitted[lane] <= '0;
            end
        end else begin
            protocol_error <= 1'b0;
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                case ({chain_valid[lane] && chain_ready[lane],
                       admission_fire[lane]})
                    2'b01: pending_valid[lane] <= 1'b0;
                    2'b10, 2'b11: begin
                        pending_valid[lane] <= 1'b1;
                        pending_chain[lane] <= chain[lane];
                        pending_metadata[lane] <=
                            metadata_bits[chain_src_port[lane]];
                        if (metadata_bits[chain_src_port[lane]][PORT_ID_WIDTH-1:0]
                            != chain_src_port[lane])
                            protocol_error <= 1'b1;
                    end
                    default: pending_valid[lane] <= pending_valid[lane];
                endcase

                if (admitted_slot_available[lane]) begin
                    if (admission_fire[lane]) begin
                        admitted_valid[lane] <= 1'b1;
                        admitted[lane] <= {
                            allocated_descriptor_id[lane],
                            pending_chain[lane],
                            pending_metadata[lane]
                        };
                    end else begin
                        admitted_valid[lane] <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        if (PORTS != NUM_PORTS)
            $error("switch2_packet_admission currently requires 48 ports");
        if (LANES != LOOKUP_LANES)
            $error("switch2_packet_admission currently requires four lanes");
    end

endmodule : switch2_packet_admission
