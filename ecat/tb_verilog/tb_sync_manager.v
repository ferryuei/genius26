// ============================================================================
// Sync Manager Testbench (Pure Verilog-2001)
// Tests mailbox mode and 3-buffer mode operations
// Compatible with: Verilator, VCS (RTL uses SystemVerilog constructs)
// ============================================================================

`timescale 1ns/1ps

module tb_sync_manager;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT_CYCLES = 100;

// SM Control Register bits
parameter CTRL_MODE_BIT0    = 0;
parameter CTRL_MODE_BIT1    = 1;
parameter CTRL_DIRECTION    = 2;
parameter CTRL_IRQ_ECAT     = 3;
parameter CTRL_IRQ_PDI      = 4;

// SM Status Register bits
parameter STAT_IRQ_WRITE    = 0;
parameter STAT_IRQ_READ     = 1;
parameter STAT_BUFFER_WRITTEN = 2;
parameter STAT_MAILBOX_FULL = 3;

// Operating modes
parameter MODE_3BUFFER = 8'h00;
parameter MODE_MAILBOX = 8'h02;

// Register offsets
parameter REG_START_ADDR = 8'h00;
parameter REG_LENGTH     = 8'h02;
parameter REG_CONTROL    = 8'h04;
parameter REG_STATUS     = 8'h05;
parameter REG_ACTIVATE   = 8'h06;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     pdi_clk;
reg                     rst_n;
reg  [255:0]            feature_vector;

// Configuration interface
reg                     cfg_wr;
reg  [7:0]              cfg_addr;
reg  [15:0]             cfg_wdata;
wire [15:0]             cfg_rdata;

// ECAT interface
reg                     ecat_req;
reg                     ecat_wr;
reg  [15:0]             ecat_addr;
reg  [7:0]              ecat_wdata;
wire                    ecat_ack;
wire [7:0]              ecat_rdata;

// PDI interface
reg                     pdi_req;
reg                     pdi_wr;
reg  [15:0]             pdi_addr;
reg  [7:0]              pdi_wdata;
wire                    pdi_ack;
wire [7:0]              pdi_rdata;

// Memory interface
wire                    mem_req;
wire                    mem_wr;
wire [15:0]             mem_addr;
wire [7:0]              mem_wdata;
reg                     mem_ack;
reg  [7:0]              mem_rdata;

// Status
wire                    sm_irq;
wire                    sm_active;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;
integer i;
reg [15:0] status_val;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_sync_manager dut (
    .clk(clk),
    .pdi_clk(pdi_clk),
    .rst_n(rst_n),
    .feature_vector(feature_vector),
    .cfg_wr(cfg_wr),
    .cfg_addr(cfg_addr),
    .cfg_wdata(cfg_wdata),
    .cfg_rdata(cfg_rdata),
    .ecat_req(ecat_req),
    .ecat_wr(ecat_wr),
    .ecat_addr(ecat_addr),
    .ecat_wdata(ecat_wdata),
    .ecat_ack(ecat_ack),
    .ecat_rdata(ecat_rdata),
    .pdi_req(pdi_req),
    .pdi_wr(pdi_wr),
    .pdi_addr(pdi_addr),
    .pdi_wdata(pdi_wdata),
    .pdi_ack(pdi_ack),
    .pdi_rdata(pdi_rdata),
    .mem_req(mem_req),
    .mem_wr(mem_wr),
    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),
    .mem_ack(mem_ack),
    .mem_rdata(mem_rdata),
    .sm_irq(sm_irq),
    .sm_active(sm_active)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

initial begin
    pdi_clk = 0;
    forever #(CLK_PERIOD/2) pdi_clk = ~pdi_clk;
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_sync_manager.vcd");
    $dumpvars(0, tb_sync_manager);
end

// ============================================================================
// Tasks: Check Pass/Fail
// ============================================================================
task check_pass;
    input [255:0] name;
    input condition;
    begin
        if (condition) begin
            $display("    [PASS] %0s", name);
            pass_count = pass_count + 1;
        end else begin
            $display("    [FAIL] %0s", name);
            fail_count = fail_count + 1;
        end
    end
endtask

// ============================================================================
// Tasks: Reset
// ============================================================================
task reset_dut;
    begin
        rst_n = 0;
        cfg_wr = 0;
        cfg_addr = 0;
        cfg_wdata = 0;
        ecat_req = 0;
        ecat_wr = 0;
        ecat_addr = 0;
        ecat_wdata = 0;
        pdi_req = 0;
        pdi_wr = 0;
        pdi_addr = 0;
        pdi_wdata = 0;
        mem_ack = 0;
        mem_rdata = 0;
        feature_vector = 256'h0;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: Configuration Write
// ============================================================================
task cfg_write;
    input [7:0] addr;
    input [15:0] data;
    begin
        @(posedge clk);
        cfg_wr = 1;
        cfg_addr = addr;
        cfg_wdata = data;
        @(posedge clk);
        cfg_wr = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Configuration Read
// ============================================================================
task cfg_read;
    input [7:0] addr;
    output [15:0] data;
    begin
        @(posedge clk);
        cfg_addr = addr;
        @(posedge clk);
        data = cfg_rdata;
    end
endtask

// ============================================================================
// Tasks: ECAT Write with Memory Handshake
// ============================================================================
task ecat_write_op;
    input [15:0] addr;
    input [7:0] data;
    begin
        @(posedge clk);
        ecat_req = 1;
        ecat_wr = 1;
        ecat_addr = addr;
        ecat_wdata = data;
        @(posedge clk);
        
        // Wait for memory access
        timeout_cnt = 0;
        while (!mem_req && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        if (mem_req) begin
            mem_ack = 1;
            @(posedge clk);
            mem_ack = 0;
        end
        
        // Wait for ECAT ack
        timeout_cnt = 0;
        while (!ecat_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        ecat_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: PDI Read with Memory Handshake
// ============================================================================
task pdi_read_op;
    input [15:0] addr;
    output [7:0] data;
    begin
        @(posedge clk);
        pdi_req = 1;
        pdi_wr = 0;
        pdi_addr = addr;
        @(posedge clk);
        
        // Wait for memory access
        timeout_cnt = 0;
        while (!mem_req && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        if (mem_req) begin
            mem_ack = 1;
            mem_rdata = 8'hAB;  // Test data
            @(posedge clk);
            mem_ack = 0;
        end
        
        // Wait for PDI ack
        timeout_cnt = 0;
        while (!pdi_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        data = pdi_rdata;
        pdi_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Configure for Mailbox Mode
// ============================================================================
task configure_mailbox;
    input [15:0] start;
    input [15:0] len;
    input ecat_writes;
    reg [7:0] ctrl;
    begin
        $display("  Configuring SM for mailbox mode");
        $display("    Start: 0x%04x, Length: %0d bytes", start, len);
        $display("    Direction: %s", ecat_writes ? "ECAT writes" : "PDI writes");
        
        cfg_write(REG_START_ADDR, start);
        cfg_write(REG_LENGTH, len);
        
        ctrl = MODE_MAILBOX;
        if (!ecat_writes) ctrl = ctrl | (1 << CTRL_DIRECTION);
        ctrl = ctrl | (1 << CTRL_IRQ_ECAT) | (1 << CTRL_IRQ_PDI);
        cfg_write(REG_CONTROL, {8'h00, ctrl});
        
        cfg_write(REG_ACTIVATE, 16'h0001);
        
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Configure for 3-Buffer Mode
// ============================================================================
task configure_3buffer;
    input [15:0] start;
    input [15:0] len;
    input ecat_writes;
    reg [7:0] ctrl;
    begin
        $display("  Configuring SM for 3-buffer mode");
        $display("    Start: 0x%04x, Length: %0d bytes", start, len);
        
        cfg_write(REG_START_ADDR, start);
        cfg_write(REG_LENGTH, len);
        
        ctrl = MODE_3BUFFER;
        if (!ecat_writes) ctrl = ctrl | (1 << CTRL_DIRECTION);
        ctrl = ctrl | (1 << CTRL_IRQ_ECAT) | (1 << CTRL_IRQ_PDI);
        cfg_write(REG_CONTROL, {8'h00, ctrl});
        
        cfg_write(REG_ACTIVATE, 16'h0001);
        
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Test 1: Mailbox Write-Read Sequence
// ============================================================================
task test_mailbox_write_read;
    reg [7:0] read_data;
    begin
        $display("\n=== TEST 1: Mailbox Write-Read Sequence ===");
        
        reset_dut;
        configure_mailbox(16'h1000, 16'd128, 1'b1);  // ECAT writes
        
        // Initial status
        cfg_read(REG_STATUS, status_val);
        $display("  Initial status: 0x%04x", status_val);
        check_pass("Initial mailbox not full", (status_val & (1 << STAT_MAILBOX_FULL)) == 0);
        
        // ECAT writes to mailbox
        $display("  EtherCAT writing to mailbox...");
        ecat_write_op(16'h1000, 8'h42);
        
        // Check mailbox full
        cfg_read(REG_STATUS, status_val);
        $display("  Status after write: 0x%04x", status_val);
        check_pass("Mailbox full after write", (status_val & (1 << STAT_MAILBOX_FULL)) != 0);
        check_pass("Write event occurred", (status_val & (1 << STAT_IRQ_WRITE)) != 0);
        check_pass("SM IRQ asserted", sm_irq != 0);
        
        repeat(5) @(posedge clk);
        
        // PDI reads from mailbox
        $display("  PDI reading from mailbox...");
        pdi_read_op(16'h1000, read_data);
        
        // Check mailbox cleared
        cfg_read(REG_STATUS, status_val);
        $display("  Status after read: 0x%04x", status_val);
        check_pass("Mailbox cleared after read", (status_val & (1 << STAT_MAILBOX_FULL)) == 0);
    end
endtask

// ============================================================================
// Test 2: 3-Buffer Mode
// ============================================================================
task test_3buffer_mode;
    begin
        $display("\n=== TEST 2: 3-Buffer Mode ===");
        
        reset_dut;
        configure_3buffer(16'h2000, 16'd64, 1'b1);  // ECAT writes
        
        // Initial status
        cfg_read(REG_STATUS, status_val);
        $display("  Initial status: 0x%04x", status_val);
        
        // ECAT writes
        $display("  EtherCAT writing to buffer...");
        ecat_write_op(16'h2000, 8'h55);
        
        // Check status
        cfg_read(REG_STATUS, status_val);
        $display("  Status after write: 0x%04x", status_val);
        check_pass("Write event in 3-buffer", (status_val & (1 << STAT_IRQ_WRITE)) != 0);
        check_pass("Buffer written flag", (status_val & (1 << STAT_BUFFER_WRITTEN)) != 0);
    end
endtask

// ============================================================================
// Test 3: Status Bit Verification
// ============================================================================
task test_status_bits;
    begin
        $display("\n=== TEST 3: Status Register Bit Positions ===");
        
        $display("  Verifying ETG.1000 compliant bit positions:");
        $display("    Bit 0: IRQ Write");
        $display("    Bit 1: IRQ Read");
        $display("    Bit 2: Buffer Written (3-buffer)");
        $display("    Bit 3: Mailbox Full (mailbox) / Buffer Full (3-buffer)");
        
        // Test mailbox mode bit 3
        reset_dut;
        configure_mailbox(16'h3000, 16'd32, 1'b1);
        ecat_write_op(16'h3000, 8'hAA);
        
        cfg_read(REG_STATUS, status_val);
        check_pass("Bit 3 set in mailbox mode", (status_val & 8'h08) != 0);
        
        // Test 3-buffer mode bit 2
        reset_dut;
        configure_3buffer(16'h4000, 16'd32, 1'b1);
        ecat_write_op(16'h4000, 8'hBB);
        
        cfg_read(REG_STATUS, status_val);
        check_pass("Bit 2 set in 3-buffer mode", (status_val & 8'h04) != 0);
    end
endtask

// ============================================================================
// Test 4: Mailbox PDI Writes
// ============================================================================
task test_mailbox_pdi_writes;
    begin
        $display("\n=== TEST 4: Mailbox Mode - PDI Writes ===");
        
        reset_dut;
        configure_mailbox(16'h5000, 16'd64, 1'b0);  // PDI writes
        
        cfg_read(REG_STATUS, status_val);
        check_pass("Initial mailbox not full", (status_val & (1 << STAT_MAILBOX_FULL)) == 0);
        
        // PDI writes to mailbox
        $display("  PDI writing to mailbox...");
        @(posedge clk);
        pdi_req = 1;
        pdi_wr = 1;
        pdi_addr = 16'h5000;
        pdi_wdata = 8'h77;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (!mem_req && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        if (mem_req) begin
            mem_ack = 1;
            @(posedge clk);
            mem_ack = 0;
        end
        
        timeout_cnt = 0;
        while (!pdi_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        pdi_req = 0;
        @(posedge clk);
        
        cfg_read(REG_STATUS, status_val);
        $display("  Status after PDI write: 0x%04x", status_val);
        check_pass("Mailbox full after PDI write", (status_val & (1 << STAT_MAILBOX_FULL)) != 0);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("==========================================");
    $display("Sync Manager Testbench");
    $display("==========================================");
    
    test_mailbox_write_read;
    test_3buffer_mode;
    test_status_bits;
    test_mailbox_pdi_writes;
    
    // Summary
    $display("\n==========================================");
    $display("Sync Manager Test Summary:");
    $display("  PASSED: %0d", pass_count);
    $display("  FAILED: %0d", fail_count);
    $display("==========================================");
    
    if (fail_count > 0)
        $display("TEST FAILED");
    else
        $display("TEST PASSED");
    
    $finish;
end

endmodule
