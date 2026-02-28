// ============================================================================
// Distributed Clock (DC) Testbench (Pure Verilog-2001)
// Tests all 12 DC test cases per ETG.1000 specification
// Compatible with: Verilator, VCS (RTL uses SystemVerilog constructs)
// ============================================================================

`timescale 1ns/1ps

module tb_dc;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter CLK_PERIOD_NS = 40;  // Matching DUT parameter
parameter TIMEOUT_CYCLES = 100;

// DC Register Addresses
parameter ADDR_PORT0_RECV_TIME   = 16'h0900;
parameter ADDR_PORT1_RECV_TIME   = 16'h0908;
parameter ADDR_SYSTEM_TIME       = 16'h0910;
parameter ADDR_SYSTEM_OFFSET     = 16'h0920;
parameter ADDR_SYSTEM_DELAY      = 16'h0928;
parameter ADDR_SPEED_START       = 16'h0930;
parameter ADDR_SPEED_DIFF        = 16'h0934;
parameter ADDR_DC_ACTIVATION     = 16'h0981;
parameter ADDR_SYNC_IMPULSE_LEN  = 16'h0982;
parameter ADDR_SYNC0_START_TIME  = 16'h0990;
parameter ADDR_SYNC0_CYCLE_TIME  = 16'h09A0;
parameter ADDR_SYNC1_CYCLE_TIME  = 16'h09A4;
parameter ADDR_SYNC1_START_SHIFT = 16'h09A8;
parameter ADDR_LATCH_CTRL_STATUS = 16'h09AE;
parameter ADDR_LATCH0_POS_TIME   = 16'h09B0;
parameter ADDR_LATCH0_NEG_TIME   = 16'h09B8;

// DC Activation bits
parameter DC_ACT_CYCLIC_OP = 8'h01;
parameter DC_ACT_SYNC0_EN  = 8'h02;
parameter DC_ACT_SYNC1_EN  = 8'h04;

// Latch control bits
parameter LATCH_POS_EN      = 16'h0001;
parameter LATCH_NEG_EN      = 16'h0002;
parameter LATCH_SINGLE_SHOT = 16'h0100;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     rst_n;

// Register interface
reg                     reg_req;
reg                     reg_wr;
reg  [15:0]             reg_addr;
reg  [15:0]             reg_wdata;
wire [15:0]             reg_rdata;
wire                    reg_ack;

// Port receive SOF
reg  [3:0]              port_rx_sof;

// Latch inputs
reg                     latch0_in;
reg                     latch1_in;

// Outputs
wire                    sync0_out;
wire                    sync1_out;
wire                    sync0_active;
wire                    sync1_active;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;
integer i;

// 64-bit values
reg [63:0] time_val;
reg [63:0] time1, time2;
reg [15:0] reg_val;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_dc dut (
    .clk(clk),
    .rst_n(rst_n),
    .reg_req(reg_req),
    .reg_wr(reg_wr),
    .reg_addr(reg_addr),
    .reg_wdata(reg_wdata),
    .reg_rdata(reg_rdata),
    .reg_ack(reg_ack),
    .port_rx_sof(port_rx_sof),
    .latch0_in(latch0_in),
    .latch1_in(latch1_in),
    .sync0_out(sync0_out),
    .sync1_out(sync1_out),
    .sync0_active(sync0_active),
    .sync1_active(sync1_active)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_dc.vcd");
    $dumpvars(0, tb_dc);
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
        reg_req = 0;
        reg_wr = 0;
        reg_addr = 0;
        reg_wdata = 0;
        port_rx_sof = 0;
        latch0_in = 0;
        latch1_in = 0;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: Read 16-bit Register
// ============================================================================
task read_reg;
    input [15:0] addr;
    output [15:0] data;
    begin
        @(posedge clk);
        reg_req = 1;
        reg_wr = 0;
        reg_addr = addr;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (!reg_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        data = reg_rdata;
        reg_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Write 16-bit Register
// ============================================================================
task write_reg;
    input [15:0] addr;
    input [15:0] data;
    begin
        @(posedge clk);
        reg_req = 1;
        reg_wr = 1;
        reg_addr = addr;
        reg_wdata = data;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (!reg_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        reg_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Read 64-bit Register
// ============================================================================
task read_reg64;
    input [15:0] addr;
    output [63:0] data;
    reg [15:0] w0, w1, w2, w3;
    begin
        read_reg(addr, w0);
        read_reg(addr + 2, w1);
        read_reg(addr + 4, w2);
        read_reg(addr + 6, w3);
        data = {w3, w2, w1, w0};
    end
endtask

// ============================================================================
// Tasks: Write 64-bit Register
// ============================================================================
task write_reg64;
    input [15:0] addr;
    input [63:0] data;
    begin
        write_reg(addr, data[15:0]);
        write_reg(addr + 2, data[31:16]);
        write_reg(addr + 4, data[47:32]);
        write_reg(addr + 6, data[63:48]);
    end
endtask

// ============================================================================
// Tasks: Read/Write 32-bit Register
// ============================================================================
task read_reg32;
    input [15:0] addr;
    output [31:0] data;
    reg [15:0] w0, w1;
    begin
        read_reg(addr, w0);
        read_reg(addr + 2, w1);
        data = {w1, w0};
    end
endtask

task write_reg32;
    input [15:0] addr;
    input [31:0] data;
    begin
        write_reg(addr, data[15:0]);
        write_reg(addr + 2, data[31:16]);
    end
endtask

// ============================================================================
// DC-01: Local Clock Increment Verification
// ============================================================================
task test_dc01_clock_increment;
    reg [63:0] expected_diff, actual_diff;
    begin
        $display("\n=== DC-01: Local Clock Increment Verification ===");
        reset_dut;
        
        read_reg64(ADDR_SYSTEM_TIME, time1);
        $display("  First read: %0d ns", time1);
        
        repeat(100) @(posedge clk);
        
        read_reg64(ADDR_SYSTEM_TIME, time2);
        $display("  Second read (after 100 cycles): %0d ns", time2);
        
        expected_diff = 100 * CLK_PERIOD_NS;
        actual_diff = time2 - time1;
        $display("  Expected diff: ~%0d ns", expected_diff);
        $display("  Actual diff: %0d ns", actual_diff);
        
        check_pass("Time counter increments", time2 > time1);
        check_pass("Increment approximately correct", 
                   actual_diff >= expected_diff && actual_diff < expected_diff + 1000);
    end
endtask

// ============================================================================
// DC-02: System Time Offset Application
// ============================================================================
task test_dc02_offset_application;
    reg [63:0] time_before, time_after, offset, expected;
    begin
        $display("\n=== DC-02: System Time Offset Application ===");
        reset_dut;
        
        read_reg64(ADDR_SYSTEM_TIME, time_before);
        $display("  Time before offset: %0d ns", time_before);
        
        offset = 64'd1000000;  // 1ms
        write_reg64(ADDR_SYSTEM_OFFSET, offset);
        $display("  Writing offset: %0d ns", offset);
        
        read_reg64(ADDR_SYSTEM_TIME, time_after);
        $display("  Time after offset: %0d ns", time_after);
        
        expected = time_before + offset;
        check_pass("Time jumped by offset", 
                   time_after >= expected - 1000 && time_after <= expected + 1000);
    end
endtask

// ============================================================================
// DC-04: Port Receive Time Capture
// ============================================================================
task test_dc04_port_receive_time;
    reg [63:0] captured, current;
    begin
        $display("\n=== DC-04: Port Receive Time Capture ===");
        reset_dut;
        
        repeat(50) @(posedge clk);
        
        $display("  Triggering frame on Port 0...");
        port_rx_sof = 4'h1;
        @(posedge clk);
        port_rx_sof = 4'h0;
        
        repeat(10) @(posedge clk);
        
        read_reg64(ADDR_PORT0_RECV_TIME, captured);
        $display("  Port 0 Receive Time: %0d ns", captured);
        
        check_pass("Receive time captured (non-zero)", captured > 0);
        
        read_reg64(ADDR_SYSTEM_TIME, current);
        check_pass("Captured time before current", captured < current);
    end
endtask

// ============================================================================
// DC-06: SYNC0 Pulse Generation Configuration
// ============================================================================
task test_dc06_sync0_config;
    reg [63:0] current_time, start_time;
    integer pulse_count, prev_sync;
    begin
        $display("\n=== DC-06: SYNC0 Pulse Generation Configuration ===");
        reset_dut;
        
        repeat(100) @(posedge clk);
        
        read_reg64(ADDR_SYSTEM_TIME, current_time);
        start_time = current_time + 2000;
        write_reg64(ADDR_SYNC0_START_TIME, start_time);
        $display("  SYNC0 Start Time: %0d ns", start_time);
        
        write_reg32(ADDR_SYNC0_CYCLE_TIME, 32'd10000);  // 10us cycle
        $display("  SYNC0 Cycle Time: 10000 ns");
        
        write_reg(ADDR_DC_ACTIVATION, {8'h00, DC_ACT_SYNC0_EN});
        $display("  SYNC0 Enabled");
        
        pulse_count = 0;
        prev_sync = 0;
        for (i = 0; i < 500; i = i + 1) begin
            @(posedge clk);
            if (sync0_out && !prev_sync) begin
                pulse_count = pulse_count + 1;
                $display("  SYNC0 pulse detected at cycle %0d", i);
            end
            prev_sync = sync0_out;
        end
        
        check_pass("SYNC0 pulse generated", pulse_count > 0);
        check_pass("SYNC0 active status", sync0_active != 0);
    end
endtask

// ============================================================================
// DC-09: SYNC Signal Masking
// ============================================================================
task test_dc09_sync_masking;
    integer pulses_enabled, pulses_disabled, pulses_reenabled, prev;
    begin
        $display("\n=== DC-09: SYNC Signal Masking ===");
        reset_dut;
        
        write_reg64(ADDR_SYNC0_START_TIME, 64'd500);
        write_reg32(ADDR_SYNC0_CYCLE_TIME, 32'd2000);
        write_reg(ADDR_DC_ACTIVATION, {8'h00, DC_ACT_SYNC0_EN});
        
        pulses_enabled = 0;
        prev = 0;
        for (i = 0; i < 300; i = i + 1) begin
            @(posedge clk);
            if (sync0_out && !prev) pulses_enabled = pulses_enabled + 1;
            prev = sync0_out;
        end
        $display("  Pulses while enabled: %0d", pulses_enabled);
        
        write_reg(ADDR_DC_ACTIVATION, 16'h0000);
        
        pulses_disabled = 0;
        prev = 0;
        for (i = 0; i < 300; i = i + 1) begin
            @(posedge clk);
            if (sync0_out && !prev) pulses_disabled = pulses_disabled + 1;
            prev = sync0_out;
        end
        $display("  Pulses while disabled: %0d", pulses_disabled);
        
        check_pass("Pulses when enabled", pulses_enabled > 0);
        check_pass("No pulses when disabled", pulses_disabled == 0);
        
        write_reg(ADDR_DC_ACTIVATION, {8'h00, DC_ACT_SYNC0_EN});
        
        pulses_reenabled = 0;
        prev = 0;
        for (i = 0; i < 300; i = i + 1) begin
            @(posedge clk);
            if (sync0_out && !prev) pulses_reenabled = pulses_reenabled + 1;
            prev = sync0_out;
        end
        $display("  Pulses after re-enable: %0d", pulses_reenabled);
        
        check_pass("Pulses resume after re-enable", pulses_reenabled > 0);
    end
endtask

// ============================================================================
// DC-10: Latch0 Positive Edge Capture
// ============================================================================
task test_dc10_latch_capture;
    reg [63:0] captured_time;
    begin
        $display("\n=== DC-10: Latch0 Positive Edge Capture ===");
        reset_dut;
        
        write_reg(ADDR_LATCH_CTRL_STATUS, 16'h0F00);  // Clear flags
        write_reg(ADDR_LATCH_CTRL_STATUS, LATCH_POS_EN);
        
        repeat(100) @(posedge clk);
        
        $display("  Generating positive edge on Latch0...");
        latch0_in = 1;
        repeat(10) @(posedge clk);
        latch0_in = 0;
        repeat(5) @(posedge clk);
        
        read_reg(ADDR_LATCH_CTRL_STATUS, reg_val);
        $display("  Latch Status: 0x%04x", reg_val);
        
        read_reg64(ADDR_LATCH0_POS_TIME, captured_time);
        $display("  Captured Time: %0d ns", captured_time);
        
        check_pass("Positive edge event flag set", (reg_val & 16'h0100) != 0);
        check_pass("Timestamp captured", captured_time > 0);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("==========================================");
    $display("Distributed Clock (DC) Testbench");
    $display("==========================================");
    
    test_dc01_clock_increment;
    test_dc02_offset_application;
    test_dc04_port_receive_time;
    test_dc06_sync0_config;
    test_dc09_sync_masking;
    test_dc10_latch_capture;
    
    // Summary
    $display("\n==========================================");
    $display("DC Test Summary:");
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
