//============================================================================
// Switch Core Top - 1.2Tbps 48x25G L2交换机核心顶层 (Enhanced with P0+P1 Features)
// 功能: 整合所有子模块 + LAG + IGMP Snooping + Port Statistics + PAUSE + Egress Output
//       + RSTP + LACP + LLDP + 802.1X
//============================================================================
`timescale 1ns/1ps

module switch_core
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 48个端口输入接口
    input  logic [NUM_PORTS-1:0]      port_rx_valid,
    input  logic [NUM_PORTS-1:0]      port_rx_sop,
    input  logic [NUM_PORTS-1:0]      port_rx_eop,
    input  logic [63:0]               port_rx_data [NUM_PORTS-1:0],
    input  logic [2:0]                port_rx_empty [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      port_rx_ready,
    
    // PHY/MAC层错误信号 (新增)
    input  logic [NUM_PORTS-1:0]      port_rx_error,
    input  logic [NUM_PORTS-1:0]      port_rx_crc_error,
    input  logic [NUM_PORTS-1:0]      port_rx_align_error,
    input  logic [NUM_PORTS-1:0]      port_rx_overrun,
    input  logic [NUM_PORTS-1:0]      port_rx_jabber,
    input  logic [NUM_PORTS-1:0]      port_rx_undersize,
    input  logic [NUM_PORTS-1:0]      port_rx_fragment,
    
    // 48个端口输出接口
    output logic [NUM_PORTS-1:0]      port_tx_valid,
    output logic [NUM_PORTS-1:0]      port_tx_sop,
    output logic [NUM_PORTS-1:0]      port_tx_eop,
    output logic [63:0]               port_tx_data [NUM_PORTS-1:0],
    output logic [2:0]                port_tx_empty [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      port_tx_ready,
    
    // Tx错误信号 (新增)
    input  logic [NUM_PORTS-1:0]      port_tx_error,
    input  logic [NUM_PORTS-1:0]      port_tx_collision,
    input  logic [NUM_PORTS-1:0]      port_tx_late_collision,
    input  logic [NUM_PORTS-1:0]      port_tx_excessive_collision,
    input  logic [NUM_PORTS-1:0]      port_tx_underrun,
    
    // 链路状态 (新增 - for LAG)
    input  logic [NUM_PORTS-1:0]      port_link_up,
    
    // CPU配置接口
    input  logic                      cfg_wr_en,
    input  logic [31:0]               cfg_addr,
    input  logic [31:0]               cfg_wr_data,
    output logic [31:0]               cfg_rd_data,
    
    // 中断
    output logic                      irq_learn,
    output logic                      irq_link,
    output logic                      irq_overflow,
    
    // 测试模式接口 (保留)
    input  logic                      test_mode,
    input  logic                      test_mac_lookup_req,
    input  logic [47:0]               test_mac_lookup_mac,
    input  logic [VLAN_ID_WIDTH-1:0]  test_mac_lookup_vid,
    input  logic                      test_mac_learn_req,
    input  logic [47:0]               test_mac_learn_mac,
    input  logic [VLAN_ID_WIDTH-1:0]  test_mac_learn_vid,
    input  logic [PORT_WIDTH-1:0]     test_mac_learn_port,
    input  logic                      test_egr_enq_req,
    input  logic [PORT_WIDTH-1:0]     test_egr_enq_port,
    input  logic [QUEUE_ID_WIDTH-1:0] test_egr_enq_queue,
    input  logic [DESC_ID_WIDTH-1:0]  test_egr_enq_desc_id,
    input  logic [6:0]                test_egr_enq_cell_count
);

    //------------------------------------------------------------------------
    // 内部信号 (保留原有)
    //------------------------------------------------------------------------
    port_config_t port_config [NUM_PORTS-1:0];
    storm_ctrl_cfg_t storm_ctrl_cfg [NUM_PORTS-1:0][STORM_CTRL_TYPES-1:0];
    
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
    logic             cell_init_done;
    
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
    
    mem_req_t         pkt_buf_mem_req;
    mem_resp_t        pkt_buf_mem_resp;
    
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
    
    logic             age_tick;
    logic [31:0]      age_counter;
    
    //------------------------------------------------------------------------
    // 新增: PAUSE Frame Control接口
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0] port_paused;
    logic [15:0]          pause_timer [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] tx_pause_req;
    logic [15:0]          tx_pause_quanta [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] tx_pause_ready;
    logic [NUM_PORTS-1:0] tx_pause_valid;
    logic [NUM_PORTS-1:0] tx_pause_sop;
    logic [NUM_PORTS-1:0] tx_pause_eop;
    logic [63:0]          tx_pause_data [NUM_PORTS-1:0];
    logic [2:0]           tx_pause_empty [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] tx_pause_ack;
    logic [47:0]          port_src_mac [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // 新增: LAG Engine接口
    //------------------------------------------------------------------------
    logic                 lag_lookup_req;
    logic [PORT_WIDTH-1:0] lag_lookup_port;
    logic                 lag_lookup_valid;
    logic                 lag_is_lag_port;
    logic [2:0]           lag_id;
    
    logic                 lag_distribute_req;
    logic [2:0]           lag_dist_lag_id;
    logic [47:0]          lag_dist_smac;
    logic [47:0]          lag_dist_dmac;
    logic [VLAN_ID_WIDTH-1:0] lag_dist_vid;
    logic                 lag_distribute_valid;
    logic [PORT_WIDTH-1:0] lag_selected_port;
    
    //------------------------------------------------------------------------
    // 新增: IGMP Snooping接口
    //------------------------------------------------------------------------
    igmp_pkt_info_t       igmp_pkt_info;
    logic                 igmp_lookup_req;
    logic [31:0]          igmp_lookup_group_ip;
    logic [VLAN_ID_WIDTH-1:0] igmp_lookup_vid;
    logic                 igmp_lookup_valid;
    logic                 igmp_lookup_hit;
    logic [NUM_PORTS-1:0] igmp_lookup_port_mask;
    
    //------------------------------------------------------------------------
    // 新增: Port Statistics接口
    //------------------------------------------------------------------------
    logic [PORT_WIDTH-1:0] stats_read_port;
    logic [7:0]            stats_read_counter_id;
    logic [63:0]           stats_read_value;
    logic                  stats_clear_req;
    logic [PORT_WIDTH-1:0] stats_clear_port;
    logic                  stats_clear_done;
    
    //------------------------------------------------------------------------
    // 新增: RSTP Engine接口
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0]  rstp_port_enable;
    logic [15:0]           rstp_port_path_cost [NUM_PORTS-1:0];
    logic [7:0]            rstp_port_priority [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  rstp_bpdu_rx_valid;
    logic [63:0]           rstp_bpdu_rx_data [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  rstp_bpdu_tx_valid;
    logic [63:0]           rstp_bpdu_tx_data [NUM_PORTS-1:0];
    logic [1:0]            rstp_port_state [NUM_PORTS-1:0];
    logic [1:0]            rstp_port_role [NUM_PORTS-1:0];
    logic [63:0]           rstp_bridge_id;
    logic                  rstp_enable;
    logic                  rstp_topology_change;
    
    //------------------------------------------------------------------------
    // 新增: LACP Engine接口
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0]  lacp_port_enable;
    logic [NUM_PORTS-1:0]  lacp_lacpdu_rx_valid;
    logic [NUM_PORTS-1:0]  lacp_lacpdu_tx_valid;
    logic [2:0]            lacp_cfg_lag_id [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  lacp_port_selected;
    logic [NUM_PORTS-1:0]  lacp_port_standby;
    
    //------------------------------------------------------------------------
    // 新增: LLDP Engine接口
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0]  lldp_port_enable;
    logic [15:0]           lldp_port_speed [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  lldp_port_duplex;
    logic [NUM_PORTS-1:0]  lldp_lldpdu_rx_valid;
    logic [1023:0]         lldp_lldpdu_rx_data [NUM_PORTS-1:0];
    logic [15:0]           lldp_lldpdu_rx_len [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  lldp_lldpdu_tx_valid;
    logic [1023:0]         lldp_lldpdu_tx_data [NUM_PORTS-1:0];
    logic [15:0]           lldp_lldpdu_tx_len [NUM_PORTS-1:0];
    logic [47:0]           lldp_chassis_id;
    logic [2:0]            lldp_chassis_id_subtype;
    logic [127:0]          lldp_system_name;
    logic [7:0]            lldp_system_name_len;
    logic [255:0]          lldp_system_description;
    logic [7:0]            lldp_system_desc_len;
    logic [15:0]           lldp_system_capabilities;
    logic [15:0]           lldp_enabled_capabilities;
    logic [31:0]           lldp_mgmt_addr;
    logic                  lldp_enable;
    logic [NUM_PORTS-1:0]  lldp_neighbor_present;
    logic [47:0]           lldp_neighbor_chassis_id [NUM_PORTS-1:0];
    logic [63:0]           lldp_neighbor_port_id [NUM_PORTS-1:0];
    logic [15:0]           lldp_neighbor_ttl [NUM_PORTS-1:0];
    logic [15:0]           lldp_neighbor_capabilities [NUM_PORTS-1:0];
    
    //------------------------------------------------------------------------
    // 新增: 802.1X Engine接口
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0]  dot1x_port_enable;
    logic [NUM_PORTS-1:0]  dot1x_eapol_rx_valid;
    logic [1023:0]         dot1x_eapol_rx_data [NUM_PORTS-1:0];
    logic [15:0]           dot1x_eapol_rx_len [NUM_PORTS-1:0];
    logic [47:0]           dot1x_eapol_rx_src_mac [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  dot1x_eapol_tx_valid;
    logic [1023:0]         dot1x_eapol_tx_data [NUM_PORTS-1:0];
    logic [15:0]           dot1x_eapol_tx_len [NUM_PORTS-1:0];
    logic [47:0]           dot1x_eapol_tx_dst_mac [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  dot1x_radius_req_valid;
    logic [47:0]           dot1x_radius_req_mac [NUM_PORTS-1:0];
    logic [127:0]          dot1x_radius_req_identity [NUM_PORTS-1:0];
    logic [255:0]          dot1x_radius_req_credentials [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  dot1x_radius_resp_valid;
    logic [NUM_PORTS-1:0]  dot1x_radius_resp_accept;
    logic [11:0]           dot1x_radius_resp_vlan [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  dot1x_enable;
    logic [NUM_PORTS-1:0]  dot1x_mab_enable;
    logic [NUM_PORTS-1:0]  dot1x_reauth_enable;
    logic [31:0]           dot1x_reauth_period;
    logic [11:0]           dot1x_guest_vlan_id;
    logic [NUM_PORTS-1:0]  dot1x_port_authorized;
    logic [NUM_PORTS-1:0]  dot1x_port_authenticating;
    logic [47:0]           dot1x_authenticated_mac [NUM_PORTS-1:0];
    logic [11:0]           dot1x_dynamic_vlan [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  dot1x_port_security_enable;
    logic [7:0]            dot1x_max_mac_per_port [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]  dot1x_security_violation;
    
    //------------------------------------------------------------------------
    // Cell分配器实例 (保留)
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
    // 报文缓冲区实例 (保留)
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
    // 简化内存模型 (保留)
    //------------------------------------------------------------------------
    logic [CELL_SIZE_BITS-1:0] cell_memory [0:TOTAL_CELLS-1];
    logic [CELL_SIZE_BITS-1:0] mem_rd_data_reg;
    logic mem_ack_reg;
    
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
    // MAC查表引擎实例 (保留)
    //------------------------------------------------------------------------
    logic mac_learn_req_mux;
    logic [47:0] mac_learn_mac_mux;
    logic [VLAN_ID_WIDTH-1:0] mac_learn_vid_mux;
    logic [PORT_WIDTH-1:0] mac_learn_port_mux;
    
    assign mac_learn_req_mux = test_mode ? test_mac_learn_req : mac_learn_req;
    assign mac_learn_mac_mux = test_mode ? test_mac_learn_mac : mac_learn_mac;
    assign mac_learn_vid_mux = test_mode ? test_mac_learn_vid : mac_learn_vid;
    assign mac_learn_port_mux = test_mode ? test_mac_learn_port : mac_learn_port;
    
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
    // Ingress Pipeline实例 (保留)
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
    // ACL Engine实例 (保留)
    //------------------------------------------------------------------------
    acl_lookup_req_t acl_lookup_req;
    acl_lookup_resp_t acl_lookup_resp;
    logic [31:0] stat_acl_lookup;
    logic [31:0] stat_acl_hit;
    logic [31:0] stat_acl_deny;
    
    logic acl_cfg_wr_en;
    logic [ACL_TABLE_WIDTH-1:0] acl_cfg_rule_idx;
    acl_rule_t acl_cfg_rule_data;
    
    assign acl_cfg_wr_en = 1'b0;
    assign acl_cfg_rule_idx = '0;
    assign acl_cfg_rule_data = '0;
    
    assign acl_lookup_req.valid = lookup_req.valid;
    assign acl_lookup_req.smac = lookup_req.smac;
    assign acl_lookup_req.dmac = lookup_req.dmac;
    assign acl_lookup_req.vid = lookup_req.vid;
    assign acl_lookup_req.ethertype = 16'h0800;
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
    
    //------------------------------------------------------------------------
    // 新增: LAG Engine实例
    //------------------------------------------------------------------------
    logic [31:0] stat_lag_rx [7:0];
    logic [31:0] stat_lag_tx [7:0];
    
    lag_engine u_lag_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req     (lag_lookup_req),
        .lookup_port    (lag_lookup_port),
        .lookup_valid   (lag_lookup_valid),
        .is_lag_port    (lag_is_lag_port),
        .lag_id         (lag_id),
        .distribute_req (lag_distribute_req),
        .dist_lag_id    (lag_dist_lag_id),
        .dist_smac      (lag_dist_smac),
        .dist_dmac      (lag_dist_dmac),
        .dist_vid       (lag_dist_vid),
        .distribute_valid(lag_distribute_valid),
        .selected_port  (lag_selected_port),
        .cfg_wr_en      (1'b0),
        .cfg_lag_id     ('0),
        .cfg_member_mask('0),
        .cfg_enabled    (1'b0),
        .cfg_hash_mode  (2'd2),
        .port_link_up   (port_link_up),
        .stat_lag_rx    (stat_lag_rx),
        .stat_lag_tx    (stat_lag_tx)
    );
    
    // LAG查找触发 (Ingress)
    assign lag_lookup_req = lookup_req.valid;
    assign lag_lookup_port = lookup_req.src_port;
    
    //------------------------------------------------------------------------
    // 新增: IGMP Snooping实例
    //------------------------------------------------------------------------
    logic [31:0] stat_igmp_report;
    logic [31:0] stat_igmp_leave;
    logic [31:0] stat_igmp_query;
    logic [15:0] stat_group_count;
    
    // IGMP报文信息提取 (简化 - 需要深度解析)
    assign igmp_pkt_info.valid = lookup_req.valid;
    assign igmp_pkt_info.dmac = lookup_req.dmac;
    assign igmp_pkt_info.smac = lookup_req.smac;
    assign igmp_pkt_info.vid = lookup_req.vid;
    assign igmp_pkt_info.ethertype = 16'h0800;  // 假设IPv4
    assign igmp_pkt_info.ip_proto = 8'd2;       // IGMP
    assign igmp_pkt_info.dst_ip = '0;           // 需要从报文提取
    assign igmp_pkt_info.igmp_type = '0;
    assign igmp_pkt_info.igmp_group = '0;
    assign igmp_pkt_info.src_port = lookup_req.src_port;
    
    igmp_snooping u_igmp_snooping (
        .clk            (clk),
        .rst_n          (rst_n),
        .pkt_valid      (igmp_pkt_info.valid),
        .pkt_dmac       (igmp_pkt_info.dmac),
        .pkt_smac       (igmp_pkt_info.smac),
        .pkt_vid        (igmp_pkt_info.vid),
        .pkt_ethertype  (igmp_pkt_info.ethertype),
        .pkt_ip_proto   (igmp_pkt_info.ip_proto),
        .pkt_dst_ip     (igmp_pkt_info.dst_ip),
        .pkt_igmp_type  (igmp_pkt_info.igmp_type),
        .pkt_igmp_group (igmp_pkt_info.igmp_group),
        .pkt_src_port   (igmp_pkt_info.src_port),
        .lookup_req     (igmp_lookup_req),
        .lookup_group_ip(igmp_lookup_group_ip),
        .lookup_vid     (igmp_lookup_vid),
        .lookup_valid   (igmp_lookup_valid),
        .lookup_hit     (igmp_lookup_hit),
        .lookup_port_mask(igmp_lookup_port_mask),
        .cfg_enable     (1'b0),  // 通过CPU配置
        .cfg_router_ports('0),
        .cfg_aging_time (16'd300),  // 300秒
        .age_tick       (age_tick),
        .stat_igmp_report(stat_igmp_report),
        .stat_igmp_leave(stat_igmp_leave),
        .stat_igmp_query(stat_igmp_query),
        .stat_group_count(stat_group_count)
    );
    
    // IGMP查找触发 (组播报文)
    assign igmp_lookup_req = lookup_req.valid && lookup_req.dmac[40];
    assign igmp_lookup_group_ip = '0;  // 需要从报文提取
    assign igmp_lookup_vid = lookup_req.vid;
    
    //------------------------------------------------------------------------
    // 新增: PAUSE Frame Controller实例
    //------------------------------------------------------------------------
    logic [31:0] stat_pause_rx [NUM_PORTS-1:0];
    logic [31:0] stat_pause_tx [NUM_PORTS-1:0];
    
    pause_frame_ctrl u_pause_ctrl (
        .clk                (clk),
        .rst_n              (rst_n),
        .rx_valid           (port_rx_valid),
        .rx_sop             (port_rx_sop),
        .rx_eop             (port_rx_eop),
        .rx_data            (port_rx_data),
        .port_paused        (port_paused),
        .pause_timer        (pause_timer),
        .tx_pause_req       (tx_pause_req),
        .tx_pause_quanta    (tx_pause_quanta),
        .tx_pause_ready     (tx_pause_ready),
        .tx_pause_valid     (tx_pause_valid),
        .tx_pause_sop       (tx_pause_sop),
        .tx_pause_eop       (tx_pause_eop),
        .tx_pause_data      (tx_pause_data),
        .tx_pause_empty     (tx_pause_empty),
        .tx_pause_ack       (tx_pause_ack),
        .cfg_flow_ctrl_enable(port_config[0].flow_ctrl_enable),  // 简化：所有端口
        .cfg_pause_tx_enable('1),
        .cfg_pause_rx_enable('1),
        .cfg_src_mac        (port_src_mac),
        .stat_pause_rx      (stat_pause_rx),
        .stat_pause_tx      (stat_pause_tx)
    );
    
    // PAUSE生成逻辑 (基于缓冲区水位)
    logic flow_ctrl_xoff;
    logic flow_ctrl_xon;
    
    assign flow_ctrl_xoff = (free_cell_count < XOFF_THRESHOLD);
    assign flow_ctrl_xon  = (free_cell_count > XON_THRESHOLD);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                tx_pause_req[p] <= 1'b0;
                tx_pause_quanta[p] <= PAUSE_QUANTA;
            end
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                if (port_config[p].flow_ctrl_enable) begin
                    if (flow_ctrl_xoff && !tx_pause_req[p]) begin
                        tx_pause_req[p] <= 1'b1;
                        tx_pause_quanta[p] <= PAUSE_QUANTA;
                    end else if (flow_ctrl_xon) begin
                        tx_pause_req[p] <= 1'b0;
                    end
                end else begin
                    tx_pause_req[p] <= 1'b0;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 新增: Port Statistics实例
    //------------------------------------------------------------------------
    logic [31:0] stat_egr_out_pkts [NUM_PORTS-1:0];
    
    port_statistics u_port_statistics (
        .clk                (clk),
        .rst_n              (rst_n),
        .rx_valid           (port_rx_valid),
        .rx_sop             (port_rx_sop),
        .rx_eop             (port_rx_eop),
        .rx_data            (port_rx_data),
        .rx_empty           (port_rx_empty),
        .rx_error           (port_rx_error),
        .rx_crc_error       (port_rx_crc_error),
        .rx_align_error     (port_rx_align_error),
        .rx_overrun         (port_rx_overrun),
        .rx_jabber          (port_rx_jabber),
        .rx_undersize       (port_rx_undersize),
        .rx_fragment        (port_rx_fragment),
        .rx_drop            (stat_rx_drops),
        .tx_valid           (port_tx_valid),
        .tx_sop             (port_tx_sop),
        .tx_eop             (port_tx_eop),
        .tx_data            (port_tx_data),
        .tx_empty           (port_tx_empty),
        .tx_error           (port_tx_error),
        .tx_collision       (port_tx_collision),
        .tx_late_collision  (port_tx_late_collision),
        .tx_excessive_collision(port_tx_excessive_collision),
        .tx_underrun        (port_tx_underrun),
        .tx_drop            (egr_deq_drop),
        .read_port          (stats_read_port),
        .read_counter_id    (stats_read_counter_id),
        .read_counter_value (stats_read_value),
        .clear_req          (stats_clear_req),
        .clear_port         (stats_clear_port),
        .clear_done         (stats_clear_done)
    );
    
    logic [NUM_PORTS-1:0] egr_deq_drop;
    assign egr_deq_drop = '0;  // 简化
    
    //------------------------------------------------------------------------
    // 新增: RSTP Engine实例
    //------------------------------------------------------------------------
    assign rstp_port_enable = port_enable;
    assign rstp_bridge_id = {16'h8000, lldp_chassis_id};  // Priority + MAC
    assign rstp_enable = 1'b0;  // 通过CPU配置
    
    // 初始化端口参数
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                rstp_port_path_cost[i] <= 16'd20;  // 1Gbps default
                rstp_port_priority[i] <= 8'd128;
                rstp_bpdu_rx_valid[i] <= 1'b0;
                rstp_bpdu_rx_data[i] <= '0;
            end
        end else begin
            // BPDU接收检测 (简化 - 需要从报文中提取)
            for (int i = 0; i < NUM_PORTS; i++) begin
                rstp_bpdu_rx_valid[i] <= 1'b0;
            end
        end
    end
    
    rstp_engine u_rstp_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .port_enable        (rstp_port_enable),
        .port_link_up       (port_link_up),
        .port_path_cost     (rstp_port_path_cost),
        .port_priority      (rstp_port_priority),
        .bpdu_rx_valid      (rstp_bpdu_rx_valid),
        .bpdu_rx_data       (rstp_bpdu_rx_data),
        .bpdu_tx_valid      (rstp_bpdu_tx_valid),
        .bpdu_tx_data       (rstp_bpdu_tx_data),
        .port_state         (rstp_port_state),
        .port_role          (rstp_port_role),
        .bridge_id          (rstp_bridge_id),
        .rstp_enable        (rstp_enable),
        .topology_change    (rstp_topology_change)
    );
    
    //------------------------------------------------------------------------
    // 新增: LACP Engine实例
    //------------------------------------------------------------------------
    assign lacp_port_enable = port_enable;
    
    // LACP配置初始化
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                lacp_cfg_lag_id[i] <= 3'd0;
                lacp_lacpdu_rx_valid[i] <= 1'b0;
            end
        end else begin
            // LACPDU接收检测 (简化 - 需要从报文中提取)
            for (int i = 0; i < NUM_PORTS; i++) begin
                lacp_lacpdu_rx_valid[i] <= 1'b0;
            end
        end
    end
    
    lacp_engine u_lacp_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .port_enable        (lacp_port_enable),
        .port_link_up       (port_link_up),
        .lacpdu_rx_valid    (lacp_lacpdu_rx_valid),
        .lacpdu_tx_valid    (lacp_lacpdu_tx_valid),
        .cfg_lag_id         (lacp_cfg_lag_id),
        .port_selected      (lacp_port_selected),
        .port_standby       (lacp_port_standby)
    );
    
    //------------------------------------------------------------------------
    // 新增: LLDP Engine实例
    //------------------------------------------------------------------------
    assign lldp_port_enable = port_enable;
    assign lldp_chassis_id = 48'h001122334455;  // 通过CPU配置
    assign lldp_chassis_id_subtype = 3'd4;  // MAC address
    assign lldp_system_name = 128'h53776974636831540000000000000000;  // "Switch1T"
    assign lldp_system_name_len = 8'd8;
    assign lldp_system_description = 256'h312E32546270732034387832354720537769746368000000000000000000000000;
    assign lldp_system_desc_len = 8'd21;
    assign lldp_system_capabilities = 16'h0004;  // Bridge
    assign lldp_enabled_capabilities = 16'h0004;
    assign lldp_mgmt_addr = 32'h0A000001;  // 10.0.0.1
    assign lldp_enable = 1'b1;  // 默认启用
    
    // 端口速度和双工模式
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                lldp_port_speed[i] <= 16'd25000;  // 25Gbps
                lldp_port_duplex[i] <= 1'b1;      // Full duplex
                lldp_lldpdu_rx_valid[i] <= 1'b0;
                lldp_lldpdu_rx_data[i] <= '0;
                lldp_lldpdu_rx_len[i] <= '0;
            end
        end else begin
            // LLDPDU接收检测 (简化 - 需要从报文中提取)
            for (int i = 0; i < NUM_PORTS; i++) begin
                lldp_lldpdu_rx_valid[i] <= 1'b0;
            end
        end
    end
    
    lldp_engine u_lldp_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .port_enable        (lldp_port_enable),
        .port_link_up       (port_link_up),
        .port_speed         (lldp_port_speed),
        .port_duplex        (lldp_port_duplex),
        .lldpdu_rx_valid    (lldp_lldpdu_rx_valid),
        .lldpdu_rx_data     (lldp_lldpdu_rx_data),
        .lldpdu_rx_len      (lldp_lldpdu_rx_len),
        .lldpdu_tx_valid    (lldp_lldpdu_tx_valid),
        .lldpdu_tx_data     (lldp_lldpdu_tx_data),
        .lldpdu_tx_len      (lldp_lldpdu_tx_len),
        .chassis_id         (lldp_chassis_id),
        .chassis_id_subtype (lldp_chassis_id_subtype),
        .system_name        (lldp_system_name),
        .system_name_len    (lldp_system_name_len),
        .system_description (lldp_system_description),
        .system_desc_len    (lldp_system_desc_len),
        .system_capabilities(lldp_system_capabilities),
        .enabled_capabilities(lldp_enabled_capabilities),
        .mgmt_addr          (lldp_mgmt_addr),
        .lldp_enable        (lldp_enable),
        .neighbor_present   (lldp_neighbor_present),
        .neighbor_chassis_id(lldp_neighbor_chassis_id),
        .neighbor_port_id   (lldp_neighbor_port_id),
        .neighbor_ttl       (lldp_neighbor_ttl),
        .neighbor_capabilities(lldp_neighbor_capabilities)
    );
    
    //------------------------------------------------------------------------
    // 新增: 802.1X Engine实例
    //------------------------------------------------------------------------
    assign dot1x_port_enable = port_enable;
    assign dot1x_enable = '0;  // 默认禁用，通过CPU配置
    assign dot1x_mab_enable = '0;
    assign dot1x_reauth_enable = '0;
    assign dot1x_reauth_period = 32'd3600;  // 1小时
    assign dot1x_guest_vlan_id = 12'd999;
    assign dot1x_port_security_enable = '0;
    assign dot1x_radius_resp_valid = '0;  // 需要RADIUS客户端
    assign dot1x_radius_resp_accept = '0;
    assign dot1x_radius_resp_vlan = '0;
    
    // 端口最大MAC数量配置
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                dot1x_max_mac_per_port[i] <= 8'd1;  // 默认1个MAC
                dot1x_eapol_rx_valid[i] <= 1'b0;
                dot1x_eapol_rx_data[i] <= '0;
                dot1x_eapol_rx_len[i] <= '0;
                dot1x_eapol_rx_src_mac[i] <= '0;
            end
        end else begin
            // EAPOL接收检测 (简化 - 需要从报文中提取)
            for (int i = 0; i < NUM_PORTS; i++) begin
                dot1x_eapol_rx_valid[i] <= 1'b0;
            end
        end
    end
    
    dot1x_engine u_dot1x_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .port_enable        (dot1x_port_enable),
        .port_link_up       (port_link_up),
        .eapol_rx_valid     (dot1x_eapol_rx_valid),
        .eapol_rx_data      (dot1x_eapol_rx_data),
        .eapol_rx_len       (dot1x_eapol_rx_len),
        .eapol_rx_src_mac   (dot1x_eapol_rx_src_mac),
        .eapol_tx_valid     (dot1x_eapol_tx_valid),
        .eapol_tx_data      (dot1x_eapol_tx_data),
        .eapol_tx_len       (dot1x_eapol_tx_len),
        .eapol_tx_dst_mac   (dot1x_eapol_tx_dst_mac),
        .radius_req_valid   (dot1x_radius_req_valid),
        .radius_req_mac     (dot1x_radius_req_mac),
        .radius_req_identity(dot1x_radius_req_identity),
        .radius_req_credentials(dot1x_radius_req_credentials),
        .radius_resp_valid  (dot1x_radius_resp_valid),
        .radius_resp_accept (dot1x_radius_resp_accept),
        .radius_resp_vlan   (dot1x_radius_resp_vlan),
        .dot1x_enable       (dot1x_enable),
        .mab_enable         (dot1x_mab_enable),
        .reauth_enable      (dot1x_reauth_enable),
        .reauth_period_cfg  (dot1x_reauth_period),
        .guest_vlan_id      (dot1x_guest_vlan_id),
        .port_authorized    (dot1x_port_authorized),
        .port_authenticating(dot1x_port_authenticating),
        .authenticated_mac  (dot1x_authenticated_mac),
        .dynamic_vlan       (dot1x_dynamic_vlan),
        .port_security_enable(dot1x_port_security_enable),
        .max_mac_per_port   (dot1x_max_mac_per_port),
        .security_violation (dot1x_security_violation)
    );
    
    //------------------------------------------------------------------------
    // 转发决策逻辑 (保留并增强)
    //------------------------------------------------------------------------
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
                
                // ACL检查
                if (acl_lookup_resp.valid && acl_lookup_resp.hit && 
                    acl_lookup_resp.action == ACL_DENY) begin
                    lookup_result.drop <= 1'b1;
                end
                // 广播
                else if (lookup_req.dmac == 48'hFFFFFFFFFFFF) begin
                    lookup_result.is_unicast <= 1'b0;
                    lookup_result.is_flood <= 1'b1;
                    lookup_result.dst_mask <= vlan_member[lookup_req.vid] & ~(1 << lookup_req.src_port);
                    lookup_result.drop <= 1'b0;
                end
                // 组播 (增强: 使用IGMP Snooping)
                else if (lookup_req.dmac[40]) begin
                    lookup_result.is_unicast <= 1'b0;
                    lookup_result.is_flood <= 1'b1;
                    // 使用IGMP查找结果
                    if (igmp_lookup_valid && igmp_lookup_hit) begin
                        lookup_result.dst_mask <= igmp_lookup_port_mask & ~(1 << lookup_req.src_port);
                    end else begin
                        lookup_result.dst_mask <= vlan_member[lookup_req.vid] & ~(1 << lookup_req.src_port);
                    end
                    lookup_result.drop <= 1'b0;
                end
                // 单播
                else if (mac_lookup_hit) begin
                    lookup_result.is_unicast <= 1'b1;
                    lookup_result.is_flood <= 1'b0;
                    lookup_result.dst_port <= mac_lookup_port;
                    lookup_result.drop <= (mac_lookup_port == lookup_req.src_port);
                end
                // 未知单播
                else begin
                    lookup_result.is_unicast <= 1'b0;
                    lookup_result.is_flood <= 1'b1;
                    lookup_result.dst_mask <= vlan_member[lookup_req.vid] & ~(1 << lookup_req.src_port);
                    lookup_result.drop <= 1'b0;
                end
                
                if (!(acl_lookup_resp.valid && acl_lookup_resp.hit && 
                      acl_lookup_resp.action == ACL_DENY)) begin
                    egr_enq_req <= 1'b1;
                end
            end
        end
    end
    
    // MAC查找触发
    assign mac_lookup_req = test_mode ? test_mac_lookup_req : lookup_req.valid;
    assign mac_lookup_mac = test_mode ? test_mac_lookup_mac : lookup_req.dmac;
    assign mac_lookup_vid = test_mode ? test_mac_lookup_vid : lookup_req.vid;
    
    //------------------------------------------------------------------------
    // Port Mirroring逻辑 (保留)
    //------------------------------------------------------------------------
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
    logic mirror_enq_req;
    logic [PORT_WIDTH-1:0] mirror_enq_port;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mirror_state <= MIRROR_IDLE;
            mirror_pending <= 1'b0;
            mirror_enq_req <= 1'b0;
        end else begin
            mirror_enq_req <= 1'b0;
            
            case (mirror_state)
                MIRROR_IDLE: begin
                    if (egr_enq_req && !test_mode) begin
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
                    if (egr_enq_ack) begin
                        mirror_state <= MIRROR_ENQ;
                    end
                end
                
                MIRROR_ENQ: begin
                    mirror_enq_req <= 1'b1;
                    mirror_enq_port <= mirror_dst_port;
                    mirror_pending <= 1'b0;
                    mirror_state <= MIRROR_IDLE;
                end
            endcase
        end
    end
    
    // 入队逻辑复用 (测试模式 > 镜像 > 正常)
    logic egr_enq_req_mux;
    logic [PORT_WIDTH-1:0] egr_enq_port_mux;
    logic [QUEUE_ID_WIDTH-1:0] egr_enq_queue_mux;
    logic [DESC_ID_WIDTH-1:0] egr_enq_desc_id_mux;
    logic [6:0] egr_enq_cell_count_mux;
    
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
    
    assign egr_enq_port = lookup_result.dst_port;
    assign egr_enq_queue = lookup_result.queue_id;
    assign egr_enq_desc_id = lookup_result.desc_id;
    assign egr_enq_cell_count = desc_rd_data.cell_count;
    assign desc_rd_addr = lookup_result.desc_id;
    
    //------------------------------------------------------------------------
    // Egress调度器实例 (保留)
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
    // 新增: Egress Output Controller实例
    //------------------------------------------------------------------------
    logic [NUM_PORTS-1:0] egr_deq_ack;
    pkt_desc_t egr_desc_rd_data [NUM_PORTS-1:0];
    
    // 为每个端口提供描述符数据
    generate
        for (genvar i = 0; i < NUM_PORTS; i++) begin : gen_egr_desc
            assign egr_desc_rd_data[i] = desc_rd_data;  // 简化：共享
        end
    endgenerate
    
    egress_output_ctrl u_egress_output (
        .clk            (clk),
        .rst_n          (rst_n),
        .deq_valid      (egr_deq_valid),
        .deq_desc_id    (egr_deq_desc_id),
        .deq_queue      (egr_deq_queue),
        .deq_ack        (egr_deq_ack),
        .buf_rd_req     (buf_rd_req),
        .buf_rd_desc_id (buf_rd_desc_id),
        .buf_rd_valid   (buf_rd_valid),
        .buf_rd_sop     (buf_rd_sop),
        .buf_rd_eop     (buf_rd_eop),
        .buf_rd_data    (buf_rd_data),
        .buf_rd_ready   (buf_rd_ready),
        .desc_rd_data   (egr_desc_rd_data),
        .release_req    (release_req),
        .release_desc_id(release_desc_id),
        .release_done   (release_done),
        .port_tx_valid  (port_tx_valid),
        .port_tx_sop    (port_tx_sop),
        .port_tx_eop    (port_tx_eop),
        .port_tx_data   (port_tx_data),
        .port_tx_empty  (port_tx_empty),
        .port_tx_ready  (port_tx_ready),
        .pause_tx_valid (tx_pause_valid),
        .pause_tx_sop   (tx_pause_sop),
        .pause_tx_eop   (tx_pause_eop),
        .pause_tx_data  (tx_pause_data),
        .pause_tx_empty (tx_pause_empty),
        .pause_tx_ack   (tx_pause_ack),
        .stat_egr_out_pkts(stat_egr_out_pkts)
    );
    
    assign egr_deq_req = port_tx_ready;
    
    //------------------------------------------------------------------------
    // 老化定时器 (保留)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            age_counter <= '0;
            age_tick <= 1'b0;
        end else begin
            age_tick <= 1'b0;
            age_counter <= age_counter + 1;
            if (age_counter[27:0] == '1) begin
                age_tick <= 1'b1;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 端口配置初始化 (保留并增强)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                port_config[p].enabled <= 1'b1;
                port_config[p].state <= PORT_FORWARDING;
                port_config[p].fwd_mode <= FWD_STORE_AND_FORWARD;
                port_config[p].default_vid <= 12'd1;
                port_config[p].default_pcp <= 3'd0;
                port_config[p].mtu <= DEFAULT_MTU;
                port_config[p].mirror_enable <= 1'b0;
                port_config[p].mirror_dest <= '0;
                port_config[p].mirror_ingress <= 1'b0;
                port_config[p].mirror_egress <= 1'b0;
                port_config[p].flow_ctrl_enable <= 1'b0;
                
                // 端口MAC地址 (用于PAUSE帧)
                port_src_mac[p] <= 48'h001122334400 + p;
                
                for (int t = 0; t < STORM_CTRL_TYPES; t++) begin
                    storm_ctrl_cfg[p][t].enabled <= 1'b0;
                    storm_ctrl_cfg[p][t].pir <= DEFAULT_PIR;
                    storm_ctrl_cfg[p][t].cbs <= DEFAULT_CBS;
                end
            end
            
            for (int v = 0; v < MAX_VLAN; v++) begin
                vlan_member[v] <= '0;
            end
            vlan_member[1] <= '1;
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                port_config[p] <= port_config[p];
            end
        end
    end
    
    //------------------------------------------------------------------------
    // CPU配置接口 (保留并增强)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_rd_data <= '0;
            stats_read_port <= '0;
            stats_read_counter_id <= '0;
            stats_clear_req <= 1'b0;
            stats_clear_port <= '0;
        end else begin
            cfg_rd_data <= '0;
            stats_clear_req <= 1'b0;
            
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
                
                4'h1: begin  // 端口统计 (新增)
                    stats_read_port <= cfg_addr[11:6];
                    stats_read_counter_id <= cfg_addr[5:0];
                    cfg_rd_data <= stats_read_value;
                end
                
                4'h2: begin  // LAG统计 (新增)
                    automatic int lag_idx = cfg_addr[2:0];
                    case (cfg_addr[3])
                        1'b0: cfg_rd_data <= stat_lag_rx[lag_idx];
                        1'b1: cfg_rd_data <= stat_lag_tx[lag_idx];
                    endcase
                end
                
                4'h3: begin  // IGMP统计 (新增)
                    case (cfg_addr[1:0])
                        2'd0: cfg_rd_data <= stat_igmp_report;
                        2'd1: cfg_rd_data <= stat_igmp_leave;
                        2'd2: cfg_rd_data <= stat_igmp_query;
                        2'd3: cfg_rd_data <= {16'b0, stat_group_count};
                    endcase
                end
            endcase
            
            // 统计清零
            if (cfg_wr_en && cfg_addr[15:12] == 4'hF) begin
                stats_clear_req <= 1'b1;
                stats_clear_port <= cfg_wr_data[PORT_WIDTH-1:0];
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 中断 (保留)
    //------------------------------------------------------------------------
    assign irq_learn = mac_learn_done && mac_learn_success;
    assign irq_link = 1'b0;
    assign irq_overflow = nearly_empty;

endmodule : switch_core
