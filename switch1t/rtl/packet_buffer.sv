//============================================================================
// Packet Buffer - 报文缓冲区
// 功能: 报文存储和读取，管理Cell链表
//============================================================================
`timescale 1ns/1ps

module packet_buffer
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 报文写入接口
    input  logic                      wr_pkt_valid,
    input  logic                      wr_pkt_sop,     // Start of Packet
    input  logic                      wr_pkt_eop,     // End of Packet
    input  logic [CELL_SIZE_BITS-1:0] wr_pkt_data,
    input  logic [6:0]                wr_pkt_len,     // 本Cell有效字节数
    input  logic [PORT_WIDTH-1:0]     wr_src_port,
    output logic                      wr_pkt_ready,
    output logic [DESC_ID_WIDTH-1:0]  wr_desc_id,     // 分配的描述符ID
    output logic                      wr_desc_valid,
    
    // 报文读取接口
    input  logic                      rd_pkt_req,
    input  logic [DESC_ID_WIDTH-1:0]  rd_desc_id,
    output logic                      rd_pkt_valid,
    output logic                      rd_pkt_sop,
    output logic                      rd_pkt_eop,
    output logic [CELL_SIZE_BITS-1:0] rd_pkt_data,
    output logic                      rd_pkt_ready,
    
    // 描述符访问
    input  logic [DESC_ID_WIDTH-1:0]  desc_rd_addr,
    output pkt_desc_t                 desc_rd_data,
    input  logic                      desc_wr_en,
    input  logic [DESC_ID_WIDTH-1:0]  desc_wr_addr,
    input  pkt_desc_t                 desc_wr_data,
    
    // 释放接口
    input  logic                      release_req,
    input  logic [DESC_ID_WIDTH-1:0]  release_desc_id,
    output logic                      release_done,
    
    // Cell分配器接口
    output cell_alloc_req_t           cell_alloc_req,
    input  cell_alloc_resp_t          cell_alloc_resp,
    output cell_free_req_t            cell_free_req,
    input  logic                      cell_free_ack,
    
    // 内存接口
    output mem_req_t                  mem_req,
    input  mem_resp_t                 mem_resp
);

    //------------------------------------------------------------------------
    // 描述符存储
    //------------------------------------------------------------------------
    pkt_desc_t desc_mem [DESC_POOL_SIZE-1:0];
    
    // 描述符空闲链表
    logic [DESC_ID_WIDTH-1:0] desc_free_head;
    logic [DESC_ID_WIDTH-1:0] desc_free_tail;
    logic [DESC_ID_WIDTH:0]   desc_free_count;
    logic [DESC_ID_WIDTH-1:0] desc_free_link [DESC_POOL_SIZE-1:0];
    
    //------------------------------------------------------------------------
    // 状态机
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        WR_IDLE,
        WR_ALLOC_DESC,
        WR_ALLOC_CELL,
        WR_WRITE_DATA,
        WR_LINK_CELL,
        WR_DONE
    } wr_state_e;
    
    typedef enum logic [2:0] {
        RD_IDLE,
        RD_READ_DESC,
        RD_READ_CELL,
        RD_OUTPUT,
        RD_NEXT_CELL
    } rd_state_e;
    
    typedef enum logic [1:0] {
        REL_IDLE,
        REL_READ_DESC,
        REL_FREE_CELLS,
        REL_FREE_DESC
    } rel_state_e;
    
    wr_state_e  wr_state, wr_state_next;
    rd_state_e  rd_state, rd_state_next;
    rel_state_e rel_state, rel_state_next;
    
    //------------------------------------------------------------------------
    // 写入控制寄存器
    //------------------------------------------------------------------------
    logic [DESC_ID_WIDTH-1:0]  wr_cur_desc_id;
    logic [CELL_ID_WIDTH-1:0]  wr_first_cell_id;
    logic [CELL_ID_WIDTH-1:0]  wr_prev_cell_id;
    logic [CELL_ID_WIDTH-1:0]  wr_cur_cell_id;
    logic [6:0]                wr_cell_count;
    logic [PKT_LEN_WIDTH-1:0]  wr_total_len;
    logic                      wr_is_first_cell;
    
    //------------------------------------------------------------------------
    // 读取控制寄存器
    //------------------------------------------------------------------------
    logic [DESC_ID_WIDTH-1:0]  rd_cur_desc_id;
    logic [CELL_ID_WIDTH-1:0]  rd_cur_cell_id;
    logic [CELL_ID_WIDTH-1:0]  rd_next_cell_id;
    pkt_desc_t                 rd_cur_desc;
    logic                      rd_is_first_cell;
    logic                      rd_is_last_cell;
    
    //------------------------------------------------------------------------
    // 释放控制寄存器
    //------------------------------------------------------------------------
    logic [DESC_ID_WIDTH-1:0]  rel_cur_desc_id;
    logic [CELL_ID_WIDTH-1:0]  rel_cur_cell_id;
    logic [CELL_ID_WIDTH-1:0]  rel_next_cell_id;
    pkt_desc_t                 rel_cur_desc;
    
    //------------------------------------------------------------------------
    // 初始化状态机
    //------------------------------------------------------------------------
    typedef enum logic [1:0] {
        DESC_INIT_IDLE,
        DESC_INIT_RUNNING,
        DESC_INIT_DONE
    } desc_init_state_e;
    
    desc_init_state_e desc_init_state;
    logic [DESC_ID_WIDTH-1:0] desc_init_cnt;
    logic desc_init_done;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            desc_init_state <= DESC_INIT_IDLE;
            desc_init_cnt <= '0;
            desc_init_done <= 1'b0;
            desc_free_head <= '0;
            desc_free_tail <= DESC_POOL_SIZE - 1;
            desc_free_count <= DESC_POOL_SIZE;
        end else begin
            case (desc_init_state)
                DESC_INIT_IDLE: begin
                    desc_init_state <= DESC_INIT_RUNNING;
                    desc_init_cnt <= '0;
                end
                
                DESC_INIT_RUNNING: begin
                    // 初始化空闲链表
                    if (desc_init_cnt < DESC_POOL_SIZE - 1) begin
                        desc_free_link[desc_init_cnt] <= desc_init_cnt + 1;
                    end else begin
                        desc_free_link[desc_init_cnt] <= '1;  // 尾部标记
                    end
                    desc_mem[desc_init_cnt] <= '0;
                    
                    if (desc_init_cnt == DESC_POOL_SIZE - 1) begin
                        desc_init_state <= DESC_INIT_DONE;
                    end else begin
                        desc_init_cnt <= desc_init_cnt + 1;
                    end
                end
                
                DESC_INIT_DONE: begin
                    desc_init_done <= 1'b1;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 写入状态机 - 需等待初始化完成
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state <= WR_IDLE;
        end else begin
            wr_state <= wr_state_next;
        end
    end
    
    always_comb begin
        wr_state_next = wr_state;
        wr_pkt_ready = 1'b0;
        wr_desc_valid = 1'b0;
        cell_alloc_req.req = 1'b0;
        cell_alloc_req.pool_hint = '0;
        mem_req.req = 1'b0;
        mem_req.wr_en = 1'b0;
        mem_req.cell_id = '0;
        mem_req.wr_data = '0;
        
        case (wr_state)
            WR_IDLE: begin
                wr_pkt_ready = desc_init_done && (desc_free_count > 0);
                if (desc_init_done && wr_pkt_valid && wr_pkt_sop && desc_free_count > 0) begin
                    wr_state_next = WR_ALLOC_DESC;
                end
            end
            
            WR_ALLOC_DESC: begin
                // 分配描述符 (组合逻辑完成)
                wr_state_next = WR_ALLOC_CELL;
            end
            
            WR_ALLOC_CELL: begin
                cell_alloc_req.req = 1'b1;
                cell_alloc_req.pool_hint = wr_src_port[1:0];
                if (cell_alloc_resp.ack && cell_alloc_resp.success) begin
                    wr_state_next = WR_WRITE_DATA;
                end
            end
            
            WR_WRITE_DATA: begin
                mem_req.req = 1'b1;
                mem_req.wr_en = 1'b1;
                mem_req.cell_id = wr_cur_cell_id;
                mem_req.wr_data = wr_pkt_data;
                if (mem_resp.ack) begin
                    wr_state_next = WR_LINK_CELL;
                end
            end
            
            WR_LINK_CELL: begin
                if (wr_pkt_eop) begin
                    wr_state_next = WR_DONE;
                end else begin
                    wr_state_next = WR_ALLOC_CELL;
                end
            end
            
            WR_DONE: begin
                wr_desc_valid = 1'b1;
                wr_state_next = WR_IDLE;
            end
        endcase
    end
    
    // 写入数据通路
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cur_desc_id <= '0;
            wr_first_cell_id <= '0;
            wr_prev_cell_id <= '0;
            wr_cur_cell_id <= '0;
            wr_cell_count <= '0;
            wr_total_len <= '0;
            wr_is_first_cell <= 1'b1;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    wr_is_first_cell <= 1'b1;
                    wr_cell_count <= '0;
                    wr_total_len <= '0;
                end
                
                WR_ALLOC_DESC: begin
                    wr_cur_desc_id <= desc_free_head;
                    // 更新空闲链表
                    desc_free_head <= desc_free_link[desc_free_head];
                    desc_free_count <= desc_free_count - 1;
                end
                
                WR_ALLOC_CELL: begin
                    if (cell_alloc_resp.ack && cell_alloc_resp.success) begin
                        wr_cur_cell_id <= cell_alloc_resp.cell_id;
                        if (wr_is_first_cell) begin
                            wr_first_cell_id <= cell_alloc_resp.cell_id;
                            wr_is_first_cell <= 1'b0;
                        end
                    end
                end
                
                WR_LINK_CELL: begin
                    wr_prev_cell_id <= wr_cur_cell_id;
                    wr_cell_count <= wr_cell_count + 1;
                    wr_total_len <= wr_total_len + {7'b0, wr_pkt_len};
                end
                
                WR_DONE: begin
                    // 更新描述符
                    desc_mem[wr_cur_desc_id].head_ptr <= wr_first_cell_id;
                    desc_mem[wr_cur_desc_id].tail_ptr <= wr_cur_cell_id;
                    desc_mem[wr_cur_desc_id].cell_count <= wr_cell_count + 1;
                    desc_mem[wr_cur_desc_id].pkt_len <= wr_total_len + {7'b0, wr_pkt_len};
                    desc_mem[wr_cur_desc_id].src_port <= wr_src_port;
                end
            endcase
        end
    end
    
    assign wr_desc_id = wr_cur_desc_id;
    
    //------------------------------------------------------------------------
    // 描述符读取
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        desc_rd_data <= desc_mem[desc_rd_addr];
    end
    
    // 描述符写入
    always_ff @(posedge clk) begin
        if (desc_wr_en) begin
            desc_mem[desc_wr_addr] <= desc_wr_data;
        end
    end
    
    //------------------------------------------------------------------------
    // 读取状态机 (简化)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state <= RD_IDLE;
            rd_pkt_valid <= 1'b0;
            rd_pkt_sop <= 1'b0;
            rd_pkt_eop <= 1'b0;
            rd_pkt_ready <= 1'b1;
        end else begin
            rd_pkt_valid <= 1'b0;
            rd_pkt_sop <= 1'b0;
            rd_pkt_eop <= 1'b0;
            
            case (rd_state)
                RD_IDLE: begin
                    rd_pkt_ready <= 1'b1;
                    if (rd_pkt_req) begin
                        rd_cur_desc_id <= rd_desc_id;
                        rd_state <= RD_READ_DESC;
                        rd_pkt_ready <= 1'b0;
                    end
                end
                
                RD_READ_DESC: begin
                    rd_cur_desc <= desc_mem[rd_cur_desc_id];
                    rd_cur_cell_id <= desc_mem[rd_cur_desc_id].head_ptr;
                    rd_is_first_cell <= 1'b1;
                    rd_state <= RD_READ_CELL;
                end
                
                RD_READ_CELL: begin
                    // 发起内存读取
                    rd_state <= RD_OUTPUT;
                end
                
                RD_OUTPUT: begin
                    rd_pkt_valid <= 1'b1;
                    rd_pkt_sop <= rd_is_first_cell;
                    rd_is_first_cell <= 1'b0;
                    
                    // 检查是否为最后一个Cell
                    // (简化：使用desc中的tail_ptr比较)
                    if (rd_cur_cell_id == rd_cur_desc.tail_ptr) begin
                        rd_pkt_eop <= 1'b1;
                        rd_state <= RD_IDLE;
                    end else begin
                        rd_state <= RD_NEXT_CELL;
                    end
                end
                
                RD_NEXT_CELL: begin
                    // 读取下一个Cell ID (从元数据)
                    rd_state <= RD_READ_CELL;
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 释放逻辑 (简化)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rel_state <= REL_IDLE;
            release_done <= 1'b0;
            cell_free_req.req <= 1'b0;
        end else begin
            release_done <= 1'b0;
            cell_free_req.req <= 1'b0;
            
            case (rel_state)
                REL_IDLE: begin
                    if (release_req) begin
                        rel_cur_desc_id <= release_desc_id;
                        rel_state <= REL_READ_DESC;
                    end
                end
                
                REL_READ_DESC: begin
                    rel_cur_desc <= desc_mem[rel_cur_desc_id];
                    rel_cur_cell_id <= desc_mem[rel_cur_desc_id].head_ptr;
                    rel_state <= REL_FREE_CELLS;
                end
                
                REL_FREE_CELLS: begin
                    cell_free_req.req <= 1'b1;
                    cell_free_req.cell_id <= rel_cur_cell_id;
                    
                    if (cell_free_ack) begin
                        if (rel_cur_cell_id == rel_cur_desc.tail_ptr) begin
                            rel_state <= REL_FREE_DESC;
                        end
                        // 需要读取next_ptr，简化处理
                    end
                end
                
                REL_FREE_DESC: begin
                    // 归还描述符到空闲链表
                    desc_free_link[desc_free_tail] <= rel_cur_desc_id;
                    desc_free_tail <= rel_cur_desc_id;
                    desc_free_count <= desc_free_count + 1;
                    desc_mem[rel_cur_desc_id] <= '0;
                    release_done <= 1'b1;
                    rel_state <= REL_IDLE;
                end
            endcase
        end
    end

endmodule : packet_buffer
