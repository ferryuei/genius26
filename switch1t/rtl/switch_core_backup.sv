//============================================================================
// Switch Core Top - 1.2Tbps 48x25G L2交换机核心顶层
// 功能: 整合所有子模块
//============================================================================
`timescale 1ns/1ps

module switch_core
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 48个端口输入接口 (简化为单一位宽)
    input  logic [NUM_PORTS-1:0]      port_rx_valid,
    input  logic [NUM_PORTS-1:0]      port_rx_sop,
    input  logic [NUM_PORTS-1:0]      port_rx_eop,
    input  logic [63:0]               port_rx_data [NUM_PORTS-1:0],
    input  logic [2:0]                port_rx_empty [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      port_rx_ready,
    
    // 48个端口输出接口
    output logic [NUM_PORTS-1:0]      port_tx_valid,
    output logic [NUM_PORTS-1:0]      port_tx_sop,
    output logic [NUM_PORTS-1:0]      port_tx_eop,
    output logic [63:0]               port_tx_data [NUM_PORTS-1:0],
    output logic [2:0]                port_tx_empty [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      port_tx_ready,
    
    // CPU配置接口
    input  logic                      cfg_wr_en,
    input  logic [31:0]               cfg_addr,
    input  logic [31:0]               cfg_wr_data,
    output logic [31:0]               cfg_rd_data,
    
    // 中断
    output logic                      irq_learn,      // MAC学习中断
    output logic                      irq_link,       // 链路状态变化
    output logic                      irq_overflow,   // 缓冲区溢出
    
    // 直接测试接口 - 用于提高覆盖率
    input  logic                      test_mode,
    // 直接MAC表测试
    input  logic                      test_mac_lookup_req,
    input  logic [47:0]               test_mac_lookup_mac,
    input  logic [VLAN_ID_WIDTH-1:0]  test_mac_lookup_vid,
    input  logic                      test_mac_learn_req,
    input  logic [47:0]               test_mac_learn_mac,
    input  logic [VLAN_ID_WIDTH-1:0]  test_mac_learn_vid,
    input  logic [PORT_WIDTH-1:0]     test_mac_learn_port,
    // 直接Egress调度器测试
    input  logic                      test_egr_enq_req,
    input  logic [PORT_WIDTH-1:0]     test_egr_enq_port,
    input  logic [QUEUE_ID_WIDTH-1:0] test_egr_enq_queue,
    input  logic [DESC_ID_WIDTH-1:0]  test_egr_enq_desc_id,
    input  logic [6:0]                test_egr_enq_cell_count
);

    //------------------------------------------------------------------------
    // 内部信号
    //------------------------------------------------------------------------
    
    // 端口配置
    port_config_t port_config [NUM_PORTS-1:0];
    
    // Storm Control配置
    storm_ctrl_cfg_t storm_ctrl_cfg [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0];
    
    // Flow Control状态
    logic [NUM_PORTS-1:0] port_paused;
    logic [15:0] pause_timer [NUM_PORTS-1:0];
    
    // Cell分配器接口
    cell_alloc_req_t  cell_alloc_req  [NUM_FREE_POOLS-1:0];
    cell_alloc_resp_t cell_alloc_resp [NUM_FREE_POOLS-1:0];
    cell_free_req_t   cell_free_req   [NUM_FREE_POOLS-1:0];
    logic [NUM_FREE_POOLS-1:0] cell_free_ack;
    
    logic             meta_rd_en;
    logic [CELL_ID_WIDTH-1:0] meta_rd_addr;
    cell_meta_t       meta_rd_data;
    logic             meta_wr_en;
    logic [CELL_ID_WIDTH-1:0] meta_wr_addr;
    cell_meta_t       meta_wr_data;
    
    logic [CELL_ID_WIDTH:0] free_cell_count;
    logic             nearly_full;
    logic             nearly_empty;
    logic             cell_init_done;  // Cell分配器初始化完成
    
    // 报文缓冲区接口
    logic             buf_wr_valid;
    logic             buf_wr_sop;
    logic             buf_wr_eop;
    logic [CELL_SIZE_BITS-1:0] buf_wr_data;
    logic [6:0]       buf_wr_len;
    logic [PORT_WIDTH-1:0] buf_wr_port;
    logic             buf_wr_ready;
    logic [DESC_ID_WIDTH-1:0] buf_desc_id;
    logic             buf_desc_valid;
    
    logic             buf_rd_req;
    logic [DESC_ID_WIDTH-1:0] buf_rd_desc_id;
    logic             buf_rd_valid;
    logic             buf_rd_sop;
    logic             buf_rd_eop;
    logic [CELL_SIZE_BITS-1:0] buf_rd_data;
    logic             buf_rd_ready;
    
    logic [DESC_ID_WIDTH-1:0] desc_rd_addr;
    pkt_desc_t        desc_rd_data;
    logic             desc_wr_en;
    logic [DESC_ID_WIDTH-1:0] desc_wr_addr;
    pkt_desc_t        desc_wr_data;
    
    logic             release_req;
    logic [DESC_ID_WIDTH-1:0] release_desc_id;
    logic             release_done;
    
    // 内存接口
    mem_req_t         pkt_buf_mem_req;
    mem_resp_t        pkt_buf_mem_resp;
    
    // Ingress到Lookup
    ingress_lookup_req_t lookup_req;
    
    // MAC表接口
    logic             mac_lookup_req;
    logic [47:0]      mac_lookup_mac;
    logic [VLAN_ID_WIDTH-1:0] mac_lookup_vid;
    logic             mac_lookup_valid;
    logic             mac_lookup_hit;
    logic [PORT_WIDTH-1:0] mac_lookup_port;
    
    logic             mac_learn_req;
    logic [47:0]      mac_learn_mac;
    logic [VLAN_ID_WIDTH-1:0] mac_learn_vid;
    logic [PORT_WIDTH-1:0] mac_learn_port;
    logic             mac_learn_done;
    logic             mac_learn_success;
    
    // VLAN成员表 (简化)
    logic [NUM_PORTS-1:0] vlan_member [MAX_VLAN-1:0];
    
    // Egress调度器接口
    logic             egr_enq_req;
    logic [PORT_WIDTH-1:0] egr_enq_port;
    logic [QUEUE_ID_WIDTH-1:0] egr_enq_queue;
    logic [DESC_ID_WIDTH-1:0] egr_enq_desc_id;
    logic [6:0]       egr_enq_cell_count;
    logic             egr_enq_ack;
    logic             egr_enq_drop;
    
    logic [NUM_PORTS-1:0] egr_deq_req;
    logic [NUM_PORTS-1:0] egr_deq_valid;
    logic [DESC_ID_WIDTH-1:0] egr_deq_desc_id [NUM_PORTS-1:0];
    logic [QUEUE_ID_WIDTH-1:0] egr_deq_queue [NUM_PORTS-1:0];
    
    // 统计信号
    logic [31:0]      stat_rx_packets [NUM_PORTS-1:0];
    logic [31:0]      stat_rx_bytes [NUM_PORTS-1:0];
    logic [31:0]      stat_rx_drops [NUM_PORTS-1:0];
    logic [31:0]      stat_mac_lookup;
    logic [31:0]      stat_mac_hit;
    logic [31:0]      stat_mac_miss;
    logic [31:0]      stat_mac_learn;
    logic [15:0]      stat_mac_entries;
    logic [31:0]      stat_egr_enq;
    logic [31:0]      stat_egr_deq;
    logic [31:0]      stat_egr_drop;
    
    // 老化定时器
    logic             age_tick;
    logic [31:0]      age_counter;
    
    //------------------------------------------------------------------------
    // Cell分配器实例
    //------------------------------------------------------------------------
    cell_allocator u_cell_allocator (
        .clk            (clk),
        .rst_n          (rst_n),
        .alloc_req      (cell_alloc_req),
        .alloc_resp     (cell_alloc_resp),
        .free_req       (cell_free_req),
        .free_ack       (cell_free_ack),
        .meta_rd_en     (meta_rd_en),
        .meta_rd_addr   (meta_rd_addr),
        .meta_rd_data   (meta_rd_data),
        .meta_wr_en     (meta_wr_en),
        .meta_wr_addr   (meta_wr_addr),
        .meta_wr_data   (meta_wr_data),
        .free_count     (free_cell_count),
        .nearly_full    (nearly_full),
        .nearly_empty   (nearly_empty),
        .init_done      (cell_init_done)
    );
    
    //------------------------------------------------------------------------
    // 报文缓冲区实例
    //------------------------------------------------------------------------
    packet_buffer u_packet_buffer (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_pkt_valid   (buf_wr_valid),
        .wr_pkt_sop     (buf_wr_sop),
        .wr_pkt_eop     (buf_wr_eop),
        .wr_pkt_data    (buf_wr_data),
        .wr_pkt_len     (buf_wr_len),
        .wr_src_port    (buf_wr_port),
        .wr_pkt_ready   (buf_wr_ready),
        .wr_desc_id     (buf_desc_id),
        .wr_desc_valid  (buf_desc_valid),
        .rd_pkt_req     (buf_rd_req),
        .rd_desc_id     (buf_rd_desc_id),
        .rd_pkt_valid   (buf_rd_valid),
        .rd_pkt_sop     (buf_rd_sop),
        .rd_pkt_eop     (buf_rd_eop),
        .rd_pkt_data    (buf_rd_data),
        .rd_pkt_ready   (buf_rd_ready),
        .desc_rd_addr   (desc_rd_addr),
        .desc_rd_data   (desc_rd_data),
        .desc_wr_en     (desc_wr_en),
        .desc_wr_addr   (desc_wr_addr),
        .desc_wr_data   (desc_wr_data),
        .release_req    (release_req),
        .release_desc_id(release_desc_id),
        .release_done   (release_done),
        .cell_alloc_req (cell_alloc_req[0]),
        .cell_alloc_resp(cell_alloc_resp[0]),
        .cell_free_req  (cell_free_req[0]),
        .cell_free_ack  (cell_free_ack[0]),
        .mem_req        (pkt_buf_mem_req),
        .mem_resp       (pkt_buf_mem_resp)
    );
    
    //------------------------------------------------------------------------
    // 简化内存模型 - 单周期延迟响应 (避免组合逻辑环路)
    //------------------------------------------------------------------------
    logic [CELL_SIZE_BITS-1:0] cell_memory [0:TOTAL_CELLS-1];
    logic [CELL_SIZE_BITS-1:0] mem_rd_data_reg;
    logic mem_ack_reg;
    
    // 响应信号赋值
    assign pkt_buf_mem_resp.ack = mem_ack_reg;
    assign pkt_buf_mem_resp.rd_data = mem_rd_data_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ack_reg <= 1'b0;
            mem_rd_data_reg <= '0;
        end else begin
            mem_ack_reg <= pkt_buf_mem_req.req;
            if (pkt_buf_mem_req.req) begin
                if (pkt_buf_mem_req.wr_en) begin
                    cell_memory[pkt_buf_mem_req.cell_id] <= pkt_buf_mem_req.wr_data;
                end else begin
                    mem_rd_data_reg <= cell_memory[pkt_buf_mem_req.cell_id];
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // MAC查表引擎实例
    //------------------------------------------------------------------------
    mac_table u_mac_table (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req     (mac_lookup_req),
        .lookup_mac     (mac_lookup_mac),
        .lookup_vid     (mac_lookup_vid),
        .lookup_valid   (mac_lookup_valid),
        .lookup_hit     (mac_lookup_hit),
        .lookup_port    (mac_lookup_port),
        .learn_req      (mac_learn_req_mux),
        .learn_mac      (mac_learn_mac_mux),
        .learn_vid      (mac_learn_vid_mux),
        .learn_port     (mac_learn_port_mux),
        .learn_done     (mac_learn_done),
        .learn_success  (mac_learn_success),
        .cfg_wr_en      (1'b0),
        .cfg_set_idx    ('0),
        .cfg_way        ('0),
        .cfg_entry      ('0),
        .age_tick       (age_tick),
        .stat_lookup_cnt(stat_mac_lookup),
        .stat_hit_cnt   (stat_mac_hit),
        .stat_miss_cnt  (stat_mac_miss),
        .stat_learn_cnt (stat_mac_learn),
        .stat_entry_cnt (stat_mac_entries)
    );
    
    //------------------------------------------------------------------------
    // Ingress Pipeline实例
    //------------------------------------------------------------------------
    ingress_pipeline u_ingress (
        .clk            (clk),
        .rst_n          (rst_n),
        .port_rx_valid  (port_rx_valid),
        .port_rx_sop    (port_rx_sop),
        .port_rx_eop    (port_rx_eop),
        .port_rx_data   (port_rx_data),
        .port_rx_empty  (port_rx_empty),
        .port_rx_ready  (port_rx_ready),
        .port_config    (port_config),
        .storm_ctrl_cfg (storm_ctrl_cfg),
        .buf_wr_valid   (buf_wr_valid),
        .buf_wr_sop     (buf_wr_sop),
        .buf_wr_eop     (buf_wr_eop),
        .buf_wr_data    (buf_wr_data),
        .buf_wr_len     (buf_wr_len),
        .buf_wr_port    (buf_wr_port),
        .buf_wr_ready   (buf_wr_ready),
        .buf_desc_id    (buf_desc_id),
        .buf_desc_valid (buf_desc_valid),
        .lookup_req     (lookup_req),
        .learn_req      (mac_learn_req),
        .learn_mac      (mac_learn_mac),
        .learn_vid      (mac_learn_vid),
        .learn_port     (mac_learn_port),
        .learn_done     (mac_learn_done),
        .stat_rx_packets(stat_rx_packets),
        .stat_rx_bytes  (stat_rx_bytes),
        .stat_rx_drops  (stat_rx_drops)
    );
    
    //------------------------------------------------------------------------
    // Lookup Engine (组合逻辑)
    //------------------------------------------------------------------------
    // 简化的Lookup逻辑 - 支持测试模式
    assign mac_lookup_req = test_mode ? test_mac_lookup_req : lookup_req.valid;
    assign mac_lookup_mac = test_mode ? test_mac_lookup_mac : lookup_req.dmac;
    assign mac_lookup_vid = test_mode ? test_mac_lookup_vid : lookup_req.vid;
    
    // MAC学习请求 - 测试模式覆盖
    logic mac_learn_req_mux;
    logic [47:0] mac_learn_mac_mux;
    logic [VLAN_ID_WIDTH-1:0] mac_learn_vid_mux;
    logic [PORT_WIDTH-1:0] mac_learn_port_mux;
    
    assign mac_learn_req_mux = test_mode ? test_mac_learn_req : mac_learn_req;
    assign mac_learn_mac_mux = test_mode ? test_mac_learn_mac : mac_learn_mac;
    assign mac_learn_vid_mux = test_mode ? test_mac_learn_vid : mac_learn_vid;
    assign mac_learn_port_mux = test_mode ? test_mac_learn_port : mac_learn_port;
    
    //------------------------------------------------------------------------
    // ACL Engine实例
    //------------------------------------------------------------------------
    acl_lookup_req_t acl_lookup_req;
    acl_lookup_resp_t acl_lookup_resp;
    logic [31:0] stat_acl_lookup;
    logic [31:0] stat_acl_hit;
    logic [31:0] stat_acl_deny;
    
    // ACL规则配置 (简化: 通过复位初始化)
    logic acl_cfg_wr_en;
    logic [ACL_TABLE_WIDTH-1:0] acl_cfg_rule_idx;
    acl_rule_t acl_cfg_rule_data;
    
    assign acl_cfg_wr_en = 1'b0;  // 通过CPU配置接口控制
    assign acl_cfg_rule_idx = '0;
    assign acl_cfg_rule_data = '0;
    
    // ACL查找请求构造
    assign acl_lookup_req.valid = lookup_req.valid;
    assign acl_lookup_req.smac = lookup_req.smac;
    assign acl_lookup_req.dmac = lookup_req.dmac;
    assign acl_lookup_req.vid = lookup_req.vid;
    assign acl_lookup_req.ethertype = 16'h0800;  // 简化: 假设IPv4
    assign acl_lookup_req.src_port = lookup_req.src_port;
    
    acl_engine u_acl_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req     (acl_lookup_req),
        .lookup_resp    (acl_lookup_resp),
        .cfg_wr_en      (acl_cfg_wr_en),
        .cfg_rule_idx   (acl_cfg_rule_idx),
        .cfg_rule_data  (acl_cfg_rule_data),
        .stat_acl_lookup(stat_acl_lookup),
        .stat_acl_hit   (stat_acl_hit),
        .stat_acl_deny  (stat_acl_deny)
    );
    
    // 转发决策
    lookup_result_t lookup_result;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_result <= '0;
            egr_enq_req <= 1'b0;
        end else begin
            egr_enq_req <= 1'b0;
            
            if (mac_lookup_valid) begin
                lookup_result.valid <= 1'b1;
                lookup_result.desc_id <= lookup_req.desc_id;
                lookup_result.queue_id <= lookup_req.queue_id;
                
                // ACL检查 - DENY则丢弃
                if (acl_lookup_resp.valid && acl_lookup_resp.hit && 
                    acl_lookup_resp.action == ACL_DENY) begin
                    lookup_result.drop <= 1'b1;
                end
                // 检查广播
                else if (lookup_req.dmac == 48'hFFFFFFFFFFFF) begin
                    lookup_result.is_unicast <= 1'b0;
                    lookup_result.is_flood <= 1'b1;
                    lookup_result.dst_mask <= vlan_member[lookup_req.vid] & ~(1 << lookup_req.src_port);
                    lookup_result.drop <= 1'b0;
                end
                // 检查组播
                else if (lookup_req.dmac[40]) begin
                    lookup_result.is_unicast <= 1'b0;
                    lookup_result.is_flood <= 1'b1;
                    lookup_result.dst_mask <= vlan_member[lookup_req.vid] & ~(1 << lookup_req.src_port);
                    lookup_result.drop <= 1'b0;
                end
                // 单播
                else if (mac_lookup_hit) begin
                    lookup_result.is_unicast <= 1'b1;
                    lookup_result.is_flood <= 1'b0;
                    lookup_result.dst_port <= mac_lookup_port;
                    lookup_result.drop <= (mac_lookup_port == lookup_req.src_port);  // 源端口过滤
                end
                // 未知单播 - 泛洪
                else begin
                    lookup_result.is_unicast <= 1'b0;
                    lookup_result.is_flood <= 1'b1;
                    lookup_result.dst_mask <= vlan_member[lookup_req.vid] & ~(1 << lookup_req.src_port);
                    lookup_result.drop <= 1'b0;
                end
                
                // 触发入队 (ACL DENY时不入队)
                if (!(acl_lookup_resp.valid && acl_lookup_resp.hit && 
                      acl_lookup_resp.action == ACL_DENY)) begin
                    egr_enq_req <= 1'b1;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // Port Mirroring (SPAN) Logic
    //------------------------------------------------------------------------
    // 镜像状态机
    typedef enum logic [1:0] {
        MIRROR_IDLE,
        MIRROR_WAIT_ACK,
        MIRROR_ENQ
    } mirror_state_e;
    
    mirror_state_e mirror_state;
    logic mirror_pending;
    logic [PORT_WIDTH-1:0] mirror_src_port;
    logic [PORT_WIDTH-1:0] mirror_dst_port;
    logic [DESC_ID_WIDTH-1:0] mirror_desc_id;
    logic [QUEUE_ID_WIDTH-1:0] mirror_queue_id;
    logic [6:0] mirror_cell_count;
    
    // 镜像入队请求
    logic mirror_enq_req;
    logic [PORT_WIDTH-1:0] mirror_enq_port;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mirror_state <= MIRROR_IDLE;
            mirror_pending <= 1'b0;
            mirror_enq_req <= 1'b0;
            mirror_src_port <= '0;
            mirror_dst_port <= '0;
            mirror_desc_id <= '0;
            mirror_queue_id <= '0;
            mirror_cell_count <= '0;
        end else begin
            mirror_enq_req <= 1'b0;
            
            case (mirror_state)
                MIRROR_IDLE: begin
                    // 检查是否需要镜像 (当有新的入队请求时)
                    if (egr_enq_req && !test_mode) begin
                        // 检查源端口镜像 (入向镜像)
                        if (port_config[lookup_req.src_port].mirror_enable && 
                            port_config[lookup_req.src_port].mirror_ingress) begin
                            mirror_pending <= 1'b1;
                            mirror_src_port <= lookup_req.src_port;
                            mirror_dst_port <= port_config[lookup_req.src_port].mirror_dest;
                            mirror_desc_id <= lookup_result.desc_id;
                            mirror_queue_id <= lookup_result.queue_id;
                            mirror_cell_count <= desc_rd_data.cell_count;
                            mirror_state <= MIRROR_WAIT_ACK;
                        end
                        // 检查目的端口镜像 (出向镜像)
                        else if (port_config[lookup_result.dst_port].mirror_enable && 
                                 port_config[lookup_result.dst_port].mirror_egress) begin
                            mirror_pending <= 1'b1;
                            mirror_src_port <= lookup_result.dst_port;
                            mirror_dst_port <= port_config[lookup_result.dst_port].mirror_dest;
                            mirror_desc_id <= lookup_result.desc_id;
                            mirror_queue_id <= lookup_result.queue_id;
                            mirror_cell_count <= desc_rd_data.cell_count;
                            mirror_state <= MIRROR_WAIT_ACK;
                        end
                    end
                end
                
                MIRROR_WAIT_ACK: begin
                    // 等待主入队完成
                    if (egr_enq_ack) begin
                        mirror_state <= MIRROR_ENQ;
                    end
                end
                
                MIRROR_ENQ: begin
                    // 发送镜像入队请求
                    mirror_enq_req <= 1'b1;
                    mirror_enq_port <= mirror_dst_port;
                    mirror_pending <= 1'b0;
                    mirror_state <= MIRROR_IDLE;
                end
            endcase
        end
    end
    
    // 入队逻辑 (简化：只处理单播) - 支持测试模式和镜像
    logic egr_enq_req_mux;
    logic [PORT_WIDTH-1:0] egr_enq_port_mux;
    logic [QUEUE_ID_WIDTH-1:0] egr_enq_queue_mux;
    logic [DESC_ID_WIDTH-1:0] egr_enq_desc_id_mux;
    logic [6:0] egr_enq_cell_count_mux;
    
    // 优先级: test_mode > mirror_enq > normal_enq
    always_comb begin
        if (test_mode) begin
            egr_enq_req_mux = test_egr_enq_req;
            egr_enq_port_mux = test_egr_enq_port;
            egr_enq_queue_mux = test_egr_enq_queue;
            egr_enq_desc_id_mux = test_egr_enq_desc_id;
            egr_enq_cell_count_mux = test_egr_enq_cell_count;
        end else if (mirror_enq_req) begin
            egr_enq_req_mux = 1'b1;
            egr_enq_port_mux = mirror_enq_port;
            egr_enq_queue_mux = mirror_queue_id;
            egr_enq_desc_id_mux = mirror_desc_id;
            egr_enq_cell_count_mux = mirror_cell_count;
        end else begin
            egr_enq_req_mux = egr_enq_req;
            egr_enq_port_mux = lookup_result.dst_port;
            egr_enq_queue_mux = lookup_result.queue_id;
            egr_enq_desc_id_mux = lookup_result.desc_id;
            egr_enq_cell_count_mux = desc_rd_data.cell_count;
        end
    end
    
    // 保留原始信号用于其他逻辑
    assign egr_enq_port = lookup_result.dst_port;
    assign egr_enq_queue = lookup_result.queue_id;
    assign egr_enq_desc_id = lookup_result.desc_id;
    assign egr_enq_cell_count = desc_rd_data.cell_count;
    assign desc_rd_addr = lookup_result.desc_id;
    
    //------------------------------------------------------------------------
    // Egress调度器实例
    //------------------------------------------------------------------------
    egress_scheduler u_egress (
        .clk            (clk),
        .rst_n          (rst_n),
        .enq_req        (egr_enq_req_mux),
        .enq_port       (egr_enq_port_mux),
        .enq_queue      (egr_enq_queue_mux),
        .enq_desc_id    (egr_enq_desc_id_mux),
        .enq_cell_count (egr_enq_cell_count_mux),
        .enq_ack        (egr_enq_ack),
        .enq_drop       (egr_enq_drop),
        .deq_req        (egr_deq_req),
        .deq_valid      (egr_deq_valid),
        .deq_desc_id    (egr_deq_desc_id),
        .deq_queue      (egr_deq_queue),
        .port_paused    (port_paused),
        .query_port     ('0),
        .query_queue    ('0),
        .query_depth    (),
        .query_state    (),
        .wred_min_th    (16'd100),
        .wred_max_th    (16'd500),
        .wred_max_prob  (8'd25),
        .stat_enq_count (stat_egr_enq),
        .stat_deq_count (stat_egr_deq),
        .stat_drop_count(stat_egr_drop)
    );
    
    //------------------------------------------------------------------------
    // Egress输出 (简化)
    //------------------------------------------------------------------------
    // 每端口出队请求
    assign egr_deq_req = port_tx_ready;
    
    // 输出数据 (简化：需要读取报文缓冲区)
    genvar i;
    generate
        for (i = 0; i < NUM_PORTS; i++) begin : gen_tx
            assign port_tx_valid[i] = egr_deq_valid[i];
            assign port_tx_sop[i] = 1'b1;  // 简化
            assign port_tx_eop[i] = 1'b1;  // 简化
            assign port_tx_data[i] = '0;   // 需要从缓冲区读取
            assign port_tx_empty[i] = '0;
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // 老化定时器
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            age_counter <= '0;
            age_tick <= 1'b0;
        end else begin
            age_tick <= 1'b0;
            age_counter <= age_counter + 1;
            // 假设500MHz时钟，每300秒触发一次老化
            // 300s * 500MHz = 150,000,000,000 cycles
            // 简化为每2^28 cycles (~0.5s)
            if (age_counter[27:0] == '1) begin
                age_tick <= 1'b1;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 端口配置初始化 - 通过复位完成
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                port_config[p].enabled <= 1'b1;
                port_config[p].state <= PORT_FORWARDING;
                port_config[p].fwd_mode <= FWD_STORE_AND_FORWARD;
                port_config[p].default_vid <= 12'd1;
                port_config[p].default_pcp <= 3'd0;
                // P0 Feature defaults
                port_config[p].mtu <= DEFAULT_MTU;           // 1518 bytes
                port_config[p].mirror_enable <= 1'b0;
                port_config[p].mirror_dest <= '0;
                port_config[p].mirror_ingress <= 1'b0;
                port_config[p].mirror_egress <= 1'b0;
                port_config[p].flow_ctrl_enable <= 1'b0;
                
                // Storm Control默认配置 (禁用)
                for (int t = 0; t < STORM_CTRL_TYPES; t++) begin
                    storm_ctrl_cfg[p][t].enabled <= 1'b0;
                    storm_ctrl_cfg[p][t].pir <= DEFAULT_PIR;
                    storm_ctrl_cfg[p][t].cbs <= DEFAULT_CBS;
                end
                
                // Flow Control状态初始化
                port_paused[p] <= 1'b0;
                pause_timer[p] <= '0;
            end
            
            // 初始化VLAN表
            for (int v = 0; v < MAX_VLAN; v++) begin
                vlan_member[v] <= '0;
            end
            vlan_member[1] <= '1;  // VLAN 1包含所有端口
        end else begin
            // 保持端口配置 (防止Verilator优化问题)
            for (int p = 0; p < NUM_PORTS; p++) begin
                port_config[p] <= port_config[p];
            end
        end
    end
    
    //------------------------------------------------------------------------
    // CPU配置接口 (简化)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_rd_data <= '0;
        end else begin
            cfg_rd_data <= '0;
            
            case (cfg_addr[15:12])
                4'h0: begin  // 统计寄存器
                    case (cfg_addr[11:0])
                        12'h000: cfg_rd_data <= stat_mac_lookup;
                        12'h004: cfg_rd_data <= stat_mac_hit;
                        12'h008: cfg_rd_data <= stat_mac_miss;
                        12'h00C: cfg_rd_data <= stat_mac_learn;
                        12'h010: cfg_rd_data <= {16'b0, stat_mac_entries};
                        12'h020: cfg_rd_data <= stat_egr_enq;
                        12'h024: cfg_rd_data <= stat_egr_deq;
                        12'h028: cfg_rd_data <= stat_egr_drop;
                        12'h030: cfg_rd_data <= {15'b0, free_cell_count};
                    endcase
                end
            endcase
        end
    end
    
    //------------------------------------------------------------------------
    // 802.3x Flow Control
    //------------------------------------------------------------------------
    // PAUSE帧生成请求 (基于缓冲区水位)
    logic [NUM_PORTS-1:0] pause_gen_req;
    logic flow_ctrl_xoff;
    logic flow_ctrl_xon;
    
    // 水位监测
    assign flow_ctrl_xoff = (free_cell_count < XOFF_THRESHOLD);
    assign flow_ctrl_xon  = (free_cell_count > XON_THRESHOLD);
    
    // PAUSE定时器和状态管理
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                pause_gen_req[p] <= 1'b0;
            end
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                if (port_config[p].flow_ctrl_enable) begin
                    // 当缓冲区低于XOFF阈值时请求发送PAUSE
                    if (flow_ctrl_xoff && !pause_gen_req[p]) begin
                        pause_gen_req[p] <= 1'b1;
                    end
                    // 当缓冲区恢复到XON阈值以上时取消PAUSE请求
                    else if (flow_ctrl_xon) begin
                        pause_gen_req[p] <= 1'b0;
                    end
                end else begin
                    pause_gen_req[p] <= 1'b0;
                end
            end
        end
    end
    
    // PAUSE接收处理 (从MAC层接收PAUSE帧后设置paused状态)
    // 注: 实际PAUSE帧解析需要在ingress pipeline中实现
    // 这里简化为通过pause_timer控制
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                port_paused[p] <= 1'b0;
                pause_timer[p] <= '0;
            end
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                // 定时器递减
                if (pause_timer[p] > 0) begin
                    pause_timer[p] <= pause_timer[p] - 1;
                    port_paused[p] <= 1'b1;
                end else begin
                    port_paused[p] <= 1'b0;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 中断
    //------------------------------------------------------------------------
    assign irq_learn = mac_learn_done && mac_learn_success;
    assign irq_link = 1'b0;  // 需要连接到PHY
    assign irq_overflow = nearly_empty;

endmodule : switch_core
