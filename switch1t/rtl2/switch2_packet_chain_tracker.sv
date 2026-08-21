// Maintains one packet Cell-chain context per source port. Commit acceptance,
// link generation and packet completion are lossless ready/valid operations.
`timescale 1ns/1ps

module switch2_packet_chain_tracker
    import switch2_pkg::*;
#(
    parameter int unsigned PORTS = NUM_PORTS,
    parameter int unsigned LANES = INGRESS_CELL_LANES
) (
    input logic clk,
    input logic rst_n,

    input  logic [LANES-1:0] commit_valid,
    output logic [LANES-1:0] commit_ready,
    input  committed_cell_t commit [LANES-1:0],

    output logic [LANES-1:0] link_valid,
    input  logic [LANES-1:0] link_ready,
    output cell_id_t link_cell_id [LANES-1:0],
    output cell_id_t link_next_cell [LANES-1:0],

    output logic [LANES-1:0] packet_complete_valid,
    input  logic [LANES-1:0] packet_complete_ready,
    output packet_cell_chain_t packet_complete [LANES-1:0],

    output logic [LANES-1:0] source_release_valid,
    output port_id_t source_release_port [LANES-1:0],

    output logic protocol_error
);

    localparam int unsigned COMMIT_WIDTH = $bits(committed_cell_t);

    logic [PORTS-1:0] packet_active;
    cell_id_t head_cell [PORTS-1:0];
    cell_id_t tail_cell [PORTS-1:0];
    logic [CELL_COUNT_WIDTH-1:0] cell_count [PORTS-1:0];

    logic [COMMIT_WIDTH-1:0] commit_bits [LANES-1:0];
    cell_id_t committed_cell_id [LANES-1:0];
    port_id_t committed_src_port [LANES-1:0];
    logic [LANES-1:0] committed_first;
    logic [LANES-1:0] committed_last;
    logic [LANES-1:0] link_slot_available;
    logic [LANES-1:0] complete_slot_available;
    logic [LANES-1:0] commit_fire;
    logic [LANES-1:0] complete_wait_link;
    logic [LANES-1:0] complete_pending;
    port_id_t link_src_port [LANES-1:0];

    assign link_slot_available = ~link_valid | link_ready;
    assign complete_slot_available = ~complete_pending |
                                      (packet_complete_valid &
                                       packet_complete_ready);
    assign packet_complete_valid = complete_pending & ~complete_wait_link;
    assign commit_fire = commit_valid & commit_ready;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_commit_decode
            assign commit_bits[lane] = commit[lane];
            assign committed_cell_id[lane] =
                commit_bits[lane][COMMIT_WIDTH-1 -: CELL_ID_WIDTH];
            assign committed_src_port[lane] =
                commit_bits[lane][PORT_ID_WIDTH-1:0];
            assign committed_last[lane] = commit_bits[lane][PORT_ID_WIDTH];
            assign committed_first[lane] = commit_bits[lane][PORT_ID_WIDTH+1];
            assign commit_ready[lane] =
                (committed_first[lane] ? !link_valid[lane] :
                                         link_slot_available[lane]) &&
                (!committed_last[lane] || complete_slot_available[lane]);
            assign source_release_valid[lane] =
                (link_valid[lane] && link_ready[lane]) ||
                (commit_fire[lane] && committed_first[lane]);
            assign source_release_port[lane] =
                (link_valid[lane] && link_ready[lane]) ?
                    link_src_port[lane] : committed_src_port[lane];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            packet_active <= '0;
            link_valid <= '0;
            complete_pending <= '0;
            complete_wait_link <= '0;
            protocol_error <= 1'b0;
            for (int unsigned port = 0; port < PORTS; port++) begin
                head_cell[port] <= '0;
                tail_cell[port] <= '0;
                cell_count[port] <= '0;
            end
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                link_cell_id[lane] <= '0;
                link_next_cell[lane] <= '0;
                link_src_port[lane] <= '0;
                packet_complete[lane] <= '0;
            end
        end else begin
            protocol_error <= 1'b0;

            for (int unsigned lane = 0; lane < LANES; lane++) begin
                if (link_valid[lane] && link_ready[lane]) begin
                    link_valid[lane] <= 1'b0;
                    if (complete_pending[lane] && complete_wait_link[lane])
                        complete_wait_link[lane] <= 1'b0;
                end
                if (packet_complete_valid[lane] &&
                    packet_complete_ready[lane]) begin
                    complete_pending[lane] <= 1'b0;
                end

                if (commit_fire[lane]) begin
                    if (int'(committed_src_port[lane]) >= PORTS) begin
                        protocol_error <= 1'b1;
                    end else if (committed_first[lane]) begin
                        if (packet_active[committed_src_port[lane]])
                            protocol_error <= 1'b1;
                        head_cell[committed_src_port[lane]] <=
                            committed_cell_id[lane];
                        tail_cell[committed_src_port[lane]] <=
                            committed_cell_id[lane];
                        cell_count[committed_src_port[lane]] <=
                            CELL_COUNT_WIDTH'(1);
                        packet_active[committed_src_port[lane]] <=
                            !committed_last[lane];

                        if (committed_last[lane]) begin
                            complete_pending[lane] <= 1'b1;
                            complete_wait_link[lane] <= 1'b0;
                            packet_complete[lane] <= {
                                committed_cell_id[lane],
                                committed_cell_id[lane],
                                CELL_COUNT_WIDTH'(1),
                                committed_src_port[lane]
                            };
                        end
                    end else begin
                        if (!packet_active[committed_src_port[lane]])
                            protocol_error <= 1'b1;
                        if (cell_count[committed_src_port[lane]] ==
                            CELL_COUNT_WIDTH'(MAX_CELLS_PER_PACKET))
                            protocol_error <= 1'b1;

                        link_valid[lane] <= 1'b1;
                        link_cell_id[lane] <=
                            tail_cell[committed_src_port[lane]];
                        link_next_cell[lane] <= committed_cell_id[lane];
                        link_src_port[lane] <= committed_src_port[lane];
                        tail_cell[committed_src_port[lane]] <=
                            committed_cell_id[lane];
                        cell_count[committed_src_port[lane]] <=
                            cell_count[committed_src_port[lane]] + 1'b1;
                        packet_active[committed_src_port[lane]] <=
                            !committed_last[lane];

                        if (committed_last[lane]) begin
                            complete_pending[lane] <= 1'b1;
                            complete_wait_link[lane] <= 1'b1;
                            packet_complete[lane] <= {
                                head_cell[committed_src_port[lane]],
                                committed_cell_id[lane],
                                cell_count[committed_src_port[lane]] + 1'b1,
                                committed_src_port[lane]
                            };
                        end
                    end
                end
            end
        end
    end

    initial begin
        if (LANES != INGRESS_CELL_LANES)
            $error("switch2_packet_chain_tracker currently requires four lanes");
    end

endmodule : switch2_packet_chain_tracker
