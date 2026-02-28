//============================================================================
// PAUSE Frame Controller - IEEE 802.3x Flow Control
// 功能: PAUSE帧生成和解析，实现全双工流量控制
//============================================================================
`timescale 1ns/1ps

module pause_frame_ctrl
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Rx解析接口 (来自Ingress)
    input  logic [NUM_PORTS-1:0]      rx_valid,
    input  logic [NUM_PORTS-1:0]      rx_sop,
    input  logic [NUM_PORTS-1:0]      rx_eop,
    input  logic [63:0]               rx_data [NUM_PORTS-1:0],
    
    // Rx PAUSE状态输出
    output logic [NUM_PORTS-1:0]      port_paused,
    output logic [15:0]               pause_timer [NUM_PORTS-1:0],
    
    // Tx生成接口
    input  logic [NUM_PORTS-1:0]      tx_pause_req,      // 请求发送PAUSE
    input  logic [15:0]               tx_pause_quanta [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      tx_pause_ready,
    output logic [NUM_PORTS-1:0]      tx_pause_valid,
    output logic [NUM_PORTS-1:0]      tx_pause_sop,
    output logic [NUM_PORTS-1:0]      tx_pause_eop,
    output logic [63:0]               tx_pause_data [NUM_PORTS-1:0],
    output logic [2:0]                tx_pause_empty [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      tx_pause_ack,
    
    // 端口配置
    input  logic [NUM_PORTS-1:0]      cfg_flow_ctrl_enable,
    input  logic [NUM_PORTS-1:0]      cfg_pause_tx_enable,
    input  logic [NUM_PORTS-1:0]      cfg_pause_rx_enable,
    input  logic [47:0]               cfg_src_mac [NUM_PORTS-1:0],
    
    // 统计
    output logic [31:0]               stat_pause_rx [NUM_PORTS-1:0],
    output logic [31:0]               stat_pause_tx [NUM_PORTS-1:0]
);

    //------------------------------------------------------------------------
    // PAUSE帧常量
    //------------------------------------------------------------------------
    // PAUSE帧目的MAC: 01:80:C2:00:00:01 (保留组播地址)
    localparam logic [47:0] PAUSE_DMAC = 48'h0180C2000001;
    // PAUSE帧EtherType: 0x8808 (MAC Control)
    localparam logic [15:0] PAUSE_ETYPE = 16'h8808;
    // PAUSE帧Opcode: 0x0001
    localparam logic [15:0] PAUSE_OPCODE = 16'h0001;
    
    // PAUSE帧格式 (64字节最小帧):
    // DMAC(6) + SMAC(6) + EtherType(2) + Opcode(2) + Quanta(2) + Padding(42) + FCS(4)
    
    //------------------------------------------------------------------------
    // Rx PAUSE解析
    //------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_rx_pause
            
            typedef enum logic [2:0] {
                RX_IDLE,
                RX_PARSE_L2,
                RX_PARSE_MAC_CTRL,
                RX_EXTRACT_QUANTA,
                RX_DONE
            } rx_parse_state_e;
            
            rx_parse_state_e rx_state;
            logic [47:0] rx_parsed_dmac;
            logic [47:0] rx_parsed_smac;
            logic [15:0] rx_parsed_etype;
            logic [15:0] rx_parsed_opcode;
            logic [15:0] rx_parsed_quanta;
            logic rx_is_pause;
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rx_state <= RX_IDLE;
                    pause_timer[p] <= '0;
                    port_paused[p] <= 1'b0;
                    rx_is_pause <= 1'b0;
                    stat_pause_rx[p] <= '0;
                end else begin
                    
                    // PAUSE定时器递减 (每周期-1, 假设512 bit times = 1 cycle at 500MHz)
                    if (pause_timer[p] > 0) begin
                        pause_timer[p] <= pause_timer[p] - 1;
                        port_paused[p] <= 1'b1;
                    end else begin
                        port_paused[p] <= 1'b0;
                    end
                    
                    case (rx_state)
                        RX_IDLE: begin
                            if (cfg_pause_rx_enable[p] && rx_valid[p] && rx_sop[p]) begin
                                rx_state <= RX_PARSE_L2;
                            end
                        end
                        
                        RX_PARSE_L2: begin
                            if (rx_valid[p]) begin
                                // 第一个周期: DMAC[47:0] + SMAC[47:32]
                                rx_parsed_dmac <= rx_data[p][47:0];
                                rx_parsed_smac[47:32] <= rx_data[p][63:48];
                                rx_state <= RX_PARSE_MAC_CTRL;
                            end
                        end
                        
                        RX_PARSE_MAC_CTRL: begin
                            if (rx_valid[p]) begin
                                // 第二个周期: SMAC[31:0] + EtherType[15:0] + Opcode[15:0]
                                rx_parsed_smac[31:0] <= rx_data[p][31:0];
                                rx_parsed_etype <= rx_data[p][47:32];
                                rx_parsed_opcode <= rx_data[p][63:48];
                                
                                // 检查是否为PAUSE帧
                                if (rx_parsed_dmac == PAUSE_DMAC &&
                                    rx_data[p][47:32] == PAUSE_ETYPE &&
                                    rx_data[p][63:48] == PAUSE_OPCODE) begin
                                    rx_is_pause <= 1'b1;
                                    rx_state <= RX_EXTRACT_QUANTA;
                                end else begin
                                    rx_is_pause <= 1'b0;
                                    rx_state <= RX_IDLE;
                                end
                            end
                        end
                        
                        RX_EXTRACT_QUANTA: begin
                            if (rx_valid[p]) begin
                                // 第三个周期: Quanta[15:0] + Padding...
                                rx_parsed_quanta <= rx_data[p][15:0];
                                
                                // 设置PAUSE定时器
                                if (rx_is_pause && rx_parsed_quanta > 0) begin
                                    pause_timer[p] <= rx_parsed_quanta;
                                    stat_pause_rx[p] <= stat_pause_rx[p] + 1;
                                end else begin
                                    // Quanta=0表示取消PAUSE
                                    pause_timer[p] <= '0;
                                end
                                
                                rx_state <= RX_DONE;
                            end
                        end
                        
                        RX_DONE: begin
                            if (rx_eop[p]) begin
                                rx_state <= RX_IDLE;
                            end
                        end
                    endcase
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // Tx PAUSE生成
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_tx_pause
            
            typedef enum logic [2:0] {
                TX_IDLE,
                TX_WAIT_READY,
                TX_SEND_L2,
                TX_SEND_MAC_CTRL,
                TX_SEND_PADDING,
                TX_DONE
            } tx_gen_state_e;
            
            tx_gen_state_e tx_state;
            logic [15:0] tx_quanta_reg;
            logic [3:0] tx_padding_cnt;  // 需要5个周期的padding (42字节)
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tx_state <= TX_IDLE;
                    tx_pause_valid[p] <= 1'b0;
                    tx_pause_sop[p] <= 1'b0;
                    tx_pause_eop[p] <= 1'b0;
                    tx_pause_data[p] <= '0;
                    tx_pause_empty[p] <= '0;
                    tx_pause_ready[p] <= 1'b1;
                    tx_quanta_reg <= '0;
                    tx_padding_cnt <= '0;
                    stat_pause_tx[p] <= '0;
                end else begin
                    tx_pause_valid[p] <= 1'b0;
                    tx_pause_sop[p] <= 1'b0;
                    tx_pause_eop[p] <= 1'b0;
                    
                    case (tx_state)
                        TX_IDLE: begin
                            tx_pause_ready[p] <= 1'b1;
                            if (cfg_pause_tx_enable[p] && tx_pause_req[p]) begin
                                tx_quanta_reg <= tx_pause_quanta[p];
                                tx_padding_cnt <= '0;
                                tx_state <= TX_WAIT_READY;
                                tx_pause_ready[p] <= 1'b0;
                            end
                        end
                        
                        TX_WAIT_READY: begin
                            // 等待一个周期准备数据
                            tx_state <= TX_SEND_L2;
                        end
                        
                        TX_SEND_L2: begin
                            // 发送 DMAC + SMAC[47:32] (8字节)
                            tx_pause_valid[p] <= 1'b1;
                            tx_pause_sop[p] <= 1'b1;
                            tx_pause_data[p] <= {cfg_src_mac[p][47:32], PAUSE_DMAC};
                            tx_pause_empty[p] <= 3'd0;
                            
                            if (tx_pause_ack[p]) begin
                                tx_state <= TX_SEND_MAC_CTRL;
                            end
                        end
                        
                        TX_SEND_MAC_CTRL: begin
                            // 发送 SMAC[31:0] + EtherType + Opcode (8字节)
                            tx_pause_valid[p] <= 1'b1;
                            tx_pause_data[p] <= {PAUSE_OPCODE, PAUSE_ETYPE, cfg_src_mac[p][31:0]};
                            tx_pause_empty[p] <= 3'd0;
                            
                            if (tx_pause_ack[p]) begin
                                tx_state <= TX_SEND_PADDING;
                            end
                        end
                        
                        TX_SEND_PADDING: begin
                            // 发送 Quanta + Padding (42字节 = 5个周期+ 2字节)
                            tx_pause_valid[p] <= 1'b1;
                            
                            if (tx_padding_cnt == 0) begin
                                // 第一个padding周期: Quanta + 6字节padding
                                tx_pause_data[p] <= {48'b0, tx_quanta_reg};
                            end else begin
                                // 剩余padding
                                tx_pause_data[p] <= '0;
                            end
                            
                            if (tx_padding_cnt == 4) begin
                                // 最后一个周期，只有2字节有效
                                tx_pause_eop[p] <= 1'b1;
                                tx_pause_empty[p] <= 3'd6;  // 6字节无效
                            end else begin
                                tx_pause_empty[p] <= 3'd0;
                            end
                            
                            if (tx_pause_ack[p]) begin
                                if (tx_padding_cnt == 4) begin
                                    tx_state <= TX_DONE;
                                end else begin
                                    tx_padding_cnt <= tx_padding_cnt + 1;
                                end
                            end
                        end
                        
                        TX_DONE: begin
                            stat_pause_tx[p] <= stat_pause_tx[p] + 1;
                            tx_state <= TX_IDLE;
                        end
                    endcase
                end
            end
        end
    endgenerate

endmodule : pause_frame_ctrl
