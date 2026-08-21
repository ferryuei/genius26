`timescale 1ns/1ps

module tb_switch2_cell_assembler;
    import switch2_pkg::*;

    logic clk;
    logic rst_n;
    logic s_valid;
    logic s_ready;
    logic s_sop;
    logic s_eop;
    logic [PORT_DATA_WIDTH-1:0] s_data;
    logic [PORT_EMPTY_WIDTH-1:0] s_empty;
    logic cell_valid;
    logic cell_ready;
    assembled_cell_t assembled_cell;
    logic protocol_error;
    logic [CELL_DATA_WIDTH-1:0] observed_data;
    logic [CELL_DATA_WIDTH-1:0] held_data;
    logic [CELL_VALID_BYTES_WIDTH-1:0] held_valid_bytes;
    logic held_first;
    logic held_last;
    port_id_t held_src_port;

    assign observed_data = assembled_cell.data;

    switch2_cell_assembler #(
        .PORT_INDEX(11)
    ) dut (.*);

    always #1 clk = ~clk;

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
        cell_ready = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // A 157-byte frame produces one full Cell and one 29-byte Cell.
        for (int beat = 0; beat < 16; beat++) begin
            send_beat(64'hA000_0000_0000_0000 + beat, beat == 0, 1'b0, 3'd0);
        end

        if (!cell_valid) $fatal(1, "full Cell was not produced");
        if (!assembled_cell.first_cell || assembled_cell.last_cell)
            $fatal(1, "first Cell boundary flags mismatch");
        if (assembled_cell.valid_bytes !== CELL_VALID_BYTES_WIDTH'(128))
            $fatal(1, "full Cell byte count mismatch");
        if (assembled_cell.src_port !== PORT_ID_WIDTH'(11))
            $fatal(1, "Cell source port mismatch");
        if (observed_data[1023 -: 64] !== 64'hA000_0000_0000_0000)
            $fatal(1, "first beat byte placement mismatch");
        if (observed_data[63:0] !== 64'hA000_0000_0000_000F)
            $fatal(1, "last beat byte placement mismatch");

        held_data = assembled_cell.data;
        held_valid_bytes = assembled_cell.valid_bytes;
        held_first = assembled_cell.first_cell;
        held_last = assembled_cell.last_cell;
        held_src_port = assembled_cell.src_port;
        repeat (3) begin
            @(posedge clk);
            if (!cell_valid || observed_data !== held_data ||
                assembled_cell.valid_bytes !== held_valid_bytes ||
                assembled_cell.first_cell !== held_first ||
                assembled_cell.last_cell !== held_last ||
                assembled_cell.src_port !== held_src_port)
                $fatal(1, "Cell changed while downstream was stalled");
            if (s_ready) $fatal(1, "assembler accepted data while Cell was stalled");
        end

        // Release the full Cell, then supply 3 full beats plus a 5-byte tail.
        @(negedge clk);
        cell_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cell_ready = 1'b0;

        send_beat(64'hB000_0000_0000_0010, 1'b0, 1'b0, 3'd0);
        send_beat(64'hB000_0000_0000_0011, 1'b0, 1'b0, 3'd0);
        send_beat(64'hB000_0000_0000_0012, 1'b0, 1'b0, 3'd0);
        send_beat(64'hB000_0000_0000_0013, 1'b0, 1'b1, 3'd3);

        if (!cell_valid) $fatal(1, "tail Cell was not produced");
        if (assembled_cell.first_cell || !assembled_cell.last_cell)
            $fatal(1, "tail Cell boundary flags mismatch");
        if (assembled_cell.valid_bytes !== CELL_VALID_BYTES_WIDTH'(29))
            $fatal(1, "tail Cell byte count mismatch");
        if (observed_data[1023 -: 64] !== 64'hB000_0000_0000_0010)
            $fatal(1, "tail Cell first beat mismatch");
        if (observed_data[831 -: 64] !== 64'hB000_0000_0000_0013)
            $fatal(1, "tail Cell final beat mismatch");
        if (protocol_error) $fatal(1, "well-formed frame raised protocol_error");

        $display("PASS: 128-byte Cell assembly, tail bytes and output backpressure");
        $finish;
    end

endmodule : tb_switch2_cell_assembler
