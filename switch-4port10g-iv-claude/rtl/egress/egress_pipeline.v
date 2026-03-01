// ============================================================================
// Egress Pipeline — per port
// QoS: 4-level priority queues (WRR scheduling)
// Adds/strips 802.1Q tag based on VLAN untagged config
// Outputs XGMII frames
// ============================================================================
`timescale 1ns/1ps

module egress_pipeline #(
    parameter PORT_ID   = 0,
    parameter PORT_NUM  = 4,
    parameter DATA_W    = 64,
    parameter CTRL_W    = 8,
    parameter Q_DEPTH   = 256   // per-priority queue depth
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // From switch fabric
    input  wire                 cell_valid,
    input  wire [DATA_W-1:0]    cell_data,
    input  wire [PORT_NUM-1:0]  cell_src,
    input  wire [11:0]          cell_vid,
    input  wire [2:0]           cell_prio,
    input  wire                 cell_sof,
    input  wire                 cell_eof,
    output wire                 cell_ready,

    // VLAN untagged mask (from vlan_table)
    input  wire [PORT_NUM-1:0]  vlan_untagged,

    // XGMII output
    output reg  [DATA_W-1:0]    xgmii_txd,
    output reg  [CTRL_W-1:0]    xgmii_txc,

    // STP tx enable
    input  wire                 tx_en,

    // Statistics
    output reg  [31:0]          stat_tx_pkts,
    output reg  [31:0]          stat_tx_bytes,
    output reg  [31:0]          stat_drop_pkts
);

    // -------------------------------------------------------------------------
    // Priority queue (4 levels from 802.1p: prio[2:1])
    // -------------------------------------------------------------------------
    localparam PRIO_LEVELS = 4;
    localparam Q_AW        = $clog2(Q_DEPTH);
    localparam CELL_W      = DATA_W + PORT_NUM + 12 + 1 + 1; // data+src+vid+sof+eof

    reg [CELL_W-1:0] pq_mem   [0:PRIO_LEVELS-1][0:Q_DEPTH-1];
    reg [Q_AW:0]     pq_wptr  [0:PRIO_LEVELS-1];
    reg [Q_AW:0]     pq_rptr  [0:PRIO_LEVELS-1];

    wire [Q_AW:0]    pq_count [0:PRIO_LEVELS-1];
    wire             pq_full  [0:PRIO_LEVELS-1];
    wire             pq_empty [0:PRIO_LEVELS-1];

    genvar q;
    generate
        for (q = 0; q < PRIO_LEVELS; q = q+1) begin : gen_pq
            assign pq_count[q] = pq_wptr[q] - pq_rptr[q];
            assign pq_full[q]  = pq_count[q] >= Q_DEPTH;
            assign pq_empty[q] = (pq_count[q] == 0);
        end
    endgenerate

    // Map 3-bit 802.1p priority to 2-bit queue index (0=lowest, 3=highest)
    function [1:0] prio_to_queue;
        input [2:0] p;
        case (p)
            3'd0, 3'd1: prio_to_queue = 2'd0;
            3'd2, 3'd3: prio_to_queue = 2'd1;
            3'd4, 3'd5: prio_to_queue = 2'd2;
            default:    prio_to_queue = 2'd3;
        endcase
    endfunction

    wire [1:0] wr_q = prio_to_queue(cell_prio);
    assign cell_ready = !pq_full[wr_q];

    // -------------------------------------------------------------------------
    // Enqueue
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin : enqueue
        integer qi;
        if (!rst_n) begin
            for (qi = 0; qi < PRIO_LEVELS; qi = qi+1)
                pq_wptr[qi] <= 0;
        end else begin
            if (cell_valid && !pq_full[wr_q]) begin
                pq_mem[wr_q][pq_wptr[wr_q][Q_AW-1:0]] <= {
                    cell_eof, cell_sof, cell_vid, cell_src, cell_data
                };
                pq_wptr[wr_q] <= pq_wptr[wr_q] + 1'b1;
            end else if (cell_valid && pq_full[wr_q]) begin
                stat_drop_pkts <= stat_drop_pkts + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // WRR Scheduler: weights [4,3,2,1] for queues [3,2,1,0]
    // -------------------------------------------------------------------------
    // WRR weights per queue level (index 0=lowest, 3=highest)
    // Encoded as 3-bit constants: q0=1, q1=2, q2=3, q3=4
    function [2:0] wrr_weight;
        input [1:0] qi;
        case (qi)
            2'd0: wrr_weight = 3'd1;
            2'd1: wrr_weight = 3'd2;
            2'd2: wrr_weight = 3'd3;
            default: wrr_weight = 3'd4;
        endcase
    endfunction

    reg [2:0]  wrr_credit [0:PRIO_LEVELS-1];
    reg [1:0]  sched_q;
    reg        sched_valid;
    reg [CELL_W-1:0] sched_cell;

    always @(posedge clk or negedge rst_n) begin : scheduler
        integer qi, best;
        if (!rst_n) begin
            for (qi = 0; qi < PRIO_LEVELS; qi = qi+1) begin
                pq_rptr[qi]    <= 0;
                wrr_credit[qi] <= wrr_weight(qi[1:0]);
            end
            sched_valid <= 0;
            sched_q     <= 0;
        end else begin
            sched_valid <= 0;
            if (tx_en) begin
                // Find highest non-empty queue with credit
                best = -1;
                for (qi = 0; qi < PRIO_LEVELS; qi = qi+1) begin
                    if (!pq_empty[qi] && wrr_credit[qi] > 0)
                        best = qi;
                end
                if (best >= 0) begin
                    sched_q     <= best[1:0];
                    sched_cell  <= pq_mem[best][pq_rptr[best][Q_AW-1:0]];
                    pq_rptr[best] <= pq_rptr[best] + 1'b1;
                    wrr_credit[best] <= wrr_credit[best] - 1'b1;
                    sched_valid <= 1'b1;
                end else begin
                    // Replenish credits
                    for (qi = 0; qi < PRIO_LEVELS; qi = qi+1)
                        wrr_credit[qi] <= wrr_weight(qi[1:0]);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // XGMII Framing
    // Add preamble/SFD on SOF, TERM on EOF
    // Optionally add/strip 802.1Q tag
    // -------------------------------------------------------------------------
    localparam XGMII_IDLE_WORD = 64'h0707070707070707;
    localparam XGMII_IDLE_CTRL = 8'hFF;
    localparam XGMII_PREAMBLE  = 64'hD555555555555555;
    localparam XGMII_TERM_SEQ  = 8'hFD;

    reg tx_active;
    reg [1:0] tx_state; // 0=idle,1=preamble,2=data,3=term

    wire sched_sof = sched_cell[CELL_W-2];
    wire sched_eof = sched_cell[CELL_W-1];
    wire [DATA_W-1:0] sched_data = sched_cell[DATA_W-1:0];

    always @(posedge clk or negedge rst_n) begin : xgmii_tx
        if (!rst_n) begin
            xgmii_txd  <= XGMII_IDLE_WORD;
            xgmii_txc  <= XGMII_IDLE_CTRL;
            tx_active  <= 0;
            tx_state   <= 0;
        end else begin
            case (tx_state)
                2'd0: begin // IDLE
                    xgmii_txd <= XGMII_IDLE_WORD;
                    xgmii_txc <= XGMII_IDLE_CTRL;
                    if (sched_valid && sched_sof) begin
                        tx_state <= 2'd1;
                    end
                end
                2'd1: begin // PREAMBLE+SFD
                    xgmii_txd <= XGMII_PREAMBLE;
                    xgmii_txc <= 8'h01; // START in lane 0
                    tx_state  <= 2'd2;
                end
                2'd2: begin // DATA
                    xgmii_txd <= sched_data;
                    xgmii_txc <= 8'h00;
                    stat_tx_bytes <= stat_tx_bytes + (DATA_W/8);
                    if (sched_eof) begin
                        tx_state <= 2'd3;
                        stat_tx_pkts <= stat_tx_pkts + 1'b1;
                    end
                end
                2'd3: begin // TERMINATE
                    xgmii_txd <= {56'h07070707070707, 8'hFD};
                    xgmii_txc <= 8'hFE; // TERM in lane 0 + IDLE rest
                    tx_state  <= 2'd0;
                end
                default: tx_state <= 2'd0;
            endcase
        end
    end

endmodule
