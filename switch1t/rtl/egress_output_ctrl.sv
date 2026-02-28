//============================================================================
// Egress Output Controller - 出向输出控制器
// 功能: 从报文缓冲区读取数据，格式化输出到端口
//============================================================================
`timescale 1ns/1ps

module egress_output_ctrl
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 来自Egress调度器
    input  logic [NUM_PORTS-1:0]      deq_valid,
    input  logic [DESC_ID_WIDTH-1:0]  deq_desc_id [NUM_PORTS-1:0],
    input  logic [QUEUE_ID_WIDTH-1:0] deq_queue [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      deq_ack,
    
    // 到报文缓冲区读取接口
    output logic                      buf_rd_req,
    output logic [DESC_ID_WIDTH-1:0]  buf_rd_desc_id,
    input  logic                      buf_rd_valid,
    input  logic                      buf_rd_sop,
    input  logic                      buf_rd_eop,
    input  logic [CELL_SIZE_BITS-1:0] buf_rd_data,
    output logic                      buf_rd_ready,
    
    // 描述符访问
    input  pkt_desc_t                 desc_rd_data [NUM_PORTS-1:0],
    
    // 报文释放接口
    output logic                      release_req,
    output logic [DESC_ID_WIDTH-1:0]  release_desc_id,
    input  logic                      release_done,
    
    // 端口输出接口
    output logic [NUM_PORTS-1:0]      port_tx_valid,
    output logic [NUM_PORTS-1:0]      port_tx_sop,
    output logic [NUM_PORTS-1:0]      port_tx_eop,
    output logic [63:0]               port_tx_data [NUM_PORTS-1:0],
    output logic [2:0]                port_tx_empty [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      port_tx_ready,
    
    // PAUSE帧插入接口 (优先级高于正常报文)
    input  logic [NUM_PORTS-1:0]      pause_tx_valid,
    input  logic [NUM_PORTS-1:0]      pause_tx_sop,
    input  logic [NUM_PORTS-1:0]      pause_tx_eop,
    input  logic [63:0]               pause_tx_data [NUM_PORTS-1:0],
    input  logic [2:0]                pause_tx_empty [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      pause_tx_ack,
    
    // 统计
    output logic [31:0]               stat_egr_out_pkts [NUM_PORTS-1:0]
);

    //------------------------------------------------------------------------
    // 每端口输出状态机
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        OUT_IDLE,
        OUT_REQ_PKT,
        OUT_WAIT_FIRST_CELL,
        OUT_STREAM_CELL,
        OUT_NEXT_CELL,
        OUT_RELEASE,
        OUT_WAIT_RELEASE
    } out_state_e;
    
    out_state_e out_state [NUM_PORTS-1:0];
    
    logic [DESC_ID_WIDTH-1:0]  out_desc_id [NUM_PORTS-1:0];
    logic [QUEUE_ID_WIDTH-1:0] out_queue [NUM_PORTS-1:0];
    logic [6:0]                out_cell_remain [NUM_PORTS-1:0];
    logic [CELL_SIZE_BITS-1:0] out_cell_data [NUM_PORTS-1:0];
    logic [7:0]                out_cell_bytes [NUM_PORTS-1:0];
    logic [3:0]                out_word_cnt [NUM_PORTS-1:0];  // Cell内8字节字计数
    
    //------------------------------------------------------------------------
    // 缓冲区读取仲裁 (轮询)
    //------------------------------------------------------------------------
    logic [PORT_WIDTH-1:0] buf_rd_port_rr;
    logic [PORT_WIDTH-1:0] buf_rd_grant_port;
    logic buf_rd_grant_valid;
    
    always_comb begin
        buf_rd_grant_valid = 1'b0;
        buf_rd_grant_port = '0;
        
        // 轮询查找需要读取的端口
        for (int i = 0; i < NUM_PORTS; i++) begin
            automatic int idx = (buf_rd_port_rr + i) % NUM_PORTS;
            if (out_state[idx] == OUT_REQ_PKT || out_state[idx] == OUT_NEXT_CELL) begin
                buf_rd_grant_valid = 1'b1;
                buf_rd_grant_port = idx[PORT_WIDTH-1:0];
                break;
            end
        end
    end
    
    assign buf_rd_req = buf_rd_grant_valid;
    assign buf_rd_desc_id = out_desc_id[buf_rd_grant_port];
    
    // 更新轮询指针
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_rd_port_rr <= '0;
        end else begin
            if (buf_rd_req && buf_rd_ready) begin
                buf_rd_port_rr <= (buf_rd_grant_port + 1) % NUM_PORTS;
            end
        end
    end
    
    // buf_rd_ready: 总是ready (简化)
    assign buf_rd_ready = 1'b1;
    
    //------------------------------------------------------------------------
    // 每端口输出逻辑
    //------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_egress_out
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_state[p] <= OUT_IDLE;
                    deq_ack[p] <= 1'b0;
                    port_tx_valid[p] <= 1'b0;
                    port_tx_sop[p] <= 1'b0;
                    port_tx_eop[p] <= 1'b0;
                    port_tx_data[p] <= '0;
                    port_tx_empty[p] <= '0;
                    pause_tx_ack[p] <= 1'b0;
                    release_req <= 1'b0;
                    out_word_cnt[p] <= '0;
                    stat_egr_out_pkts[p] <= '0;
                end else begin
                    deq_ack[p] <= 1'b0;
                    port_tx_valid[p] <= 1'b0;
                    port_tx_sop[p] <= 1'b0;
                    port_tx_eop[p] <= 1'b0;
                    pause_tx_ack[p] <= 1'b0;
                    release_req <= 1'b0;
                    
                    case (out_state[p])
                        OUT_IDLE: begin
                            // PAUSE帧优先级最高
                            if (pause_tx_valid[p]) begin
                                port_tx_valid[p] <= 1'b1;
                                port_tx_sop[p] <= pause_tx_sop[p];
                                port_tx_eop[p] <= pause_tx_eop[p];
                                port_tx_data[p] <= pause_tx_data[p];
                                port_tx_empty[p] <= pause_tx_empty[p];
                                
                                if (port_tx_ready[p]) begin
                                    pause_tx_ack[p] <= 1'b1;
                                end
                            end
                            // 正常报文出队
                            else if (deq_valid[p]) begin
                                out_desc_id[p] <= deq_desc_id[p];
                                out_queue[p] <= deq_queue[p];
                                deq_ack[p] <= 1'b1;
                                out_state[p] <= OUT_REQ_PKT;
                            end
                        end
                        
                        OUT_REQ_PKT: begin
                            // 等待缓冲区读取仲裁
                            if (buf_rd_grant_valid && buf_rd_grant_port == p[PORT_WIDTH-1:0]) begin
                                out_state[p] <= OUT_WAIT_FIRST_CELL;
                                out_cell_remain[p] <= desc_rd_data[p].cell_count;
                            end
                        end
                        
                        OUT_WAIT_FIRST_CELL: begin
                            // 等待第一个Cell数据
                            if (buf_rd_valid && buf_rd_sop) begin
                                out_cell_data[p] <= buf_rd_data;
                                out_cell_bytes[p] <= 8'd128;  // 假设Cell满
                                out_word_cnt[p] <= '0;
                                out_state[p] <= OUT_STREAM_CELL;
                            end
                        end
                        
                        OUT_STREAM_CELL: begin
                            // 流式输出Cell数据 (每周期8字节)
                            if (port_tx_ready[p]) begin
                                port_tx_valid[p] <= 1'b1;
                                
                                if (out_word_cnt[p] == 0) begin
                                    port_tx_sop[p] <= (out_cell_remain[p] == desc_rd_data[p].cell_count);
                                end
                                
                                // 提取8字节
                                port_tx_data[p] <= out_cell_data[p][out_word_cnt[p]*64 +: 64];
                                
                                // 检查是否为最后一个字
                                if (out_word_cnt[p] == 15 || 
                                    (out_word_cnt[p]+1)*8 >= out_cell_bytes[p]) begin
                                    
                                    // 检查是否为最后一个Cell
                                    if (out_cell_remain[p] == 1) begin
                                        port_tx_eop[p] <= 1'b1;
                                        // 计算empty字节
                                        begin
                                            int valid_bytes = out_cell_bytes[p] - out_word_cnt[p]*8;
                                            port_tx_empty[p] <= 8 - valid_bytes[2:0];
                                        end
                                        out_state[p] <= OUT_RELEASE;
                                    end else begin
                                        // 还有更多Cell
                                        out_cell_remain[p] <= out_cell_remain[p] - 1;
                                        out_state[p] <= OUT_NEXT_CELL;
                                    end
                                end else begin
                                    out_word_cnt[p] <= out_word_cnt[p] + 1;
                                end
                            end
                        end
                        
                        OUT_NEXT_CELL: begin
                            // 请求读取下一个Cell
                            if (buf_rd_grant_valid && buf_rd_grant_port == p[PORT_WIDTH-1:0]) begin
                                out_state[p] <= OUT_WAIT_FIRST_CELL;
                            end
                        end
                        
                        OUT_RELEASE: begin
                            // 释放描述符和Cell
                            release_req <= 1'b1;
                            release_desc_id <= out_desc_id[p];
                            stat_egr_out_pkts[p] <= stat_egr_out_pkts[p] + 1;
                            out_state[p] <= OUT_WAIT_RELEASE;
                        end
                        
                        OUT_WAIT_RELEASE: begin
                            if (release_done) begin
                                out_state[p] <= OUT_IDLE;
                            end
                        end
                    endcase
                end
            end
        end
    endgenerate

endmodule : egress_output_ctrl
