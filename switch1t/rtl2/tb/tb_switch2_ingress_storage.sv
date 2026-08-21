`timescale 1ns/1ps

module tb_switch2_ingress_storage;
    import switch2_pkg::*;

    localparam int unsigned TEST_CELLS = 64;
    localparam int unsigned TEST_DESCRIPTORS = 64;
    localparam int unsigned META_WIDTH = $bits(parsed_packet_t);
    localparam int unsigned ADMITTED_WIDTH = $bits(admitted_packet_t);
    localparam int unsigned PAYLOAD_WIDTH = $bits(assembled_cell_t);
    localparam int unsigned CELL_META_WIDTH = $bits(cell_metadata_t);

    logic clk;
    logic rst_n;
    logic datapath_ready;
    logic [CELL_ID_WIDTH:0] free_cell_count;
    logic [DESCRIPTOR_ID_WIDTH:0] free_descriptor_count;
    logic [NUM_PORTS-1:0] port_rx_valid;
    logic [NUM_PORTS-1:0] port_rx_ready;
    logic [NUM_PORTS-1:0] port_rx_sop;
    logic [NUM_PORTS-1:0] port_rx_eop;
    logic [PORT_DATA_WIDTH-1:0] port_rx_data [NUM_PORTS-1:0];
    logic [PORT_EMPTY_WIDTH-1:0] port_rx_empty [NUM_PORTS-1:0];
    logic [LOOKUP_LANES-1:0] admitted_valid;
    logic [LOOKUP_LANES-1:0] admitted_ready;
    admitted_packet_t admitted [LOOKUP_LANES-1:0];
    logic [ADMITTED_WIDTH-1:0] admitted_bits [LOOKUP_LANES-1:0];
    logic [EGRESS_CELL_LANES-1:0] cell_release_valid;
    logic [EGRESS_CELL_LANES-1:0] cell_release_ready;
    cell_id_t cell_release_id [EGRESS_CELL_LANES-1:0];
    logic [LOOKUP_LANES-1:0] descriptor_free_valid;
    logic [LOOKUP_LANES-1:0] descriptor_free_ready;
    descriptor_id_t descriptor_free_id [LOOKUP_LANES-1:0];
    logic [EGRESS_CELL_LANES-1:0] read_req_valid;
    logic [EGRESS_CELL_LANES-1:0] read_req_ready;
    cell_id_t read_req_cell_id [EGRESS_CELL_LANES-1:0];
    logic [EGRESS_CELL_LANES-1:0] read_rsp_valid;
    logic [EGRESS_CELL_LANES-1:0] read_rsp_ready;
    assembled_cell_t read_rsp_payload [EGRESS_CELL_LANES-1:0];
    cell_metadata_t read_rsp_metadata [EGRESS_CELL_LANES-1:0];
    logic [PAYLOAD_WIDTH-1:0] read_rsp_bits [EGRESS_CELL_LANES-1:0];
    logic [CELL_META_WIDTH-1:0] read_meta_bits [EGRESS_CELL_LANES-1:0];
    logic [NUM_PORTS-1:0] ingress_protocol_error;
    logic ordering_error;
    logic chain_protocol_error;
    logic admission_protocol_error;
    logic cell_ownership_error;
    logic store_protocol_error;
    logic descriptor_ownership_error;
    logic any_error_seen;
    logic [NUM_PORTS-1:0] source_seen;
    cell_id_t saved_cell_id [LOOKUP_LANES-1:0];
    descriptor_id_t saved_descriptor_id [LOOKUP_LANES-1:0];
    cell_id_t multi_head;
    cell_id_t multi_tail;
    descriptor_id_t multi_descriptor;
    integer multi_lane;

    generate
        for (genvar lane = 0; lane < LOOKUP_LANES; lane++) begin : gen_admit_alias
            assign admitted_bits[lane] = admitted[lane];
        end
        for (genvar lane = 0; lane < EGRESS_CELL_LANES; lane++) begin : gen_read_alias
            assign read_rsp_bits[lane] = read_rsp_payload[lane];
            assign read_meta_bits[lane] = read_rsp_metadata[lane];
        end
    endgenerate

    switch2_ingress_storage #(
        .TOTAL_CELLS_PARAM(TEST_CELLS),
        .DESCRIPTOR_COUNT_PARAM(TEST_DESCRIPTORS)
    ) dut (.*);

    always #1 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            any_error_seen <= 1'b0;
        end else if ((|ingress_protocol_error) || ordering_error ||
                     chain_protocol_error || admission_protocol_error ||
                     cell_ownership_error || store_protocol_error ||
                     descriptor_ownership_error) begin
            any_error_seen <= 1'b1;
        end
    end

    task automatic drive_four_frame_beat(input int beat);
        logic [63:0] word;
        @(negedge clk);
        case (beat)
            0: word = 64'h0011_2233_4455_6677;
            1: word = 64'h8899_AABB_0800_DEAD;
            2: word = 64'h0001_0203_0405_0607;
            3: word = 64'h0809_0A0B_0C0D_0E0F;
            4: word = 64'h1011_1213_1415_1617;
            5: word = 64'h1819_1A1B_1C1D_1E1F;
            6: word = 64'h2021_2223_2425_2627;
            default: word = 64'h2829_2A2B_2C2D_2E2F;
        endcase
        for (int port = 0; port < 4; port++) begin
            port_rx_valid[port] = 1'b1;
            port_rx_sop[port] = (beat == 0);
            port_rx_eop[port] = (beat == 7);
            port_rx_data[port] = word + port;
            port_rx_empty[port] = '0;
        end
        #0;
        if ((port_rx_ready[3:0] & 4'hF) !== 4'hF)
            $fatal(1, "four-port beat %0d was backpressured unexpectedly", beat);
        @(posedge clk);
        @(negedge clk);
        port_rx_valid[3:0] = '0;
        port_rx_sop[3:0] = '0;
        port_rx_eop[3:0] = '0;
    endtask

    task automatic drive_port5_beat(input int beat);
        logic [63:0] word;
        @(negedge clk);
        if (beat == 0)
            word = 64'h0A11_2233_4455_6677;
        else if (beat == 1)
            word = 64'h8899_AABB_0800_BEEF;
        else
            word = 64'h5000_0000_0000_0000 + beat;
        port_rx_valid[5] = 1'b1;
        port_rx_sop[5] = (beat == 0);
        port_rx_eop[5] = (beat == 19);
        port_rx_data[5] = word;
        port_rx_empty[5] = (beat == 19) ? 3'd3 : 3'd0;
        do @(posedge clk); while (!port_rx_ready[5]);
        @(negedge clk);
        port_rx_valid[5] = 1'b0;
        port_rx_sop[5] = 1'b0;
        port_rx_eop[5] = 1'b0;
        port_rx_empty[5] = '0;
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        port_rx_valid = '0;
        port_rx_sop = '0;
        port_rx_eop = '0;
        admitted_ready = '0;
        cell_release_valid = '0;
        descriptor_free_valid = '0;
        read_req_valid = '0;
        read_rsp_ready = '0;
        source_seen = '0;
        for (int port = 0; port < NUM_PORTS; port++) begin
            port_rx_data[port] = '0;
            port_rx_empty[port] = '0;
        end
        for (int lane = 0; lane < LOOKUP_LANES; lane++) begin
            cell_release_id[lane] = '0;
            descriptor_free_id[lane] = '0;
            read_req_cell_id[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (datapath_ready);
        @(negedge clk);
        if (free_cell_count !== TEST_CELLS ||
            free_descriptor_count !== TEST_DESCRIPTORS)
            $fatal(1, "integrated pools did not initialize");

        for (int beat = 0; beat < 8; beat++) drive_four_frame_beat(beat);
        wait (admitted_valid == 4'b1111);
        @(negedge clk);
        for (int lane = 0; lane < LOOKUP_LANES; lane++) begin
            int src;
            src = admitted_bits[lane][PORT_ID_WIDTH-1:0];
            if (src < 0 || src > 3 || source_seen[src])
                $fatal(1, "four-port admission source duplicated or invalid");
            source_seen[src] = 1'b1;
            if (admitted_bits[lane]
                [META_WIDTH+PORT_ID_WIDTH +: CELL_COUNT_WIDTH] !==
                CELL_COUNT_WIDTH'(1))
                $fatal(1, "single-Cell frame has wrong Cell count");
            saved_cell_id[lane] = admitted_bits[lane]
                [META_WIDTH+PORT_ID_WIDTH+CELL_COUNT_WIDTH+CELL_ID_WIDTH +:
                 CELL_ID_WIDTH];
            saved_descriptor_id[lane] =
                admitted_bits[lane][ADMITTED_WIDTH-1 -: DESCRIPTOR_ID_WIDTH];
        end
        if (source_seen[3:0] !== 4'hF)
            $fatal(1, "not all four source ports were admitted");

        admitted_ready = '1;
        @(posedge clk);
        @(negedge clk);
        admitted_ready = '0;

        for (int lane = 0; lane < LOOKUP_LANES; lane++) begin
            cell_release_id[lane] = saved_cell_id[lane];
            descriptor_free_id[lane] = saved_descriptor_id[lane];
        end
        cell_release_valid = '1;
        descriptor_free_valid = '1;
        #0;
        if (cell_release_ready !== '1 || descriptor_free_ready !== '1)
            $fatal(1, "resource release inputs were not accepted");
        @(posedge clk);
        @(negedge clk);
        cell_release_valid = '0;
        descriptor_free_valid = '0;
        wait (free_cell_count == TEST_CELLS &&
              free_descriptor_count == TEST_DESCRIPTORS);
        @(negedge clk);

        // A 157-byte frame exercises two Cells and one forward-link update.
        for (int beat = 0; beat < 20; beat++) drive_port5_beat(beat);
        wait (admitted_valid != '0);
        @(negedge clk);
        multi_lane = -1;
        for (int lane = 0; lane < LOOKUP_LANES; lane++) begin
            if (admitted_valid[lane]) multi_lane = lane;
        end
        if (multi_lane < 0) $fatal(1, "multi-Cell admission not found");
        if (admitted_bits[multi_lane][PORT_ID_WIDTH-1:0] !== port_id_t'(5))
            $fatal(1, "multi-Cell source mismatch");
        if (admitted_bits[multi_lane]
            [META_WIDTH+PORT_ID_WIDTH +: CELL_COUNT_WIDTH] !==
            CELL_COUNT_WIDTH'(2))
            $fatal(1, "multi-Cell count mismatch");
        multi_tail = admitted_bits[multi_lane]
            [META_WIDTH+PORT_ID_WIDTH+CELL_COUNT_WIDTH +: CELL_ID_WIDTH];
        multi_head = admitted_bits[multi_lane]
            [META_WIDTH+PORT_ID_WIDTH+CELL_COUNT_WIDTH+CELL_ID_WIDTH +:
             CELL_ID_WIDTH];
        multi_descriptor = admitted_bits[multi_lane]
            [ADMITTED_WIDTH-1 -: DESCRIPTOR_ID_WIDTH];

        admitted_ready[multi_lane] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        admitted_ready = '0;

        read_req_cell_id[0] = multi_head;
        read_req_cell_id[1] = multi_tail;
        read_req_valid = 4'b0011;
        #0;
        if ((read_req_ready & 4'b0011) !== 4'b0011)
            $fatal(1, "two-Cell readback requests not accepted");
        @(posedge clk);
        @(negedge clk);
        read_req_valid = '0;
        if ((read_rsp_valid & 4'b0011) !== 4'b0011)
            $fatal(1, "two-Cell readback responses missing");
        if (!read_meta_bits[0][0] || read_meta_bits[0][1] ||
            read_meta_bits[0][CELL_ID_WIDTH+1:2] !== multi_tail)
            $fatal(1, "head Cell link metadata mismatch");
        if (!read_meta_bits[1][0] || !read_meta_bits[1][1])
            $fatal(1, "tail Cell EOP metadata mismatch");
        read_rsp_ready = 4'b0011;
        @(posedge clk);
        @(negedge clk);
        read_rsp_ready = '0;

        cell_release_id[0] = multi_head;
        cell_release_id[1] = multi_tail;
        cell_release_valid = 4'b0011;
        descriptor_free_id[0] = multi_descriptor;
        descriptor_free_valid = 4'b0001;
        @(posedge clk);
        @(negedge clk);
        cell_release_valid = '0;
        descriptor_free_valid = '0;
        wait (free_cell_count == TEST_CELLS &&
              free_descriptor_count == TEST_DESCRIPTORS);
        @(negedge clk);

        if (any_error_seen) $fatal(1, "integrated ingress raised an error");
        $display("PASS: 48-port ingress-to-storage/admission end-to-end path");
        $finish;
    end

endmodule : tb_switch2_ingress_storage
