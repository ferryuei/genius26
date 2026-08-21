`timescale 1ns/1ps

module tb_switch2_cell_arbiter;
    import switch2_pkg::*;

    localparam int unsigned INPUTS = 8;
    localparam int unsigned LANES = 4;

    logic clk;
    logic rst_n;
    logic [INPUTS-1:0] in_valid;
    logic [INPUTS-1:0] in_eligible;
    logic [INPUTS-1:0] in_ready;
    assembled_cell_t in_cell [INPUTS-1:0];
    logic [$bits(assembled_cell_t)-1:0] in_bits [INPUTS-1:0];
    logic [LANES-1:0] out_valid;
    logic [LANES-1:0] out_ready;
    assembled_cell_t out_cell [LANES-1:0];
    logic [INPUTS-1:0] accepted_mask;
    logic [INPUTS-1:0] consumed_mask;
    logic [$bits(assembled_cell_t)-1:0] out_bits [LANES-1:0];
    port_id_t out_src_port [LANES-1:0];
    logic [$bits(assembled_cell_t)-1:0] held_lane_zero;

    generate
        for (genvar source = 0; source < INPUTS; source++) begin : gen_input_alias
            assign in_cell[source] = in_bits[source];
        end
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_alias
            assign out_bits[lane] = out_cell[lane];
            assign out_src_port[lane] = out_bits[lane][PORT_ID_WIDTH-1:0];
        end
    endgenerate

    switch2_cell_arbiter #(
        .INPUTS(INPUTS),
        .LANES(LANES)
    ) dut (.*);

    always #1 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accepted_mask <= '0;
            consumed_mask <= '0;
        end else begin
            for (int source = 0; source < INPUTS; source++) begin
                if (in_valid[source] && in_ready[source]) begin
                    if (accepted_mask[source])
                        $fatal(1, "input %0d was accepted twice", source);
                    accepted_mask[source] <= 1'b1;
                    in_valid[source] <= 1'b0;
                end
            end
            for (int lane = 0; lane < LANES; lane++) begin
                if (out_valid[lane] && out_ready[lane]) begin
                    if (consumed_mask[out_src_port[lane]])
                        $fatal(1, "source %0d was emitted twice",
                               out_src_port[lane]);
                    consumed_mask[out_src_port[lane]] <= 1'b1;
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        in_valid = '0;
        in_eligible = '1;
        out_ready = '0;
        for (int source = 0; source < INPUTS; source++) begin
            in_bits[source] = '0;
            in_bits[source][PORT_ID_WIDTH-1:0] = source[PORT_ID_WIDTH-1:0];
            in_bits[source][PORT_ID_WIDTH+2 +: CELL_VALID_BYTES_WIDTH] =
                CELL_BYTES;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        in_valid = '1;

        // Fill all holding lanes while the consumer is stopped.
        @(posedge clk);
        @(negedge clk);
        if (out_valid !== 4'b1111) $fatal(1, "four lanes were not filled");
        if (accepted_mask !== 8'h0F) $fatal(1, "initial grant was not 0..3");
        held_lane_zero = out_bits[0];

        // Keep lane 0 stalled while other lanes drain and refill.
        out_ready = 4'b1110;
        repeat (3) begin
            @(posedge clk);
            @(negedge clk);
            if (!out_valid[0] || out_bits[0] !== held_lane_zero)
                $fatal(1, "stalled output lane changed transaction");
        end

        if (accepted_mask !== 8'hFF)
            $fatal(1, "not all inputs were eventually accepted");
        if (consumed_mask !== 8'hFE)
            $fatal(1, "unexpected set of outputs drained during lane-0 stall");

        out_ready = '1;
        @(posedge clk);
        @(negedge clk);
        if (consumed_mask !== 8'hFF) $fatal(1, "one or more Cells were lost");
        if (out_valid !== '0) $fatal(1, "arbiter did not drain cleanly");

        $display("PASS: 8-to-4 lossless arbitration, uniqueness and lane stability");
        $finish;
    end

endmodule : tb_switch2_cell_arbiter
