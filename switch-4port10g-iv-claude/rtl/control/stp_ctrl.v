// ============================================================================
// STP Port State Manager (per-port spanning tree state)
// Implements port states: Disabled / Blocking / Listening / Learning / Forwarding
// CPU configures state; hardware enforces frame filtering
// ============================================================================
`timescale 1ns/1ps

module stp_ctrl #(
    parameter PORT_NUM = 4
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // CPU configuration
    input  wire [PORT_NUM-1:0]  cpu_port_sel,  // one-hot
    input  wire [2:0]           cpu_state_wr,  // new state
    input  wire                 cpu_wr_en,

    // Per-port state output
    output reg  [2:0]           port_state [0:PORT_NUM-1],

    // Per-port enable signals derived from STP state
    output wire [PORT_NUM-1:0]  rx_enable,   // allow frame reception
    output wire [PORT_NUM-1:0]  tx_enable,   // allow frame transmission
    output wire [PORT_NUM-1:0]  learn_enable // allow MAC learning
);

    // STP states
    localparam STP_DISABLED   = 3'd0;
    localparam STP_BLOCKING   = 3'd1;
    localparam STP_LISTENING  = 3'd2;
    localparam STP_LEARNING   = 3'd3;
    localparam STP_FORWARDING = 3'd4;

    genvar p;
    integer i;

    // Initialize all ports to forwarding (no STP by default)
    initial begin
        for (i = 0; i < PORT_NUM; i = i+1)
            port_state[i] = STP_FORWARDING;
    end

    // CPU write
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < PORT_NUM; i = i+1)
                port_state[i] <= STP_FORWARDING;
        end else if (cpu_wr_en) begin
            for (i = 0; i < PORT_NUM; i = i+1) begin
                if (cpu_port_sel[i])
                    port_state[i] <= cpu_state_wr;
            end
        end
    end

    // Derive enable signals from state
    generate
        for (p = 0; p < PORT_NUM; p = p+1) begin : gen_enables
            assign rx_enable[p]    = (port_state[p] == STP_LISTENING)  ||
                                     (port_state[p] == STP_LEARNING)   ||
                                     (port_state[p] == STP_FORWARDING);
            assign tx_enable[p]    = (port_state[p] == STP_FORWARDING);
            assign learn_enable[p] = (port_state[p] == STP_LEARNING)   ||
                                     (port_state[p] == STP_FORWARDING);
        end
    endgenerate

endmodule
