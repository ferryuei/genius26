// Four-lane front end for the 16 independent Cell free-ID banks.
`timescale 1ns/1ps

module switch2_cell_pool
    import switch2_pkg::*;
#(
    parameter int unsigned BANKS = NUM_MEMORY_BANKS,
    parameter int unsigned LANES = INGRESS_CELL_LANES,
    parameter int unsigned TOTAL_CELLS_PARAM = TOTAL_CELLS
) (
    input logic clk,
    input logic rst_n,

    output logic pool_ready,
    output logic [CELL_ID_WIDTH:0] free_count,

    input  logic [LANES-1:0] alloc_req_valid,
    output logic [LANES-1:0] alloc_req_ready,
    output logic [LANES-1:0] alloc_rsp_valid,
    input  logic [LANES-1:0] alloc_rsp_ready,
    output cell_id_t alloc_cell_id [LANES-1:0],

    input  logic [LANES-1:0] free_valid,
    output logic [LANES-1:0] free_ready,
    input  cell_id_t free_cell_id [LANES-1:0],

    output logic ownership_error
);

    localparam int unsigned BANK_INDEX_WIDTH =
        (BANKS <= 1) ? 1 : $clog2(BANKS);
    localparam int unsigned LANE_INDEX_WIDTH =
        (LANES <= 1) ? 1 : $clog2(LANES);
    localparam int unsigned BANK_COUNT_WIDTH =
        $clog2(TOTAL_CELLS_PARAM / BANKS + 1);

    logic [BANKS-1:0] bank_initialized;
    logic [BANKS-1:0] bank_alloc_valid;
    logic [BANKS-1:0] bank_alloc_ready;
    cell_id_t bank_alloc_cell_id [BANKS-1:0];
    logic [BANKS-1:0] bank_free_valid;
    logic [BANKS-1:0] bank_free_ready;
    cell_id_t bank_free_cell_id [BANKS-1:0];
    logic [BANK_COUNT_WIDTH-1:0] bank_free_count [BANKS-1:0];
    logic [BANKS-1:0] bank_ownership_error;

    logic [BANK_INDEX_WIDTH-1:0] alloc_bank_rr;
    logic [BANK_INDEX_WIDTH-1:0] next_alloc_bank_rr;
    logic [LANE_INDEX_WIDTH-1:0] alloc_lane_rr;
    logic [LANE_INDEX_WIDTH-1:0] next_alloc_lane_rr;
    logic [LANE_INDEX_WIDTH-1:0] free_lane_rr [BANKS-1:0];
    logic [LANES-1:0] alloc_grant_valid;
    logic [BANK_INDEX_WIDTH-1:0] alloc_grant_bank [LANES-1:0];
    logic [BANKS-1:0] selected_bank;
    logic [LANE_INDEX_WIDTH-1:0] free_grant_lane [BANKS-1:0];

    integer request_offset;
    integer request_lane;
    integer bank_offset;
    integer bank_candidate;
    integer bank_search_start;
    integer free_bank;
    integer free_offset;
    integer free_lane_candidate;
    logic bank_found;
    logic free_found;

    assign pool_ready = &bank_initialized;
    assign ownership_error = |bank_ownership_error;

    always_comb begin
        free_count = '0;
        for (int unsigned count_bank = 0; count_bank < BANKS; count_bank++) begin
            free_count = free_count +
                (CELL_ID_WIDTH+1)'(bank_free_count[count_bank]);
        end
    end

    // Allocate distinct banks to request lanes with both lane and bank RR state.
    always_comb begin
        alloc_req_ready = '0;
        bank_alloc_ready = '0;
        alloc_grant_valid = '0;
        selected_bank = '0;
        next_alloc_bank_rr = alloc_bank_rr;
        next_alloc_lane_rr = alloc_lane_rr;
        request_lane = 0;
        bank_candidate = 0;
        bank_search_start = int'(alloc_bank_rr);
        bank_found = 1'b0;
        for (int unsigned clear_lane = 0; clear_lane < LANES; clear_lane++) begin
            alloc_grant_bank[clear_lane] = '0;
        end

        for (request_offset = 0; request_offset < LANES;
             request_offset = request_offset + 1) begin
            request_lane = int'(alloc_lane_rr) + request_offset;
            if (request_lane >= LANES) request_lane = request_lane - LANES;
            if (alloc_req_valid[request_lane] &&
                (!alloc_rsp_valid[request_lane] || alloc_rsp_ready[request_lane])) begin
                bank_found = 1'b0;
                for (bank_offset = 0; bank_offset < BANKS;
                     bank_offset = bank_offset + 1) begin
                    bank_candidate = bank_search_start + bank_offset;
                    if (bank_candidate >= BANKS)
                        bank_candidate = bank_candidate - BANKS;
                    if (!bank_found && bank_alloc_valid[bank_candidate] &&
                        !selected_bank[bank_candidate]) begin
                        alloc_grant_valid[request_lane] = 1'b1;
                        alloc_grant_bank[request_lane] =
                            BANK_INDEX_WIDTH'(bank_candidate);
                        alloc_req_ready[request_lane] = 1'b1;
                        bank_alloc_ready[bank_candidate] = 1'b1;
                        selected_bank[bank_candidate] = 1'b1;
                        bank_found = 1'b1;
                        if (bank_candidate == BANKS - 1)
                            bank_search_start = 0;
                        else
                            bank_search_start = bank_candidate + 1;
                        next_alloc_bank_rr =
                            BANK_INDEX_WIDTH'(bank_search_start);
                        if (request_lane == LANES - 1)
                            next_alloc_lane_rr = '0;
                        else
                            next_alloc_lane_rr =
                                LANE_INDEX_WIDTH'(request_lane + 1);
                    end
                end
            end
        end
    end

    // Route each return to its bank; each bank fairly selects one free lane.
    always_comb begin
        bank_free_valid = '0;
        free_lane_candidate = 0;
        free_found = 1'b0;
        for (free_bank = 0; free_bank < BANKS; free_bank = free_bank + 1) begin
            bank_free_cell_id[free_bank] = '0;
            free_grant_lane[free_bank] = '0;
            free_found = 1'b0;
            for (free_offset = 0; free_offset < LANES;
                 free_offset = free_offset + 1) begin
                free_lane_candidate = int'(free_lane_rr[free_bank]) + free_offset;
                if (free_lane_candidate >= LANES)
                    free_lane_candidate = free_lane_candidate - LANES;
                if (!free_found && free_valid[free_lane_candidate] &&
                    ((int'(free_cell_id[free_lane_candidate]) % BANKS) ==
                     free_bank)) begin
                    bank_free_valid[free_bank] = 1'b1;
                    bank_free_cell_id[free_bank] =
                        free_cell_id[free_lane_candidate];
                    free_grant_lane[free_bank] =
                        LANE_INDEX_WIDTH'(free_lane_candidate);
                    free_found = 1'b1;
                end
            end
        end
    end

    // Kept separate from request selection to avoid a false combinational loop
    // through a bank's ownership-dependent ready calculation.
    always_comb begin
        free_ready = '0;
        for (int unsigned ready_bank = 0; ready_bank < BANKS; ready_bank++) begin
            if (bank_free_valid[ready_bank]) begin
                free_ready[free_grant_lane[ready_bank]] =
                    bank_free_ready[ready_bank];
            end
        end
    end

    generate
        for (genvar bank = 0; bank < BANKS; bank++) begin : gen_bank_pool
            switch2_cell_bank_pool #(
                .BANK_INDEX(bank),
                .BANKS(BANKS),
                .TOTAL_CELLS_PARAM(TOTAL_CELLS_PARAM)
            ) u_bank_pool (
                .clk             (clk),
                .rst_n           (rst_n),
                .initialized     (bank_initialized[bank]),
                .alloc_valid     (bank_alloc_valid[bank]),
                .alloc_ready     (bank_alloc_ready[bank]),
                .alloc_cell_id   (bank_alloc_cell_id[bank]),
                .free_valid      (bank_free_valid[bank]),
                .free_ready      (bank_free_ready[bank]),
                .free_cell_id    (bank_free_cell_id[bank]),
                .free_count      (bank_free_count[bank]),
                .ownership_error (bank_ownership_error[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alloc_bank_rr <= '0;
            alloc_lane_rr <= '0;
            alloc_rsp_valid <= '0;
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                alloc_cell_id[lane] <= '0;
            end
            for (int unsigned bank = 0; bank < BANKS; bank++) begin
                free_lane_rr[bank] <= '0;
            end
        end else begin
            alloc_bank_rr <= next_alloc_bank_rr;
            alloc_lane_rr <= next_alloc_lane_rr;
            for (int unsigned lane = 0; lane < LANES; lane++) begin
                if (!alloc_rsp_valid[lane] || alloc_rsp_ready[lane]) begin
                    if (alloc_grant_valid[lane]) begin
                        alloc_rsp_valid[lane] <= 1'b1;
                        alloc_cell_id[lane] <=
                            bank_alloc_cell_id[alloc_grant_bank[lane]];
                    end else begin
                        alloc_rsp_valid[lane] <= 1'b0;
                    end
                end
            end
            for (int unsigned bank = 0; bank < BANKS; bank++) begin
                if (bank_free_valid[bank] && bank_free_ready[bank]) begin
                    if (free_grant_lane[bank] == LANE_INDEX_WIDTH'(LANES - 1))
                        free_lane_rr[bank] <= '0;
                    else
                        free_lane_rr[bank] <= free_grant_lane[bank] + 1'b1;
                end
            end
        end
    end

    initial begin
        if (BANKS != NUM_MEMORY_BANKS)
            $error("switch2_cell_pool currently requires NUM_MEMORY_BANKS banks");
        if (LANES == 0 || LANES > BANKS)
            $error("switch2_cell_pool LANES must be in the range 1..BANKS");
    end

endmodule : switch2_cell_pool
