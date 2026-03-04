// ============================================================================
// FDB (Forwarding DataBase) MAC Address Learning Table
// 4-port 10G Ethernet L2 Switch
//
// Features:
//   - 4096-entry hash table (direct-mapped, 12-bit hash)
//   - MAC learning with port association
//   - Aging mechanism (configurable)
//   - Lookup result: unicast port / flood mask / CPU
// ============================================================================
`timescale 1ns/1ps

module fdb_table #(
    parameter FDB_DEPTH     = 4096,   // must be power of 2
    parameter ADDR_W        = 12,     // log2(FDB_DEPTH)
    parameter PORT_NUM      = 4,
    parameter AGE_BITS      = 20      // aging counter width
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // Learning interface (from ingress pipeline)
    input  wire                 learn_valid,
    input  wire [47:0]          learn_mac,
    input  wire [PORT_NUM-1:0]  learn_port_mask,  // one-hot

    // Lookup interface (from ingress pipeline)
    input  wire                 lookup_valid,
    input  wire [47:0]          lookup_mac,
    output reg                  lookup_hit,
    output reg  [PORT_NUM-1:0]  lookup_port_mask, // one-hot unicast / flood mask
    output reg                  lookup_done,

    // Aging tick (e.g., 1 Hz pulse)
    input  wire                 age_tick,

    // CPU management interface
    input  wire                 cpu_wr_en,
    input  wire [ADDR_W-1:0]    cpu_wr_addr,
    input  wire [47:0]          cpu_wr_mac,
    input  wire [PORT_NUM-1:0]  cpu_wr_port,
    input  wire                 cpu_wr_static,   // static entry: no aging
    input  wire                 cpu_rd_en,
    input  wire [ADDR_W-1:0]    cpu_rd_addr,
    output reg  [47:0]          cpu_rd_mac,
    output reg  [PORT_NUM-1:0]  cpu_rd_port,
    output reg                  cpu_rd_valid,
    output reg                  cpu_rd_static
);

    // -------------------------------------------------------------------------
    // FDB entry structure (stored in BRAM)
    //   [47:0]  mac
    //   [51:48] port (one-hot, 4-bit)
    //   [52]    valid
    //   [53]    static
    //   [73:54] age_counter (20-bit)
    // -------------------------------------------------------------------------
    localparam ENTRY_W = 74;
    localparam AGE_MAX = {AGE_BITS{1'b1}};

    reg [ENTRY_W-1:0] fdb_mem [0:FDB_DEPTH-1];

    // -------------------------------------------------------------------------
    // 12-bit hash: XOR folding of 48-bit MAC
    // -------------------------------------------------------------------------
    function [ADDR_W-1:0] mac_hash;
        input [47:0] mac;
        begin
            mac_hash = mac[11:0] ^ mac[23:12] ^ mac[35:24] ^ mac[47:36];
        end
    endfunction

    // -------------------------------------------------------------------------
    // State machine: arbitrate between learn / lookup / age / cpu ops
    // Priority: CPU > learn > lookup > age
    // -------------------------------------------------------------------------
    localparam ST_IDLE   = 3'd0,
               ST_LOOKUP = 3'd1,
               ST_LEARN  = 3'd2,
               ST_AGE    = 3'd3,
               ST_CPU_RD = 3'd4,
               ST_CPU_WR = 3'd5;

    reg [2:0]          state;
    reg [ADDR_W-1:0]   age_ptr;
    reg                age_running;
    reg [47:0]         pend_learn_mac;
    reg [PORT_NUM-1:0] pend_learn_port;
    reg [47:0]         pend_lkp_mac;
    reg                pend_lkp;

    // pipeline regs
    reg [ADDR_W-1:0]   rd_addr_r;
    reg [2:0]          rd_purpose; // 0=lookup,1=learn,2=age,3=cpu_rd

    wire [ADDR_W-1:0]  lkp_addr  = mac_hash(pend_lkp_mac);
    wire [ADDR_W-1:0]  lrn_addr  = mac_hash(pend_learn_mac);

    // Registered read (1-cycle latency)
    reg [ENTRY_W-1:0]  rd_data;
    always @(posedge clk)
        rd_data <= fdb_mem[rd_addr_r];

    integer i;
    initial begin
        for (i = 0; i < FDB_DEPTH; i = i+1)
            fdb_mem[i] = {ENTRY_W{1'b0}};
    end

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            age_ptr        <= 0;
            age_running    <= 0;
            lookup_hit     <= 0;
            lookup_port_mask <= {PORT_NUM{1'b1}}; // flood
            lookup_done    <= 0;
            pend_lkp       <= 0;
            cpu_rd_valid   <= 0;
        end else begin
            lookup_done <= 0;
            cpu_rd_valid <= 0;

            // Capture incoming requests
            if (learn_valid)  begin pend_learn_mac  <= learn_mac;  pend_learn_port <= learn_port_mask; end
            if (lookup_valid) begin pend_lkp_mac    <= lookup_mac; pend_lkp        <= 1'b1;            end
            if (age_tick)     age_running <= 1'b1;

            case (state)
                ST_IDLE: begin
                    if (cpu_wr_en) begin
                        // CPU write (immediate, combinational write)
                        fdb_mem[cpu_wr_addr] <= {
                            {AGE_BITS{1'b0}},
                            cpu_wr_static,
                            1'b1,
                            cpu_wr_port,
                            cpu_wr_mac
                        };
                        state <= ST_IDLE;
                    end else if (cpu_rd_en) begin
                        rd_addr_r  <= cpu_rd_addr;
                        rd_purpose <= 3'd3;
                        state      <= ST_CPU_RD;
                    end else if (learn_valid) begin
                        rd_addr_r      <= lrn_addr;
                        rd_purpose     <= 3'd1;
                        state          <= ST_LEARN;
                    end else if (pend_lkp) begin
                        rd_addr_r  <= lkp_addr;
                        rd_purpose <= 3'd0;
                        pend_lkp   <= 0;
                        state      <= ST_LOOKUP;
                    end else if (age_running) begin
                        rd_addr_r  <= age_ptr;
                        rd_purpose <= 3'd2;
                        state      <= ST_AGE;
                    end
                end

                ST_LOOKUP: begin
                    // rd_data valid now (1 cycle after rd_addr_r set)
                    if (rd_data[52] && rd_data[47:0] == pend_lkp_mac) begin
                        lookup_hit       <= 1'b1;
                        lookup_port_mask <= rd_data[51:48];
                        // Refresh age
                        fdb_mem[rd_addr_r][73:54] <= {AGE_BITS{1'b1}};
                    end else begin
                        lookup_hit       <= 1'b0;
                        lookup_port_mask <= {PORT_NUM{1'b1}}; // flood all
                    end
                    lookup_done <= 1'b1;
                    state       <= ST_IDLE;
                end

                ST_LEARN: begin
                    // Collision resolution: replace if empty, same MAC, or older entry
                    if (!rd_data[52]) begin
                        // Empty slot: write new entry
                        fdb_mem[rd_addr_r] <= {
                            AGE_MAX,
                            1'b0,           // not static
                            1'b1,           // valid
                            pend_learn_port,
                            pend_learn_mac
                        };
                    end else if (rd_data[47:0] == pend_learn_mac) begin
                        // Same MAC: update port and refresh age
                        fdb_mem[rd_addr_r] <= {
                            AGE_MAX,
                            rd_data[53],    // preserve static flag
                            1'b1,           // valid
                            pend_learn_port,
                            pend_learn_mac
                        };
                    end else if (!rd_data[53] && rd_data[73:54] < (AGE_MAX >> 1)) begin
                        // Collision: replace if existing entry is non-static and aged (< 50%)
                        fdb_mem[rd_addr_r] <= {
                            AGE_MAX,
                            1'b0,           // not static
                            1'b1,           // valid
                            pend_learn_port,
                            pend_learn_mac
                        };
                    end
                    // else: collision with fresh or static entry, keep existing
                    state <= ST_IDLE;
                end

                ST_AGE: begin
                    if (rd_data[52] && !rd_data[53]) begin // valid & not static
                        if (rd_data[73:54] == {AGE_BITS{1'b0}}) begin
                            // expired: invalidate
                            fdb_mem[rd_addr_r][52] <= 1'b0;
                        end else begin
                            fdb_mem[rd_addr_r][73:54] <= rd_data[73:54] - 1'b1;
                        end
                    end
                    age_ptr <= age_ptr + 1'b1;
                    if (age_ptr == FDB_DEPTH-1) begin
                        age_running <= 0;
                        age_ptr     <= 0;
                    end
                    state <= ST_IDLE;
                end

                ST_CPU_RD: begin
                    cpu_rd_mac    <= rd_data[47:0];
                    cpu_rd_port   <= rd_data[51:48];
                    cpu_rd_valid  <= rd_data[52];
                    cpu_rd_static <= rd_data[53];
                    state         <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
