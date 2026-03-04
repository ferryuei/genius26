// ============================================================================
// 4-Port 10G Ethernet L2 Switch — Top Level
//
// Instantiates:
//   - 4x ingress_pipeline
//   - fdb_table (shared)
//   - vlan_table (shared)
//   - stp_ctrl
//   - switch_fabric
//   - 4x egress_pipeline
//
// Interface:
//   - 4x XGMII (64b data + 8b ctrl, DDR at 156.25 MHz = 10 Gbps)
//   - APB slave for CPU management
// ============================================================================
`timescale 1ns/1ps

module l2_switch_top #(
    parameter PORT_NUM   = 4,
    parameter DATA_W     = 64,
    parameter CTRL_W     = 8,
    parameter FDB_DEPTH  = 4096,
    parameter FIFO_DEPTH = 512,
    parameter Q_DEPTH    = 256
)(
    input  wire                     clk,          // 156.25 MHz core clock
    input  wire                     rst_n,

    // XGMII Receive (4 ports)
    input  wire [DATA_W-1:0]        xgmii_rxd [0:PORT_NUM-1],
    input  wire [CTRL_W-1:0]        xgmii_rxc [0:PORT_NUM-1],

    // XGMII Transmit (4 ports)
    output wire [DATA_W-1:0]        xgmii_txd [0:PORT_NUM-1],
    output wire [CTRL_W-1:0]        xgmii_txc [0:PORT_NUM-1],

    // APB Slave (for CPU management)
    input  wire                     apb_psel,
    input  wire                     apb_penable,
    input  wire                     apb_pwrite,
    input  wire [15:0]              apb_paddr,
    input  wire [31:0]              apb_pwdata,
    output reg  [31:0]              apb_prdata,
    output wire                     apb_pready,

    // Aging tick (connect to 1-second timer)
    input  wire                     age_tick
);

    assign apb_pready = 1'b1;

    // =========================================================================
    // Internal wires
    // =========================================================================

    // FDB lookup (4 ingress ports share one FDB; arbitrated inside fdb_table)
    // For simplicity, port 0 has priority (extend with round-robin if needed)
    wire                    fdb_lkp_valid [0:PORT_NUM-1];
    wire [47:0]             fdb_lkp_mac   [0:PORT_NUM-1];
    wire                    fdb_lkp_hit   [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     fdb_lkp_port  [0:PORT_NUM-1];
    wire                    fdb_lkp_done  [0:PORT_NUM-1];
    wire                    fdb_lrn_valid [0:PORT_NUM-1];
    wire [47:0]             fdb_lrn_mac   [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     fdb_lrn_port  [0:PORT_NUM-1];

    // VLAN lookup (combinational, port-indexed via ingress vid)
    wire [11:0]             vlan_vid      [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     vlan_member   [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     vlan_untagged [0:PORT_NUM-1];
    wire                    vlan_valid_o  [0:PORT_NUM-1];

    // STP
    wire [PORT_NUM-1:0]     stp_rx_en, stp_tx_en, stp_lrn_en;

    // Ingress -> Fabric
    wire [PORT_NUM-1:0]     ing_cell_valid;
    wire [DATA_W-1:0]       ing_cell_data   [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     ing_cell_dst    [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     ing_cell_src    [0:PORT_NUM-1];
    wire [11:0]             ing_cell_vid    [0:PORT_NUM-1];
    wire [2:0]              ing_cell_prio   [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     ing_cell_sof;
    wire [PORT_NUM-1:0]     ing_cell_eof;
    wire [PORT_NUM-1:0]     ing_cell_drop;
    wire [PORT_NUM-1:0]     ing_cell_ready;

    // Fabric -> Egress
    wire [PORT_NUM-1:0]     egr_cell_valid;
    wire [DATA_W-1:0]       egr_cell_data  [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     egr_cell_src   [0:PORT_NUM-1];
    wire [11:0]             egr_cell_vid   [0:PORT_NUM-1];
    wire [2:0]              egr_cell_prio  [0:PORT_NUM-1];
    wire [PORT_NUM-1:0]     egr_cell_sof;
    wire [PORT_NUM-1:0]     egr_cell_eof;
    wire [PORT_NUM-1:0]     egr_cell_ready;

    // Statistics
    wire [31:0] stat_rx_pkts  [0:PORT_NUM-1];
    wire [31:0] stat_rx_bytes [0:PORT_NUM-1];
    wire [31:0] stat_rx_drop  [0:PORT_NUM-1];
    wire [31:0] stat_tx_pkts  [0:PORT_NUM-1];
    wire [31:0] stat_tx_bytes [0:PORT_NUM-1];
    wire [31:0] stat_tx_drop  [0:PORT_NUM-1];

    // =========================================================================
    // FDB Table (shared with round-robin arbiter)
    // =========================================================================
    // Arbitrate 4 lookup/learn requests — round-robin for fairness
    reg  [1:0]       fdb_rr_ptr_lkp;
    reg  [1:0]       fdb_rr_ptr_lrn;
    wire             fdb_arb_lkp_valid;
    wire [47:0]      fdb_arb_lkp_mac;
    wire             fdb_arb_lrn_valid;
    wire [47:0]      fdb_arb_lrn_mac;
    wire [PORT_NUM-1:0] fdb_arb_lrn_port;
    wire             fdb_hit_o;
    wire [PORT_NUM-1:0] fdb_port_o;
    wire             fdb_done_o;

    // Round-robin lookup arbiter
    reg              fdb_lkp_grant [0:PORT_NUM-1];
    reg [1:0]        fdb_lkp_winner;

    always @(*) begin : fdb_lkp_arb
        integer i, offset;
        fdb_lkp_winner = 2'd0;
        for (i = 0; i < PORT_NUM; i = i+1)
            fdb_lkp_grant[i] = 1'b0;

        for (i = 0; i < PORT_NUM; i = i+1) begin
            offset = (fdb_rr_ptr_lkp + i) % PORT_NUM;
            if (fdb_lkp_valid[offset] && !fdb_lkp_grant[0] && !fdb_lkp_grant[1] &&
                !fdb_lkp_grant[2] && !fdb_lkp_grant[3]) begin
                fdb_lkp_grant[offset] = 1'b1;
                fdb_lkp_winner = offset[1:0];
            end
        end
    end

    assign fdb_arb_lkp_valid = fdb_lkp_grant[0] | fdb_lkp_grant[1] |
                               fdb_lkp_grant[2] | fdb_lkp_grant[3];
    assign fdb_arb_lkp_mac   = fdb_lkp_grant[0] ? fdb_lkp_mac[0] :
                               fdb_lkp_grant[1] ? fdb_lkp_mac[1] :
                               fdb_lkp_grant[2] ? fdb_lkp_mac[2] :
                                                  fdb_lkp_mac[3];

    // Round-robin learn arbiter
    reg              fdb_lrn_grant [0:PORT_NUM-1];
    reg [1:0]        fdb_lrn_winner;

    always @(*) begin : fdb_lrn_arb
        integer i, offset;
        fdb_lrn_winner = 2'd0;
        for (i = 0; i < PORT_NUM; i = i+1)
            fdb_lrn_grant[i] = 1'b0;

        for (i = 0; i < PORT_NUM; i = i+1) begin
            offset = (fdb_rr_ptr_lrn + i) % PORT_NUM;
            if (fdb_lrn_valid[offset] && !fdb_lrn_grant[0] && !fdb_lrn_grant[1] &&
                !fdb_lrn_grant[2] && !fdb_lrn_grant[3]) begin
                fdb_lrn_grant[offset] = 1'b1;
                fdb_lrn_winner = offset[1:0];
            end
        end
    end

    assign fdb_arb_lrn_valid = fdb_lrn_grant[0] | fdb_lrn_grant[1] |
                               fdb_lrn_grant[2] | fdb_lrn_grant[3];
    assign fdb_arb_lrn_mac   = fdb_lrn_grant[0] ? fdb_lrn_mac[0] :
                               fdb_lrn_grant[1] ? fdb_lrn_mac[1] :
                               fdb_lrn_grant[2] ? fdb_lrn_mac[2] :
                                                  fdb_lrn_mac[3];
    assign fdb_arb_lrn_port  = fdb_lrn_grant[0] ? fdb_lrn_port[0] :
                               fdb_lrn_grant[1] ? fdb_lrn_port[1] :
                               fdb_lrn_grant[2] ? fdb_lrn_port[2] :
                                                  fdb_lrn_port[3];

    // Update round-robin pointers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fdb_rr_ptr_lkp <= 2'd0;
            fdb_rr_ptr_lrn <= 2'd0;
        end else begin
            if (fdb_arb_lkp_valid)
                fdb_rr_ptr_lkp <= (fdb_lkp_winner + 1'b1) % PORT_NUM;
            if (fdb_arb_lrn_valid)
                fdb_rr_ptr_lrn <= (fdb_lrn_winner + 1'b1) % PORT_NUM;
        end
    end

    // Broadcast result back to all ingress (each checks if it is the active requester)
    genvar p;
    generate
        for (p = 0; p < PORT_NUM; p = p+1) begin : gen_fdb_fanout
            assign fdb_lkp_hit[p]  = fdb_hit_o;
            assign fdb_lkp_port[p] = fdb_port_o;
            assign fdb_lkp_done[p] = fdb_done_o;
        end
    endgenerate

    fdb_table #(
        .FDB_DEPTH  (FDB_DEPTH),
        .PORT_NUM   (PORT_NUM)
    ) u_fdb (
        .clk            (clk),
        .rst_n          (rst_n),
        .learn_valid    (fdb_arb_lrn_valid),
        .learn_mac      (fdb_arb_lrn_mac),
        .learn_port_mask(fdb_arb_lrn_port),
        .lookup_valid   (fdb_arb_lkp_valid),
        .lookup_mac     (fdb_arb_lkp_mac),
        .lookup_hit     (fdb_hit_o),
        .lookup_port_mask(fdb_port_o),
        .lookup_done    (fdb_done_o),
        .age_tick       (age_tick),
        // CPU
        .cpu_wr_en      (apb_psel & apb_penable & apb_pwrite & (apb_paddr[15:12] == 4'h1)),
        .cpu_wr_addr    (apb_paddr[11:0]),
        .cpu_wr_mac     (48'h0),  // extend APB for full MAC
        .cpu_wr_port    (apb_pwdata[PORT_NUM-1:0]),
        .cpu_wr_static  (apb_pwdata[8]),
        .cpu_rd_en      (1'b0),
        .cpu_rd_addr    (12'h0),
        .cpu_rd_mac     (),
        .cpu_rd_port    (),
        .cpu_rd_valid   (),
        .cpu_rd_static  ()
    );

    // =========================================================================
    // VLAN Table (multi-port lookup support)
    // =========================================================================
    vlan_table #(.PORT_NUM(PORT_NUM)) u_vlan (
        .clk            (clk),
        .rst_n          (rst_n),
        .lkp_vid        (vlan_vid),
        .lkp_member     (vlan_member),
        .lkp_untagged   (vlan_untagged),
        .lkp_valid      (vlan_valid_o),
        .cpu_wr_en      (apb_psel & apb_penable & apb_pwrite & (apb_paddr[15:12] == 4'h2)),
        .cpu_wr_vid     (apb_paddr[11:0]),
        .cpu_wr_member  (apb_pwdata[PORT_NUM-1:0]),
        .cpu_wr_untagged(apb_pwdata[PORT_NUM+3:PORT_NUM]),
        .cpu_wr_valid   (apb_pwdata[8])
    );

    // =========================================================================
    // STP Controller
    // =========================================================================
    stp_ctrl #(.PORT_NUM(PORT_NUM)) u_stp (
        .clk            (clk),
        .rst_n          (rst_n),
        .cpu_port_sel   (apb_pwdata[PORT_NUM+3:PORT_NUM]),
        .cpu_state_wr   (apb_pwdata[2:0]),
        .cpu_wr_en      (apb_psel & apb_penable & apb_pwrite & (apb_paddr[15:12] == 4'h3)),
        .port_state     (),  // internal use only
        .rx_enable      (stp_rx_en),
        .tx_enable      (stp_tx_en),
        .learn_enable   (stp_lrn_en)
    );

    // =========================================================================
    // Ingress Pipelines (4 instances)
    // =========================================================================
    generate
        for (p = 0; p < PORT_NUM; p = p+1) begin : gen_ingress
            ingress_pipeline #(
                .PORT_ID    (p),
                .PORT_NUM   (PORT_NUM),
                .DATA_W     (DATA_W),
                .CTRL_W     (CTRL_W)
            ) u_ing (
                .clk            (clk),
                .rst_n          (rst_n),
                .xgmii_rxd      (xgmii_rxd[p]),
                .xgmii_rxc      (xgmii_rxc[p]),
                .rx_en          (stp_rx_en[p]),
                .learn_en       (stp_lrn_en[p]),
                .fdb_lkp_valid  (fdb_lkp_valid[p]),
                .fdb_lkp_mac    (fdb_lkp_mac[p]),
                .fdb_lkp_hit    (fdb_lkp_hit[p]),
                .fdb_lkp_port   (fdb_lkp_port[p]),
                .fdb_lkp_done   (fdb_lkp_done[p]),
                .fdb_learn_valid(fdb_lrn_valid[p]),
                .fdb_learn_mac  (fdb_lrn_mac[p]),
                .fdb_learn_port (fdb_lrn_port[p]),
                .vlan_lkp_vid   (vlan_vid[p]),
                .vlan_member    (vlan_member[p]),
                .vlan_untagged  (vlan_untagged[p]),
                .vlan_valid     (vlan_valid_o[p]),
                .cell_valid     (ing_cell_valid[p]),
                .cell_data      (ing_cell_data[p]),
                .cell_dst_mask  (ing_cell_dst[p]),
                .cell_src_mask  (ing_cell_src[p]),
                .cell_vid       (ing_cell_vid[p]),
                .cell_prio      (ing_cell_prio[p]),
                .cell_sof       (ing_cell_sof[p]),
                .cell_eof       (ing_cell_eof[p]),
                .cell_drop      (ing_cell_drop[p]),
                .cell_ready     (ing_cell_ready[p]),
                .stat_rx_pkts   (stat_rx_pkts[p]),
                .stat_rx_bytes  (stat_rx_bytes[p]),
                .stat_rx_drop   (stat_rx_drop[p])
            );
        end
    endgenerate

    // =========================================================================
    // Switch Fabric
    // =========================================================================
    switch_fabric #(
        .PORT_NUM   (PORT_NUM),
        .DATA_W     (DATA_W),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_fabric (
        .clk            (clk),
        .rst_n          (rst_n),
        .ing_valid      (ing_cell_valid),
        .ing_data       (ing_cell_data),
        .ing_dst        (ing_cell_dst),
        .ing_src        (ing_cell_src),
        .ing_vid        (ing_cell_vid),
        .ing_prio       (ing_cell_prio),
        .ing_sof        (ing_cell_sof),
        .ing_eof        (ing_cell_eof),
        .ing_drop       (ing_cell_drop),
        .ing_ready      (ing_cell_ready),
        .egr_valid      (egr_cell_valid),
        .egr_data       (egr_cell_data),
        .egr_src        (egr_cell_src),
        .egr_vid        (egr_cell_vid),
        .egr_prio       (egr_cell_prio),
        .egr_sof        (egr_cell_sof),
        .egr_eof        (egr_cell_eof),
        .egr_ready      (egr_cell_ready),
        .tx_enable      (stp_tx_en)
    );

    // =========================================================================
    // Egress Pipelines (4 instances)
    // =========================================================================
    generate
        for (p = 0; p < PORT_NUM; p = p+1) begin : gen_egress
            egress_pipeline #(
                .PORT_ID    (p),
                .PORT_NUM   (PORT_NUM),
                .DATA_W     (DATA_W),
                .CTRL_W     (CTRL_W),
                .Q_DEPTH    (Q_DEPTH)
            ) u_egr (
                .clk            (clk),
                .rst_n          (rst_n),
                .cell_valid     (egr_cell_valid[p]),
                .cell_data      (egr_cell_data[p]),
                .cell_src       (egr_cell_src[p]),
                .cell_vid       (egr_cell_vid[p]),
                .cell_prio      (egr_cell_prio[p]),
                .cell_sof       (egr_cell_sof[p]),
                .cell_eof       (egr_cell_eof[p]),
                .cell_ready     (egr_cell_ready[p]),
                .vlan_untagged  (vlan_untagged[p]),
                .xgmii_txd      (xgmii_txd[p]),
                .xgmii_txc      (xgmii_txc[p]),
                .tx_en          (stp_tx_en[p]),
                .stat_tx_pkts   (stat_tx_pkts[p]),
                .stat_tx_bytes  (stat_tx_bytes[p]),
                .stat_drop_pkts (stat_tx_drop[p])
            );
        end
    endgenerate

    // =========================================================================
    // APB Read (statistics)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            apb_prdata <= 32'h0;
        end else if (apb_psel && !apb_pwrite) begin
            case (apb_paddr[7:0])
                8'h00: apb_prdata <= stat_rx_pkts[0];
                8'h04: apb_prdata <= stat_rx_bytes[0];
                8'h08: apb_prdata <= stat_rx_drop[0];
                8'h10: apb_prdata <= stat_rx_pkts[1];
                8'h14: apb_prdata <= stat_rx_bytes[1];
                8'h18: apb_prdata <= stat_rx_drop[1];
                8'h20: apb_prdata <= stat_rx_pkts[2];
                8'h24: apb_prdata <= stat_rx_bytes[2];
                8'h28: apb_prdata <= stat_rx_drop[2];
                8'h30: apb_prdata <= stat_rx_pkts[3];
                8'h34: apb_prdata <= stat_rx_bytes[3];
                8'h38: apb_prdata <= stat_rx_drop[3];
                8'h40: apb_prdata <= stat_tx_pkts[0];
                8'h44: apb_prdata <= stat_tx_bytes[0];
                8'h50: apb_prdata <= stat_tx_pkts[1];
                8'h54: apb_prdata <= stat_tx_bytes[1];
                8'h60: apb_prdata <= stat_tx_pkts[2];
                8'h64: apb_prdata <= stat_tx_bytes[2];
                8'h70: apb_prdata <= stat_tx_pkts[3];
                8'h74: apb_prdata <= stat_tx_bytes[3];
                default: apb_prdata <= 32'hDEAD_BEEF;
            endcase
        end
    end

endmodule
