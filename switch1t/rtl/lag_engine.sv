//============================================================================
// LAG Engine - Link Aggregation (Trunk) Engine
// 功能: 端口聚合，支持最多8个LAG组，每组最多8个成员端口
//============================================================================
`timescale 1ns/1ps

module lag_engine
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 查找接口 (Ingress)
    input  logic                      lookup_req,
    input  logic [PORT_WIDTH-1:0]     lookup_port,
    output logic                      lookup_valid,
    output logic                      is_lag_port,
    output logic [2:0]                lag_id,
    
    // 分发接口 (Egress) - 选择LAG组内端口
    input  logic                      distribute_req,
    input  logic [2:0]                dist_lag_id,
    input  logic [47:0]               dist_smac,
    input  logic [47:0]               dist_dmac,
    input  logic [VLAN_ID_WIDTH-1:0]  dist_vid,
    output logic                      distribute_valid,
    output logic [PORT_WIDTH-1:0]     selected_port,
    
    // 配置接口
    input  logic                      cfg_wr_en,
    input  logic [2:0]                cfg_lag_id,
    input  logic [NUM_PORTS-1:0]      cfg_member_mask,    // 成员端口位图
    input  logic                      cfg_enabled,
    input  logic [1:0]                cfg_hash_mode,      // 0=SMAC, 1=DMAC, 2=SMAC+DMAC, 3=SMAC+DMAC+VID
    
    // 端口状态输入 (链路状态)
    input  logic [NUM_PORTS-1:0]      port_link_up,
    
    // 统计
    output logic [31:0]               stat_lag_rx [7:0],
    output logic [31:0]               stat_lag_tx [7:0]
);

    //------------------------------------------------------------------------
    // LAG组配置
    //------------------------------------------------------------------------
    typedef struct packed {
        logic                     enabled;
        logic [NUM_PORTS-1:0]     member_mask;       // 成员端口位图
        logic [NUM_PORTS-1:0]     active_mask;       // 活跃端口位图 (link_up)
        logic [3:0]               member_count;      // 成员数量
        logic [3:0]               active_count;      // 活跃成员数量
        logic [1:0]               hash_mode;         // Hash模式
    } lag_config_t;
    
    lag_config_t lag_config [7:0];
    
    // 端口到LAG映射表 (加速反向查找)
    logic [2:0] port_to_lag [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] port_in_lag;
    
    //------------------------------------------------------------------------
    // 配置写入
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) begin
                lag_config[i].enabled <= 1'b0;
                lag_config[i].member_mask <= '0;
                lag_config[i].active_mask <= '0;
                lag_config[i].member_count <= '0;
                lag_config[i].active_count <= '0;
                lag_config[i].hash_mode <= 2'd2;  // 默认SMAC+DMAC
            end
            for (int p = 0; p < NUM_PORTS; p++) begin
                port_to_lag[p] <= '0;
                port_in_lag[p] <= 1'b0;
            end
        end else begin
            if (cfg_wr_en) begin
                lag_config[cfg_lag_id].enabled <= cfg_enabled;
                lag_config[cfg_lag_id].member_mask <= cfg_member_mask;
                lag_config[cfg_lag_id].hash_mode <= cfg_hash_mode;
                
                // 更新成员计数
                begin
                    int cnt = 0;
                    for (int p = 0; p < NUM_PORTS; p++) begin
                        if (cfg_member_mask[p]) cnt++;
                    end
                    lag_config[cfg_lag_id].member_count <= cnt[3:0];
                end
                
                // 更新反向映射
                for (int p = 0; p < NUM_PORTS; p++) begin
                    if (cfg_member_mask[p]) begin
                        port_to_lag[p] <= cfg_lag_id;
                        port_in_lag[p] <= 1'b1;
                    end
                end
            end
            
            // 更新活跃端口掩码 (基于链路状态)
            for (int i = 0; i < 8; i++) begin
                lag_config[i].active_mask <= lag_config[i].member_mask & port_link_up;
                
                // 更新活跃成员计数
                begin
                    int acnt = 0;
                    for (int p = 0; p < NUM_PORTS; p++) begin
                        if (lag_config[i].member_mask[p] && port_link_up[p]) acnt++;
                    end
                    lag_config[i].active_count <= acnt[3:0];
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // Ingress查找: 端口是否属于LAG组
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_valid <= 1'b0;
            is_lag_port <= 1'b0;
            lag_id <= '0;
        end else begin
            lookup_valid <= lookup_req;
            
            if (lookup_req) begin
                is_lag_port <= port_in_lag[lookup_port];
                lag_id <= port_to_lag[lookup_port];
            end
        end
    end
    
    //------------------------------------------------------------------------
    // Hash函数 (用于负载均衡)
    //------------------------------------------------------------------------
    function automatic logic [15:0] compute_hash(
        input logic [47:0] smac,
        input logic [47:0] dmac,
        input logic [VLAN_ID_WIDTH-1:0] vid,
        input logic [1:0] mode
    );
        logic [15:0] hash_val;
        
        case (mode)
            2'd0: begin // SMAC only
                hash_val = smac[15:0] ^ smac[31:16] ^ smac[47:32];
            end
            2'd1: begin // DMAC only
                hash_val = dmac[15:0] ^ dmac[31:16] ^ dmac[47:32];
            end
            2'd2: begin // SMAC + DMAC
                hash_val = smac[15:0] ^ smac[31:16] ^ smac[47:32] ^
                          dmac[15:0] ^ dmac[31:16] ^ dmac[47:32];
            end
            2'd3: begin // SMAC + DMAC + VID
                hash_val = smac[15:0] ^ smac[31:16] ^ smac[47:32] ^
                          dmac[15:0] ^ dmac[31:16] ^ dmac[47:32] ^
                          {4'b0, vid};
            end
        endcase
        
        return hash_val;
    endfunction
    
    //------------------------------------------------------------------------
    // Egress分发: 根据Hash选择LAG组内的活跃端口
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            distribute_valid <= 1'b0;
            selected_port <= '0;
        end else begin
            distribute_valid <= 1'b0;
            
            if (distribute_req) begin
                distribute_valid <= 1'b1;
                
                // 检查LAG组是否有活跃成员
                if (lag_config[dist_lag_id].enabled && 
                    lag_config[dist_lag_id].active_count > 0) begin
                    
                    // 计算Hash
                    automatic logic [15:0] hash_val = compute_hash(
                        dist_smac, dist_dmac, dist_vid, 
                        lag_config[dist_lag_id].hash_mode
                    );
                    
                    // Hash模活跃成员数
                    automatic logic [3:0] member_idx = hash_val % lag_config[dist_lag_id].active_count;
                    
                    // 查找第member_idx个活跃端口
                    automatic int idx_cnt = 0;
                    for (int p = 0; p < NUM_PORTS; p++) begin
                        if (lag_config[dist_lag_id].active_mask[p]) begin
                            if (idx_cnt == member_idx) begin
                                selected_port <= p[PORT_WIDTH-1:0];
                                break;
                            end
                            idx_cnt++;
                        end
                    end
                    
                end else begin
                    // LAG组无活跃成员，返回无效端口
                    selected_port <= '1;  // 全1表示无效
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 统计计数器
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) begin
                stat_lag_rx[i] <= '0;
                stat_lag_tx[i] <= '0;
            end
        end else begin
            // Ingress统计
            if (lookup_valid && is_lag_port) begin
                stat_lag_rx[lag_id] <= stat_lag_rx[lag_id] + 1;
            end
            
            // Egress统计
            if (distribute_valid && selected_port != '1) begin
                stat_lag_tx[dist_lag_id] <= stat_lag_tx[dist_lag_id] + 1;
            end
        end
    end

endmodule : lag_engine
