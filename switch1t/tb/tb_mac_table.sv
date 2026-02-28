//============================================================================
// Testbench for MAC Table
// 独立测试MAC查表引擎
//============================================================================

`timescale 1ns/1ps

module tb_mac_table;
    import switch_pkg::*;
    
    //------------------------------------------------------------------------
    // 信号定义
    //------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    // 查表接口
    logic                      lookup_req;
    logic [47:0]               lookup_mac;
    logic [VLAN_ID_WIDTH-1:0]  lookup_vid;
    logic                      lookup_valid;
    logic                      lookup_hit;
    logic [PORT_WIDTH-1:0]     lookup_port;
    
    // 学习接口
    logic                      learn_req;
    logic [47:0]               learn_mac;
    logic [VLAN_ID_WIDTH-1:0]  learn_vid;
    logic [PORT_WIDTH-1:0]     learn_port;
    logic                      learn_done;
    logic                      learn_success;
    
    // 配置接口
    logic                      cfg_wr_en;
    logic [MAC_SET_IDX_WIDTH-1:0] cfg_set_idx;
    logic [1:0]                cfg_way;
    mac_entry_t                cfg_entry;
    
    // 老化
    logic                      age_tick;
    
    // 统计
    logic [31:0]               stat_lookup_cnt;
    logic [31:0]               stat_hit_cnt;
    logic [31:0]               stat_miss_cnt;
    logic [31:0]               stat_learn_cnt;
    logic [15:0]               stat_entry_cnt;
    
    //------------------------------------------------------------------------
    // 时钟生成
    //------------------------------------------------------------------------
    initial clk = 0;
    always #1 clk = ~clk;  // 500MHz
    
    //------------------------------------------------------------------------
    // DUT实例化
    //------------------------------------------------------------------------
    mac_table dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req     (lookup_req),
        .lookup_mac     (lookup_mac),
        .lookup_vid     (lookup_vid),
        .lookup_valid   (lookup_valid),
        .lookup_hit     (lookup_hit),
        .lookup_port    (lookup_port),
        .learn_req      (learn_req),
        .learn_mac      (learn_mac),
        .learn_vid      (learn_vid),
        .learn_port     (learn_port),
        .learn_done     (learn_done),
        .learn_success  (learn_success),
        .cfg_wr_en      (cfg_wr_en),
        .cfg_set_idx    (cfg_set_idx),
        .cfg_way        (cfg_way),
        .cfg_entry      (cfg_entry),
        .age_tick       (age_tick),
        .stat_lookup_cnt(stat_lookup_cnt),
        .stat_hit_cnt   (stat_hit_cnt),
        .stat_miss_cnt  (stat_miss_cnt),
        .stat_learn_cnt (stat_learn_cnt),
        .stat_entry_cnt (stat_entry_cnt)
    );
    
    //------------------------------------------------------------------------
    // 测试任务
    //------------------------------------------------------------------------
    task automatic do_learn(
        input [47:0] mac,
        input [11:0] vid,
        input [5:0] port
    );
        @(posedge clk);
        learn_req = 1;
        learn_mac = mac;
        learn_vid = vid;
        learn_port = port;
        @(posedge clk);
        learn_req = 0;
        
        // 等待完成
        wait(learn_done);
        @(posedge clk);
        
        if (learn_success)
            $display("[%0t] Learn: MAC=%h VID=%0d Port=%0d - SUCCESS", $time, mac, vid, port);
        else
            $display("[%0t] Learn: MAC=%h VID=%0d Port=%0d - FAILED", $time, mac, vid, port);
    endtask
    
    task automatic do_lookup(
        input [47:0] mac,
        input [11:0] vid
    );
        @(posedge clk);
        lookup_req = 1;
        lookup_mac = mac;
        lookup_vid = vid;
        @(posedge clk);
        lookup_req = 0;
        
        // 等待结果 (3-5 cycles流水线)
        repeat(5) @(posedge clk);
        
        if (lookup_valid) begin
            if (lookup_hit)
                $display("[%0t] Lookup: MAC=%h VID=%0d -> Port=%0d (HIT)", 
                         $time, mac, vid, lookup_port);
            else
                $display("[%0t] Lookup: MAC=%h VID=%0d -> MISS", $time, mac, vid);
        end
    endtask
    
    //------------------------------------------------------------------------
    // 测试流程
    //------------------------------------------------------------------------
    initial begin
        $display("\n############################################");
        $display("# MAC Table Testbench");
        $display("############################################\n");
        
        // 初始化
        rst_n = 0;
        lookup_req = 0;
        learn_req = 0;
        cfg_wr_en = 0;
        age_tick = 0;
        
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        //--------------------------------------------------------------------
        // 测试1: 基本学习和查表
        //--------------------------------------------------------------------
        $display("\n--- Test 1: Basic Learning and Lookup ---");
        
        // 学习几个MAC地址
        do_learn(48'h00AABBCCDDEE, 12'd1, 6'd0);
        do_learn(48'h001122334455, 12'd1, 6'd1);
        do_learn(48'h00DEADBEEF00, 12'd1, 6'd2);
        
        repeat(10) @(posedge clk);
        
        // 查表
        do_lookup(48'h00AABBCCDDEE, 12'd1);  // 应命中, port 0
        do_lookup(48'h001122334455, 12'd1);  // 应命中, port 1
        do_lookup(48'h00DEADBEEF00, 12'd1);  // 应命中, port 2
        do_lookup(48'h00FFFFFFFFFF, 12'd1);  // 应未命中
        
        //--------------------------------------------------------------------
        // 测试2: 不同VLAN
        //--------------------------------------------------------------------
        $display("\n--- Test 2: Different VLANs ---");
        
        do_learn(48'h00AABBCCDDEE, 12'd100, 6'd10);  // 同MAC不同VLAN
        do_lookup(48'h00AABBCCDDEE, 12'd1);   // VLAN 1 -> port 0
        do_lookup(48'h00AABBCCDDEE, 12'd100); // VLAN 100 -> port 10
        
        //--------------------------------------------------------------------
        // 测试3: MAC更新 (同MAC同VLAN不同端口)
        //--------------------------------------------------------------------
        $display("\n--- Test 3: MAC Update ---");
        
        do_learn(48'h00AABBCCDDEE, 12'd1, 6'd5);  // 更新端口
        do_lookup(48'h00AABBCCDDEE, 12'd1);  // 应返回 port 5
        
        //--------------------------------------------------------------------
        // 测试4: 大量学习
        //--------------------------------------------------------------------
        $display("\n--- Test 4: Bulk Learning (1000 entries) ---");
        
        for (int i = 0; i < 1000; i++) begin
            automatic logic [47:0] mac = {40'h00112233, i[15:0]};
            automatic logic [5:0] port = i % 48;
            
            learn_req = 1;
            learn_mac = mac;
            learn_vid = 12'd1;
            learn_port = port;
            @(posedge clk);
            learn_req = 0;
            wait(learn_done);
            @(posedge clk);
        end
        
        $display("Learned 1000 entries. Entry count: %0d", stat_entry_cnt);
        
        //--------------------------------------------------------------------
        // 测试5: 查表性能
        //--------------------------------------------------------------------
        $display("\n--- Test 5: Lookup Performance ---");
        
        // 连续查表
        for (int i = 0; i < 100; i++) begin
            lookup_req = 1;
            lookup_mac = {40'h00112233, i[15:0]};
            lookup_vid = 12'd1;
            @(posedge clk);
        end
        lookup_req = 0;
        
        repeat(20) @(posedge clk);
        
        $display("Lookup count: %0d", stat_lookup_cnt);
        $display("Hit count: %0d", stat_hit_cnt);
        $display("Miss count: %0d", stat_miss_cnt);
        $display("Hit rate: %0.2f%%", 100.0 * stat_hit_cnt / stat_lookup_cnt);
        
        //--------------------------------------------------------------------
        // 测试6: 老化
        //--------------------------------------------------------------------
        $display("\n--- Test 6: Aging ---");
        
        // 触发老化
        @(posedge clk);
        age_tick = 1;
        @(posedge clk);
        age_tick = 0;
        
        // 等待老化扫描完成
        repeat(MAC_TABLE_SETS * MAC_TABLE_WAYS + 100) @(posedge clk);
        
        $display("Entry count after aging: %0d", stat_entry_cnt);
        
        //--------------------------------------------------------------------
        // 打印统计
        //--------------------------------------------------------------------
        $display("\n############################################");
        $display("# Final Statistics");
        $display("############################################");
        $display("  Lookup Count:  %0d", stat_lookup_cnt);
        $display("  Hit Count:     %0d", stat_hit_cnt);
        $display("  Miss Count:    %0d", stat_miss_cnt);
        $display("  Learn Count:   %0d", stat_learn_cnt);
        $display("  Entry Count:   %0d", stat_entry_cnt);
        $display("############################################\n");
        
        repeat(100) @(posedge clk);
        $finish;
    end
    
    //------------------------------------------------------------------------
    // 波形
    //------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_mac_table.vcd");
        $dumpvars(0, tb_mac_table);
    end
    
    //------------------------------------------------------------------------
    // 超时
    //------------------------------------------------------------------------
    initial begin
        #500000;
        $display("Timeout!");
        $finish;
    end

endmodule : tb_mac_table
