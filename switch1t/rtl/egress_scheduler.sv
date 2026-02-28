//============================================================================
// Egress Scheduler - 出向调度器
// 功能: 384队列(48端口×8优先级), SP+WRR两级调度, WRED拥塞控制
//============================================================================
`timescale 1ns/1ps

module egress_scheduler
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 入队接口
    input  logic                      enq_req,
    input  logic [PORT_WIDTH-1:0]     enq_port,
    input  logic [QUEUE_ID_WIDTH-1:0] enq_queue,
    input  logic [DESC_ID_WIDTH-1:0]  enq_desc_id,
    input  logic [6:0]                enq_cell_count,
    output logic                      enq_ack,
    output logic                      enq_drop,  // WRED丢弃
    
    // 出队接口 (每端口)
    input  logic [NUM_PORTS-1:0]      deq_req,
    output logic [NUM_PORTS-1:0]      deq_valid,
    output logic [DESC_ID_WIDTH-1:0]  deq_desc_id [NUM_PORTS-1:0],
    output logic [QUEUE_ID_WIDTH-1:0] deq_queue [NUM_PORTS-1:0],
    
    // Flow Control - 端口暂停状态
    input  logic [NUM_PORTS-1:0]      port_paused,
    
    // 队列状态查询
    input  logic [PORT_WIDTH-1:0]     query_port,
    input  logic [QUEUE_ID_WIDTH-1:0] query_queue,
    output logic [15:0]               query_depth,
    output queue_state_e              query_state,
    
    // WRED配置
    input  logic [15:0]               wred_min_th,
    input  logic [15:0]               wred_max_th,
    input  logic [7:0]                wred_max_prob,  // 0-255 映射到 0-100%
    
    // 统计
    output logic [31:0]               stat_enq_count,
    output logic [31:0]               stat_deq_count,
    output logic [31:0]               stat_drop_count
);

    //------------------------------------------------------------------------
    // 队列存储
    //------------------------------------------------------------------------
    // 队列描述符
    queue_desc_t queue_desc [NUM_PORTS-1:0][NUM_QUEUES_PER_PORT-1:0];
    
    // 队列链表 (描述符ID链表)
    logic [DESC_ID_WIDTH-1:0] queue_link [DESC_POOL_SIZE-1:0];
    
    //------------------------------------------------------------------------
    // WRR权重配置 - 通过复位初始化
    //------------------------------------------------------------------------
    // Q7/Q6: Strict Priority
    // Q5~Q0: WRR权重 [8,4,2,2,1,1]
    logic [3:0] wrr_weight [5:0];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wrr_weight[5] <= 4'd8;  // Q5
            wrr_weight[4] <= 4'd4;  // Q4
            wrr_weight[3] <= 4'd2;  // Q3
            wrr_weight[2] <= 4'd2;  // Q2
            wrr_weight[1] <= 4'd1;  // Q1
            wrr_weight[0] <= 4'd1;  // Q0
        end
    end
    
    // 每端口WRR计数器
    logic [3:0] wrr_counter [NUM_PORTS-1:0][5:0];
    
    //------------------------------------------------------------------------
    // WRED随机数生成 (LFSR)
    //------------------------------------------------------------------------
    logic [15:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 16'hACE1;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3]};
        end
    end
    
    //------------------------------------------------------------------------
    // 入队逻辑
    //------------------------------------------------------------------------
    typedef enum logic [1:0] {
        ENQ_IDLE,
        ENQ_CHECK,
        ENQ_WRITE,
        ENQ_DONE
    } enq_state_e;
    
    enq_state_e enq_state;
    
    logic [PORT_WIDTH-1:0]     enq_port_r;
    logic [QUEUE_ID_WIDTH-1:0] enq_queue_r;
    logic [DESC_ID_WIDTH-1:0]  enq_desc_id_r;
    logic [6:0]                enq_cell_count_r;
    logic                      enq_wred_drop;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enq_state <= ENQ_IDLE;
            enq_ack <= 1'b0;
            enq_drop <= 1'b0;
        end else begin
            enq_ack <= 1'b0;
            enq_drop <= 1'b0;
            
            case (enq_state)
                ENQ_IDLE: begin
                    if (q_init_done && enq_req) begin
                        enq_port_r <= enq_port;
                        enq_queue_r <= enq_queue;
                        enq_desc_id_r <= enq_desc_id;
                        enq_cell_count_r <= enq_cell_count;
                        enq_state <= ENQ_CHECK;
                    end
                end
                
                ENQ_CHECK: begin
                    // WRED检查
                    automatic logic [15:0] q_len = queue_desc[enq_port_r][enq_queue_r].length;
                    automatic logic wred_drop_decision = 1'b0;
                    
                    if (q_len >= wred_max_th) begin
                        // 尾部丢弃
                        wred_drop_decision = 1'b1;
                    end else if (q_len >= wred_min_th) begin
                        // 概率丢弃
                        automatic logic [15:0] range = wred_max_th - wred_min_th;
                        automatic logic [15:0] over = q_len - wred_min_th;
                        automatic logic [23:0] prob = (over * wred_max_prob) / range;
                        if (lfsr[7:0] < prob[7:0]) begin
                            wred_drop_decision = 1'b1;
                        end
                    end
                    
                    enq_wred_drop <= wred_drop_decision;
                    
                    if (wred_drop_decision) begin
                        enq_drop <= 1'b1;
                        enq_ack <= 1'b1;
                        enq_state <= ENQ_IDLE;
                    end else begin
                        enq_state <= ENQ_WRITE;
                    end
                end
                
                ENQ_WRITE: begin
                    automatic queue_desc_t q = queue_desc[enq_port_r][enq_queue_r];
                    
                    // 更新队列
                    if (q.state == Q_STATE_EMPTY) begin
                        // 队列为空
                        queue_desc[enq_port_r][enq_queue_r].head <= enq_desc_id_r;
                        queue_desc[enq_port_r][enq_queue_r].tail <= enq_desc_id_r;
                        queue_desc[enq_port_r][enq_queue_r].state <= Q_STATE_NORMAL;
                    end else begin
                        // 链接到队列尾
                        queue_link[q.tail] <= enq_desc_id_r;
                        queue_desc[enq_port_r][enq_queue_r].tail <= enq_desc_id_r;
                    end
                    
                    // 更新队列长度
                    queue_desc[enq_port_r][enq_queue_r].length <= 
                        queue_desc[enq_port_r][enq_queue_r].length + {9'b0, enq_cell_count_r};
                    
                    // 标记链表尾
                    queue_link[enq_desc_id_r] <= '1;
                    
                    enq_state <= ENQ_DONE;
                end
                
                ENQ_DONE: begin
                    enq_ack <= 1'b1;
                    enq_state <= ENQ_IDLE;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 出队逻辑 (每端口独立)
    //------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_deq
            
            typedef enum logic [1:0] {
                DEQ_IDLE,
                DEQ_SELECT,
                DEQ_READ,
                DEQ_OUTPUT
            } deq_state_e;
            
            deq_state_e deq_state;
            logic [QUEUE_ID_WIDTH-1:0] selected_queue;
            logic selected_valid;
            
            // 队列选择逻辑 (SP + WRR)
            always_comb begin
                selected_queue = '0;
                selected_valid = 1'b0;
                
                // Strict Priority: Q7, Q6
                if (queue_desc[p][7].state != Q_STATE_EMPTY) begin
                    selected_queue = 3'd7;
                    selected_valid = 1'b1;
                end else if (queue_desc[p][6].state != Q_STATE_EMPTY) begin
                    selected_queue = 3'd6;
                    selected_valid = 1'b1;
                end else begin
                    // WRR: Q5~Q0
                    for (int q = 5; q >= 0; q--) begin
                        if (queue_desc[p][q].state != Q_STATE_EMPTY) begin
                            if (wrr_counter[p][q] < wrr_weight[q]) begin
                                selected_queue = q[2:0];
                                selected_valid = 1'b1;
                                break;
                            end
                        end
                    end
                end
            end
            
            // 出队状态机
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    deq_state <= DEQ_IDLE;
                    deq_valid[p] <= 1'b0;
                    deq_desc_id[p] <= '0;
                    deq_queue[p] <= '0;
                    for (int q = 0; q < 6; q++) begin
                        wrr_counter[p][q] <= '0;
                    end
                end else begin
                    deq_valid[p] <= 1'b0;
                    
                    case (deq_state)
                        DEQ_IDLE: begin
                            // Flow Control: 检查端口是否被PAUSE
                            if (deq_req[p] && !port_paused[p]) begin
                                deq_state <= DEQ_SELECT;
                            end
                        end
                        
                        DEQ_SELECT: begin
                            if (selected_valid) begin
                                deq_state <= DEQ_READ;
                            end else begin
                                deq_state <= DEQ_IDLE;
                            end
                        end
                        
                        DEQ_READ: begin
                            // 读取队列头
                            deq_desc_id[p] <= queue_desc[p][selected_queue].head;
                            deq_queue[p] <= selected_queue;
                            
                            // 更新队列头
                            queue_desc[p][selected_queue].head <= queue_link[queue_desc[p][selected_queue].head];
                            
                            // 检查队列是否变空
                            if (queue_desc[p][selected_queue].head == queue_desc[p][selected_queue].tail) begin
                                queue_desc[p][selected_queue].state <= Q_STATE_EMPTY;
                                queue_desc[p][selected_queue].length <= '0;
                            end
                            
                            // 更新WRR计数器
                            if (selected_queue <= 3'd5) begin
                                wrr_counter[p][selected_queue] <= wrr_counter[p][selected_queue] + 1;
                                // 检查是否需要重置
                                if (wrr_counter[p][selected_queue] >= wrr_weight[selected_queue] - 1) begin
                                    wrr_counter[p][selected_queue] <= '0;
                                end
                            end
                            
                            deq_state <= DEQ_OUTPUT;
                        end
                        
                        DEQ_OUTPUT: begin
                            deq_valid[p] <= 1'b1;
                            deq_state <= DEQ_IDLE;
                        end
                    endcase
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 队列状态查询
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        query_depth <= queue_desc[query_port][query_queue].length;
        query_state <= queue_desc[query_port][query_queue].state;
    end
    
    //------------------------------------------------------------------------
    // 统计计数器
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_enq_count <= '0;
            stat_deq_count <= '0;
            stat_drop_count <= '0;
        end else begin
            if (enq_ack && !enq_drop) begin
                stat_enq_count <= stat_enq_count + 1;
            end
            if (enq_drop) begin
                stat_drop_count <= stat_drop_count + 1;
            end
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (deq_valid[i]) begin
                    stat_deq_count <= stat_deq_count + 1;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 初始化队列描述符 - 通过状态机完成
    //------------------------------------------------------------------------
    typedef enum logic [1:0] {
        Q_INIT_IDLE,
        Q_INIT_QUEUE,
        Q_INIT_LINK,
        Q_INIT_DONE
    } q_init_state_e;
    
    q_init_state_e q_init_state;
    logic [PORT_WIDTH-1:0] init_port_cnt;
    logic [QUEUE_ID_WIDTH-1:0] init_queue_cnt;
    logic [DESC_ID_WIDTH-1:0] init_link_cnt;
    logic q_init_done;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_init_state <= Q_INIT_IDLE;
            init_port_cnt <= '0;
            init_queue_cnt <= '0;
            init_link_cnt <= '0;
            q_init_done <= 1'b0;
        end else begin
            case (q_init_state)
                Q_INIT_IDLE: begin
                    q_init_state <= Q_INIT_QUEUE;
                    init_port_cnt <= '0;
                    init_queue_cnt <= '0;
                end
                
                Q_INIT_QUEUE: begin
                    // 初始化队列描述符
                    queue_desc[init_port_cnt][init_queue_cnt] <= '0;
                    queue_desc[init_port_cnt][init_queue_cnt].state <= Q_STATE_EMPTY;
                    
                    if (init_queue_cnt == NUM_QUEUES_PER_PORT - 1) begin
                        init_queue_cnt <= '0;
                        if (init_port_cnt == NUM_PORTS - 1) begin
                            q_init_state <= Q_INIT_LINK;
                            init_link_cnt <= '0;
                        end else begin
                            init_port_cnt <= init_port_cnt + 1;
                        end
                    end else begin
                        init_queue_cnt <= init_queue_cnt + 1;
                    end
                end
                
                Q_INIT_LINK: begin
                    // 初始化队列链表
                    queue_link[init_link_cnt] <= '1;
                    
                    if (init_link_cnt == DESC_POOL_SIZE - 1) begin
                        q_init_state <= Q_INIT_DONE;
                    end else begin
                        init_link_cnt <= init_link_cnt + 1;
                    end
                end
                
                Q_INIT_DONE: begin
                    q_init_done <= 1'b1;
                end
            endcase
        end
    end

endmodule : egress_scheduler
