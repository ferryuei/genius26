//******************************************************************************
// M20K Buffer
// Description: Dual-port memory buffer using M20K blocks
// Features:
//   - True dual-port: independent read/write ports
//   - Configurable depth and width
//   - Uses Intel M20K memory blocks (to be inferred or IP instantiated)
//   - Synchronous read (1 cycle latency)
//******************************************************************************

module m20k_buffer #(
    parameter ADDR_WIDTH = 18,
    parameter DATA_WIDTH = 32,
    parameter DEPTH = 262144  // 256K entries = 1MB for 32-bit data
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Write Port
    input  wire [ADDR_WIDTH-1:0]        waddr,
    input  wire [DATA_WIDTH-1:0]        wdata,
    input  wire                         we,
    
    // Read Port
    input  wire [ADDR_WIDTH-1:0]        raddr,
    output reg  [DATA_WIDTH-1:0]        rdata,
    input  wire                         re
);

    //==========================================================================
    // Memory Array Declaration
    //==========================================================================
    // This will be inferred as M20K blocks by Quartus
    // For explicit instantiation, use altera_syncram or twentynm_ram_block
    
    (* ramstyle = "M20K" *) reg [DATA_WIDTH-1:0] mem_array [0:DEPTH-1];
    
    // Optional: Initialize memory to zero
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            mem_array[i] = {DATA_WIDTH{1'b0}};
        end
    end
    
    //==========================================================================
    // Write Port Logic
    //==========================================================================
    
    always @(posedge clk) begin
        if (we) begin
            mem_array[waddr] <= wdata;
        end
    end
    
    //==========================================================================
    // Read Port Logic (Synchronous Read)
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            rdata <= {DATA_WIDTH{1'b0}};
        end else if (re) begin
            rdata <= mem_array[raddr];
        end
    end

endmodule


//******************************************************************************
// M20K Weight Buffer Manager
// Description: Manages weight loading and distribution to PE array
// Features:
//   - Prefetch logic for next layer weights
//   - Double buffering support
//   - Address generation for sequential/strided access
//******************************************************************************

module m20k_weight_manager #(
    parameter ADDR_WIDTH = 18,
    parameter DATA_WIDTH = 32,
    parameter NUM_BUFFERS = 2  // Double buffering
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Control Interface
    input  wire                         load_start,
    input  wire [ADDR_WIDTH-1:0]        load_base_addr,
    input  wire [15:0]                  load_length,
    output reg                          load_done,
    
    input  wire                         prefetch_start,
    input  wire [ADDR_WIDTH-1:0]        prefetch_base_addr,
    
    // DMA Write Interface
    input  wire [DATA_WIDTH-1:0]        dma_wdata,
    input  wire                         dma_wvalid,
    output wire                         dma_wready,
    
    // PE Read Interface
    input  wire [ADDR_WIDTH-1:0]        pe_raddr,
    output wire [DATA_WIDTH-1:0]        pe_rdata,
    input  wire                         pe_rvalid
);

    //==========================================================================
    // Internal Signals
    //==========================================================================
    
    reg [ADDR_WIDTH-1:0]    write_addr;
    reg [15:0]              write_count;
    reg                     write_buffer_sel;  // 0 or 1
    reg                     read_buffer_sel;
    
    wire [ADDR_WIDTH-1:0]   buf0_waddr, buf1_waddr;
    wire [DATA_WIDTH-1:0]   buf0_wdata, buf1_wdata;
    wire                    buf0_we, buf1_we;
    
    wire [ADDR_WIDTH-1:0]   buf0_raddr, buf1_raddr;
    wire [DATA_WIDTH-1:0]   buf0_rdata, buf1_rdata;
    wire                    buf0_re, buf1_re;
    
    //==========================================================================
    // Buffer Selection
    //==========================================================================
    
    assign buf0_waddr = write_addr;
    assign buf1_waddr = write_addr;
    assign buf0_wdata = dma_wdata;
    assign buf1_wdata = dma_wdata;
    assign buf0_we = dma_wvalid && !write_buffer_sel;
    assign buf1_we = dma_wvalid && write_buffer_sel;
    
    assign buf0_raddr = pe_raddr;
    assign buf1_raddr = pe_raddr;
    assign buf0_re = pe_rvalid && !read_buffer_sel;
    assign buf1_re = pe_rvalid && read_buffer_sel;
    
    assign pe_rdata = read_buffer_sel ? buf1_rdata : buf0_rdata;
    assign dma_wready = 1'b1;  // Always ready (simplified)
    
    //==========================================================================
    // Write Control (Load Weights)
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            write_addr <= {ADDR_WIDTH{1'b0}};
            write_count <= 16'd0;
            write_buffer_sel <= 1'b0;
            load_done <= 1'b0;
        end else begin
            if (load_start) begin
                write_addr <= load_base_addr;
                write_count <= 16'd0;
                load_done <= 1'b0;
            end else if (dma_wvalid && write_count < load_length) begin
                write_addr <= write_addr + 1'b1;
                write_count <= write_count + 1'b1;
                
                if (write_count == load_length - 1) begin
                    load_done <= 1'b1;
                    // Swap buffers
                    write_buffer_sel <= ~write_buffer_sel;
                    read_buffer_sel <= ~read_buffer_sel;
                end
            end else begin
                load_done <= 1'b0;
            end
        end
    end
    
    //==========================================================================
    // Buffer Instances
    //==========================================================================
    
    m20k_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(1 << ADDR_WIDTH)
    ) u_buffer_0 (
        .clk    (clk),
        .rst_n  (rst_n),
        .waddr  (buf0_waddr),
        .wdata  (buf0_wdata),
        .we     (buf0_we),
        .raddr  (buf0_raddr),
        .rdata  (buf0_rdata),
        .re     (buf0_re)
    );
    
    m20k_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(1 << ADDR_WIDTH)
    ) u_buffer_1 (
        .clk    (clk),
        .rst_n  (rst_n),
        .waddr  (buf1_waddr),
        .wdata  (buf1_wdata),
        .we     (buf1_we),
        .raddr  (buf1_raddr),
        .rdata  (buf1_rdata),
        .re     (buf1_re)
    );

endmodule
