// ============================================================================
// Switch Fabric — Input-Buffered, Round-Robin Arbiter
// 4-port crossbar with per-port output FIFOs
//
// Each ingress port writes cells into a shared crossbar.
// Per-egress arbitration (round-robin) selects which ingress port wins.
// ============================================================================
`timescale 1ns/1ps

module switch_fabric #(
    parameter PORT_NUM  = 4,
    parameter DATA_W    = 64,
    parameter FIFO_DEPTH = 512  // cells per output port
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Ingress cell inputs (one per port)
    input  wire [PORT_NUM-1:0]          ing_valid,
    input  wire [DATA_W-1:0]            ing_data   [0:PORT_NUM-1],
    input  wire [PORT_NUM-1:0]          ing_dst    [0:PORT_NUM-1],  // dst mask
    input  wire [PORT_NUM-1:0]          ing_src    [0:PORT_NUM-1],  // src one-hot
    input  wire [11:0]                  ing_vid    [0:PORT_NUM-1],
    input  wire [2:0]                   ing_prio   [0:PORT_NUM-1],
    input  wire [PORT_NUM-1:0]          ing_sof,
    input  wire [PORT_NUM-1:0]          ing_eof,
    input  wire [PORT_NUM-1:0]          ing_drop,
    output wire [PORT_NUM-1:0]          ing_ready,

    // Egress cell outputs (one per port)
    output wire [PORT_NUM-1:0]          egr_valid,
    output wire [DATA_W-1:0]            egr_data   [0:PORT_NUM-1],
    output wire [PORT_NUM-1:0]          egr_src    [0:PORT_NUM-1],
    output wire [11:0]                  egr_vid    [0:PORT_NUM-1],
    output wire [2:0]                   egr_prio   [0:PORT_NUM-1],
    output wire [PORT_NUM-1:0]          egr_sof,
    output wire [PORT_NUM-1:0]          egr_eof,
    input  wire [PORT_NUM-1:0]          egr_ready,

    // QoS: per-port tx-enable from STP
    input  wire [PORT_NUM-1:0]          tx_enable
);

    // -------------------------------------------------------------------------
    // Internal FIFO cell width:
    //   DATA_W + PORT_NUM(src) + 12(vid) + 3(prio) + 1(sof) + 1(eof)
    // -------------------------------------------------------------------------
    localparam FIFO_W = DATA_W + PORT_NUM + 12 + 3 + 2;
    localparam FIFO_AW = $clog2(FIFO_DEPTH);

    // -------------------------------------------------------------------------
    // Per-egress-port FIFO
    // Simple synchronous FIFO (separate for each egress port)
    // -------------------------------------------------------------------------
    genvar ep, ip;
    integer i;

    // Per-egress FIFO storage
    reg [FIFO_W-1:0] fifo_mem   [0:PORT_NUM-1][0:FIFO_DEPTH-1];
    reg [FIFO_AW:0]  fifo_wptr  [0:PORT_NUM-1];
    reg [FIFO_AW:0]  fifo_rptr  [0:PORT_NUM-1];

    wire [FIFO_AW:0]  fifo_count [0:PORT_NUM-1];
    wire              fifo_full  [0:PORT_NUM-1];
    wire              fifo_empty [0:PORT_NUM-1];

    generate
        for (ep = 0; ep < PORT_NUM; ep = ep+1) begin : gen_fifo_status
            assign fifo_count[ep] = fifo_wptr[ep] - fifo_rptr[ep];
            assign fifo_full[ep]  = fifo_count[ep] >= FIFO_DEPTH;
            assign fifo_empty[ep] = (fifo_count[ep] == 0);
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Round-robin arbiter per egress port
    // Selects which ingress port writes into this egress FIFO this cycle
    // -------------------------------------------------------------------------
    reg [1:0] rr_ptr [0:PORT_NUM-1]; // per-egress RR pointer (binary counter)

    // Write side: for each egress port, find highest-priority requesting ingress
    // (among ing_valid & ing_dst[ep] & !fifo_full[ep])
    wire [PORT_NUM-1:0] req [0:PORT_NUM-1]; // req[ep][ip] = ingress ip requests egress ep
    wire [PORT_NUM-1:0] grant [0:PORT_NUM-1];

    generate
        for (ep = 0; ep < PORT_NUM; ep = ep+1) begin : gen_req
            for (ip = 0; ip < PORT_NUM; ip = ip+1) begin : gen_req_ip
                assign req[ep][ip] = ing_valid[ip] && ing_dst[ip][ep] &&
                                     !ing_drop[ip] && !fifo_full[ep] &&
                                     tx_enable[ep];
            end
        end
    endgenerate

    // Simple fixed-priority grant (round-robin state tracked in rr_ptr)
    // Grant[ep] is one-hot selecting the winning ingress port for egress ep
    reg [PORT_NUM-1:0] grant_r [0:PORT_NUM-1];

    generate
        for (ep = 0; ep < PORT_NUM; ep = ep+1) begin : gen_grant
            assign grant[ep] = grant_r[ep];
        end
    endgenerate

    // Round-robin arbiter logic
    always @(posedge clk or negedge rst_n) begin : arb_rr
        integer e, p, pp;
        if (!rst_n) begin
            for (e = 0; e < PORT_NUM; e = e+1) begin
                rr_ptr[e]  <= 2'd0; // start at port 0 (binary counter)
                grant_r[e] <= {PORT_NUM{1'b0}};
            end
        end else begin
            for (e = 0; e < PORT_NUM; e = e+1) begin
                grant_r[e] <= {PORT_NUM{1'b0}};
                for (p = 0; p < PORT_NUM; p = p+1) begin
                    pp = (rr_ptr[e] + p) % PORT_NUM; // round-robin offset
                    if (req[e][pp] && grant_r[e] == {PORT_NUM{1'b0}}) begin
                        grant_r[e][pp] <= 1'b1;
                    end
                end
                // Advance RR pointer if a grant was given
                if (grant_r[e] != {PORT_NUM{1'b0}}) begin
                    if (rr_ptr[e] == PORT_NUM-1)
                        rr_ptr[e] <= 2'd0;
                    else
                        rr_ptr[e] <= rr_ptr[e] + 2'd1;
                end
            end
        end
    end

    // ing_ready: ingress port is ready if at least one of its dst egress ports
    // can accept (not full). Simplified: always ready unless all dst FIFOs full.
    generate
        for (ip = 0; ip < PORT_NUM; ip = ip+1) begin : gen_ing_rdy
            wire any_dst_full;
            // Check if any target egress FIFO is full
            assign any_dst_full = |(ing_dst[ip] & {fifo_full[3], fifo_full[2],
                                                    fifo_full[1], fifo_full[0]});
            assign ing_ready[ip] = !any_dst_full;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // FIFO Write: multicast — cell may be written into multiple egress FIFOs
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin : fifo_wr
        integer e, p;
        if (!rst_n) begin
            for (e = 0; e < PORT_NUM; e = e+1)
                fifo_wptr[e] <= 0;
        end else begin
            for (e = 0; e < PORT_NUM; e = e+1) begin
                for (p = 0; p < PORT_NUM; p = p+1) begin
                    if (grant[e][p]) begin
                        fifo_mem[e][fifo_wptr[e][FIFO_AW-1:0]] <= {
                            ing_eof[p],
                            ing_sof[p],
                            ing_prio[p],
                            ing_vid[p],
                            ing_src[p],
                            ing_data[p]
                        };
                        fifo_wptr[e] <= fifo_wptr[e] + 1'b1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // FIFO Read: egress side
    // -------------------------------------------------------------------------
    reg [FIFO_W-1:0] fifo_rd_data [0:PORT_NUM-1];
    reg [PORT_NUM-1:0] fifo_rd_valid_r;

    always @(posedge clk or negedge rst_n) begin : fifo_rd
        integer e;
        if (!rst_n) begin
            for (e = 0; e < PORT_NUM; e = e+1) begin
                fifo_rptr[e]     <= 0;
                fifo_rd_valid_r[e] <= 0;
            end
        end else begin
            for (e = 0; e < PORT_NUM; e = e+1) begin
                fifo_rd_valid_r[e] <= 0;
                if (!fifo_empty[e] && egr_ready[e] && tx_enable[e]) begin
                    fifo_rd_data[e]    <= fifo_mem[e][fifo_rptr[e][FIFO_AW-1:0]];
                    fifo_rptr[e]       <= fifo_rptr[e] + 1'b1;
                    fifo_rd_valid_r[e] <= 1'b1;
                end
            end
        end
    end

    // Unpack egress outputs
    generate
        for (ep = 0; ep < PORT_NUM; ep = ep+1) begin : gen_egr_out
            assign egr_valid[ep]    = fifo_rd_valid_r[ep];
            assign egr_data[ep]     = fifo_rd_data[ep][DATA_W-1:0];
            assign egr_src[ep]      = fifo_rd_data[ep][DATA_W+PORT_NUM-1:DATA_W];
            assign egr_vid[ep]      = fifo_rd_data[ep][DATA_W+PORT_NUM+11:DATA_W+PORT_NUM];
            assign egr_prio[ep]     = fifo_rd_data[ep][DATA_W+PORT_NUM+14:DATA_W+PORT_NUM+12];
            assign egr_sof[ep]      = fifo_rd_data[ep][FIFO_W-2];
            assign egr_eof[ep]      = fifo_rd_data[ep][FIFO_W-1];
        end
    endgenerate

endmodule
