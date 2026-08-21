// Collects 64-bit MAC beats into 128-byte Cells without losing the final beat.
// Byte 0 remains at cell.data[CELL_DATA_WIDTH-1 -: 8].
`timescale 1ns/1ps

module switch2_cell_assembler
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

    output logic cell_valid,
    input  logic cell_ready,
    output assembled_cell_t assembled_cell,

    output logic protocol_error
);

    localparam int unsigned BEATS_PER_CELL = CELL_BYTES / PORT_DATA_BYTES;
    localparam int unsigned BEAT_INDEX_WIDTH = $clog2(BEATS_PER_CELL);

    logic [CELL_DATA_WIDTH-1:0] cell_buffer;
    logic [CELL_DATA_WIDTH-1:0] cell_with_beat;
    logic [BEAT_INDEX_WIDTH-1:0] beat_index;
    logic [CELL_VALID_BYTES_WIDTH-1:0] byte_count;
    logic packet_active;
    logic current_cell_first;
    logic beat_accepted;
    logic [PORT_EMPTY_WIDTH:0] accepted_bytes;
    logic cell_complete;

    assign s_ready = !cell_valid || cell_ready;
    assign beat_accepted = s_valid && s_ready;
    assign accepted_bytes = s_eop
        ? (PORT_EMPTY_WIDTH+1)'(PORT_DATA_BYTES) - {1'b0, s_empty}
        : (PORT_EMPTY_WIDTH+1)'(PORT_DATA_BYTES);
    assign cell_complete = s_eop || (beat_index == BEAT_INDEX_WIDTH'(BEATS_PER_CELL - 1));

    always_comb begin
        cell_with_beat = cell_buffer;
        cell_with_beat[
            CELL_DATA_WIDTH - 1 - beat_index * PORT_DATA_WIDTH -: PORT_DATA_WIDTH
        ] = s_data;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cell_buffer <= '0;
            beat_index <= '0;
            byte_count <= '0;
            packet_active <= 1'b0;
            current_cell_first <= 1'b1;
            cell_valid <= 1'b0;
            assembled_cell <= '0;
            protocol_error <= 1'b0;
        end else begin
            protocol_error <= 1'b0;

            if (cell_valid && cell_ready) begin
                cell_valid <= 1'b0;
            end

            if (beat_accepted) begin
                if (s_empty != '0 && !s_eop) begin
                    protocol_error <= 1'b1;
                end
                if (s_sop == packet_active) begin
                    // SOP is required exactly when no packet is active.
                    protocol_error <= 1'b1;
                end

                cell_buffer <= cell_with_beat;

                if (cell_complete) begin
                    assembled_cell.data <= cell_with_beat;
                    assembled_cell.valid_bytes <= s_eop
                        ? byte_count + CELL_VALID_BYTES_WIDTH'(accepted_bytes)
                        : CELL_VALID_BYTES_WIDTH'(CELL_BYTES);
                    assembled_cell.first_cell <= current_cell_first;
                    assembled_cell.last_cell <= s_eop;
                    assembled_cell.src_port <= PORT_ID_WIDTH'(PORT_INDEX);
                    cell_valid <= 1'b1;

                    cell_buffer <= '0;
                    beat_index <= '0;
                    byte_count <= '0;
                    current_cell_first <= s_eop;
                end else begin
                    beat_index <= beat_index + 1'b1;
                    byte_count <= byte_count + CELL_VALID_BYTES_WIDTH'(accepted_bytes);
                end

                if (s_sop) begin
                    packet_active <= !s_eop;
                    current_cell_first <= 1'b1;
                end else if (s_eop) begin
                    packet_active <= 1'b0;
                    current_cell_first <= 1'b1;
                end else begin
                    packet_active <= 1'b1;
                    if (cell_complete) current_cell_first <= 1'b0;
                end
            end
        end
    end

    initial begin
        if (PORT_INDEX >= NUM_PORTS)
            $error("switch2_cell_assembler PORT_INDEX is out of range");
        if (CELL_BYTES % PORT_DATA_BYTES != 0)
            $error("CELL_BYTES must be divisible by PORT_DATA_BYTES");
    end

endmodule : switch2_cell_assembler
