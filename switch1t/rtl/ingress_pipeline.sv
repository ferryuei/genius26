//============================================================================
// Ingress Pipeline - 入向流水线
// 功能: 报文解析、ACL检查、QoS分类、MAC学习触发
//============================================================================
`timescale 1ns/1ps

module ingress_pipeline
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 端口输入接口 (来自MAC层)
    input  logic [NUM_PORTS-1:0]      port_rx_valid,
    input  logic [NUM_PORTS-1:0]      port_rx_sop,
    input  logic [NUM_PORTS-1:0]      port_rx_eop,
    input  logic [63:0]               port_rx_data [NUM_PORTS-1:0],
    input  logic [2:0]                port_rx_empty [NUM_PORTS-1:0],  // 无效字节数
    output logic [NUM_PORTS-1:0]      port_rx_ready,
    
    // 端口配置
    input  port_config_t              port_config [NUM_PORTS-1:0],
    
    // Storm Control配置 (per-port, per-type: B/M/U)
    input  storm_ctrl_cfg_t           storm_ctrl_cfg [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0],
    
    // 到报文缓冲区
    output logic                      buf_wr_valid,
    output logic                      buf_wr_sop,
    output logic                      buf_wr_eop,
    output logic [CELL_SIZE_BITS-1:0] buf_wr_data,
    output logic [7:0]                buf_wr_len,
    output logic [PORT_WIDTH-1:0]     buf_wr_port,
    input  logic                      buf_wr_ready,
    input  logic [DESC_ID_WIDTH-1:0]  buf_desc_id,
    input  logic                      buf_desc_valid,
    
    // 到Lookup引擎
    output ingress_lookup_req_t       lookup_req,
    
    // MAC学习请求
    output logic                      learn_req,
    output logic [47:0]               learn_mac,
    output logic [VLAN_ID_WIDTH-1:0]  learn_vid,
    output logic [PORT_WIDTH-1:0]     learn_port,
    input  logic                      learn_done,
    
    // 统计
    output logic [31:0]               stat_rx_packets [NUM_PORTS-1:0],
    output logic [31:0]               stat_rx_bytes [NUM_PORTS-1:0],
    output logic [31:0]               stat_rx_drops [NUM_PORTS-1:0]
);

    //------------------------------------------------------------------------
    // 端口仲裁器 - 48端口分6组汇聚
    // 修复: 组内仲裁改为组合逻辑，减少延迟
    //------------------------------------------------------------------------
    localparam int PORTS_PER_GROUP = 8;
    localparam int NUM_GROUPS = NUM_PORTS / PORTS_PER_GROUP;
    
    // 组内仲裁 - 组合逻辑
    logic [2:0] group_grant [NUM_GROUPS-1:0];
    logic [NUM_GROUPS-1:0] group_valid;
    logic [2:0] rr_ptr [NUM_GROUPS-1:0];
    
    // 生成组内轮询仲裁器
    genvar g;
    generate
        for (g = 0; g < NUM_GROUPS; g++) begin : gen_group_arb
            logic [PORTS_PER_GROUP-1:0] group_req;
            
            // 收集组内请求
            always_comb begin
                for (int p = 0; p < PORTS_PER_GROUP; p++) begin
                    group_req[p] = port_rx_valid[g * PORTS_PER_GROUP + p] &&
                                   port_config[g * PORTS_PER_GROUP + p].enabled;
                end
            end
            
            // 组合逻辑仲裁
            always_comb begin
                group_grant[g] = '0;
                group_valid[g] = 1'b0;
                
                for (int i = 0; i < PORTS_PER_GROUP; i++) begin
                    automatic int idx = (rr_ptr[g] + i) % PORTS_PER_GROUP;
                    if (group_req[idx]) begin
                        group_grant[g] = idx[2:0];
                        group_valid[g] = 1'b1;
                        break;
                    end
                end
            end
            
            // 轮询指针更新 (仅在EOP时更新)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rr_ptr[g] <= '0;
                end else begin
                    if (group_valid[g] && port_rx_eop[g * PORTS_PER_GROUP + group_grant[g]]) begin
                        rr_ptr[g] <= (group_grant[g] + 1) % PORTS_PER_GROUP;
                    end
                end
            end
        end
    endgenerate
    
    // 组间仲裁 - 组合逻辑
    logic [2:0] selected_group;
    logic [PORT_WIDTH-1:0] selected_port;
    logic selected_valid;
    logic [2:0] group_rr_ptr;
    
    always_comb begin
        selected_group = '0;
        selected_port = '0;
        selected_valid = 1'b0;
        
        for (int i = 0; i < NUM_GROUPS; i++) begin
            automatic int idx = (group_rr_ptr + i) % NUM_GROUPS;
            if (group_valid[idx]) begin
                selected_group = idx[2:0];
                selected_port = idx * PORTS_PER_GROUP + group_grant[idx];
                selected_valid = 1'b1;
                break;
            end
        end
    end
    
    // 组间轮询指针更新
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_rr_ptr <= '0;
        end else begin
            if (selected_valid && port_rx_eop[selected_port]) begin
                group_rr_ptr <= (selected_group + 1) % NUM_GROUPS;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 解析流水线
    //------------------------------------------------------------------------
    // Stage 1: 提取L2头部
    typedef enum logic [2:0] {
        PARSE_IDLE,
        PARSE_L2_HDR,
        PARSE_VLAN,
        PARSE_PAYLOAD,
        PARSE_DONE
    } parse_state_e;
    
    parse_state_e parse_state;
    
    parsed_hdr_t parsed_hdr;
    logic [PORT_WIDTH-1:0] cur_src_port;
    logic [PKT_LEN_WIDTH-1:0] cur_pkt_len;
    logic cur_pkt_valid;
    logic cur_pkt_sop;
    logic cur_pkt_eop;
    logic [63:0] cur_pkt_data;
    
    // STP/BPDU检测
    logic is_bpdu;
    logic stp_drop;
    logic stp_learn_only;
    
    // Jumbo Frame / MTU检测
    logic mtu_exceeded;
    logic jumbo_drop;
    
    // BPDU目标MAC地址
    localparam logic [47:0] BPDU_DMAC = 48'h0180C2000000;
    
    // Cell聚合缓冲
    logic [CELL_SIZE_BITS-1:0] cell_buffer;
    logic [7:0] cell_offset;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parse_state <= PARSE_IDLE;
            parsed_hdr <= '0;
            cur_src_port <= '0;
            cur_pkt_len <= '0;
            cell_buffer <= '0;
            cell_offset <= '0;
            jumbo_drop <= 1'b0;
        end else begin
            case (parse_state)
                PARSE_IDLE: begin
                    jumbo_drop <= 1'b0;
                    if (selected_valid && port_rx_sop[selected_port]) begin
                        cur_src_port <= selected_port;
                        parse_state <= PARSE_L2_HDR;
                        cell_offset <= '0;
                        cur_pkt_len <= '0;
                    end
                end
                
                PARSE_L2_HDR: begin
                    // 假设第一个cycle收到DMAC[47:0] + SMAC[47:32]
                    if (selected_valid) begin
                        cur_pkt_data <= port_rx_data[cur_src_port];
                        // 提取DMAC (假设从byte 0开始)
                        parsed_hdr.dmac <= port_rx_data[cur_src_port][47:0];
                        parse_state <= PARSE_VLAN;
                    end
                end
                
                PARSE_VLAN: begin
                    if (selected_valid) begin
                        // 提取SMAC和检查VLAN tag
                        parsed_hdr.smac <= {port_rx_data[cur_src_port][47:0], parsed_hdr.dmac[47:32]};
                        
                        // 检查是否有VLAN tag (0x8100)
                        if (port_rx_data[cur_src_port][63:48] == 16'h8100) begin
                            parsed_hdr.has_vlan <= 1'b1;
                            parsed_hdr.pcp <= port_rx_data[cur_src_port][47:45];
                            parsed_hdr.dei <= port_rx_data[cur_src_port][44];
                            parsed_hdr.vid <= port_rx_data[cur_src_port][43:32];
                        end else begin
                            parsed_hdr.has_vlan <= 1'b0;
                            parsed_hdr.vid <= port_config[cur_src_port].default_vid;
                            parsed_hdr.pcp <= port_config[cur_src_port].default_pcp;
                        end
                        
                        parse_state <= PARSE_PAYLOAD;
                    end
                end
                
                PARSE_PAYLOAD: begin
                    if (selected_valid) begin
                        cur_pkt_len <= cur_pkt_len + 8;  // 每cycle 8字节
                        
                        // Jumbo Frame MTU检查
                        if ((cur_pkt_len + 8) > port_config[cur_src_port].mtu) begin
                            jumbo_drop <= 1'b1;
                        end
                        
                        // 聚合到Cell缓冲
                        cell_buffer[cell_offset*8 +: 64] <= port_rx_data[cur_src_port];
                        cell_offset <= cell_offset + 8;
                        
                        if (port_rx_eop[cur_src_port]) begin
                            parse_state <= PARSE_DONE;
                            parsed_hdr.pkt_len <= cur_pkt_len + 8 - {11'b0, port_rx_empty[cur_src_port]};
                        end
                    end
                end
                
                PARSE_DONE: begin
                    parse_state <= PARSE_IDLE;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 输出到缓冲区
    //------------------------------------------------------------------------
    // 修复: buf_wr_sop必须与buf_wr_valid同时有效
    logic first_cell_of_pkt;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_cell_of_pkt <= 1'b1;
        end else begin
            if (parse_state == PARSE_IDLE) begin
                first_cell_of_pkt <= 1'b1;
            end else if (buf_wr_valid && buf_wr_ready) begin
                first_cell_of_pkt <= 1'b0;
            end
        end
    end
    
    assign buf_wr_valid = (parse_state == PARSE_PAYLOAD || parse_state == PARSE_DONE) && 
                          selected_valid && (cell_offset >= CELL_SIZE || parse_state == PARSE_DONE);
    assign buf_wr_sop = buf_wr_valid && first_cell_of_pkt;
    assign buf_wr_eop = (parse_state == PARSE_DONE) && buf_wr_valid;
    assign buf_wr_data = cell_buffer;
    assign buf_wr_len = (parse_state == PARSE_DONE) ? cell_offset[7:0] : 8'd128;
    assign buf_wr_port = cur_src_port;
    
    // MTU检查组合逻辑
    assign mtu_exceeded = (parsed_hdr.pkt_len > port_config[cur_src_port].mtu);
    
    //------------------------------------------------------------------------
    // Storm Control - Token Bucket Rate Limiting
    //------------------------------------------------------------------------
    // 流量类型检测
    traffic_type_e cur_traffic_type;
    logic storm_drop;
    
    // Token buckets: [port][type] where type: 0=Broadcast, 1=Multicast, 2=Unknown
    logic [31:0] storm_tokens [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0];
    logic [31:0] stat_storm_drops [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0];
    
    // 流量类型检测 - 基于DMAC
    always_comb begin
        if (parsed_hdr.dmac == 48'hFFFFFFFFFFFF) begin
            cur_traffic_type = TRAFFIC_BROADCAST;
        end else if (parsed_hdr.dmac[40]) begin
            // 组播位 (bit 40 = LSB of first byte)
            cur_traffic_type = TRAFFIC_MULTICAST;
        end else begin
            cur_traffic_type = TRAFFIC_UNICAST;
        end
    end
    
    // Token补充计数器 (每1024周期补充一次, ~2us at 500MHz)
    logic [9:0] token_refill_counter;
    logic token_refill_tick;
    
    // Storm packet type (pre-computed for use in sequential logic)
    logic [1:0] storm_pkt_type;
    assign storm_pkt_type = (cur_traffic_type == TRAFFIC_BROADCAST) ? 2'd0 :
                           (cur_traffic_type == TRAFFIC_MULTICAST) ? 2'd1 : 2'd2;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            token_refill_counter <= '0;
            token_refill_tick <= 1'b0;
        end else begin
            token_refill_counter <= token_refill_counter + 1;
            token_refill_tick <= (token_refill_counter == '1);
        end
    end
    
    // Storm Control Token Bucket Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                for (int t = 0; t < STORM_CTRL_TYPES; t++) begin
                    storm_tokens[p][t] <= DEFAULT_CBS;
                    stat_storm_drops[p][t] <= '0;
                end
            end
        end else begin
            // Token补充 (per-port, per-type)
            if (token_refill_tick) begin
                for (int p = 0; p < NUM_PORTS; p++) begin
                    for (int t = 0; t < STORM_CTRL_TYPES; t++) begin
                        if (storm_ctrl_cfg[p][t].enabled) begin
                            // 补充tokens, 不超过CBS
                            if (storm_tokens[p][t] < storm_ctrl_cfg[p][t].cbs) begin
                                // PIR是bytes/sec, 每2us补充 PIR/500000
                                storm_tokens[p][t] <= storm_tokens[p][t] + (storm_ctrl_cfg[p][t].pir >> 19);
                                if (storm_tokens[p][t] + (storm_ctrl_cfg[p][t].pir >> 19) > storm_ctrl_cfg[p][t].cbs) begin
                                    storm_tokens[p][t] <= storm_ctrl_cfg[p][t].cbs;
                                end
                            end
                        end
                    end
                end
            end
            
            // Token消耗 (当报文完成解析时)
            if (parse_state == PARSE_DONE && !stp_drop && !jumbo_drop) begin
                if (storm_ctrl_cfg[cur_src_port][storm_pkt_type].enabled) begin
                    if (storm_tokens[cur_src_port][storm_pkt_type] >= parsed_hdr.pkt_len) begin
                        storm_tokens[cur_src_port][storm_pkt_type] <= storm_tokens[cur_src_port][storm_pkt_type] - parsed_hdr.pkt_len;
                    end else begin
                        // Token不足，统计丢包
                        stat_storm_drops[cur_src_port][storm_pkt_type] <= stat_storm_drops[cur_src_port][storm_pkt_type] + 1;
                    end
                end
            end
        end
    end
    
    // Storm drop决策
    always_comb begin
        storm_drop = 1'b0;
        if (parse_state == PARSE_DONE) begin
            if (storm_ctrl_cfg[cur_src_port][storm_pkt_type].enabled) begin
                if (storm_tokens[cur_src_port][storm_pkt_type] < parsed_hdr.pkt_len) begin
                    storm_drop = 1'b1;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // STP状态和BPDU检测
    //------------------------------------------------------------------------
    // BPDU检测 (目标MAC = 01:80:C2:00:00:00)
    assign is_bpdu = (parsed_hdr.dmac == BPDU_DMAC);
    
    // STP状态决策
    always_comb begin
        stp_drop = 1'b0;
        stp_learn_only = 1'b0;
        
        case (port_config[cur_src_port].state)
            PORT_DISABLED: begin
                // 禁用端口丢弃所有帧
                stp_drop = 1'b1;
            end
            PORT_BLOCKING: begin
                // 阻塞状态只允许BPDU通过
                stp_drop = !is_bpdu;
            end
            PORT_LEARNING: begin
                // 学习状态允许MAC学习但不转发
                stp_learn_only = 1'b1;
            end
            PORT_FORWARDING: begin
                // 转发状态正常处理
                stp_drop = 1'b0;
                stp_learn_only = 1'b0;
            end
        endcase
    end
    
    //------------------------------------------------------------------------
    // 输出到Lookup
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_req <= '0;
        end else begin
            lookup_req.valid <= 1'b0;
            
            // STP检查、MTU检查、Storm Control检查: 全部通过才转发
            if (parse_state == PARSE_DONE && buf_desc_valid && 
                !stp_drop && !stp_learn_only && !jumbo_drop && !storm_drop) begin
                lookup_req.valid <= 1'b1;
                lookup_req.dmac <= parsed_hdr.dmac;
                lookup_req.smac <= parsed_hdr.smac;
                lookup_req.vid <= parsed_hdr.vid;
                lookup_req.src_port <= cur_src_port;
                lookup_req.queue_id <= parsed_hdr.pcp;
                lookup_req.desc_id <= buf_desc_id;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // MAC学习触发
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            learn_req <= 1'b0;
            learn_mac <= '0;
            learn_vid <= '0;
            learn_port <= '0;
        end else begin
            learn_req <= 1'b0;
            
            // 在LEARNING和FORWARDING状态都允许MAC学习
            if (parse_state == PARSE_DONE && !stp_drop &&
                (port_config[cur_src_port].state == PORT_FORWARDING ||
                 port_config[cur_src_port].state == PORT_LEARNING)) begin
                // 检查SMAC是否为组播地址
                if (!parsed_hdr.smac[40]) begin  // bit 40是组播位
                    learn_req <= 1'b1;
                    learn_mac <= parsed_hdr.smac;
                    learn_vid <= parsed_hdr.vid;
                    learn_port <= cur_src_port;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 端口ready信号
    //------------------------------------------------------------------------
    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            port_rx_ready[p] = buf_wr_ready && (cur_src_port == p[PORT_WIDTH-1:0] || parse_state == PARSE_IDLE);
        end
    end
    
    //------------------------------------------------------------------------
    // 统计计数器
    //------------------------------------------------------------------------
    // STP丢包计数
    logic [31:0] stat_stp_drops [NUM_PORTS-1:0];
    // Jumbo/MTU丢包计数
    logic [31:0] stat_mtu_drops [NUM_PORTS-1:0];
    
    generate
        for (g = 0; g < NUM_PORTS; g++) begin : gen_stats
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    stat_rx_packets[g] <= '0;
                    stat_rx_bytes[g] <= '0;
                    stat_rx_drops[g] <= '0;
                    stat_stp_drops[g] <= '0;
                    stat_mtu_drops[g] <= '0;
                end else begin
                    if (port_rx_valid[g] && port_rx_eop[g] && port_rx_ready[g]) begin
                        stat_rx_packets[g] <= stat_rx_packets[g] + 1;
                    end
                    if (port_rx_valid[g] && port_rx_ready[g]) begin
                        stat_rx_bytes[g] <= stat_rx_bytes[g] + 8;
                    end
                    if (port_rx_valid[g] && !port_rx_ready[g]) begin
                        stat_rx_drops[g] <= stat_rx_drops[g] + 1;
                    end
                    // STP丢包统计
                    if (parse_state == PARSE_DONE && cur_src_port == g[PORT_WIDTH-1:0] && stp_drop) begin
                        stat_stp_drops[g] <= stat_stp_drops[g] + 1;
                        stat_rx_drops[g] <= stat_rx_drops[g] + 1;
                    end
                    // MTU/Jumbo丢包统计
                    if (parse_state == PARSE_DONE && cur_src_port == g[PORT_WIDTH-1:0] && jumbo_drop) begin
                        stat_mtu_drops[g] <= stat_mtu_drops[g] + 1;
                        stat_rx_drops[g] <= stat_rx_drops[g] + 1;
                    end
                    // Storm Control丢包统计
                    if (parse_state == PARSE_DONE && cur_src_port == g[PORT_WIDTH-1:0] && storm_drop) begin
                        stat_rx_drops[g] <= stat_rx_drops[g] + 1;
                    end
                end
            end
        end
    endgenerate

endmodule : ingress_pipeline
