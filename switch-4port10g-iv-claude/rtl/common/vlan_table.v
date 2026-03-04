// ============================================================================
// VLAN Table  (802.1Q)
// Supports 4096 VLANs, per-VLAN member port mask and untagged port mask
// ============================================================================
`timescale 1ns/1ps

module vlan_table #(
    parameter PORT_NUM  = 4,
    parameter VLAN_BITS = 12     // 4096 VLANs
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // Multi-port lookup interface (one per port)
    input  wire [VLAN_BITS-1:0] lkp_vid      [0:PORT_NUM-1],
    output reg  [PORT_NUM-1:0]  lkp_member   [0:PORT_NUM-1],
    output reg  [PORT_NUM-1:0]  lkp_untagged [0:PORT_NUM-1],
    output reg                  lkp_valid    [0:PORT_NUM-1],

    // CPU write interface
    input  wire                 cpu_wr_en,
    input  wire [VLAN_BITS-1:0] cpu_wr_vid,
    input  wire [PORT_NUM-1:0]  cpu_wr_member,
    input  wire [PORT_NUM-1:0]  cpu_wr_untagged,
    input  wire                 cpu_wr_valid
);

    // Each entry: [valid, untagged[3:0], member[3:0]] = 9 bits
    localparam ENTRY_W = 1 + PORT_NUM + PORT_NUM;
    localparam VLAN_NUM = 1 << VLAN_BITS;

    reg [ENTRY_W-1:0] vlan_mem [0:VLAN_NUM-1];

    integer i;
    initial begin
        for (i = 0; i < VLAN_NUM; i = i+1)
            vlan_mem[i] = {ENTRY_W{1'b0}};
        // Default VLAN 1: all ports member, all untagged
        vlan_mem[1] = {1'b1, 4'b1111, 4'b1111};
    end

    // Write
    always @(posedge clk) begin
        if (cpu_wr_en)
            vlan_mem[cpu_wr_vid] <= {cpu_wr_valid, cpu_wr_untagged, cpu_wr_member};
    end

    // Read (1-cycle registered, multi-port)
    genvar p;
    generate
        for (p = 0; p < PORT_NUM; p = p+1) begin : gen_vlan_lookup
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    lkp_member[p]   <= {PORT_NUM{1'b1}};
                    lkp_untagged[p] <= {PORT_NUM{1'b0}};
                    lkp_valid[p]    <= 1'b0;
                end else begin
                    lkp_valid[p]    <= vlan_mem[lkp_vid[p]][ENTRY_W-1];
                    lkp_untagged[p] <= vlan_mem[lkp_vid[p]][PORT_NUM*2-1:PORT_NUM];
                    lkp_member[p]   <= vlan_mem[lkp_vid[p]][PORT_NUM-1:0];
                end
            end
        end
    endgenerate

endmodule
