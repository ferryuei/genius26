//============================================================================
// RSTP Engine - Rapid Spanning Tree Protocol (IEEE 802.1w/802.1D-2004)
// 功能: 快速生成树协议，防止网络环路，支持快速收敛
//============================================================================
`timescale 1ns/1ps

module rstp_engine
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 端口配置
    input  logic [NUM_PORTS-1:0]      port_enable,
    input  logic [NUM_PORTS-1:0]      port_link_up,
    input  logic [15:0]               port_path_cost [NUM_PORTS-1:0],
    input  logic [7:0]                port_priority [NUM_PORTS-1:0],
    
    // BPDU接收接口
    input  logic [NUM_PORTS-1:0]      bpdu_rx_valid,
    input  logic [63:0]               bpdu_rx_data [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      bpdu_rx_sop,
    input  logic [NUM_PORTS-1:0]      bpdu_rx_eop,
    
    // BPDU发送接口
    output logic [NUM_PORTS-1:0]      bpdu_tx_valid,
    output logic [63:0]               bpdu_tx_data [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      bpdu_tx_sop,
    output logic [NUM_PORTS-1:0]      bpdu_tx_eop,
    input  logic [NUM_PORTS-1:0]      bpdu_tx_ready,
    
    // 端口状态输出
    output logic [1:0]                port_state [NUM_PORTS-1:0],  // STP state
    output logic [1:0]                port_role [NUM_PORTS-1:0],   // Port role
    
    // 桥配置
    input  logic [63:0]               bridge_id,      // Priority(16) + MAC(48)
    input  logic [15:0]               bridge_priority,
    input  logic [47:0]               bridge_mac,
    input  logic [15:0]               hello_time,     // Default: 2s
    input  logic [15:0]               max_age,        // Default: 20s
    input  logic [15:0]               forward_delay,  // Default: 15s
    input  logic                      rstp_enable,
    
    // 拓扑变化通知
    output logic                      topology_change,
    output logic [PORT_WIDTH-1:0]     tc_port,
    
    // 统计
    output logic [31:0]               stat_bpdu_rx [NUM_PORTS-1:0],
    output logic [31:0]               stat_bpdu_tx [NUM_PORTS-1:0],
    output logic [15:0]               stat_tc_count
);

    //------------------------------------------------------------------------
    // RSTP常量定义
    //------------------------------------------------------------------------
    // 端口状态
    localparam [1:0] STATE_DISCARDING = 2'b00;
    localparam [1:0] STATE_LEARNING   = 2'b01;
    localparam [1:0] STATE_FORWARDING = 2'b10;
    
    // 端口角色
    localparam [1:0] ROLE_DISABLED   = 2'b00;
    localparam [1:0] ROLE_ROOT       = 2'b01;
    localparam [1:0] ROLE_DESIGNATED = 2'b10;
    localparam [1:0] ROLE_ALTERNATE  = 2'b11;
    
    // BPDU类型
    localparam [7:0] BPDU_TYPE_CONFIG = 8'h00;
    localparam [7:0] BPDU_TYPE_RST    = 8'h02;
    localparam [7:0] BPDU_TYPE_TCN    = 8'h80;
    
    // 协议常量
    localparam [15:0] PROTOCOL_ID = 16'h0000;
    localparam [7:0]  PROTOCOL_VERSION = 8'h02;  // RSTP
    
    //------------------------------------------------------------------------
    // 桥级变量
    //------------------------------------------------------------------------
    logic [63:0] designated_root;     // Root Bridge ID
    logic [31:0] root_path_cost;      // Cost to Root
    logic [PORT_WIDTH-1:0] root_port; // Root Port
    logic is_root_bridge;
    
    //------------------------------------------------------------------------
    // 端口信息
    //------------------------------------------------------------------------
    typedef struct packed {
        logic [63:0] designated_root;
        logic [31:0] designated_cost;
        logic [63:0] designated_bridge;
        logic [PORT_WIDTH-1:0] designated_port;
        logic [15:0] message_age;
        logic [15:0] max_age;
        logic [15:0] hello_time;
        logic [15:0] forward_delay;
        logic        tc_flag;
        logic        tc_ack_flag;
    } port_info_t;
    
    port_info_t port_info [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // 定时器 (单位: 1s)
    //------------------------------------------------------------------------
    logic [15:0] hello_timer [NUM_PORTS-1:0];
    logic [15:0] age_timer [NUM_PORTS-1:0];
    logic [15:0] fwd_delay_timer [NUM_PORTS-1:0];
    logic [15:0] tc_timer;
    
    // 1秒定时器tick
    logic [31:0] tick_counter;
    logic tick_1s;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_counter <= '0;
            tick_1s <= 1'b0;
        end else begin
            tick_1s <= 1'b0;
            if (tick_counter >= CORE_FREQ_MHZ * 1000000 - 1) begin
                tick_counter <= '0;
                tick_1s <= 1'b1;
            end else begin
                tick_counter <= tick_counter + 1;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // BPDU解析状态机
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        BPDU_IDLE,
        BPDU_PARSE_HDR,
        BPDU_PARSE_ROOT,
        BPDU_PARSE_COST,
        BPDU_PARSE_BRIDGE,
        BPDU_DONE
    } bpdu_parse_state_e;
    
    bpdu_parse_state_e bpdu_state [NUM_PORTS-1:0];
    
    // BPDU接收缓冲
    logic [63:0] bpdu_buffer [NUM_PORTS-1:0][7:0];
    logic [2:0]  bpdu_word_cnt [NUM_PORTS-1:0];
    
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_bpdu_rx
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    bpdu_state[p] <= BPDU_IDLE;
                    bpdu_word_cnt[p] <= '0;
                    stat_bpdu_rx[p] <= '0;
                end else begin
                    
                    case (bpdu_state[p])
                        BPDU_IDLE: begin
                            if (bpdu_rx_valid[p] && bpdu_rx_sop[p]) begin
                                bpdu_word_cnt[p] <= '0;
                                bpdu_state[p] <= BPDU_PARSE_HDR;
                            end
                        end
                        
                        BPDU_PARSE_HDR: begin
                            if (bpdu_rx_valid[p]) begin
                                bpdu_buffer[p][bpdu_word_cnt[p]] <= bpdu_rx_data[p];
                                bpdu_word_cnt[p] <= bpdu_word_cnt[p] + 1;
                                
                                if (bpdu_word_cnt[p] >= 3'd6) begin
                                    bpdu_state[p] <= BPDU_DONE;
                                end
                            end
                        end
                        
                        BPDU_DONE: begin
                            if (bpdu_rx_eop[p]) begin
                                // 解析BPDU内容
                                // Word0: DMAC(48) + Protocol(16)
                                // Word1: Version(8) + Type(8) + Flags(8) + Root ID(40)
                                // Word2: Root ID(24) + Root Cost(32) + Bridge ID(8)
                                // ...
                                
                                // 提取关键信息 (简化)
                                port_info[p].designated_root <= bpdu_buffer[p][1][39:0];
                                port_info[p].designated_cost <= bpdu_buffer[p][2][63:32];
                                port_info[p].tc_flag <= bpdu_buffer[p][1][56];
                                
                                stat_bpdu_rx[p] <= stat_bpdu_rx[p] + 1;
                                bpdu_state[p] <= BPDU_IDLE;
                            end
                        end
                    endcase
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 端口角色选择 (Port Role Selection)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            designated_root <= bridge_id;
            root_path_cost <= '0;
            root_port <= '0;
            is_root_bridge <= 1'b1;
            
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_role[i] <= ROLE_DESIGNATED;
                port_state[i] <= STATE_DISCARDING;
            end
        end else if (rstp_enable) begin
            
            // 根桥选举 (Root Bridge Election)
            logic [63:0] best_root;
            logic [31:0] best_cost;
            logic [PORT_WIDTH-1:0] best_port;
            logic found_better_root;
            
            best_root = bridge_id;
            best_cost = '1;
            best_port = '0;
            found_better_root = 1'b0;
            
            // 遍历所有端口找最优根路径
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (port_enable[i] && port_link_up[i]) begin
                    // 比较Root Bridge ID
                    if (port_info[i].designated_root < best_root) begin
                        best_root = port_info[i].designated_root;
                        best_cost = port_info[i].designated_cost + port_path_cost[i];
                        best_port = i[PORT_WIDTH-1:0];
                        found_better_root = 1'b1;
                    end else if (port_info[i].designated_root == best_root) begin
                        // 相同Root，比较Cost
                        if (port_info[i].designated_cost + port_path_cost[i] < best_cost) begin
                            best_cost = port_info[i].designated_cost + port_path_cost[i];
                            best_port = i[PORT_WIDTH-1:0];
                        end
                    end
                end
            end
            
            // 更新桥级信息
            if (found_better_root) begin
                designated_root <= best_root;
                root_path_cost <= best_cost;
                root_port <= best_port;
                is_root_bridge <= 1'b0;
            end else begin
                designated_root <= bridge_id;
                root_path_cost <= '0;
                is_root_bridge <= 1'b1;
            end
            
            // 分配端口角色
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (!port_enable[i] || !port_link_up[i]) begin
                    port_role[i] <= ROLE_DISABLED;
                    port_state[i] <= STATE_DISCARDING;
                end else if (is_root_bridge) begin
                    // Root Bridge所有端口都是Designated
                    port_role[i] <= ROLE_DESIGNATED;
                    port_state[i] <= STATE_FORWARDING;
                end else if (i == root_port) begin
                    // Root Port
                    port_role[i] <= ROLE_ROOT;
                    port_state[i] <= STATE_FORWARDING;
                end else begin
                    // 比较是否应该是Designated Port
                    if (port_info[i].designated_root > designated_root ||
                        (port_info[i].designated_root == designated_root &&
                         port_info[i].designated_cost > root_path_cost)) begin
                        port_role[i] <= ROLE_DESIGNATED;
                        port_state[i] <= STATE_FORWARDING;
                    end else begin
                        port_role[i] <= ROLE_ALTERNATE;
                        port_state[i] <= STATE_DISCARDING;
                    end
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // BPDU生成与发送
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_PREP,
        TX_SEND,
        TX_DONE
    } bpdu_tx_state_e;
    
    bpdu_tx_state_e tx_state [NUM_PORTS-1:0];
    
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_bpdu_tx
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tx_state[p] <= TX_IDLE;
                    bpdu_tx_valid[p] <= 1'b0;
                    bpdu_tx_sop[p] <= 1'b0;
                    bpdu_tx_eop[p] <= 1'b0;
                    hello_timer[p] <= hello_time;
                    stat_bpdu_tx[p] <= '0;
                end else begin
                    bpdu_tx_valid[p] <= 1'b0;
                    bpdu_tx_sop[p] <= 1'b0;
                    bpdu_tx_eop[p] <= 1'b0;
                    
                    // Hello定时器
                    if (tick_1s) begin
                        if (hello_timer[p] > 0) begin
                            hello_timer[p] <= hello_timer[p] - 1;
                        end else begin
                            hello_timer[p] <= hello_time;
                            // 触发BPDU发送
                            if (port_role[p] == ROLE_DESIGNATED && rstp_enable) begin
                                tx_state[p] <= TX_PREP;
                            end
                        end
                    end
                    
                    case (tx_state[p])
                        TX_IDLE: begin
                            // 等待定时器触发
                        end
                        
                        TX_PREP: begin
                            tx_state[p] <= TX_SEND;
                        end
                        
                        TX_SEND: begin
                            if (bpdu_tx_ready[p]) begin
                                bpdu_tx_valid[p] <= 1'b1;
                                bpdu_tx_sop[p] <= 1'b1;
                                bpdu_tx_eop[p] <= 1'b1;
                                
                                // 构造BPDU (简化 - 仅关键字段)
                                // DMAC: 01:80:C2:00:00:00
                                // Protocol: 0x0000
                                // Version: 0x02 (RSTP)
                                // Type: 0x02
                                bpdu_tx_data[p] <= {
                                    16'h0180, 48'hC200_0000_0000  // DMAC + Protocol
                                };
                                
                                stat_bpdu_tx[p] <= stat_bpdu_tx[p] + 1;
                                tx_state[p] <= TX_DONE;
                            end
                        end
                        
                        TX_DONE: begin
                            tx_state[p] <= TX_IDLE;
                        end
                    endcase
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 拓扑变化检测 (Topology Change)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            topology_change <= 1'b0;
            tc_port <= '0;
            tc_timer <= '0;
            stat_tc_count <= '0;
        end else begin
            topology_change <= 1'b0;
            
            // 检测链路状态变化
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (port_enable[i]) begin
                    // 链路Down触发TC
                    if (!port_link_up[i] && port_state[i] == STATE_FORWARDING) begin
                        topology_change <= 1'b1;
                        tc_port <= i[PORT_WIDTH-1:0];
                        tc_timer <= max_age + forward_delay;
                        stat_tc_count <= stat_tc_count + 1;
                    end
                end
            end
            
            // TC定时器递减
            if (tick_1s && tc_timer > 0) begin
                tc_timer <= tc_timer - 1;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 端口老化定时器
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_age_timer
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    age_timer[p] <= max_age;
                end else begin
                    if (bpdu_rx_valid[p] && bpdu_rx_eop[p]) begin
                        // 收到BPDU，重置老化定时器
                        age_timer[p] <= max_age;
                    end else if (tick_1s && age_timer[p] > 0) begin
                        age_timer[p] <= age_timer[p] - 1;
                        
                        // 超时，端口信息失效
                        if (age_timer[p] == 1) begin
                            port_info[p] <= '0;
                            port_info[p].designated_root <= '1;  // Invalid
                        end
                    end
                end
            end
        end
    endgenerate

endmodule : rstp_engine
