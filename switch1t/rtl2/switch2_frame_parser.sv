// Per-port L2 parser with a lossless ready/valid data bypass.
// Byte 0 is carried in beat_data[63:56] (network byte order).
`timescale 1ns/1ps

module switch2_frame_parser
    import switch2_pkg::*;
#(
    parameter int unsigned PORT_INDEX = 0
) (
    input logic clk,
    input logic rst_n,

    input  logic s_valid,
    output logic s_ready,
    input  logic s_sop,
    input  logic s_eop,
    input  logic [PORT_DATA_WIDTH-1:0] s_data,
    input  logic [PORT_EMPTY_WIDTH-1:0] s_empty,

    output logic m_valid,
    input  logic m_ready,
    output logic m_sop,
    output logic m_eop,
    output logic [PORT_DATA_WIDTH-1:0] m_data,
    output logic [PORT_EMPTY_WIDTH-1:0] m_empty,

    output logic meta_valid,
    input  logic meta_ready,
    output parsed_packet_t meta,

    output logic protocol_error
);

    logic in_frame;
    logic [1:0] header_beat_count;
    logic [PORT_DATA_WIDTH-1:0] header_word0;
    logic [PORT_DATA_WIDTH-1:0] header_word1;
    logic [PORT_DATA_WIDTH-1:0] header_word2;
    logic [PACKET_LENGTH_WIDTH-1:0] byte_count;
    logic parser_available;
    logic beat_accepted;
    logic [PORT_EMPTY_WIDTH:0] accepted_bytes;

    assign parser_available = !meta_valid || meta_ready;
    assign m_valid = s_valid && parser_available;
    assign s_ready = m_ready && parser_available;
    assign m_sop = s_sop;
    assign m_eop = s_eop;
    assign m_data = s_data;
    assign m_empty = s_empty;
    assign beat_accepted = s_valid && s_ready;
    assign accepted_bytes = s_eop
        ? (PORT_EMPTY_WIDTH+1)'(PORT_DATA_BYTES) - {1'b0, s_empty}
        : (PORT_EMPTY_WIDTH+1)'(PORT_DATA_BYTES);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_frame <= 1'b0;
            header_beat_count <= '0;
            header_word0 <= '0;
            header_word1 <= '0;
            header_word2 <= '0;
            byte_count <= '0;
            meta_valid <= 1'b0;
            meta <= '0;
            protocol_error <= 1'b0;
        end else begin
            protocol_error <= 1'b0;

            if (meta_valid && meta_ready) begin
                meta_valid <= 1'b0;
            end

            if (beat_accepted) begin
                if (s_empty != '0 && !s_eop) begin
                    protocol_error <= 1'b1;
                end

                if (!in_frame) begin
                    if (!s_sop) begin
                        protocol_error <= 1'b1;
                    end
                    in_frame <= !s_eop;
                    header_beat_count <= 2'd1;
                    header_word0 <= s_data;
                    byte_count <= PACKET_LENGTH_WIDTH'(accepted_bytes);

                    if (s_eop) begin
                        // A legal Ethernet frame cannot end in its first beat.
                        protocol_error <= 1'b1;
                        meta_valid <= 1'b0;
                    end
                end else begin
                    if (s_sop) begin
                        protocol_error <= 1'b1;
                    end

                    case (header_beat_count)
                        2'd1: begin
                            header_word1 <= s_data;
                            header_beat_count <= 2'd2;
                        end
                        2'd2: begin
                            header_word2 <= s_data;
                            header_beat_count <= 2'd3;
                        end
                        default: header_beat_count <= header_beat_count;
                    endcase

                    if (s_eop) begin
                        in_frame <= 1'b0;
                        if (header_beat_count < 2'd3) begin
                            protocol_error <= 1'b1;
                            meta_valid <= 1'b0;
                        end else begin
                            meta.dmac <= header_word0[63:16];
                            meta.smac <= {header_word0[15:0], header_word1[63:32]};
                            meta.vlan_tagged <= (header_word1[31:16] == 16'h8100);
                            if (header_word1[31:16] == 16'h8100) begin
                                meta.pcp <= header_word1[15:13];
                                meta.dei <= header_word1[12];
                                meta.vid <= header_word1[11:0];
                                meta.ethertype <= header_word2[63:48];
                            end else begin
                                meta.pcp <= '0;
                                meta.dei <= 1'b0;
                                meta.vid <= '0;
                                meta.ethertype <= header_word1[31:16];
                            end
                            meta.packet_length <=
                                byte_count + PACKET_LENGTH_WIDTH'(accepted_bytes);
                            meta.src_port <= PORT_ID_WIDTH'(PORT_INDEX);
                            meta_valid <= 1'b1;
                        end
                    end else begin
                        byte_count <= byte_count + PACKET_LENGTH_WIDTH'(accepted_bytes);
                    end
                end
            end
        end
    end

    initial begin
        if (PORT_INDEX >= NUM_PORTS)
            $error("switch2_frame_parser PORT_INDEX is out of range");
    end

endmodule : switch2_frame_parser
