//============================================================================
// Cell Allocator - Cell分配器
// 功能: 管理64K个128B Cells，支持4路并行分配
//============================================================================
`timescale 1ns/1ps

module cell_allocator
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 分配接口 (4路并行)
    input  cell_alloc_req_t           alloc_req  [NUM_FREE_POOLS-1:0],
    output cell_alloc_resp_t          alloc_resp [NUM_FREE_POOLS-1:0],
    
    // 释放接口 (4路并行)
    input  cell_free_req_t            free_req   [NUM_FREE_POOLS-1:0],
    output logic [NUM_FREE_POOLS-1:0] free_ack,
    
    // Cell元数据访问
    input  logic                      meta_rd_en,
    input  logic [CELL_ID_WIDTH-1:0]  meta_rd_addr,
    output cell_meta_t                meta_rd_data,
    
    input  logic                      meta_wr_en,
    input  logic [CELL_ID_WIDTH-1:0]  meta_wr_addr,
    input  cell_meta_t                meta_wr_data,
    
    // 状态
    output logic [CELL_ID_WIDTH:0]    free_count,
    output logic                      nearly_full,
    output logic                      nearly_empty,
    output logic                      init_done       // 初始化完成信号
);

    //------------------------------------------------------------------------
    // 参数
    //------------------------------------------------------------------------
    localparam int CELLS_PER_POOL = TOTAL_CELLS / NUM_FREE_POOLS;  // 16K per pool
    localparam int POOL_ID_WIDTH = 2;
    localparam int LOW_WATERMARK = 1024;   // 低水位
    localparam int HIGH_WATERMARK = TOTAL_CELLS - 1024;  // 高水位

    //------------------------------------------------------------------------
    // 空闲链表结构
    //------------------------------------------------------------------------
    typedef struct packed {
        logic [CELL_ID_WIDTH-1:0] head;
        logic [CELL_ID_WIDTH-1:0] tail;
        logic [CELL_ID_WIDTH-1:0] count;
    } free_list_t;
    
    free_list_t free_lists [NUM_FREE_POOLS-1:0];
    
    //------------------------------------------------------------------------
    // Cell元数据存储 (SRAM)
    //------------------------------------------------------------------------
    cell_meta_t cell_meta_mem [TOTAL_CELLS-1:0];
    
    // 元数据读取
    always_ff @(posedge clk) begin
        if (meta_rd_en) begin
            meta_rd_data <= cell_meta_mem[meta_rd_addr];
        end
    end
    
    // 元数据写入 (初始化期间由init状态机控制)
    always_ff @(posedge clk) begin
        if (init_wr_en) begin
            cell_meta_mem[init_wr_addr] <= '0;
        end else if (meta_wr_en) begin
            cell_meta_mem[meta_wr_addr] <= meta_wr_data;
        end
    end
    
    //------------------------------------------------------------------------
    // 空闲链表SRAM (存储next指针)
    //------------------------------------------------------------------------
    logic [CELL_ID_WIDTH-1:0] free_link_mem [TOTAL_CELLS-1:0];
    
    //------------------------------------------------------------------------
    // 初始化状态机
    //------------------------------------------------------------------------
    typedef enum logic [1:0] {
        INIT_IDLE,
        INIT_RUNNING,
        INIT_DONE
    } init_state_e;
    
    init_state_e init_state;
    logic [CELL_ID_WIDTH-1:0] init_cnt;
    logic init_wr_en;
    logic [CELL_ID_WIDTH-1:0] init_wr_addr;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_state <= INIT_IDLE;
            init_cnt <= '0;
            init_done <= 1'b0;
            init_wr_en <= 1'b0;
            init_wr_addr <= '0;
            
            // 复位空闲链表控制结构
            for (int pool = 0; pool < NUM_FREE_POOLS; pool++) begin
                free_lists[pool].head <= pool * CELLS_PER_POOL;
                free_lists[pool].tail <= (pool + 1) * CELLS_PER_POOL - 1;
                free_lists[pool].count <= CELLS_PER_POOL;
            end
            
        end else begin
            case (init_state)
                INIT_IDLE: begin
                    init_state <= INIT_RUNNING;
                    init_cnt <= '0;
                    init_wr_en <= 1'b1;
                    init_wr_addr <= '0;
                end
                
                INIT_RUNNING: begin
                    init_wr_en <= 1'b1;
                    init_wr_addr <= init_cnt;
                    
                    // 初始化free_link_mem: 每个cell指向下一个
                    if ((init_cnt + 1) % CELLS_PER_POOL == 0) begin
                        // 池的最后一个cell，next指针为无效
                        free_link_mem[init_cnt] <= '1;
                    end else begin
                        free_link_mem[init_cnt] <= init_cnt + 1;
                    end
                    
                    if (init_cnt == TOTAL_CELLS - 1) begin
                        init_state <= INIT_DONE;
                        init_wr_en <= 1'b0;
                    end else begin
                        init_cnt <= init_cnt + 1;
                    end
                end
                
                INIT_DONE: begin
                    init_done <= 1'b1;
                    init_wr_en <= 1'b0;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 分配逻辑 (每个池独立) - 需等待初始化完成
    //------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < NUM_FREE_POOLS; p++) begin : gen_alloc
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    alloc_resp[p].ack <= 1'b0;
                    alloc_resp[p].success <= 1'b0;
                    alloc_resp[p].cell_id <= '0;
                end else begin
                    alloc_resp[p].ack <= 1'b0;
                    
                    if (init_done && alloc_req[p].req) begin
                        alloc_resp[p].ack <= 1'b1;
                        
                        // 检查指定池是否有空闲Cell
                        if (free_lists[p].count > 0) begin
                            // 从链表头分配
                            alloc_resp[p].success <= 1'b1;
                            alloc_resp[p].cell_id <= free_lists[p].head;
                            
                            // 更新链表
                            free_lists[p].head <= free_link_mem[free_lists[p].head];
                            free_lists[p].count <= free_lists[p].count - 1;
                            
                            // 标记Cell为已使用
                            cell_meta_mem[free_lists[p].head].valid <= 1'b1;
                            
                        end else begin
                            // 池为空，尝试从其他池借用 (简化：返回失败)
                            alloc_resp[p].success <= 1'b0;
                            alloc_resp[p].cell_id <= '0;
                        end
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 释放逻辑 - 需等待初始化完成
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_FREE_POOLS; p++) begin : gen_free
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    free_ack[p] <= 1'b0;
                end else begin
                    free_ack[p] <= 1'b0;
                    
                    if (init_done && free_req[p].req) begin
                        // 归还到对应的池 (根据Cell ID低2位)
                        automatic logic [1:0] target_pool = free_req[p].cell_id[1:0];
                        
                        if (target_pool == p[1:0]) begin
                            free_ack[p] <= 1'b1;
                            
                            // 检查引用计数
                            if (cell_meta_mem[free_req[p].cell_id].ref_cnt > 0) begin
                                // 减少引用计数
                                cell_meta_mem[free_req[p].cell_id].ref_cnt <= 
                                    cell_meta_mem[free_req[p].cell_id].ref_cnt - 1;
                            end else begin
                                // 真正释放：加入链表尾
                                free_link_mem[free_lists[p].tail] <= free_req[p].cell_id;
                                free_link_mem[free_req[p].cell_id] <= '1;
                                free_lists[p].tail <= free_req[p].cell_id;
                                free_lists[p].count <= free_lists[p].count + 1;
                                
                                // 清除元数据
                                cell_meta_mem[free_req[p].cell_id].valid <= 1'b0;
                                cell_meta_mem[free_req[p].cell_id].next_ptr <= '0;
                                cell_meta_mem[free_req[p].cell_id].eop <= 1'b0;
                            end
                        end
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 统计
    //------------------------------------------------------------------------
    always_comb begin
        free_count = '0;
        for (int i = 0; i < NUM_FREE_POOLS; i++) begin
            free_count = free_count + {1'b0, free_lists[i].count};
        end
    end
    
    assign nearly_empty = (free_count < LOW_WATERMARK);
    assign nearly_full  = (free_count > HIGH_WATERMARK);

endmodule : cell_allocator
