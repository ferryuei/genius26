//============================================================================
// MAC Table - MAC地址表查表引擎
// 功能: 32K条目, 4路组相联, Hash查表, MAC学习
//============================================================================
`timescale 1ns/1ps

module mac_table
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 查表接口 (流水线)
    input  logic                      lookup_req,
    input  logic [47:0]               lookup_mac,
    input  logic [VLAN_ID_WIDTH-1:0]  lookup_vid,
    output logic                      lookup_valid,
    output logic                      lookup_hit,
    output logic [PORT_WIDTH-1:0]     lookup_port,
    
    // 学习接口
    input  logic                      learn_req,
    input  logic [47:0]               learn_mac,
    input  logic [VLAN_ID_WIDTH-1:0]  learn_vid,
    input  logic [PORT_WIDTH-1:0]     learn_port,
    output logic                      learn_done,
    output logic                      learn_success,
    
    // 静态条目配置接口
    input  logic                      cfg_wr_en,
    input  logic [MAC_SET_IDX_WIDTH-1:0] cfg_set_idx,
    input  logic [1:0]                cfg_way,
    input  mac_entry_t                cfg_entry,
    
    // 老化触发
    input  logic                      age_tick,
    
    // 统计
    output logic [31:0]               stat_lookup_cnt,
    output logic [31:0]               stat_hit_cnt,
    output logic [31:0]               stat_miss_cnt,
    output logic [31:0]               stat_learn_cnt,
    output logic [15:0]               stat_entry_cnt
);

    //------------------------------------------------------------------------
    // MAC表存储 (4路组相联)
    //------------------------------------------------------------------------
    mac_entry_t mac_mem [MAC_TABLE_SETS-1:0][MAC_TABLE_WAYS-1:0];
    
    //------------------------------------------------------------------------
    // Hash计算
    //------------------------------------------------------------------------
    function automatic logic [MAC_SET_IDX_WIDTH-1:0] compute_hash(
        input logic [47:0] mac,
        input logic [VLAN_ID_WIDTH-1:0] vid
    );
        // 简化的CRC16 XOR VID
        logic [15:0] crc;
        crc = mac[15:0] ^ mac[31:16] ^ mac[47:32];
        return (crc ^ {4'b0, vid}) % MAC_TABLE_SETS;
    endfunction
    
    //------------------------------------------------------------------------
    // 查表流水线
    //------------------------------------------------------------------------
    // Stage 1: Hash计算
    logic                      s1_valid;
    logic [47:0]               s1_mac;
    logic [VLAN_ID_WIDTH-1:0]  s1_vid;
    logic [MAC_SET_IDX_WIDTH-1:0] s1_set_idx;
    
    // Stage 2: SRAM读取
    logic                      s2_valid;
    logic [47:0]               s2_mac;
    logic [VLAN_ID_WIDTH-1:0]  s2_vid;
    mac_entry_t                s2_entries [MAC_TABLE_WAYS-1:0];
    
    // Stage 3: 比较匹配
    logic                      s3_valid;
    logic                      s3_hit;
    logic [PORT_WIDTH-1:0]     s3_port;
    logic [MAC_SET_IDX_WIDTH-1:0] s3_set_idx;
    logic [1:0]                s3_hit_way;
    
    // Stage 1: Hash计算
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_mac <= '0;
            s1_vid <= '0;
            s1_set_idx <= '0;
        end else begin
            s1_valid <= lookup_req;
            if (lookup_req) begin
                s1_mac <= lookup_mac;
                s1_vid <= lookup_vid;
                s1_set_idx <= compute_hash(lookup_mac, lookup_vid);
            end
        end
    end
    
    // Stage 2: SRAM读取
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_mac <= '0;
            s2_vid <= '0;
        end else begin
            s2_valid <= s1_valid;
            s2_mac <= s1_mac;
            s2_vid <= s1_vid;
            
            if (s1_valid) begin
                for (int way = 0; way < MAC_TABLE_WAYS; way++) begin
                    s2_entries[way] <= mac_mem[s1_set_idx][way];
                end
            end
        end
    end
    
    // Stage 3: 比较匹配
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_hit <= 1'b0;
            s3_port <= '0;
        end else begin
            s3_valid <= s2_valid;
            s3_hit <= 1'b0;
            s3_port <= '0;
            
            if (s2_valid) begin
                for (int way = 0; way < MAC_TABLE_WAYS; way++) begin
                    if (s2_entries[way].valid &&
                        s2_entries[way].mac_addr == s2_mac &&
                        s2_entries[way].vid == s2_vid) begin
                        s3_hit <= 1'b1;
                        s3_port <= s2_entries[way].port;
                        s3_hit_way <= way[1:0];
                    end
                end
            end
        end
    end
    
    // 输出
    assign lookup_valid = s3_valid;
    assign lookup_hit = s3_hit;
    assign lookup_port = s3_port;
    
    //------------------------------------------------------------------------
    // MAC学习逻辑
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        LEARN_IDLE,
        LEARN_HASH,
        LEARN_READ,
        LEARN_CHECK,
        LEARN_WRITE,
        LEARN_DONE
    } learn_state_e;
    
    learn_state_e learn_state;
    
    logic [47:0]               learn_mac_r;
    logic [VLAN_ID_WIDTH-1:0]  learn_vid_r;
    logic [PORT_WIDTH-1:0]     learn_port_r;
    logic [MAC_SET_IDX_WIDTH-1:0] learn_set_idx;
    mac_entry_t                learn_entries [MAC_TABLE_WAYS-1:0];
    logic [1:0]                learn_target_way;
    logic                      learn_found_empty;
    logic                      learn_found_match;
    
    // Unified memory write interface
    logic mem_wr_en;
    logic [MAC_SET_IDX_WIDTH-1:0] mem_wr_set;
    logic [1:0] mem_wr_way;
    mac_entry_t mem_wr_data;
    
    typedef enum logic [1:0] {
        WR_SRC_NONE,
        WR_SRC_LEARN,
        WR_SRC_CONFIG,
        WR_SRC_AGING
    } mem_wr_source_t;
    
    mem_wr_source_t mem_wr_source;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            learn_state <= LEARN_IDLE;
            learn_done <= 1'b0;
            learn_success <= 1'b0;
            mem_wr_en <= 1'b0;
        end else begin
            learn_done <= 1'b0;
            mem_wr_en <= 1'b0;  // Default: clear write enable
            
            // Only clear learn_success when entering IDLE state
            if (learn_state == LEARN_IDLE && !learn_req) begin
                learn_success <= 1'b0;
            end
            
            case (learn_state)
                LEARN_IDLE: begin
                    if (learn_req) begin
                        learn_mac_r <= learn_mac;
                        learn_vid_r <= learn_vid;
                        learn_port_r <= learn_port;
                        learn_success <= 1'b0;  // Clear at start of new request
                        learn_state <= LEARN_HASH;
                    end
                end
                
                LEARN_HASH: begin
                    learn_set_idx <= compute_hash(learn_mac_r, learn_vid_r);
                    learn_state <= LEARN_READ;
                end
                
                LEARN_READ: begin
                    for (int way = 0; way < MAC_TABLE_WAYS; way++) begin
                        learn_entries[way] <= mac_mem[learn_set_idx][way];
                    end
                    learn_state <= LEARN_CHECK;
                end
                
                LEARN_CHECK: begin
                    learn_found_empty = 1'b0;
                    learn_found_match = 1'b0;
                    learn_target_way = '0;
                    
                    // 查找匹配或空闲条目
                    for (int way = 0; way < MAC_TABLE_WAYS; way++) begin
                        if (learn_entries[way].valid &&
                            learn_entries[way].mac_addr == learn_mac_r &&
                            learn_entries[way].vid == learn_vid_r) begin
                            // 已存在，更新
                            learn_found_match = 1'b1;
                            learn_target_way = way[1:0];
                        end else if (!learn_entries[way].valid && !learn_found_empty) begin
                            // 空闲条目
                            learn_found_empty = 1'b1;
                            learn_target_way = way[1:0];
                        end
                    end
                    
                    learn_state <= LEARN_WRITE;
                end
                
                LEARN_WRITE: begin
                    if (learn_found_match || learn_found_empty) begin
                        // Direct memory write - bypass unified interface
                        mac_mem[learn_set_idx][learn_target_way].mac_addr <= learn_mac_r;
                        mac_mem[learn_set_idx][learn_target_way].vid <= learn_vid_r;
                        mac_mem[learn_set_idx][learn_target_way].port <= learn_port_r;
                        mac_mem[learn_set_idx][learn_target_way].is_static <= 1'b0;
                        mac_mem[learn_set_idx][learn_target_way].age <= 2'b11;
                        mac_mem[learn_set_idx][learn_target_way].valid <= 1'b1;
                        learn_success <= 1'b1;
                    end
                    learn_state <= LEARN_DONE;
                end
                
                LEARN_DONE: begin
                    learn_done <= 1'b1;
                    // Keep learn_success valid here
                    learn_state <= LEARN_IDLE;
                end
                
                default: begin
                    // Handle unexpected states
                    learn_state <= LEARN_IDLE;
                end
            endcase
            
            // Config write has highest priority - can override learn
            if (cfg_wr_en) begin
                mem_wr_en <= 1'b1;
                mem_wr_source <= WR_SRC_CONFIG;
                mem_wr_set <= cfg_set_idx;
                mem_wr_way <= cfg_way;
                mem_wr_data <= cfg_entry;
            end
        end
    end
    
    //------------------------------------------------------------------------
    // 配置写入 - removed direct write, use unified interface
    //------------------------------------------------------------------------
    // Configuration requests now go through unified memory write
    
    //------------------------------------------------------------------------
    // 老化逻辑 - modified to use unified interface
    //------------------------------------------------------------------------
    logic [MAC_SET_IDX_WIDTH-1:0] age_scan_idx;
    logic [1:0]                   age_scan_way;
    logic                         age_scanning;
    logic                         age_wr_pending;
    mac_entry_t                   age_entry;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            age_scan_idx <= '0;
            age_scan_way <= '0;
            age_scanning <= 1'b0;
            age_wr_pending <= 1'b0;
        end else begin
            age_wr_pending <= 1'b0;
            
            if (age_tick && !age_scanning) begin
                age_scanning <= 1'b1;
                age_scan_idx <= '0;
                age_scan_way <= '0;
            end else if (age_scanning && !age_wr_pending) begin
                // Read entry
                age_entry <= mac_mem[age_scan_idx][age_scan_way];
                
                // Check if entry needs aging
                if (mac_mem[age_scan_idx][age_scan_way].valid &&
                    !mac_mem[age_scan_idx][age_scan_way].is_static) begin
                    
                    // Direct aging update
                    if (mac_mem[age_scan_idx][age_scan_way].age > 0) begin
                        mac_mem[age_scan_idx][age_scan_way].age <= mac_mem[age_scan_idx][age_scan_way].age - 1;
                    end else begin
                        // 老化删除
                        mac_mem[age_scan_idx][age_scan_way].valid <= 1'b0;
                    end
                    
                    age_wr_pending <= 1'b1;
                end
                
                // Move to next entry
                if (age_scan_way == MAC_TABLE_WAYS - 1) begin
                    age_scan_way <= '0;
                    if (age_scan_idx == MAC_TABLE_SETS - 1) begin
                        age_scanning <= 1'b0;
                    end else begin
                        age_scan_idx <= age_scan_idx + 1;
                    end
                end else begin
                    age_scan_way <= age_scan_way + 1;
                end
            end
        end
    end
    
    //------------------------------------------------------------------------
    // Config Write (separate from learn, handled via unified interface)
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (cfg_wr_en) begin
            mac_mem[cfg_set_idx][cfg_way] <= cfg_entry;
        end
    end
    
    //------------------------------------------------------------------------
    // 统计计数器
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_lookup_cnt <= '0;
            stat_hit_cnt <= '0;
            stat_miss_cnt <= '0;
            stat_learn_cnt <= '0;
        end else begin
            if (lookup_req) begin
                stat_lookup_cnt <= stat_lookup_cnt + 1;
            end
            if (s3_valid && s3_hit) begin
                stat_hit_cnt <= stat_hit_cnt + 1;
            end
            if (s3_valid && !s3_hit) begin
                stat_miss_cnt <= stat_miss_cnt + 1;
            end
            if (learn_done && learn_success) begin
                stat_learn_cnt <= stat_learn_cnt + 1;
            end
        end
    end
    
    // 条目计数
    always_comb begin
        stat_entry_cnt = '0;
        for (int s = 0; s < MAC_TABLE_SETS; s++) begin
            for (int w = 0; w < MAC_TABLE_WAYS; w++) begin
                if (mac_mem[s][w].valid) begin
                    stat_entry_cnt = stat_entry_cnt + 1;
                end
            end
        end
    end

endmodule : mac_table
