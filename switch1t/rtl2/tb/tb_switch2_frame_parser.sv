`timescale 1ns/1ps

module tb_switch2_frame_parser;
    import switch2_pkg::*;

    logic clk;
    logic rst_n;
    logic s_valid;
    logic s_ready;
    logic s_sop;
    logic s_eop;
    logic [PORT_DATA_WIDTH-1:0] s_data;
    logic [PORT_EMPTY_WIDTH-1:0] s_empty;
    logic m_valid;
    logic m_ready;
    logic m_sop;
    logic m_eop;
    logic [PORT_DATA_WIDTH-1:0] m_data;
    logic [PORT_EMPTY_WIDTH-1:0] m_empty;
    logic meta_valid;
    logic meta_ready;
    parsed_packet_t meta;
    logic protocol_error;
    int forwarded_beats;

    switch2_frame_parser #(
        .PORT_INDEX(7)
    ) dut (.*);

    always #1 clk = ~clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            forwarded_beats <= 0;
        end else if (m_valid && m_ready) begin
            forwarded_beats <= forwarded_beats + 1;
        end
    end

    task automatic send_beat(
        input logic [63:0] data,
        input logic sop,
        input logic eop,
        input logic [2:0] empty
    );
        @(negedge clk);
        s_valid = 1'b1;
        s_data = data;
        s_sop = sop;
        s_eop = eop;
        s_empty = empty;
        do @(posedge clk); while (!s_ready);
        @(negedge clk);
        s_valid = 1'b0;
        s_sop = 1'b0;
        s_eop = 1'b0;
        s_empty = '0;
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        s_valid = 1'b0;
        s_sop = 1'b0;
        s_eop = 1'b0;
        s_data = '0;
        s_empty = '0;
        m_ready = 1'b1;
        meta_ready = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // 64-byte untagged frame. First wire byte is data[63:56].
        send_beat(64'h0011_2233_4455_6677, 1'b1, 1'b0, 3'd0);
        send_beat(64'h8899_AABB_0800_DEAD, 1'b0, 1'b0, 3'd0);
        send_beat(64'h0001_0203_0405_0607, 1'b0, 1'b0, 3'd0);
        send_beat(64'h0809_0A0B_0C0D_0E0F, 1'b0, 1'b0, 3'd0);
        send_beat(64'h1011_1213_1415_1617, 1'b0, 1'b0, 3'd0);
        send_beat(64'h1819_1A1B_1C1D_1E1F, 1'b0, 1'b0, 3'd0);
        send_beat(64'h2021_2223_2425_2627, 1'b0, 1'b0, 3'd0);
        send_beat(64'h2829_2A2B_2C2D_2E2F, 1'b0, 1'b1, 3'd0);

        @(posedge clk);
        if (!meta_valid) $fatal(1, "metadata was not produced");
        if (meta.dmac !== 48'h0011_2233_4455) $fatal(1, "DMAC mismatch");
        if (meta.smac !== 48'h6677_8899_AABB) $fatal(1, "SMAC mismatch");
        if (meta.vlan_tagged) $fatal(1, "untagged frame marked tagged");
        if (meta.ethertype !== 16'h0800) $fatal(1, "EtherType mismatch");
        if (meta.packet_length !== 15'd64) $fatal(1, "length mismatch");
        if (meta.src_port !== 6'd7) $fatal(1, "source port mismatch");
        if (forwarded_beats !== 8) $fatal(1, "data bypass lost a beat");

        // Metadata backpressure must stop the next frame, not overwrite metadata.
        if (s_ready) $fatal(1, "parser accepted a new frame with metadata stalled");
        repeat (2) @(posedge clk);
        if (!meta_valid || meta.dmac !== 48'h0011_2233_4455)
            $fatal(1, "metadata changed under backpressure");

        meta_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (meta_valid) $fatal(1, "metadata handshake did not complete");
        if (protocol_error) $fatal(1, "well-formed frame raised protocol_error");

        $display("PASS: frame parser, byte order, length and metadata backpressure");
        $finish;
    end

endmodule : tb_switch2_frame_parser
