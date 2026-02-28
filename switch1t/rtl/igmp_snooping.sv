//============================================================================
// IGMP Snooping Engine - IGMP窥探引擎
// 功能: 监听IGMP报告/离开消息，维护组播组成员表，优化组播转发
//============================================================================
`timescale 1ns/1ps

module igmp_snooping
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 报文解析输入 (来自Ingress Pipeline)
    input  logic                      pkt_valid,
    input  logic [47:0]               pkt_dmac,
    input  logic [47:0]               pkt_smac,
    input  logic [VLAN_ID_WIDTH-1:0]  pkt_vid,
    input  logic [15:0]               pkt_ethertype,
    input  logic [7:0]                pkt_ip_proto,      // IPv4协议号
    input  logic [31:0]               pkt_dst_ip,        // 目的IP地址
    input  logic [7:0]                pkt_igmp_type,     // IGMP类型
    input  logic [31:0]               pkt_igmp_group,    // IGMP组地址
    input  logic [PORT_WIDTH-1:0]     pkt_src_port,
    
    // 组播组查找接口
    input  logic                      lookup_req,
    input  logic [31:0]               lookup_group_ip,   // 组播组IP
    input  logic [VLAN_ID_WIDTH-1:0]  lookup_vid,
    output logic                      lookup_valid,
    output logic                      lookup_hit,
    output logic [NUM_PORTS-1:0]      lookup_port_mask,  // 组成员端口位图
    
    // 配置接口
    input  logic                      cfg_enable,        // 全局使能
    input  logic [NUM_PORTS-1:0]      cfg_router_ports,  // 路由器端口 (总是接收组播)
    input  logic [15:0]               cfg_aging_time,    // 老化时间 (秒)
    
    // 老化触发
    input  logic                      age_tick,          // 每秒触发
    
    // 统计
    output logic [31:0]               stat_igmp_report,
    output logic [31:0]               stat_igmp_leave,
    output logic [31:0]               stat_igmp_query,
    output logic [15:0]               stat_group_count
);

    //------------------------------------------------------------------------
    // 参数
    //------------------------------------------------------------------------
    localparam int IGMP_TABLE_SIZE = 512;          // 支持512个组播组
    localparam int IGMP_TABLE_IDX_WIDTH = 9;
    
    // IGMP消息类型
    localparam logic [7:0] IGMP_QUERY    = 8'h11;  // 0x11
    localparam logic [7:0] IGMP_REPORT_V1 = 8'h12; // 0x12
    localparam logic [7:0] IGMP_REPORT_V2 = 8'h16; // 0x16
    localparam logic [7:0] IGMP_REPORT_V3 = 8'h22; // 0x22
    localparam logic [7:0] IGMP_LEAVE    = 8'h17;  // 0x17
    
    // IPv4协议号
    localparam logic [7:0] IP_PROTO_IGMP = 8'd2;
    
    //------------------------------------------------------------------------
    // 组播组表项
    //------------------------------------------------------------------------
    typedef struct packed {
        logic                     valid;
        logic [31:0]              group_ip;        // 组播组IP地址
        logic [VLAN_ID_WIDTH-1:0] vid;             // VLAN ID
        logic [NUM_PORTS-1:0]     member_ports;    // 成员端口位图
        logic [15:0]              age_timer;       // 老化计数器
    } igmp_entry_t;
    
    igmp_entry_t igmp_table [IGMP_TABLE_SIZE-1:0];
    
    //------------------------------------------------------------------------
    // Hash计算
    //------------------------------------------------------------------------
    function automatic logic [IGMP_TABLE_IDX_WIDTH-1:0] compute_hash(
        input logic [31:0] group_ip,
        input logic [VLAN_ID_WIDTH-1:0] vid
    );
        logic [15:0] hash_val;
        hash_val = group_ip[15:0] ^ group_ip[31:16] ^ {4'b0, vid};
        return hash_val % IGMP_TABLE_SIZE;
    endfunction
    
    //------------------------------------------------------------------------
    // IGMP报文检测与处理
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        PROC_IDLE,
        PROC_CHECK,
        PROC_HASH,
        PROC_SEARCH,
        PROC_UPDATE,
        PROC_DONE
    } proc_state_e;
    
    proc_state_e proc_state;
    
    logic [IGMP_TABLE_IDX_WIDTH-1:0] proc_hash_idx;
    logic [IGMP_TABLE_IDX_WIDTH-1:0] proc_search_idx;
    logic [31:0]                      proc_group_ip;
    logic [VLAN_ID_WIDTH-1:0]         proc_vid;
    logic [PORT_WIDTH-1:0]            proc_src_port;
    logic [7:0]                       proc_igmp_type;
    logic                             proc_found;
    logic [IGMP_TABLE_IDX_WIDTH-1:0] proc_found_idx;
    logic [IGMP_TABLE_IDX_WIDTH-1:0] proc_empty_idx;
    logic                             proc_found_empty;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            proc_state <= PROC_IDLE;
            proc_found <= 1'b0;
            proc_found_empty <= 1'b0;
        end else begin
            case (proc_state)
                PROC_IDLE: begin
                    if (cfg_enable && pkt_valid) begin
                        proc_state <= PROC_CHECK;
                    end
                end
                
                PROC_CHECK: begin
                    // 检查是否为IGMP报文
                    if (pkt_ethertype == 16'h0800 && pkt_ip_proto == IP_PROTO_IGMP) begin
                        // 检查IGMP类型
                        if (pkt_igmp_type == IGMP_REPORT_V1 || 
                            pkt_igmp_type == IGMP_REPORT_V2 ||
                            pkt_igmp_type == IGMP_REPORT_V3 ||
                            pkt_igmp_type == IGMP_LEAVE) begin
                            
                            proc_group_ip <= pkt_igmp_group;
                            proc_vid <= pkt_vid;
                            proc_src_port <= pkt_src_port;
                            proc_igmp_type <= pkt_igmp_type;
                            proc_state <= PROC_HASH;
                        end else begin
                            proc_state <= PROC_IDLE;
                        end
                    end else begin
                        proc_state <= PROC_IDLE;
                    end
                end
                
                PROC_HASH: begin
                    proc_hash_idx <= compute_hash(proc_group_ip, proc_vid);
                    proc_search_idx <= compute_hash(proc_group_ip, proc_vid);
                    proc_state <= PROC_SEARCH;
                    proc_found <= 1'b0;
                    proc_found_empty <= 1'b0;
                end
                
                PROC_SEARCH: begin
                    // 线性探测查找
                    if (igmp_table[proc_search_idx].valid &&
                        igmp_table[proc_search_idx].group_ip == proc_group_ip &&
                        igmp_table[proc_search_idx].vid == proc_vid) begin
                        // 找到匹配条目
                        proc_found <= 1'b1;
                        proc_found_idx <= proc_search_idx;
                        proc_state <= PROC_UPDATE;
                    end else if (!igmp_table[proc_search_idx].valid && !proc_found_empty) begin
                        // 找到空闲条目
                        proc_found_empty <= 1'b1;
                        proc_empty_idx <= proc_search_idx;
                        
                        // 继续搜索是否有匹配
                        if (proc_search_idx == IGMP_TABLE_SIZE - 1) begin
                            proc_search_idx <= 0;
                        end else begin
                            proc_search_idx <= proc_search_idx + 1;
                        end
                        
                        // 最多搜索8个位置
                        if ((proc_search_idx - proc_hash_idx) >= 8) begin
                            proc_state <= PROC_UPDATE;
                        end
                    end else begin
                        // 继续探测
                        if (proc_search_idx == IGMP_TABLE_SIZE - 1) begin
                            proc_search_idx <= 0;
                        end else begin
                            proc_search_idx <= proc_search_idx + 1;
                        end
                        
                        // 最多搜索8个位置
                        if ((proc_search_idx - proc_hash_idx) >= 8) begin
                            proc_state <= PROC_UPDATE;
                        end
                    end
                end
                
                PROC_UPDATE: begin
                    // IGMP Report: 添加端口到组
                    if (proc_igmp_type == IGMP_REPORT_V1 || 
                        proc_igmp_type == IGMP_REPORT_V2 ||
                        proc_igmp_type == IGMP_REPORT_V3) begin
                        
                        if (proc_found) begin
                            // 更新现有条目
                            igmp_table[proc_found_idx].member_ports[proc_src_port] <= 1'b1;
                            igmp_table[proc_found_idx].age_timer <= cfg_aging_time;
                        end else if (proc_found_empty) begin
                            // 创建新条目
                            igmp_table[proc_empty_idx].valid <= 1'b1;
                            igmp_table[proc_empty_idx].group_ip <= proc_group_ip;
                            igmp_table[proc_empty_idx].vid <= proc_vid;
                            igmp_table[proc_empty_idx].member_ports <= (1 << proc_src_port);
                            igmp_table[proc_empty_idx].age_timer <= cfg_aging_time;
                        end
                    end
                    // IGMP Leave: 移除端口
                    else if (proc_igmp_type == IGMP_LEAVE) begin
                        if (proc_found) begin
                            igmp_table[proc_found_idx].member_ports[proc_src_port] <= 1'b0;
                            
                            // 如果没有成员了，删除条目
                            if ((igmp_table[proc_found_idx].member_ports & ~(1 << proc_src_port)) == '0) begin
                                igmp_table[proc_found_idx].valid <= 1'b0;
                            end
                        end
                    end
                    
                    proc_state <= PROC_DONE;
                end
                
                PROC_DONE: begin
                    proc_state <= PROC_IDLE;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 组播组查找
    //------------------------------------------------------------------------
    logic [IGMP_TABLE_IDX_WIDTH-1:0] lookup_hash_idx;
    logic [IGMP_TABLE_IDX_WIDTH-1:0] lookup_search_idx;
    logic [2:0] lookup_probe_cnt;
    
    typedef enum logic [1:0] {
        LOOKUP_IDLE,
        LOOKUP_HASH,
        LOOKUP_SEARCH,
        LOOKUP_DONE
    } lookup_state_e;
    
    lookup_state_e lookup_state;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_state <= LOOKUP_IDLE;
            lookup_valid <= 1'b0;
            lookup_hit <= 1'b0;
            lookup_port_mask <= '0;
        end else begin
            lookup_valid <= 1'b0;
            
            case (lookup_state)
                LOOKUP_IDLE: begin
                    if (lookup_req) begin
                        lookup_state <= LOOKUP_HASH;
                    end
                end
                
                LOOKUP_HASH: begin
                    lookup_hash_idx <= compute_hash(lookup_group_ip, lookup_vid);
                    lookup_search_idx <= compute_hash(lookup_group_ip, lookup_vid);
                    lookup_probe_cnt <= '0;
                    lookup_state <= LOOKUP_SEARCH;
                end
                
                LOOKUP_SEARCH: begin
                    if (igmp_table[lookup_search_idx].valid &&
                        igmp_table[lookup_search_idx].group_ip == lookup_group_ip &&
                        igmp_table[lookup_search_idx].vid == lookup_vid) begin
                        // 找到匹配
                        lookup_hit <= 1'b1;
                        lookup_port_mask <= igmp_table[lookup_search_idx].member_ports | cfg_router_ports;
                        lookup_state <= LOOKUP_DONE;
                    end else if (lookup_probe_cnt >= 7) begin
                        // 未找到
                        lookup_hit <= 1'b0;
                        lookup_port_mask <= cfg_router_ports;  // 仅转发到路由器端口
                        lookup_state <= LOOKUP_DONE;
                    end else begin
                        // 继续探测
                        if (lookup_search_idx == IGMP_TABLE_SIZE - 1) begin
                            lookup_search_idx <= 0;
                        end else begin
                            lookup_search_idx <= lookup_search_idx + 1;
                        end
                        lookup_probe_cnt <= lookup_probe_cnt + 1;
                    end
                end
                
                LOOKUP_DONE: begin
                    lookup_valid <= 1'b1;
                    lookup_state <= LOOKUP_IDLE;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 老化逻辑
    //------------------------------------------------------------------------
    logic [IGMP_TABLE_IDX_WIDTH-1:0] age_scan_idx;
    logic age_scanning;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            age_scan_idx <= '0;
            age_scanning <= 1'b0;
        end else begin
            if (age_tick && !age_scanning) begin
                age_scanning <= 1'b1;
                age_scan_idx <= '0;
            end else if (age_scanning) begin
                // 扫描一个条目
                if (igmp_table[age_scan_idx].valid) begin
                    if (igmp_table[age_scan_idx].age_timer > 0) begin
                        igmp_table[age_scan_idx].age_timer <= 
                            igmp_table[age_scan_idx].age_timer - 1;
                    end else begin
                        // 老化删除
                        igmp_table[age_scan_idx].valid <= 1'b0;
                    end
                end
                
                // 移动到下一个条目
                if (age_scan_idx == IGMP_TABLE_SIZE - 1) begin
                    age_scanning <= 1'b0;
                end else begin
                    age_scan_idx <= age_scan_idx + 1;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 统计计数器
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_igmp_report <= '0;
            stat_igmp_leave <= '0;
            stat_igmp_query <= '0;
        end else begin
            if (proc_state == PROC_DONE) begin
                if (proc_igmp_type == IGMP_REPORT_V1 || 
                    proc_igmp_type == IGMP_REPORT_V2 ||
                    proc_igmp_type == IGMP_REPORT_V3) begin
                    stat_igmp_report <= stat_igmp_report + 1;
                end else if (proc_igmp_type == IGMP_LEAVE) begin
                    stat_igmp_leave <= stat_igmp_leave + 1;
                end
            end
            
            if (pkt_valid && pkt_igmp_type == IGMP_QUERY) begin
                stat_igmp_query <= stat_igmp_query + 1;
            end
        end
    end
    
    // 组计数
    always_comb begin
        stat_group_count = '0;
        for (int i = 0; i < IGMP_TABLE_SIZE; i++) begin
            if (igmp_table[i].valid) begin
                stat_group_count = stat_group_count + 1;
            end
        end
    end

endmodule : igmp_snooping
