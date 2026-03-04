// ============================================================================
// Ingress Pipeline — per port
// Receives XGMII frames, strips preamble/SFD, parses Ethernet header,
// performs VLAN lookup, MAC lookup, builds internal cell header
//
// Internal cell format:
//   [WIDTH-1:0] data
//   [3:0]       dst_port_mask  (flood or unicast)
//   [3:0]       src_port_mask  (one-hot source port)
//   [11:0]      vid
//   [2:0]       prio           (802.1p)
//   [1:0]       cell_ctrl      (SOC / EOC / DATA / DROP)
// ============================================================================
`timescale 1ns/1ps

module ingress_pipeline #(
    parameter PORT_ID   = 0,
    parameter PORT_NUM  = 4,
    parameter DATA_W    = 64,     // XGMII data width
    parameter CTRL_W    = 8       // XGMII ctrl width
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // XGMII input
    input  wire [DATA_W-1:0]    xgmii_rxd,
    input  wire [CTRL_W-1:0]    xgmii_rxc,

    // STP enable
    input  wire                 rx_en,
    input  wire                 learn_en,

    // FDB lookup/learn interface
    output reg                  fdb_lkp_valid,
    output reg  [47:0]          fdb_lkp_mac,
    input  wire                 fdb_lkp_hit,
    input  wire [PORT_NUM-1:0]  fdb_lkp_port,
    input  wire                 fdb_lkp_done,

    output reg                  fdb_learn_valid,
    output reg  [47:0]          fdb_learn_mac,
    output reg  [PORT_NUM-1:0]  fdb_learn_port,

    // VLAN lookup interface
    output wire [11:0]          vlan_lkp_vid,
    input  wire [PORT_NUM-1:0]  vlan_member,
    input  wire [PORT_NUM-1:0]  vlan_untagged,
    input  wire                 vlan_valid,

    // Output cell stream to switch fabric
    output reg                  cell_valid,
    output reg  [DATA_W-1:0]    cell_data,
    output reg  [PORT_NUM-1:0]  cell_dst_mask,
    output reg  [PORT_NUM-1:0]  cell_src_mask,
    output reg  [11:0]          cell_vid,
    output reg  [2:0]           cell_prio,
    output reg                  cell_sof,
    output reg                  cell_eof,
    output reg                  cell_drop,
    input  wire                 cell_ready,

    // Statistics
    output reg  [31:0]          stat_rx_pkts,
    output reg  [31:0]          stat_rx_bytes,
    output reg  [31:0]          stat_rx_drop
);

    // -------------------------------------------------------------------------
    // XGMII control codes
    // -------------------------------------------------------------------------
    localparam XGMII_IDLE  = 8'h07;
    localparam XGMII_START = 8'hFB;
    localparam XGMII_TERM  = 8'hFD;
    localparam PREAMBLE    = 64'hD555555555555555; // SFD+preamble

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    localparam RX_IDLE    = 3'd0,
               RX_PREAM   = 3'd1,
               RX_HDR_DST = 3'd2,
               RX_HDR_SRC = 3'd3,
               RX_HDR_ETYPE = 3'd4,
               RX_PAYLOAD = 3'd5,
               RX_LKP_WAIT = 3'd6;

    reg [2:0]           rx_state;
    reg [47:0]          dst_mac_r, src_mac_r;
    reg [15:0]          etype_r;
    reg [11:0]          vid_r;
    reg [2:0]           prio_r;
    reg                 tagged_r;
    reg [PORT_NUM-1:0]  dst_mask_r;
    reg                 drop_r;
    reg [3:0]           hdr_cnt;
    reg                 backpressure;  // Flow control flag
    reg [15:0]          frame_byte_cnt; // Frame length counter

    // Byte lane buffer (64-bit XGMII = 8 bytes/cycle)
    reg [7:0]           byte_buf [0:5]; // capture MAC bytes across cycles
    reg [2:0]           buf_idx;

    // Default VLAN per port (PVID), configurable; here static = 1
    localparam [11:0] PVID = 12'd1;

    // Frame length limits
    localparam [15:0] MIN_FRAME_LEN = 16'd64;   // Minimum Ethernet frame
    localparam [15:0] MAX_FRAME_LEN = 16'd1518; // Standard max (no jumbo)

    assign vlan_lkp_vid = tagged_r ? vid_r : PVID;

    // -------------------------------------------------------------------------
    // RX state machine
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state        <= RX_IDLE;
            fdb_lkp_valid   <= 0;
            fdb_learn_valid <= 0;
            cell_valid      <= 0;
            cell_drop       <= 0;
            cell_sof        <= 0;
            cell_eof        <= 0;
            stat_rx_pkts    <= 0;
            stat_rx_bytes   <= 0;
            stat_rx_drop    <= 0;
            drop_r          <= 0;
            tagged_r        <= 0;
            hdr_cnt         <= 0;
            backpressure    <= 0;
            frame_byte_cnt  <= 0;
        end else begin
            fdb_lkp_valid   <= 0;
            fdb_learn_valid <= 0;
            cell_valid      <= 0;
            cell_sof        <= 0;
            cell_eof        <= 0;

            case (rx_state)
                // -----------------------------------------------------------------
                RX_IDLE: begin
                    drop_r   <= 0;
                    tagged_r <= 0;
                    hdr_cnt  <= 0;
                    frame_byte_cnt <= 0;
                    // Detect SOP: first byte of XGMII lane 0 is START
                    if (xgmii_rxc[0] && xgmii_rxd[7:0] == XGMII_START && rx_en) begin
                        rx_state <= RX_PREAM;
                        frame_byte_cnt <= DATA_W/8; // Count preamble/SFD
                    end else if (xgmii_rxc[0] && xgmii_rxd[7:0] == XGMII_START && !rx_en) begin
                        drop_r <= 1;
                        frame_byte_cnt <= DATA_W/8;
                        rx_state <= RX_PAYLOAD; // drain and drop
                    end
                end

                // -----------------------------------------------------------------
                // After SFD, capture DST MAC (6 bytes = lanes 2..7 of first word,
                // then lanes 0..1 of next word for simple 8B/cycle XGMII)
                // This is a simplified model: collect 6 bytes of dst, 6 of src
                // -----------------------------------------------------------------
                RX_PREAM: begin
                    // Preamble cycle consumed, next cycle has dst_mac[47:0]
                    // In real XGMII 64b the SFD byte is in lane 7 of the START word.
                    // We capture DST MAC from next two 64-bit words.
                    dst_mac_r[47:16] <= xgmii_rxd[63:32]; // bytes 0..3 of DST
                    hdr_cnt <= 1;
                    frame_byte_cnt <= frame_byte_cnt + DATA_W/8;
                    rx_state <= RX_HDR_DST;
                end

                RX_HDR_DST: begin
                    frame_byte_cnt <= frame_byte_cnt + DATA_W/8;
                    if (hdr_cnt == 1) begin
                        dst_mac_r[15:0] <= xgmii_rxd[15:0]; // bytes 4..5 of DST
                        src_mac_r[47:32] <= xgmii_rxd[47:16]; // bytes 0..3 of SRC
                        hdr_cnt <= 2;
                    end else begin
                        src_mac_r[31:0] <= xgmii_rxd[47:16];
                        etype_r <= xgmii_rxd[63:48];
                        hdr_cnt <= 0;
                        rx_state <= RX_HDR_ETYPE;
                    end
                end

                RX_HDR_SRC: begin
                    frame_byte_cnt <= frame_byte_cnt + DATA_W/8;
                    src_mac_r[15:0]  <= xgmii_rxd[15:0];
                    etype_r          <= xgmii_rxd[31:16];
                    rx_state <= RX_HDR_ETYPE;
                end

                // -----------------------------------------------------------------
                RX_HDR_ETYPE: begin
                    frame_byte_cnt <= frame_byte_cnt + DATA_W/8;
                    // Check for 802.1Q tag (0x8100)
                    if (etype_r == 16'h8100) begin
                        prio_r   <= xgmii_rxd[15:13];
                        vid_r    <= xgmii_rxd[11:0];
                        tagged_r <= 1'b1;
                    end else begin
                        vid_r    <= PVID;
                        prio_r   <= 3'd0;
                        tagged_r <= 1'b0;
                    end

                    // Start FDB dst lookup
                    fdb_lkp_valid <= 1'b1;
                    fdb_lkp_mac   <= dst_mac_r;

                    // Multicast/broadcast: set flood mask
                    if (dst_mac_r[40]) begin // LSB of first byte = 1 => multicast
                        dst_mask_r <= {PORT_NUM{1'b1}} & ~(1 << PORT_ID); // flood excl src
                    end

                    rx_state <= RX_LKP_WAIT;
                end

                // -----------------------------------------------------------------
                RX_LKP_WAIT: begin
                    if (fdb_lkp_done) begin
                        // Calculate destination mask based on lookup result
                        if (fdb_lkp_hit && !dst_mac_r[40]) begin
                            // Unicast hit: forward only to learned port
                            dst_mask_r <= (fdb_lkp_port & ~(1 << PORT_ID)) & vlan_member;
                        end else if (!dst_mac_r[40]) begin
                            // Unknown unicast: flood (excl src port)
                            dst_mask_r <= ({PORT_NUM{1'b1}} & ~(1 << PORT_ID)) & vlan_member;
                        end else begin
                            // Multicast/broadcast: flood (excl src port)
                            dst_mask_r <= ({PORT_NUM{1'b1}} & ~(1 << PORT_ID)) & vlan_member;
                        end

                        // Learn src MAC (if port is learn-enabled)
                        if (learn_en && !src_mac_r[40]) begin // don't learn multicast src
                            fdb_learn_valid <= 1'b1;
                            fdb_learn_mac   <= src_mac_r;
                            fdb_learn_port  <= (1 << PORT_ID);
                        end

                        // Check backpressure before transitioning to PAYLOAD
                        if (cell_ready) begin
                            rx_state <= RX_PAYLOAD;
                            backpressure <= 1'b0;
                            // Emit SOF cell
                            cell_valid    <= 1'b1;
                            cell_sof      <= 1'b1;
                            cell_data     <= xgmii_rxd;
                            cell_dst_mask <= dst_mask_r;
                            cell_src_mask <= (1 << PORT_ID);
                            cell_vid      <= vid_r;
                            cell_prio     <= prio_r;
                            cell_drop     <= drop_r || (dst_mask_r == 0);
                            stat_rx_pkts  <= stat_rx_pkts + 1'b1;
                        end else begin
                            // Fabric FIFO full, stay in wait state
                            backpressure <= 1'b1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                RX_PAYLOAD: begin
                    // Check backpressure before sending data
                    if (!cell_ready) begin
                        backpressure <= 1'b1;
                        // Stay in PAYLOAD state, don't advance frame
                    end else if (xgmii_rxc != 0) begin
                        // Control byte present — could be TERM (end of frame)
                        frame_byte_cnt <= frame_byte_cnt + DATA_W/8;

                        // Check frame length validity
                        if (frame_byte_cnt < MIN_FRAME_LEN) begin
                            // Runt frame: too short
                            drop_r <= 1'b1;
                        end else if (frame_byte_cnt > MAX_FRAME_LEN) begin
                            // Oversize frame: too long
                            drop_r <= 1'b1;
                        end

                        cell_valid <= 1'b1;
                        cell_eof   <= 1'b1;
                        cell_data  <= xgmii_rxd;
                        cell_drop  <= drop_r;
                        stat_rx_bytes <= stat_rx_bytes + frame_byte_cnt;
                        if (drop_r) stat_rx_drop <= stat_rx_drop + 1'b1;
                        rx_state <= RX_IDLE;
                        backpressure <= 1'b0;
                    end else begin
                        frame_byte_cnt <= frame_byte_cnt + DATA_W/8;

                        // Check for oversize frame during reception
                        if (frame_byte_cnt > MAX_FRAME_LEN) begin
                            drop_r <= 1'b1;
                        end

                        cell_valid <= 1'b1;
                        cell_data  <= xgmii_rxd;
                        cell_drop  <= drop_r;
                        backpressure <= 1'b0;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

endmodule
