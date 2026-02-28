//============================================================================
// 1.2Tbps 48x25G L2 Switch Core - Package Definitions
// 基础数据类型和参数定义
//============================================================================
`timescale 1ns/1ps

package switch_pkg;

    //------------------------------------------------------------------------
    // 系统参数
    //------------------------------------------------------------------------
    parameter int NUM_PORTS          = 48;           // 端口数量
    parameter int PORT_WIDTH         = 6;            // 端口ID位宽
    parameter int PORT_SPEED_GBPS    = 25;           // 单端口速率
    
    parameter int CELL_SIZE          = 128;          // Cell大小 (Bytes)
    parameter int CELL_SIZE_BITS     = CELL_SIZE * 8;// Cell大小 (bits)
    parameter int TOTAL_CELLS        = 65536;        // 64K Cells
    parameter int CELL_ID_WIDTH      = 16;           // Cell ID位宽
    parameter int NUM_BANKS          = 16;           // 内存Bank数
    parameter int NUM_FREE_POOLS     = 4;            // 空闲池数量
    
    parameter int MAC_TABLE_SIZE     = 32768;        // MAC表容量 32K
    parameter int MAC_TABLE_WAYS     = 4;            // 4路组相联
    parameter int MAC_TABLE_SETS     = MAC_TABLE_SIZE / MAC_TABLE_WAYS; // 8K Sets
    parameter int MAC_SET_IDX_WIDTH  = 13;           // Set索引位宽
    
    parameter int NUM_QUEUES_PER_PORT = 8;           // 每端口队列数
    parameter int TOTAL_QUEUES       = NUM_PORTS * NUM_QUEUES_PER_PORT;
    parameter int QUEUE_ID_WIDTH     = 3;            // 队列ID位宽
    
    parameter int VLAN_ID_WIDTH      = 12;           // VLAN ID位宽
    parameter int MAX_VLAN           = 4096;
    
    parameter int DESC_POOL_SIZE     = 4096;         // 描述符池大小
    parameter int DESC_ID_WIDTH      = 12;           // 描述符ID位宽
    
    parameter int MAX_PKT_LEN        = 16384;        // 最大包长 16KB
    parameter int PKT_LEN_WIDTH      = 14;           // 包长位宽
    parameter int DEFAULT_MTU        = 1518;         // 默认MTU
    
    // Flow Control参数
    parameter int XOFF_THRESHOLD     = 1000;         // PAUSE生成阈值 (cells)
    parameter int XON_THRESHOLD      = 2000;         // PAUSE解除阈值 (cells)
    parameter int PAUSE_QUANTA       = 65535;        // PAUSE时间量 (512 bit times)
    
    // Storm Control参数
    parameter int STORM_CTRL_TYPES   = 3;            // B/M/U types
    parameter int DEFAULT_PIR        = 100000000;    // 100MB/s default
    parameter int DEFAULT_CBS        = 10000;        // 10KB burst
    
    // ACL参数
    parameter int ACL_TABLE_SIZE     = 256;          // ACL规则数量
    parameter int ACL_TABLE_WIDTH    = 8;            // ACL索引位宽
    
    // 核心总线参数
    parameter int CORE_DATA_WIDTH    = 4096;         // 核心数据位宽
    parameter int CORE_FREQ_MHZ      = 500;          // 核心频率
    
    //------------------------------------------------------------------------
    // 枚举类型
    //------------------------------------------------------------------------
    
    // 转发模式
    typedef enum logic [0:0] {
        FWD_STORE_AND_FORWARD = 1'b0,
        FWD_CUT_THROUGH       = 1'b1
    } forward_mode_e;
    
    // 队列状态
    typedef enum logic [1:0] {
        Q_STATE_EMPTY     = 2'b00,
        Q_STATE_NORMAL    = 2'b01,
        Q_STATE_CONGESTED = 2'b10,
        Q_STATE_BLOCKED   = 2'b11
    } queue_state_e;
    
    // VLAN动作
    typedef enum logic [1:0] {
        VLAN_ACT_NONE = 2'b00,
        VLAN_ACT_PUSH = 2'b01,
        VLAN_ACT_POP  = 2'b10,
        VLAN_ACT_SWAP = 2'b11
    } vlan_action_e;
    
    // ACL动作
    typedef enum logic [1:0] {
        ACL_PERMIT     = 2'b00,
        ACL_DENY       = 2'b01,
        ACL_MIRROR     = 2'b10,
        ACL_RATE_LIMIT = 2'b11
    } acl_action_e;
    
    // 端口STP状态
    typedef enum logic [1:0] {
        PORT_DISABLED   = 2'b00,
        PORT_BLOCKING   = 2'b01,
        PORT_LEARNING   = 2'b10,
        PORT_FORWARDING = 2'b11
    } port_state_e;
    
    // Storm Control流量类型
    typedef enum logic [1:0] {
        TRAFFIC_UNICAST   = 2'b00,
        TRAFFIC_MULTICAST = 2'b01,
        TRAFFIC_BROADCAST = 2'b10,
        TRAFFIC_UNKNOWN   = 2'b11
    } traffic_type_e;
    
    //------------------------------------------------------------------------
    // 数据结构定义
    //------------------------------------------------------------------------
    
    // Cell元数据 (32bit)
    typedef struct packed {
        logic [CELL_ID_WIDTH-1:0] next_ptr;    // 16bit: 下一个Cell指针
        logic [2:0]               ref_cnt;     // 3bit: 引用计数
        logic                     eop;         // 1bit: 报文结束标记
        logic                     valid;       // 1bit: 有效标记
        logic [10:0]              reserved;    // 11bit: 预留
    } cell_meta_t;
    
    // 报文描述符 (128bit)
    typedef struct packed {
        logic [CELL_ID_WIDTH-1:0] head_ptr;    // 16bit: 首Cell指针
        logic [CELL_ID_WIDTH-1:0] tail_ptr;    // 16bit: 尾Cell指针
        logic [6:0]               cell_count;  // 7bit: Cell数量
        logic [PKT_LEN_WIDTH-1:0] pkt_len;     // 14bit: 报文长度
        logic [PORT_WIDTH-1:0]    src_port;    // 6bit: 源端口
        logic [PORT_WIDTH-1:0]    dst_port;    // 6bit: 目的端口
        logic [QUEUE_ID_WIDTH-1:0] queue_id;   // 3bit: 目的队列
        logic                     multicast;   // 1bit: 组播标记
        logic [7:0]               mc_group_id; // 8bit: 组播组ID
        vlan_action_e             vlan_action; // 2bit: VLAN动作
        logic [VLAN_ID_WIDTH-1:0] new_vid;     // 12bit: 新VLAN ID
        logic [2:0]               new_pcp;     // 3bit: 新PCP
        logic [15:0]              timestamp;   // 16bit: 时间戳
        logic                     drop_eligible;// 1bit: 可丢弃
        logic [16:0]              reserved;    // 17bit: 预留
    } pkt_desc_t;
    
    // 队列描述符 (64bit)
    typedef struct packed {
        logic [DESC_ID_WIDTH-1:0] head;        // 12bit: 队列头 (描述符ID)
        logic [DESC_ID_WIDTH-1:0] tail;        // 12bit: 队列尾
        logic [15:0]              length;      // 16bit: 队列深度 (Cell数)
        queue_state_e             state;       // 2bit: 队列状态
        logic [21:0]              reserved;    // 22bit: 预留
    } queue_desc_t;
    
    // MAC表条目 (72bit)
    typedef struct packed {
        logic [47:0]              mac_addr;    // 48bit: MAC地址
        logic [VLAN_ID_WIDTH-1:0] vid;         // 12bit: VLAN ID
        logic [PORT_WIDTH-1:0]    port;        // 6bit: 端口号
        logic                     is_static;   // 1bit: 静态条目
        logic [1:0]               age;         // 2bit: 老化计数
        logic                     valid;       // 1bit: 有效标记
        logic [1:0]               reserved;    // 2bit: 预留
    } mac_entry_t;
    
    // 解析后的报文头
    typedef struct packed {
        logic [47:0]              dmac;        // 目的MAC
        logic [47:0]              smac;        // 源MAC
        logic [VLAN_ID_WIDTH-1:0] vid;         // VLAN ID
        logic [2:0]               pcp;         // Priority
        logic                     dei;         // Drop Eligible
        logic                     has_vlan;    // 是否有VLAN tag
        logic [15:0]              ethertype;   // 以太类型
        logic [PKT_LEN_WIDTH-1:0] pkt_len;     // 报文长度
    } parsed_hdr_t;
    
    // Ingress到Lookup的请求
    typedef struct packed {
        logic [47:0]              dmac;
        logic [47:0]              smac;
        logic [VLAN_ID_WIDTH-1:0] vid;
        logic [PORT_WIDTH-1:0]    src_port;
        logic [QUEUE_ID_WIDTH-1:0] queue_id;
        logic [DESC_ID_WIDTH-1:0] desc_id;
        logic                     valid;
    } ingress_lookup_req_t;
    
    // Lookup结果
    typedef struct packed {
        logic [PORT_WIDTH-1:0]    dst_port;    // 单播目的端口
        logic [NUM_PORTS-1:0]     dst_mask;    // 组播/广播位图
        logic                     is_unicast;  // 单播标记
        logic                     is_flood;    // 泛洪标记
        logic                     drop;        // 丢弃标记
        logic [DESC_ID_WIDTH-1:0] desc_id;
        logic [QUEUE_ID_WIDTH-1:0] queue_id;
        logic                     valid;
    } lookup_result_t;
    
    // 端口配置
    typedef struct packed {
        logic                     enabled;
        port_state_e              state;
        forward_mode_e            fwd_mode;
        logic [VLAN_ID_WIDTH-1:0] default_vid;
        logic [2:0]               default_pcp;
        // P0 Features
        logic [PKT_LEN_WIDTH-1:0] mtu;              // MTU (default 1518, max 16384)
        logic                     mirror_enable;    // Port mirroring enabled
        logic [PORT_WIDTH-1:0]    mirror_dest;      // Mirror destination port
        logic                     mirror_ingress;   // Mirror ingress traffic
        logic                     mirror_egress;    // Mirror egress traffic
        logic                     flow_ctrl_enable; // 802.3x flow control enabled
    } port_config_t;
    
    // Storm Control配置 (per-port, per-traffic-type)
    typedef struct packed {
        logic                     enabled;
        logic [31:0]              pir;              // Peak Information Rate (bytes/sec)
        logic [31:0]              cbs;              // Committed Burst Size (bytes)
    } storm_ctrl_cfg_t;
    
    // ACL规则
    typedef struct packed {
        logic                     valid;
        // Match fields with masks
        logic [47:0]              smac;
        logic [47:0]              smac_mask;
        logic [47:0]              dmac;
        logic [47:0]              dmac_mask;
        logic [VLAN_ID_WIDTH-1:0] vid;
        logic [VLAN_ID_WIDTH-1:0] vid_mask;
        logic [15:0]              ethertype;
        logic [15:0]              ethertype_mask;
        logic [PORT_WIDTH-1:0]    src_port;
        logic [PORT_WIDTH-1:0]    src_port_mask;
        // Action
        acl_action_e              action;
        logic [PORT_WIDTH-1:0]    mirror_port;      // For ACL_MIRROR action
        logic [QUEUE_ID_WIDTH-1:0] remap_queue;     // QoS remap
    } acl_rule_t;
    
    // ACL查找请求
    typedef struct packed {
        logic                     valid;
        logic [47:0]              smac;
        logic [47:0]              dmac;
        logic [VLAN_ID_WIDTH-1:0] vid;
        logic [15:0]              ethertype;
        logic [PORT_WIDTH-1:0]    src_port;
    } acl_lookup_req_t;
    
    // ACL查找结果
    typedef struct packed {
        logic                     valid;
        logic                     hit;
        acl_action_e              action;
        logic [PORT_WIDTH-1:0]    mirror_port;
        logic [QUEUE_ID_WIDTH-1:0] remap_queue;
    } acl_lookup_resp_t;
    
    //------------------------------------------------------------------------
    // 接口信号
    //------------------------------------------------------------------------
    
    // Cell分配接口
    typedef struct packed {
        logic                     req;
        logic [1:0]               pool_hint;
    } cell_alloc_req_t;
    
    typedef struct packed {
        logic                     ack;
        logic                     success;
        logic [CELL_ID_WIDTH-1:0] cell_id;
    } cell_alloc_resp_t;
    
    // Cell释放接口
    typedef struct packed {
        logic                     req;
        logic [CELL_ID_WIDTH-1:0] cell_id;
    } cell_free_req_t;
    
    // 内存读写接口
    typedef struct packed {
        logic                     req;
        logic                     wr_en;
        logic [CELL_ID_WIDTH-1:0] cell_id;
        logic [CELL_SIZE_BITS-1:0] wr_data;
    } mem_req_t;
    
    typedef struct packed {
        logic                     ack;
        logic [CELL_SIZE_BITS-1:0] rd_data;
    } mem_resp_t;
    
    // Flow Control接口
    typedef struct packed {
        logic                     pause_req;        // 请求发送PAUSE帧
        logic [15:0]              pause_quanta;     // PAUSE时间
    } flow_ctrl_tx_t;
    
    typedef struct packed {
        logic                     paused;           // 端口被PAUSE
        logic [15:0]              pause_timer;      // 剩余PAUSE时间
    } flow_ctrl_status_t;
    
    // IGMP Snooping接口
    typedef struct packed {
        logic                     valid;
        logic [47:0]              dmac;
        logic [47:0]              smac;
        logic [VLAN_ID_WIDTH-1:0] vid;
        logic [15:0]              ethertype;
        logic [7:0]               ip_proto;
        logic [31:0]              dst_ip;
        logic [7:0]               igmp_type;
        logic [31:0]              igmp_group;
        logic [PORT_WIDTH-1:0]    src_port;
    } igmp_pkt_info_t;

endpackage : switch_pkg
