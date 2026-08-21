`timescale 1ns/1ps

module tb_switch2_packet_admission;
    import switch2_pkg::*;

    localparam int unsigned LANES = 4;
    localparam int unsigned TEST_DESCRIPTORS = 64;
    localparam int unsigned CHAIN_WIDTH = $bits(packet_cell_chain_t);
    localparam int unsigned META_WIDTH = $bits(parsed_packet_t);
    localparam int unsigned ADMITTED_WIDTH = $bits(admitted_packet_t);

    logic clk;
    logic rst_n;
    logic admission_ready;
    logic [DESCRIPTOR_ID_WIDTH:0] free_descriptor_count;
    logic [LANES-1:0] chain_valid;
    logic [LANES-1:0] chain_ready;
    packet_cell_chain_t chain [LANES-1:0];
    logic [CHAIN_WIDTH-1:0] chain_bits [LANES-1:0];
    logic [NUM_PORTS-1:0] metadata_valid;
    logic [NUM_PORTS-1:0] metadata_ready;
    parsed_packet_t metadata [NUM_PORTS-1:0];
    logic [META_WIDTH-1:0] metadata_bits [NUM_PORTS-1:0];
    logic [LANES-1:0] admitted_valid;
    logic [LANES-1:0] admitted_ready;
    admitted_packet_t admitted [LANES-1:0];
    logic [ADMITTED_WIDTH-1:0] admitted_bits [LANES-1:0];
    logic [ADMITTED_WIDTH-1:0] held_admitted [LANES-1:0];
    descriptor_id_t admitted_id [LANES-1:0];
    logic [LANES-1:0] descriptor_free_valid;
    logic [LANES-1:0] descriptor_free_ready;
    descriptor_id_t descriptor_free_id [LANES-1:0];
    logic ownership_error;
    logic protocol_error;
    logic [TEST_DESCRIPTORS-1:0] seen_descriptor;

    generate
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane_alias
            assign chain[lane] = chain_bits[lane];
            assign admitted_bits[lane] = admitted[lane];
        end
        for (genvar port = 0; port < NUM_PORTS; port++) begin : gen_meta_alias
            assign metadata[port] = metadata_bits[port];
        end
    endgenerate

    switch2_packet_admission #(
        .DESCRIPTOR_COUNT_PARAM(TEST_DESCRIPTORS)
    ) dut (.*);

    always #1 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        chain_valid = '0;
        metadata_valid = '0;
        admitted_ready = '0;
        descriptor_free_valid = '0;
        seen_descriptor = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            chain_bits[lane] = '0;
            descriptor_free_id[lane] = '0;
        end
        for (int port = 0; port < NUM_PORTS; port++) metadata_bits[port] = '0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (admission_ready);
        @(negedge clk);

        for (int lane = 0; lane < LANES; lane++) begin
            chain_bits[lane] = {
                cell_id_t'(lane),
                cell_id_t'(lane + 16),
                CELL_COUNT_WIDTH'(2),
                port_id_t'(lane + 10)
            };
            metadata_bits[lane + 10][PORT_ID_WIDTH-1:0] =
                port_id_t'(lane + 10);
            metadata_bits[lane + 10]
                [PORT_ID_WIDTH +: PACKET_LENGTH_WIDTH] =
                PACKET_LENGTH_WIDTH'(200 + lane);
            metadata_valid[lane + 10] = 1'b1;
        end
        chain_valid = '1;
        #0;
        if (chain_ready !== '1)
            $fatal(1, "four chain/metadata pairs were not accepted");
        for (int lane = 0; lane < LANES; lane++) begin
            if (!metadata_ready[lane + 10])
                $fatal(1, "metadata source %0d was not consumed", lane + 10);
        end
        @(posedge clk);
        @(negedge clk);
        chain_valid = '0;
        metadata_valid = '0;

        wait (admitted_valid == 4'b1111);
        @(negedge clk);
        if (free_descriptor_count !== TEST_DESCRIPTORS - LANES)
            $fatal(1, "descriptor free count mismatch");
        for (int lane = 0; lane < LANES; lane++) begin
            admitted_id[lane] =
                admitted_bits[lane][ADMITTED_WIDTH-1 -: DESCRIPTOR_ID_WIDTH];
            if (seen_descriptor[admitted_id[lane]])
                $fatal(1, "duplicate descriptor ID");
            seen_descriptor[admitted_id[lane]] = 1'b1;
            if (admitted_bits[lane][PORT_ID_WIDTH-1:0] !==
                port_id_t'(lane + 10))
                $fatal(1, "admitted metadata source mismatch");
            if (admitted_bits[lane][META_WIDTH + PORT_ID_WIDTH-1 -: PORT_ID_WIDTH]
                !== port_id_t'(lane + 10))
                $fatal(1, "admitted chain source mismatch");
            held_admitted[lane] = admitted_bits[lane];
        end

        repeat (2) begin
            @(posedge clk);
            @(negedge clk);
            for (int lane = 0; lane < LANES; lane++) begin
                if (!admitted_valid[lane] ||
                    admitted_bits[lane] !== held_admitted[lane])
                    $fatal(1, "admission changed under backpressure");
            end
        end

        admitted_ready = '1;
        @(posedge clk);
        @(negedge clk);
        admitted_ready = '0;
        if (admitted_valid !== '0) $fatal(1, "admissions did not drain");

        for (int lane = 0; lane < LANES; lane++)
            descriptor_free_id[lane] = admitted_id[lane];
        descriptor_free_valid = '1;
        @(posedge clk);
        @(negedge clk);
        if (descriptor_free_ready !== '1)
            $fatal(1, "descriptor releases were not accepted");
        descriptor_free_valid = '0;
        if (free_descriptor_count !== TEST_DESCRIPTORS)
            $fatal(1, "descriptor releases did not restore the pool");
        if (ownership_error || protocol_error)
            $fatal(1, "legal packet admission raised an error");

        $display("PASS: metadata join, four descriptor allocations and admission hold");
        $finish;
    end

endmodule : tb_switch2_packet_admission
