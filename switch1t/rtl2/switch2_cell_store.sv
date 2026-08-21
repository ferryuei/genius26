// Conflict-aware 4R/4W front end over 16 independently addressed Cell banks.
`timescale 1ns/1ps

module switch2_cell_store
    import switch2_pkg::*;
#(
    parameter int unsigned BANKS = NUM_MEMORY_BANKS,
    parameter int unsigned LANES = INGRESS_CELL_LANES,
    parameter int unsigned TOTAL_CELLS_PARAM = TOTAL_CELLS
) (
    input logic clk,
    input logic rst_n,

    output logic store_ready,

    input  logic [LANES-1:0] write_valid,
    output logic [LANES-1:0] write_ready,
    input  cell_id_t write_cell_id [LANES-1:0],
    input  assembled_cell_t write_payload [LANES-1:0],

    input  logic [LANES-1:0] link_valid,
    output logic [LANES-1:0] link_ready,
    input  cell_id_t link_cell_id [LANES-1:0],
    input  cell_id_t link_next_cell [LANES-1:0],

    input  logic [LANES-1:0] invalidate_valid,
    output logic [LANES-1:0] invalidate_ready,
    input  cell_id_t invalidate_cell_id [LANES-1:0],

    input  logic [LANES-1:0] read_req_valid,
    output logic [LANES-1:0] read_req_ready,
    input  cell_id_t read_req_cell_id [LANES-1:0],
    output logic [LANES-1:0] read_rsp_valid,
    input  logic [LANES-1:0] read_rsp_ready,
    output assembled_cell_t read_rsp_payload [LANES-1:0],
    output cell_metadata_t read_rsp_metadata [LANES-1:0],

    output logic protocol_error
);

    localparam int unsigned LANE_INDEX_WIDTH = $clog2(LANES);

    logic [BANKS-1:0] bank_initialized;
    logic [BANKS-1:0] bank_write_valid;
    logic [BANKS-1:0] bank_write_ready;
    cell_id_t bank_write_cell_id [BANKS-1:0];
    assembled_cell_t bank_write_payload [BANKS-1:0];
    logic [BANKS-1:0] bank_link_valid;
    logic [BANKS-1:0] bank_link_ready;
    cell_id_t bank_link_cell_id [BANKS-1:0];
    cell_id_t bank_link_next_cell [BANKS-1:0];
    logic [BANKS-1:0] bank_invalidate_valid;
    logic [BANKS-1:0] bank_invalidate_ready;
    cell_id_t bank_invalidate_cell_id [BANKS-1:0];
    logic [BANKS-1:0] bank_read_valid;
    logic [BANKS-1:0] bank_read_ready;
    cell_id_t bank_read_cell_id [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] bank_read_lane [BANKS-1:0];
    logic [BANKS-1:0] bank_rsp_valid;
    logic [BANKS-1:0] bank_rsp_ready;
    logic [LANE_INDEX_WIDTH-1:0] bank_rsp_lane [BANKS-1:0];
    assembled_cell_t bank_rsp_payload [BANKS-1:0];
    cell_metadata_t bank_rsp_metadata [BANKS-1:0];
    logic [BANKS-1:0] bank_protocol_error;

    logic [LANE_INDEX_WIDTH-1:0] write_rr [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] link_rr [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] invalidate_rr [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] read_rr [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] write_grant_lane [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] link_grant_lane [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] invalidate_grant_lane [BANKS-1:0];
    logic [LANE_INDEX_WIDTH-1:0] read_grant_lane [BANKS-1:0];
    logic [LANES-1:0] read_lane_pending;

    assign store_ready = &bank_initialized;
    assign protocol_error = |bank_protocol_error;

    // Payload writes: at most one request is selected for each physical bank.
    always_comb begin : route_payload_writes
        integer route_bank;
        integer route_offset;
        integer route_lane;
        logic route_found;
        write_ready = '0;
        bank_write_valid = '0;
        route_lane = 0;
        route_found = 1'b0;
        for (route_bank = 0; route_bank < BANKS; route_bank = route_bank + 1) begin
            bank_write_cell_id[route_bank] = '0;
            bank_write_payload[route_bank] = '0;
            write_grant_lane[route_bank] = '0;
            route_found = 1'b0;
            for (route_offset = 0; route_offset < LANES;
                 route_offset = route_offset + 1) begin
                route_lane = int'(write_rr[route_bank]) + route_offset;
                if (route_lane >= LANES) route_lane = route_lane - LANES;
                if (!route_found && write_valid[route_lane] &&
                    ((int'(write_cell_id[route_lane]) % BANKS) == route_bank)) begin
                    bank_write_valid[route_bank] = 1'b1;
                    bank_write_cell_id[route_bank] = write_cell_id[route_lane];
                    bank_write_payload[route_bank] = write_payload[route_lane];
                    write_grant_lane[route_bank] = LANE_INDEX_WIDTH'(route_lane);
                    write_ready[route_lane] = bank_write_ready[route_bank];
                    route_found = 1'b1;
                end
            end
        end
    end

    // Forward-link updates use a separate metadata write port per bank.
    always_comb begin : route_link_updates
        integer route_bank;
        integer route_offset;
        integer route_lane;
        logic route_found;
        link_ready = '0;
        bank_link_valid = '0;
        route_lane = 0;
        route_found = 1'b0;
        for (route_bank = 0; route_bank < BANKS; route_bank = route_bank + 1) begin
            bank_link_cell_id[route_bank] = '0;
            bank_link_next_cell[route_bank] = '0;
            link_grant_lane[route_bank] = '0;
            route_found = 1'b0;
            for (route_offset = 0; route_offset < LANES;
                 route_offset = route_offset + 1) begin
                route_lane = int'(link_rr[route_bank]) + route_offset;
                if (route_lane >= LANES) route_lane = route_lane - LANES;
                if (!route_found && link_valid[route_lane] &&
                    ((int'(link_cell_id[route_lane]) % BANKS) == route_bank)) begin
                    bank_link_valid[route_bank] = 1'b1;
                    bank_link_cell_id[route_bank] = link_cell_id[route_lane];
                    bank_link_next_cell[route_bank] = link_next_cell[route_lane];
                    link_grant_lane[route_bank] = LANE_INDEX_WIDTH'(route_lane);
                    link_ready[route_lane] = bank_link_ready[route_bank];
                    route_found = 1'b1;
                end
            end
        end
    end

    // Invalidation accompanies Cell return and clears stale-read validity.
    always_comb begin : route_invalidations
        integer route_bank;
        integer route_offset;
        integer route_lane;
        logic route_found;
        invalidate_ready = '0;
        bank_invalidate_valid = '0;
        route_lane = 0;
        route_found = 1'b0;
        for (route_bank = 0; route_bank < BANKS; route_bank = route_bank + 1) begin
            bank_invalidate_cell_id[route_bank] = '0;
            invalidate_grant_lane[route_bank] = '0;
            route_found = 1'b0;
            for (route_offset = 0; route_offset < LANES;
                 route_offset = route_offset + 1) begin
                route_lane = int'(invalidate_rr[route_bank]) + route_offset;
                if (route_lane >= LANES) route_lane = route_lane - LANES;
                if (!route_found && invalidate_valid[route_lane] &&
                    ((int'(invalidate_cell_id[route_lane]) % BANKS) == route_bank)) begin
                    bank_invalidate_valid[route_bank] = 1'b1;
                    bank_invalidate_cell_id[route_bank] =
                        invalidate_cell_id[route_lane];
                    invalidate_grant_lane[route_bank] =
                        LANE_INDEX_WIDTH'(route_lane);
                    invalidate_ready[route_lane] =
                        bank_invalidate_ready[route_bank];
                    route_found = 1'b1;
                end
            end
        end
    end

    // Reads are synchronous. A lane may have only one request outstanding.
    always_comb begin : route_reads
        integer route_bank;
        integer route_offset;
        integer route_lane;
        logic route_found;
        read_req_ready = '0;
        bank_read_valid = '0;
        route_lane = 0;
        route_found = 1'b0;
        for (route_bank = 0; route_bank < BANKS; route_bank = route_bank + 1) begin
            bank_read_cell_id[route_bank] = '0;
            bank_read_lane[route_bank] = '0;
            read_grant_lane[route_bank] = '0;
            route_found = 1'b0;
            for (route_offset = 0; route_offset < LANES;
                 route_offset = route_offset + 1) begin
                route_lane = int'(read_rr[route_bank]) + route_offset;
                if (route_lane >= LANES) route_lane = route_lane - LANES;
                if (!route_found && read_req_valid[route_lane] &&
                    (!read_lane_pending[route_lane] ||
                     (read_rsp_valid[route_lane] && read_rsp_ready[route_lane])) &&
                    ((int'(read_req_cell_id[route_lane]) % BANKS) == route_bank)) begin
                    bank_read_valid[route_bank] = 1'b1;
                    bank_read_cell_id[route_bank] = read_req_cell_id[route_lane];
                    bank_read_lane[route_bank] = LANE_INDEX_WIDTH'(route_lane);
                    read_grant_lane[route_bank] = LANE_INDEX_WIDTH'(route_lane);
                    read_req_ready[route_lane] = bank_read_ready[route_bank];
                    route_found = 1'b1;
                end
            end
        end
    end

    // Bank response registers provide stable output under lane backpressure.
    always_comb begin
        read_rsp_valid = '0;
        bank_rsp_ready = '0;
        for (int unsigned lane = 0; lane < LANES; lane++) begin
            read_rsp_payload[lane] = '0;
            read_rsp_metadata[lane] = '0;
        end
        for (int unsigned bank = 0; bank < BANKS; bank++) begin
            if (bank_rsp_valid[bank]) begin
                read_rsp_valid[bank_rsp_lane[bank]] = 1'b1;
                read_rsp_payload[bank_rsp_lane[bank]] = bank_rsp_payload[bank];
                read_rsp_metadata[bank_rsp_lane[bank]] = bank_rsp_metadata[bank];
                bank_rsp_ready[bank] = read_rsp_ready[bank_rsp_lane[bank]];
            end
        end
    end

    generate
        for (genvar bank = 0; bank < BANKS; bank++) begin : gen_cell_bank
            switch2_cell_store_bank #(
                .BANK_INDEX(bank),
                .BANKS(BANKS),
                .LANES(LANES),
                .TOTAL_CELLS_PARAM(TOTAL_CELLS_PARAM)
            ) u_cell_store_bank (
                .clk                (clk),
                .rst_n              (rst_n),
                .initialized        (bank_initialized[bank]),
                .write_valid        (bank_write_valid[bank]),
                .write_ready        (bank_write_ready[bank]),
                .write_cell_id      (bank_write_cell_id[bank]),
                .write_payload      (bank_write_payload[bank]),
                .link_valid         (bank_link_valid[bank]),
                .link_ready         (bank_link_ready[bank]),
                .link_cell_id       (bank_link_cell_id[bank]),
                .link_next_cell     (bank_link_next_cell[bank]),
                .invalidate_valid   (bank_invalidate_valid[bank]),
                .invalidate_ready   (bank_invalidate_ready[bank]),
                .invalidate_cell_id (bank_invalidate_cell_id[bank]),
                .read_valid         (bank_read_valid[bank]),
                .read_ready         (bank_read_ready[bank]),
                .read_cell_id       (bank_read_cell_id[bank]),
                .read_lane          (bank_read_lane[bank]),
                .rsp_valid          (bank_rsp_valid[bank]),
                .rsp_ready          (bank_rsp_ready[bank]),
                .rsp_lane           (bank_rsp_lane[bank]),
                .rsp_payload        (bank_rsp_payload[bank]),
                .rsp_metadata       (bank_rsp_metadata[bank]),
                .protocol_error     (bank_protocol_error[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_lane_pending <= '0;
            for (int unsigned bank = 0; bank < BANKS; bank++) begin
                write_rr[bank] <= '0;
                link_rr[bank] <= '0;
                invalidate_rr[bank] <= '0;
                read_rr[bank] <= '0;
            end
        end else begin
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                case ({read_req_valid[lane] && read_req_ready[lane],
                       read_rsp_valid[lane] && read_rsp_ready[lane]})
                    2'b01: read_lane_pending[lane] <= 1'b0;
                    2'b10: read_lane_pending[lane] <= 1'b1;
                    default: read_lane_pending[lane] <= read_lane_pending[lane];
                endcase
            end
            for (int unsigned bank = 0; bank < BANKS; bank++) begin
                if (bank_write_valid[bank] && bank_write_ready[bank])
                    write_rr[bank] <= write_grant_lane[bank] + 1'b1;
                if (bank_link_valid[bank] && bank_link_ready[bank])
                    link_rr[bank] <= link_grant_lane[bank] + 1'b1;
                if (bank_invalidate_valid[bank] && bank_invalidate_ready[bank])
                    invalidate_rr[bank] <= invalidate_grant_lane[bank] + 1'b1;
                if (bank_read_valid[bank] && bank_read_ready[bank])
                    read_rr[bank] <= read_grant_lane[bank] + 1'b1;
            end
        end
    end

    initial begin
        if (BANKS != NUM_MEMORY_BANKS)
            $error("switch2_cell_store currently requires NUM_MEMORY_BANKS banks");
        if (LANES <= 1 || (1 << LANE_INDEX_WIDTH) != LANES)
            $error("switch2_cell_store requires power-of-two LANES > 1");
    end

endmodule : switch2_cell_store
