//============================================================================
// Port Statistics - 完整端口统计计数器模块
// 功能: RFC 2819/2863标准端口统计，支持Rx/Tx报文、字节、错误、丢包等
//============================================================================
`timescale 1ns/1ps

module port_statistics
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 每端口统计输入 (Rx)
    input  logic [NUM_PORTS-1:0]      rx_valid,
    input  logic [NUM_PORTS-1:0]      rx_sop,
    input  logic [NUM_PORTS-1:0]      rx_eop,
    input  logic [63:0]               rx_data [NUM_PORTS-1:0],
    input  logic [2:0]                rx_empty [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      rx_error,          // PHY/MAC层错误
    input  logic [NUM_PORTS-1:0]      rx_crc_error,
    input  logic [NUM_PORTS-1:0]      rx_align_error,
    input  logic [NUM_PORTS-1:0]      rx_overrun,
    input  logic [NUM_PORTS-1:0]      rx_jabber,         // 超长帧
    input  logic [NUM_PORTS-1:0]      rx_undersize,      // 短帧 (<64B)
    input  logic [NUM_PORTS-1:0]      rx_fragment,
    input  logic [NUM_PORTS-1:0]      rx_drop,           // 缓冲区满丢包
    
    // 每端口统计输入 (Tx)
    input  logic [NUM_PORTS-1:0]      tx_valid,
    input  logic [NUM_PORTS-1:0]      tx_sop,
    input  logic [NUM_PORTS-1:0]      tx_eop,
    input  logic [63:0]               tx_data [NUM_PORTS-1:0],
    input  logic [2:0]                tx_empty [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      tx_error,
    input  logic [NUM_PORTS-1:0]      tx_collision,      // 碰撞
    input  logic [NUM_PORTS-1:0]      tx_late_collision,
    input  logic [NUM_PORTS-1:0]      tx_excessive_collision,
    input  logic [NUM_PORTS-1:0]      tx_underrun,
    input  logic [NUM_PORTS-1:0]      tx_drop,
    
    // CPU读取接口
    input  logic [PORT_WIDTH-1:0]     read_port,
    input  logic [7:0]                read_counter_id,
    output logic [63:0]               read_counter_value,
    
    // 清零接口
    input  logic                      clear_req,
    input  logic [PORT_WIDTH-1:0]     clear_port,
    output logic                      clear_done
);

    //------------------------------------------------------------------------
    // 统计计数器ID定义
    //------------------------------------------------------------------------
    localparam logic [7:0] CNT_RX_PACKETS       = 8'd0;
    localparam logic [7:0] CNT_RX_OCTETS        = 8'd1;
    localparam logic [7:0] CNT_RX_UNICAST       = 8'd2;
    localparam logic [7:0] CNT_RX_MULTICAST     = 8'd3;
    localparam logic [7:0] CNT_RX_BROADCAST     = 8'd4;
    localparam logic [7:0] CNT_RX_PAUSE         = 8'd5;
    localparam logic [7:0] CNT_RX_UNDERSIZE     = 8'd6;
    localparam logic [7:0] CNT_RX_FRAGMENT      = 8'd7;
    localparam logic [7:0] CNT_RX_OVERSIZE      = 8'd8;  // >MTU
    localparam logic [7:0] CNT_RX_JABBER        = 8'd9;
    localparam logic [7:0] CNT_RX_ERRORS        = 8'd10;
    localparam logic [7:0] CNT_RX_CRC_ERRORS    = 8'd11;
    localparam logic [7:0] CNT_RX_ALIGN_ERRORS  = 8'd12;
    localparam logic [7:0] CNT_RX_OVERRUN       = 8'd13;
    localparam logic [7:0] CNT_RX_DROPS         = 8'd14;
    localparam logic [7:0] CNT_RX_64B           = 8'd15;
    localparam logic [7:0] CNT_RX_65_127B       = 8'd16;
    localparam logic [7:0] CNT_RX_128_255B      = 8'd17;
    localparam logic [7:0] CNT_RX_256_511B      = 8'd18;
    localparam logic [7:0] CNT_RX_512_1023B     = 8'd19;
    localparam logic [7:0] CNT_RX_1024_1518B    = 8'd20;
    localparam logic [7:0] CNT_RX_1519_PLUS     = 8'd21;
    
    localparam logic [7:0] CNT_TX_PACKETS       = 8'd32;
    localparam logic [7:0] CNT_TX_OCTETS        = 8'd33;
    localparam logic [7:0] CNT_TX_UNICAST       = 8'd34;
    localparam logic [7:0] CNT_TX_MULTICAST     = 8'd35;
    localparam logic [7:0] CNT_TX_BROADCAST     = 8'd36;
    localparam logic [7:0] CNT_TX_PAUSE         = 8'd37;
    localparam logic [7:0] CNT_TX_ERRORS        = 8'd38;
    localparam logic [7:0] CNT_TX_COLLISION     = 8'd39;
    localparam logic [7:0] CNT_TX_LATE_COLLISION = 8'd40;
    localparam logic [7:0] CNT_TX_EXCESSIVE_COLLISION = 8'd41;
    localparam logic [7:0] CNT_TX_UNDERRUN      = 8'd42;
    localparam logic [7:0] CNT_TX_DROPS         = 8'd43;
    localparam logic [7:0] CNT_TX_64B           = 8'd44;
    localparam logic [7:0] CNT_TX_65_127B       = 8'd45;
    localparam logic [7:0] CNT_TX_128_255B      = 8'd46;
    localparam logic [7:0] CNT_TX_256_511B      = 8'd47;
    localparam logic [7:0] CNT_TX_512_1023B     = 8'd48;
    localparam logic [7:0] CNT_TX_1024_1518B    = 8'd49;
    localparam logic [7:0] CNT_TX_1519_PLUS     = 8'd50;
    
    //------------------------------------------------------------------------
    // Rx统计计数器
    //------------------------------------------------------------------------
    logic [63:0] rx_packets       [NUM_PORTS-1:0];
    logic [63:0] rx_octets        [NUM_PORTS-1:0];
    logic [63:0] rx_unicast       [NUM_PORTS-1:0];
    logic [63:0] rx_multicast     [NUM_PORTS-1:0];
    logic [63:0] rx_broadcast     [NUM_PORTS-1:0];
    logic [63:0] rx_pause         [NUM_PORTS-1:0];
    logic [63:0] rx_undersize_cnt [NUM_PORTS-1:0];
    logic [63:0] rx_fragment_cnt  [NUM_PORTS-1:0];
    logic [63:0] rx_oversize      [NUM_PORTS-1:0];
    logic [63:0] rx_jabber_cnt    [NUM_PORTS-1:0];
    logic [63:0] rx_errors        [NUM_PORTS-1:0];
    logic [63:0] rx_crc_errors    [NUM_PORTS-1:0];
    logic [63:0] rx_align_errors  [NUM_PORTS-1:0];
    logic [63:0] rx_overrun_cnt   [NUM_PORTS-1:0];
    logic [63:0] rx_drops         [NUM_PORTS-1:0];
    
    // 报文长度分布
    logic [63:0] rx_64b           [NUM_PORTS-1:0];
    logic [63:0] rx_65_127b       [NUM_PORTS-1:0];
    logic [63:0] rx_128_255b      [NUM_PORTS-1:0];
    logic [63:0] rx_256_511b      [NUM_PORTS-1:0];
    logic [63:0] rx_512_1023b     [NUM_PORTS-1:0];
    logic [63:0] rx_1024_1518b    [NUM_PORTS-1:0];
    logic [63:0] rx_1519_plus     [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // Tx统计计数器
    //------------------------------------------------------------------------
    logic [63:0] tx_packets       [NUM_PORTS-1:0];
    logic [63:0] tx_octets        [NUM_PORTS-1:0];
    logic [63:0] tx_unicast       [NUM_PORTS-1:0];
    logic [63:0] tx_multicast     [NUM_PORTS-1:0];
    logic [63:0] tx_broadcast     [NUM_PORTS-1:0];
    logic [63:0] tx_pause         [NUM_PORTS-1:0];
    logic [63:0] tx_errors        [NUM_PORTS-1:0];
    logic [63:0] tx_collision_cnt [NUM_PORTS-1:0];
    logic [63:0] tx_late_collision_cnt [NUM_PORTS-1:0];
    logic [63:0] tx_excessive_collision_cnt [NUM_PORTS-1:0];
    logic [63:0] tx_underrun_cnt  [NUM_PORTS-1:0];
    logic [63:0] tx_drops         [NUM_PORTS-1:0];
    
    // 报文长度分布
    logic [63:0] tx_64b           [NUM_PORTS-1:0];
    logic [63:0] tx_65_127b       [NUM_PORTS-1:0];
    logic [63:0] tx_128_255b      [NUM_PORTS-1:0];
    logic [63:0] tx_256_511b      [NUM_PORTS-1:0];
    logic [63:0] tx_512_1023b     [NUM_PORTS-1:0];
    logic [63:0] tx_1024_1518b    [NUM_PORTS-1:0];
    logic [63:0] tx_1519_plus     [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // Rx统计逻辑
    //------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_rx_stats
            // 报文字节计数
            logic [15:0] rx_pkt_bytes;
            logic rx_pkt_active;
            logic [47:0] rx_dmac;
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rx_pkt_bytes <= '0;
                    rx_pkt_active <= 1'b0;
                    rx_dmac <= '0;
                end else begin
                    if (rx_valid[p]) begin
                        if (rx_sop[p]) begin
                            rx_pkt_bytes <= 8;
                            rx_pkt_active <= 1'b1;
                            // 提取DMAC
                            rx_dmac <= rx_data[p][47:0];
                        end else if (rx_pkt_active) begin
                            rx_pkt_bytes <= rx_pkt_bytes + 8 - {13'b0, rx_empty[p]};
                        end
                        
                        if (rx_eop[p]) begin
                            rx_pkt_active <= 1'b0;
                        end
                    end
                end
            end
            
            // 统计更新
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n || (clear_req && clear_port == p[PORT_WIDTH-1:0])) begin
                    rx_packets[p] <= '0;
                    rx_octets[p] <= '0;
                    rx_unicast[p] <= '0;
                    rx_multicast[p] <= '0;
                    rx_broadcast[p] <= '0;
                    rx_pause[p] <= '0;
                    rx_undersize_cnt[p] <= '0;
                    rx_fragment_cnt[p] <= '0;
                    rx_oversize[p] <= '0;
                    rx_jabber_cnt[p] <= '0;
                    rx_errors[p] <= '0;
                    rx_crc_errors[p] <= '0;
                    rx_align_errors[p] <= '0;
                    rx_overrun_cnt[p] <= '0;
                    rx_drops[p] <= '0;
                    rx_64b[p] <= '0;
                    rx_65_127b[p] <= '0;
                    rx_128_255b[p] <= '0;
                    rx_256_511b[p] <= '0;
                    rx_512_1023b[p] <= '0;
                    rx_1024_1518b[p] <= '0;
                    rx_1519_plus[p] <= '0;
                end else begin
                    // 报文计数
                    if (rx_valid[p] && rx_eop[p]) begin
                        rx_packets[p] <= rx_packets[p] + 1;
                        rx_octets[p] <= rx_octets[p] + {48'b0, rx_pkt_bytes};
                        
                        // 目的地址分类
                        if (rx_dmac == 48'hFFFFFFFFFFFF) begin
                            rx_broadcast[p] <= rx_broadcast[p] + 1;
                        end else if (rx_dmac[40]) begin  // 组播位
                            rx_multicast[p] <= rx_multicast[p] + 1;
                        end else begin
                            rx_unicast[p] <= rx_unicast[p] + 1;
                        end
                        
                        // PAUSE帧检测 (目的MAC = 01:80:C2:00:00:01)
                        if (rx_dmac == 48'h0180C2000001) begin
                            rx_pause[p] <= rx_pause[p] + 1;
                        end
                        
                        // 长度分布
                        case (1'b1)
                            (rx_pkt_bytes == 64):              rx_64b[p] <= rx_64b[p] + 1;
                            (rx_pkt_bytes >= 65 && rx_pkt_bytes <= 127):   rx_65_127b[p] <= rx_65_127b[p] + 1;
                            (rx_pkt_bytes >= 128 && rx_pkt_bytes <= 255):  rx_128_255b[p] <= rx_128_255b[p] + 1;
                            (rx_pkt_bytes >= 256 && rx_pkt_bytes <= 511):  rx_256_511b[p] <= rx_256_511b[p] + 1;
                            (rx_pkt_bytes >= 512 && rx_pkt_bytes <= 1023): rx_512_1023b[p] <= rx_512_1023b[p] + 1;
                            (rx_pkt_bytes >= 1024 && rx_pkt_bytes <= 1518): rx_1024_1518b[p] <= rx_1024_1518b[p] + 1;
                            (rx_pkt_bytes > 1518):             rx_1519_plus[p] <= rx_1519_plus[p] + 1;
                            default: ;
                        endcase
                        
                        // 长度异常
                        if (rx_pkt_bytes > 1518) begin
                            rx_oversize[p] <= rx_oversize[p] + 1;
                        end
                    end
                    
                    // 错误统计
                    if (rx_error[p]) rx_errors[p] <= rx_errors[p] + 1;
                    if (rx_crc_error[p]) rx_crc_errors[p] <= rx_crc_errors[p] + 1;
                    if (rx_align_error[p]) rx_align_errors[p] <= rx_align_errors[p] + 1;
                    if (rx_overrun[p]) rx_overrun_cnt[p] <= rx_overrun_cnt[p] + 1;
                    if (rx_jabber[p]) rx_jabber_cnt[p] <= rx_jabber_cnt[p] + 1;
                    if (rx_undersize[p]) rx_undersize_cnt[p] <= rx_undersize_cnt[p] + 1;
                    if (rx_fragment[p]) rx_fragment_cnt[p] <= rx_fragment_cnt[p] + 1;
                    if (rx_drop[p]) rx_drops[p] <= rx_drops[p] + 1;
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // Tx统计逻辑
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_tx_stats
            // 报文字节计数
            logic [15:0] tx_pkt_bytes;
            logic tx_pkt_active;
            logic [47:0] tx_dmac;
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tx_pkt_bytes <= '0;
                    tx_pkt_active <= 1'b0;
                    tx_dmac <= '0;
                end else begin
                    if (tx_valid[p]) begin
                        if (tx_sop[p]) begin
                            tx_pkt_bytes <= 8;
                            tx_pkt_active <= 1'b1;
                            tx_dmac <= tx_data[p][47:0];
                        end else if (tx_pkt_active) begin
                            tx_pkt_bytes <= tx_pkt_bytes + 8 - {13'b0, tx_empty[p]};
                        end
                        
                        if (tx_eop[p]) begin
                            tx_pkt_active <= 1'b0;
                        end
                    end
                end
            end
            
            // 统计更新
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n || (clear_req && clear_port == p[PORT_WIDTH-1:0])) begin
                    tx_packets[p] <= '0;
                    tx_octets[p] <= '0;
                    tx_unicast[p] <= '0;
                    tx_multicast[p] <= '0;
                    tx_broadcast[p] <= '0;
                    tx_pause[p] <= '0;
                    tx_errors[p] <= '0;
                    tx_collision_cnt[p] <= '0;
                    tx_late_collision_cnt[p] <= '0;
                    tx_excessive_collision_cnt[p] <= '0;
                    tx_underrun_cnt[p] <= '0;
                    tx_drops[p] <= '0;
                    tx_64b[p] <= '0;
                    tx_65_127b[p] <= '0;
                    tx_128_255b[p] <= '0;
                    tx_256_511b[p] <= '0;
                    tx_512_1023b[p] <= '0;
                    tx_1024_1518b[p] <= '0;
                    tx_1519_plus[p] <= '0;
                end else begin
                    // 报文计数
                    if (tx_valid[p] && tx_eop[p]) begin
                        tx_packets[p] <= tx_packets[p] + 1;
                        tx_octets[p] <= tx_octets[p] + {48'b0, tx_pkt_bytes};
                        
                        // 目的地址分类
                        if (tx_dmac == 48'hFFFFFFFFFFFF) begin
                            tx_broadcast[p] <= tx_broadcast[p] + 1;
                        end else if (tx_dmac[40]) begin
                            tx_multicast[p] <= tx_multicast[p] + 1;
                        end else begin
                            tx_unicast[p] <= tx_unicast[p] + 1;
                        end
                        
                        // PAUSE帧
                        if (tx_dmac == 48'h0180C2000001) begin
                            tx_pause[p] <= tx_pause[p] + 1;
                        end
                        
                        // 长度分布
                        case (1'b1)
                            (tx_pkt_bytes == 64):              tx_64b[p] <= tx_64b[p] + 1;
                            (tx_pkt_bytes >= 65 && tx_pkt_bytes <= 127):   tx_65_127b[p] <= tx_65_127b[p] + 1;
                            (tx_pkt_bytes >= 128 && tx_pkt_bytes <= 255):  tx_128_255b[p] <= tx_128_255b[p] + 1;
                            (tx_pkt_bytes >= 256 && tx_pkt_bytes <= 511):  tx_256_511b[p] <= tx_256_511b[p] + 1;
                            (tx_pkt_bytes >= 512 && tx_pkt_bytes <= 1023): tx_512_1023b[p] <= tx_512_1023b[p] + 1;
                            (tx_pkt_bytes >= 1024 && tx_pkt_bytes <= 1518): tx_1024_1518b[p] <= tx_1024_1518b[p] + 1;
                            (tx_pkt_bytes > 1518):             tx_1519_plus[p] <= tx_1519_plus[p] + 1;
                            default: ;
                        endcase
                    end
                    
                    // 错误统计
                    if (tx_error[p]) tx_errors[p] <= tx_errors[p] + 1;
                    if (tx_collision[p]) tx_collision_cnt[p] <= tx_collision_cnt[p] + 1;
                    if (tx_late_collision[p]) tx_late_collision_cnt[p] <= tx_late_collision_cnt[p] + 1;
                    if (tx_excessive_collision[p]) tx_excessive_collision_cnt[p] <= tx_excessive_collision_cnt[p] + 1;
                    if (tx_underrun[p]) tx_underrun_cnt[p] <= tx_underrun_cnt[p] + 1;
                    if (tx_drop[p]) tx_drops[p] <= tx_drops[p] + 1;
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 读取接口
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        case (read_counter_id)
            // Rx counters
            CNT_RX_PACKETS:       read_counter_value <= rx_packets[read_port];
            CNT_RX_OCTETS:        read_counter_value <= rx_octets[read_port];
            CNT_RX_UNICAST:       read_counter_value <= rx_unicast[read_port];
            CNT_RX_MULTICAST:     read_counter_value <= rx_multicast[read_port];
            CNT_RX_BROADCAST:     read_counter_value <= rx_broadcast[read_port];
            CNT_RX_PAUSE:         read_counter_value <= rx_pause[read_port];
            CNT_RX_UNDERSIZE:     read_counter_value <= rx_undersize_cnt[read_port];
            CNT_RX_FRAGMENT:      read_counter_value <= rx_fragment_cnt[read_port];
            CNT_RX_OVERSIZE:      read_counter_value <= rx_oversize[read_port];
            CNT_RX_JABBER:        read_counter_value <= rx_jabber_cnt[read_port];
            CNT_RX_ERRORS:        read_counter_value <= rx_errors[read_port];
            CNT_RX_CRC_ERRORS:    read_counter_value <= rx_crc_errors[read_port];
            CNT_RX_ALIGN_ERRORS:  read_counter_value <= rx_align_errors[read_port];
            CNT_RX_OVERRUN:       read_counter_value <= rx_overrun_cnt[read_port];
            CNT_RX_DROPS:         read_counter_value <= rx_drops[read_port];
            CNT_RX_64B:           read_counter_value <= rx_64b[read_port];
            CNT_RX_65_127B:       read_counter_value <= rx_65_127b[read_port];
            CNT_RX_128_255B:      read_counter_value <= rx_128_255b[read_port];
            CNT_RX_256_511B:      read_counter_value <= rx_256_511b[read_port];
            CNT_RX_512_1023B:     read_counter_value <= rx_512_1023b[read_port];
            CNT_RX_1024_1518B:    read_counter_value <= rx_1024_1518b[read_port];
            CNT_RX_1519_PLUS:     read_counter_value <= rx_1519_plus[read_port];
            
            // Tx counters
            CNT_TX_PACKETS:       read_counter_value <= tx_packets[read_port];
            CNT_TX_OCTETS:        read_counter_value <= tx_octets[read_port];
            CNT_TX_UNICAST:       read_counter_value <= tx_unicast[read_port];
            CNT_TX_MULTICAST:     read_counter_value <= tx_multicast[read_port];
            CNT_TX_BROADCAST:     read_counter_value <= tx_broadcast[read_port];
            CNT_TX_PAUSE:         read_counter_value <= tx_pause[read_port];
            CNT_TX_ERRORS:        read_counter_value <= tx_errors[read_port];
            CNT_TX_COLLISION:     read_counter_value <= tx_collision_cnt[read_port];
            CNT_TX_LATE_COLLISION: read_counter_value <= tx_late_collision_cnt[read_port];
            CNT_TX_EXCESSIVE_COLLISION: read_counter_value <= tx_excessive_collision_cnt[read_port];
            CNT_TX_UNDERRUN:      read_counter_value <= tx_underrun_cnt[read_port];
            CNT_TX_DROPS:         read_counter_value <= tx_drops[read_port];
            CNT_TX_64B:           read_counter_value <= tx_64b[read_port];
            CNT_TX_65_127B:       read_counter_value <= tx_65_127b[read_port];
            CNT_TX_128_255B:      read_counter_value <= tx_128_255b[read_port];
            CNT_TX_256_511B:      read_counter_value <= tx_256_511b[read_port];
            CNT_TX_512_1023B:     read_counter_value <= tx_512_1023b[read_port];
            CNT_TX_1024_1518B:    read_counter_value <= tx_1024_1518b[read_port];
            CNT_TX_1519_PLUS:     read_counter_value <= tx_1519_plus[read_port];
            
            default: read_counter_value <= '0;
        endcase
    end
    
    //------------------------------------------------------------------------
    // 清零确认
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_done <= 1'b0;
        end else begin
            clear_done <= clear_req;
        end
    end

endmodule : port_statistics
