//============================================================================
// ACL Engine - Access Control List引擎
// 功能: TCAM-based L2 header filtering (SMAC/DMAC/VLAN/EtherType)
//============================================================================
`timescale 1ns/1ps

module acl_engine
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // ACL查找请求
    input  acl_lookup_req_t           lookup_req,
    output acl_lookup_resp_t          lookup_resp,
    
    // ACL规则配置接口
    input  logic                      cfg_wr_en,
    input  logic [ACL_TABLE_WIDTH-1:0] cfg_rule_idx,
    input  acl_rule_t                 cfg_rule_data,
    
    // 统计
    output logic [31:0]               stat_acl_lookup,
    output logic [31:0]               stat_acl_hit,
    output logic [31:0]               stat_acl_deny
);

    //------------------------------------------------------------------------
    // ACL规则表
    //------------------------------------------------------------------------
    acl_rule_t acl_rules [ACL_TABLE_SIZE-1:0];
    
    //------------------------------------------------------------------------
    // 规则配置
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ACL_TABLE_SIZE; i++) begin
                acl_rules[i] <= '0;
            end
        end else begin
            if (cfg_wr_en) begin
                acl_rules[cfg_rule_idx] <= cfg_rule_data;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // TCAM匹配逻辑 (并行匹配)
    //------------------------------------------------------------------------
    // Stage 1: 计算每条规则的匹配结果
    logic [ACL_TABLE_SIZE-1:0] rule_match;
    
    // 预计算匹配信号
    logic [ACL_TABLE_SIZE-1:0] smac_match;
    logic [ACL_TABLE_SIZE-1:0] dmac_match;
    logic [ACL_TABLE_SIZE-1:0] vid_match;
    logic [ACL_TABLE_SIZE-1:0] etype_match;
    logic [ACL_TABLE_SIZE-1:0] sport_match;
    
    genvar gi;
    generate
        for (gi = 0; gi < ACL_TABLE_SIZE; gi++) begin : gen_match
            assign smac_match[gi] = ((lookup_req.smac & acl_rules[gi].smac_mask) == 
                                    (acl_rules[gi].smac & acl_rules[gi].smac_mask));
            assign dmac_match[gi] = ((lookup_req.dmac & acl_rules[gi].dmac_mask) == 
                                    (acl_rules[gi].dmac & acl_rules[gi].dmac_mask));
            assign vid_match[gi] = ((lookup_req.vid & acl_rules[gi].vid_mask) == 
                                   (acl_rules[gi].vid & acl_rules[gi].vid_mask));
            assign etype_match[gi] = ((lookup_req.ethertype & acl_rules[gi].ethertype_mask) == 
                                     (acl_rules[gi].ethertype & acl_rules[gi].ethertype_mask));
            assign sport_match[gi] = ((lookup_req.src_port & acl_rules[gi].src_port_mask) == 
                                     (acl_rules[gi].src_port & acl_rules[gi].src_port_mask));
            assign rule_match[gi] = acl_rules[gi].valid && smac_match[gi] && dmac_match[gi] && 
                                   vid_match[gi] && etype_match[gi] && sport_match[gi];
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 优先级编码器 (选择最高优先级匹配规则)
    // 规则索引越小优先级越高
    //------------------------------------------------------------------------
    logic hit_found;
    logic [ACL_TABLE_WIDTH-1:0] hit_idx;
    
    always_comb begin
        hit_found = 1'b0;
        hit_idx = '0;
        
        for (int i = 0; i < ACL_TABLE_SIZE; i++) begin
            if (rule_match[i] && !hit_found) begin
                hit_found = 1'b1;
                hit_idx = i[ACL_TABLE_WIDTH-1:0];
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 查找结果输出 (流水线寄存)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_resp <= '0;
        end else begin
            lookup_resp.valid <= lookup_req.valid;
            lookup_resp.hit <= lookup_req.valid && hit_found;
            
            if (hit_found) begin
                lookup_resp.action <= acl_rules[hit_idx].action;
                lookup_resp.mirror_port <= acl_rules[hit_idx].mirror_port;
                lookup_resp.remap_queue <= acl_rules[hit_idx].remap_queue;
            end else begin
                // 默认动作: PERMIT
                lookup_resp.action <= ACL_PERMIT;
                lookup_resp.mirror_port <= '0;
                lookup_resp.remap_queue <= '0;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 统计计数器
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_acl_lookup <= '0;
            stat_acl_hit <= '0;
            stat_acl_deny <= '0;
        end else begin
            if (lookup_req.valid) begin
                stat_acl_lookup <= stat_acl_lookup + 1;
                
                if (hit_found) begin
                    stat_acl_hit <= stat_acl_hit + 1;
                    
                    if (acl_rules[hit_idx].action == ACL_DENY) begin
                        stat_acl_deny <= stat_acl_deny + 1;
                    end
                end
            end
        end
    end

endmodule : acl_engine
