//============================================================================
// Storm Control Module - 风暴控制
// 功能: Broadcast/Multicast/Unknown-unicast storm suppression
// 算法: Token bucket rate limiting per port per traffic type
//============================================================================
`timescale 1ns/1ps

module storm_control
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 配置接口
    input  storm_ctrl_cfg_t           cfg [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0],
    
    // 数据包输入
    input  logic [NUM_PORTS-1:0]      pkt_valid,
    input  logic [NUM_PORTS-1:0]      pkt_broadcast,
    input  logic [NUM_PORTS-1:0]      pkt_multicast,
    input  logic [NUM_PORTS-1:0]      pkt_unknown_uc,
    input  logic [PKT_LEN_WIDTH-1:0]  pkt_len [NUM_PORTS-1:0],
    
    // 控制输出
    output logic [NUM_PORTS-1:0]      pkt_drop,
    
    // 统计
    output logic [31:0]               stat_broadcast_drop [NUM_PORTS-1:0],
    output logic [31:0]               stat_multicast_drop [NUM_PORTS-1:0],
    output logic [31:0]               stat_unknown_uc_drop [NUM_PORTS-1:0]
);

    //------------------------------------------------------------------------
    // Token bucket per port per type
    //------------------------------------------------------------------------
    typedef struct packed {
        logic [31:0] tokens;        // Current token count (bytes)
        logic [31:0] last_update;   // Last update timestamp (cycles)
    } token_bucket_t;
    
    token_bucket_t buckets [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0];
    
    // Timestamp counter
    logic [31:0] timestamp;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timestamp <= '0;
        end else begin
            timestamp <= timestamp + 1;
        end
    end
    
    //------------------------------------------------------------------------
    // Token bucket update and packet decision
    //------------------------------------------------------------------------
    genvar p, t;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_ports
            for (t = 0; t < STORM_CTRL_TYPES; t++) begin : gen_types
                
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        buckets[p][t].tokens <= '0;
                        buckets[p][t].last_update <= '0;
                        stat_broadcast_drop[p] <= '0;
                        stat_multicast_drop[p] <= '0;
                        stat_unknown_uc_drop[p] <= '0;
                    end else begin
                        // Token replenishment
                        if (cfg[p][t].enabled) begin
                            automatic logic [31:0] elapsed = timestamp - buckets[p][t].last_update;
                            automatic logic [63:0] tokens_to_add = (elapsed * cfg[p][t].pir) / (1000 * 1000 * 1000 / CLK_PERIOD);
                            
                            if (elapsed > 0) begin
                                buckets[p][t].last_update <= timestamp;
                                
                                // Add tokens but don't exceed CBS
                                if (buckets[p][t].tokens + tokens_to_add[31:0] > cfg[p][t].cbs) begin
                                    buckets[p][t].tokens <= cfg[p][t].cbs;
                                end else begin
                                    buckets[p][t].tokens <= buckets[p][t].tokens + tokens_to_add[31:0];
                                end
                            end
                        end else begin
                            buckets[p][t].tokens <= cfg[p][t].cbs;  // Full bucket when disabled
                        end
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // Packet drop decision
    //------------------------------------------------------------------------
    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            pkt_drop[p] = 1'b0;
            
            if (pkt_valid[p]) begin
                // Broadcast storm control
                if (pkt_broadcast[p] && cfg[p][0].enabled) begin
                    if (buckets[p][0].tokens < pkt_len[p]) begin
                        pkt_drop[p] = 1'b1;
                    end
                end
                
                // Multicast storm control
                if (pkt_multicast[p] && cfg[p][1].enabled) begin
                    if (buckets[p][1].tokens < pkt_len[p]) begin
                        pkt_drop[p] = 1'b1;
                    end
                end
                
                // Unknown unicast storm control
                if (pkt_unknown_uc[p] && cfg[p][2].enabled) begin
                    if (buckets[p][2].tokens < pkt_len[p]) begin
                        pkt_drop[p] = 1'b1;
                    end
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // Token consumption and statistics update
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_consume
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    // Reset handled above
                end else begin
                    if (pkt_valid[p] && !pkt_drop[p]) begin
                        // Consume tokens for passed packet
                        if (pkt_broadcast[p] && cfg[p][0].enabled) begin
                            if (buckets[p][0].tokens >= pkt_len[p]) begin
                                buckets[p][0].tokens <= buckets[p][0].tokens - pkt_len[p];
                            end
                        end
                        
                        if (pkt_multicast[p] && cfg[p][1].enabled) begin
                            if (buckets[p][1].tokens >= pkt_len[p]) begin
                                buckets[p][1].tokens <= buckets[p][1].tokens - pkt_len[p];
                            end
                        end
                        
                        if (pkt_unknown_uc[p] && cfg[p][2].enabled) begin
                            if (buckets[p][2].tokens >= pkt_len[p]) begin
                                buckets[p][2].tokens <= buckets[p][2].tokens - pkt_len[p];
                            end
                        end
                    end
                    
                    // Update drop statistics
                    if (pkt_valid[p] && pkt_drop[p]) begin
                        if (pkt_broadcast[p]) begin
                            stat_broadcast_drop[p] <= stat_broadcast_drop[p] + 1;
                        end
                        if (pkt_multicast[p]) begin
                            stat_multicast_drop[p] <= stat_multicast_drop[p] + 1;
                        end
                        if (pkt_unknown_uc[p]) begin
                            stat_unknown_uc_drop[p] <= stat_unknown_uc_drop[p] + 1;
                        end
                    end
                end
            end
        end
    endgenerate

endmodule
