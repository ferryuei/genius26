//============================================================================
// LACP Engine - Link Aggregation Control Protocol (IEEE 802.3ad/802.1AX)
// 功能: 动态链路聚合协商，自动故障检测与流量重分配
//============================================================================
`timescale 1ns/1ps

module lacp_engine
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 端口配置
    input  logic [NUM_PORTS-1:0]      port_enable,
    input  logic [NUM_PORTS-1:0]      port_link_up,
    input  logic [15:0]               port_speed [NUM_PORTS-1:0],  // Mbps
    
    // LACPDU接收接口
    input  logic [NUM_PORTS-1:0]      lacpdu_rx_valid,
    input  logic [63:0]               lacpdu_rx_data [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      lacpdu_rx_sop,
    input  logic [NUM_PORTS-1:0]      lacpdu_rx_eop,
    
    // LACPDU发送接口
    output logic [NUM_PORTS-1:0]      lacpdu_tx_valid,
    output logic [63:0]               lacpdu_tx_data [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      lacpdu_tx_sop,
    output logic [NUM_PORTS-1:0]      lacpdu_tx_eop,
    input  logic [NUM_PORTS-1:0]      lacpdu_tx_ready,
    
    // LAG组配置
    input  logic [2:0]                cfg_lag_id [NUM_PORTS-1:0],  // Port -> LAG mapping
    input  logic [NUM_PORTS-1:0]      cfg_lacp_enable,
    input  logic [47:0]               system_mac,
    input  logic [15:0]               system_priority,
    
    // LAG状态输出
    output logic [NUM_PORTS-1:0]      port_selected,    // Port in Aggregation
    output logic [NUM_PORTS-1:0]      port_standby,     // Standby port
    output logic [2:0]                port_lag_id [NUM_PORTS-1:0],
    
    // Partner信息 (for monitoring)
    output logic [47:0]               partner_mac [NUM_PORTS-1:0],
    output logic [15:0]               partner_key [NUM_PORTS-1:0],
    
    // 统计
    output logic [31:0]               stat_lacpdu_rx [NUM_PORTS-1:0],
    output logic [31:0]               stat_lacpdu_tx [NUM_PORTS-1:0],
    output logic [15:0]               stat_lag_changes
);

    //------------------------------------------------------------------------
    // LACP常量
    //------------------------------------------------------------------------
    // LACP Activity
    localparam LACP_ACTIVE  = 1'b1;
    localparam LACP_PASSIVE = 1'b0;
    
    // LACP Timeout
    localparam TIMEOUT_SHORT = 3;   // 3 seconds
    localparam TIMEOUT_LONG  = 90;  // 90 seconds
    
    // LACP State
    localparam [7:0] STATE_LACP_ACTIVITY    = 8'h01;
    localparam [7:0] STATE_LACP_TIMEOUT     = 8'h02;
    localparam [7:0] STATE_AGGREGATION      = 8'h04;
    localparam [7:0] STATE_SYNCHRONIZATION  = 8'h08;
    localparam [7:0] STATE_COLLECTING       = 8'h10;
    localparam [7:0] STATE_DISTRIBUTING     = 8'h20;
    localparam [7:0] STATE_DEFAULTED        = 8'h40;
    localparam [7:0] STATE_EXPIRED          = 8'h80;
    
    // LACPDU Subtype
    localparam [7:0] LACP_SUBTYPE = 8'h01;
    localparam [7:0] LACP_VERSION = 8'h01;
    
    //------------------------------------------------------------------------
    // Actor (本端) 信息
    //------------------------------------------------------------------------
    typedef struct packed {
        logic [15:0] system_priority;
        logic [47:0] system_mac;
        logic [15:0] key;               // Aggregation Key
        logic [15:0] port_priority;
        logic [15:0] port_number;
        logic [7:0]  state;
    } lacp_actor_t;
    
    lacp_actor_t actor_info [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // Partner (对端) 信息
    //------------------------------------------------------------------------
    typedef struct packed {
        logic [15:0] system_priority;
        logic [47:0] system_mac;
        logic [15:0] key;
        logic [15:0] port_priority;
        logic [15:0] port_number;
        logic [7:0]  state;
        logic        valid;
    } lacp_partner_t;
    
    lacp_partner_t partner_info [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // 端口状态机
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        PORT_LACP_DISABLED,
        PORT_LACP_INIT,
        PORT_LACP_EXCHANGE,
        PORT_LACP_SELECTED,
        PORT_LACP_STANDBY
    } lacp_port_state_e;
    
    lacp_port_state_e port_lacp_state [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // 定时器
    //------------------------------------------------------------------------
    logic [7:0] periodic_timer [NUM_PORTS-1:0];   // Periodic TX timer (1s)
    logic [7:0] current_timer [NUM_PORTS-1:0];    // Partner timeout timer
    
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
    // Actor信息初始化
    //------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_actor_init
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    actor_info[p].system_priority <= system_priority;
                    actor_info[p].system_mac <= system_mac;
                    actor_info[p].key <= cfg_lag_id[p];
                    actor_info[p].port_priority <= 16'h8000;
                    actor_info[p].port_number <= p[15:0];
                    actor_info[p].state <= STATE_LACP_ACTIVITY | STATE_AGGREGATION;
                end else begin
                    // 动态更新
                    actor_info[p].system_priority <= system_priority;
                    actor_info[p].system_mac <= system_mac;
                    actor_info[p].key <= cfg_lag_id[p];
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // LACPDU接收与解析
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        RX_IDLE,
        RX_PARSE_ACTOR,
        RX_PARSE_PARTNER,
        RX_DONE
    } lacpdu_rx_state_e;
    
    lacpdu_rx_state_e rx_state [NUM_PORTS-1:0];
    logic [63:0] rx_buffer [NUM_PORTS-1:0][15:0];
    logic [3:0]  rx_word_cnt [NUM_PORTS-1:0];
    
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_lacpdu_rx
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rx_state[p] <= RX_IDLE;
                    rx_word_cnt[p] <= '0;
                    partner_info[p] <= '0;
                    stat_lacpdu_rx[p] <= '0;
                end else begin
                    
                    case (rx_state[p])
                        RX_IDLE: begin
                            if (lacpdu_rx_valid[p] && lacpdu_rx_sop[p]) begin
                                rx_word_cnt[p] <= '0;
                                rx_state[p] <= RX_PARSE_ACTOR;
                            end
                        end
                        
                        RX_PARSE_ACTOR: begin
                            if (lacpdu_rx_valid[p]) begin
                                rx_buffer[p][rx_word_cnt[p]] <= lacpdu_rx_data[p];
                                rx_word_cnt[p] <= rx_word_cnt[p] + 1;
                                
                                // LACPDU长度 ~128字节 = 16个64bit字
                                if (rx_word_cnt[p] >= 4'd14) begin
                                    rx_state[p] <= RX_DONE;
                                end
                            end
                        end
                        
                        RX_DONE: begin
                            if (lacpdu_rx_eop[p]) begin
                                // 解析Partner信息 (简化)
                                // Word 0: DMAC(48) + Slow Protocol(16)
                                // Word 1: Subtype(8) + Version(8) + TLV...
                                // Word 2-5: Actor Info
                                // Word 6-9: Partner Info
                                
                                // 提取Partner System
                                partner_info[p].system_priority <= rx_buffer[p][6][63:48];
                                partner_info[p].system_mac <= rx_buffer[p][7][47:0];
                                partner_info[p].key <= rx_buffer[p][8][63:48];
                                partner_info[p].port_priority <= rx_buffer[p][8][47:32];
                                partner_info[p].port_number <= rx_buffer[p][8][31:16];
                                partner_info[p].state <= rx_buffer[p][9][63:56];
                                partner_info[p].valid <= 1'b1;
                                
                                // 重置超时定时器
                                current_timer[p] <= TIMEOUT_SHORT;
                                
                                stat_lacpdu_rx[p] <= stat_lacpdu_rx[p] + 1;
                                rx_state[p] <= RX_IDLE;
                            end
                        end
                    endcase
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // LACP端口状态机
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_port_fsm
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    port_lacp_state[p] <= PORT_LACP_DISABLED;
                    port_selected[p] <= 1'b0;
                    port_standby[p] <= 1'b0;
                    port_lag_id[p] <= '0;
                end else begin
                    
                    case (port_lacp_state[p])
                        PORT_LACP_DISABLED: begin
                            if (cfg_lacp_enable[p] && port_enable[p] && port_link_up[p]) begin
                                port_lacp_state[p] <= PORT_LACP_INIT;
                            end
                        end
                        
                        PORT_LACP_INIT: begin
                            port_selected[p] <= 1'b0;
                            port_standby[p] <= 1'b0;
                            port_lag_id[p] <= cfg_lag_id[p];
                            
                            // 设置初始状态
                            actor_info[p].state <= STATE_LACP_ACTIVITY | 
                                                   STATE_AGGREGATION |
                                                   STATE_DEFAULTED;
                            
                            port_lacp_state[p] <= PORT_LACP_EXCHANGE;
                        end
                        
                        PORT_LACP_EXCHANGE: begin
                            // 等待收到Partner LACPDU
                            if (partner_info[p].valid) begin
                                // 检查是否可以聚合
                                if (partner_info[p].key == actor_info[p].key &&
                                    (partner_info[p].state & STATE_AGGREGATION)) begin
                                    
                                    // 检查LAG ID匹配
                                    if (cfg_lag_id[p] == partner_info[p].key[2:0]) begin
                                        port_lacp_state[p] <= PORT_LACP_SELECTED;
                                    end
                                end
                            end
                            
                            // 超时处理
                            if (tick_1s && current_timer[p] == 0) begin
                                partner_info[p].valid <= 1'b0;
                                port_lacp_state[p] <= PORT_LACP_INIT;
                            end
                        end
                        
                        PORT_LACP_SELECTED: begin
                            // 端口已选中，加入聚合
                            port_selected[p] <= 1'b1;
                            port_standby[p] <= 1'b0;
                            
                            actor_info[p].state <= STATE_LACP_ACTIVITY | 
                                                   STATE_AGGREGATION |
                                                   STATE_SYNCHRONIZATION |
                                                   STATE_COLLECTING |
                                                   STATE_DISTRIBUTING;
                            
                            // 检查Partner状态
                            if (!partner_info[p].valid || 
                                !(partner_info[p].state & STATE_SYNCHRONIZATION)) begin
                                port_lacp_state[p] <= PORT_LACP_EXCHANGE;
                            end
                            
                            // 链路Down
                            if (!port_link_up[p]) begin
                                port_lacp_state[p] <= PORT_LACP_DISABLED;
                            end
                        end
                        
                        PORT_LACP_STANDBY: begin
                            // 备用端口
                            port_selected[p] <= 1'b0;
                            port_standby[p] <= 1'b1;
                        end
                    endcase
                    
                    // 定时器递减
                    if (tick_1s) begin
                        if (current_timer[p] > 0) begin
                            current_timer[p] <= current_timer[p] - 1;
                        end else begin
                            // 超时，Partner信息失效
                            partner_info[p].valid <= 1'b0;
                        end
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // LACPDU生成与周期性发送
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_PREP,
        TX_SEND_HDR,
        TX_SEND_ACTOR,
        TX_SEND_PARTNER,
        TX_DONE
    } lacpdu_tx_state_e;
    
    lacpdu_tx_state_e tx_state [NUM_PORTS-1:0];
    logic [3:0] tx_word_cnt [NUM_PORTS-1:0];
    
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_lacpdu_tx
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tx_state[p] <= TX_IDLE;
                    periodic_timer[p] <= 1;
                    lacpdu_tx_valid[p] <= 1'b0;
                    lacpdu_tx_sop[p] <= 1'b0;
                    lacpdu_tx_eop[p] <= 1'b0;
                    tx_word_cnt[p] <= '0;
                    stat_lacpdu_tx[p] <= '0;
                end else begin
                    lacpdu_tx_valid[p] <= 1'b0;
                    lacpdu_tx_sop[p] <= 1'b0;
                    lacpdu_tx_eop[p] <= 1'b0;
                    
                    // 周期性定时器 (1秒一次)
                    if (tick_1s && port_lacp_state[p] != PORT_LACP_DISABLED) begin
                        if (periodic_timer[p] > 0) begin
                            periodic_timer[p] <= periodic_timer[p] - 1;
                        end else begin
                            periodic_timer[p] <= 1;  // 1秒周期
                            tx_state[p] <= TX_PREP;
                        end
                    end
                    
                    case (tx_state[p])
                        TX_IDLE: begin
                            // 等待定时器触发
                        end
                        
                        TX_PREP: begin
                            tx_word_cnt[p] <= '0;
                            tx_state[p] <= TX_SEND_HDR;
                        end
                        
                        TX_SEND_HDR: begin
                            if (lacpdu_tx_ready[p]) begin
                                lacpdu_tx_valid[p] <= 1'b1;
                                lacpdu_tx_sop[p] <= 1'b1;
                                
                                // DMAC: 01:80:C2:00:00:02 (Slow Protocols)
                                // EtherType: 0x8809
                                // Subtype: 0x01 (LACP)
                                // Version: 0x01
                                lacpdu_tx_data[p] <= {
                                    16'h0180, 48'hC200_0000_0002
                                };
                                
                                tx_state[p] <= TX_SEND_ACTOR;
                            end
                        end
                        
                        TX_SEND_ACTOR: begin
                            if (lacpdu_tx_ready[p]) begin
                                lacpdu_tx_valid[p] <= 1'b1;
                                
                                // 发送Actor Info (简化)
                                case (tx_word_cnt[p])
                                    4'd0: lacpdu_tx_data[p] <= {16'h8809, 8'h01, 8'h01, 32'h0}; // EType+Sub+Ver
                                    4'd1: lacpdu_tx_data[p] <= {actor_info[p].system_priority, actor_info[p].system_mac};
                                    4'd2: lacpdu_tx_data[p] <= {actor_info[p].key, actor_info[p].port_priority, actor_info[p].port_number, actor_info[p].state, 8'h0};
                                    default: lacpdu_tx_data[p] <= '0;
                                endcase
                                
                                tx_word_cnt[p] <= tx_word_cnt[p] + 1;
                                
                                if (tx_word_cnt[p] >= 4'd2) begin
                                    tx_state[p] <= TX_SEND_PARTNER;
                                    tx_word_cnt[p] <= '0;
                                end
                            end
                        end
                        
                        TX_SEND_PARTNER: begin
                            if (lacpdu_tx_ready[p]) begin
                                lacpdu_tx_valid[p] <= 1'b1;
                                
                                // 发送Partner Info
                                if (partner_info[p].valid) begin
                                    case (tx_word_cnt[p])
                                        4'd0: lacpdu_tx_data[p] <= {partner_info[p].system_priority, partner_info[p].system_mac};
                                        4'd1: lacpdu_tx_data[p] <= {partner_info[p].key, partner_info[p].port_priority, partner_info[p].port_number, partner_info[p].state, 8'h0};
                                        default: lacpdu_tx_data[p] <= '0;
                                    endcase
                                end else begin
                                    lacpdu_tx_data[p] <= '0;
                                end
                                
                                tx_word_cnt[p] <= tx_word_cnt[p] + 1;
                                
                                if (tx_word_cnt[p] >= 4'd1) begin
                                    lacpdu_tx_eop[p] <= 1'b1;
                                    tx_state[p] <= TX_DONE;
                                end
                            end
                        end
                        
                        TX_DONE: begin
                            stat_lacpdu_tx[p] <= stat_lacpdu_tx[p] + 1;
                            tx_state[p] <= TX_IDLE;
                        end
                    endcase
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // Partner信息输出
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_partner_out
            assign partner_mac[p] = partner_info[p].system_mac;
            assign partner_key[p] = partner_info[p].key;
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // LAG拓扑变化统计
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0] port_selected_prev;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            port_selected_prev <= '0;
            stat_lag_changes <= '0;
        end else begin
            port_selected_prev <= port_selected;
            
            // 检测状态变化
            if (port_selected != port_selected_prev) begin
                stat_lag_changes <= stat_lag_changes + 1;
            end
        end
    end

endmodule : lacp_engine
