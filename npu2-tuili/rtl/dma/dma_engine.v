//******************************************************************************
// DMA Engine
// Description: High-performance DMA for DDR4 <-> On-chip memory transfers
// Features:
//   - Avalon-MM master interface (Stratix 10 EMIF)
//   - Burst transfers (up to 256 beats)
//   - Read and write channels
//   - Address generation and management
//******************************************************************************

module dma_engine #(
    parameter ADDR_WIDTH     = 32,
    parameter DATA_WIDTH     = 32,
    parameter DDR_DATA_WIDTH = 512,
    parameter MAX_BURST      = 256
)(
    // Clock and Reset
    input  wire                             clk,
    input  wire                             rst_n,
    
    // Control Interface
    input  wire [ADDR_WIDTH-1:0]            src_addr,
    input  wire [ADDR_WIDTH-1:0]            dst_addr,
    input  wire [31:0]                      length,         // Transfer length in bytes
    input  wire                             start,
    input  wire                             write_mode,     // 0=read from DDR, 1=write to DDR
    output reg                              done,
    
    // DDR4 Avalon-MM Master Interface
    output reg  [ADDR_WIDTH-1:0]            avmm_address,
    output reg                              avmm_read,
    output reg                              avmm_write,
    output reg  [DDR_DATA_WIDTH-1:0]        avmm_writedata,
    output reg  [DDR_DATA_WIDTH/8-1:0]      avmm_byteenable,
    input  wire [DDR_DATA_WIDTH-1:0]        avmm_readdata,
    input  wire                             avmm_readdatavalid,
    input  wire                             avmm_waitrequest,
    output reg  [7:0]                       avmm_burstcount,
    
    // Read Stream Interface (from DDR to fabric)
    output wire [DATA_WIDTH-1:0]            stream_rd_data,
    output wire                             stream_rd_valid,
    input  wire                             stream_rd_ready,
    
    // Write Stream Interface (from fabric to DDR)
    input  wire [DATA_WIDTH-1:0]            stream_wr_data,
    input  wire                             stream_wr_valid,
    output reg                              stream_wr_ready
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE         = 3'b000;
    localparam READ_REQ     = 3'b001;
    localparam READ_DATA    = 3'b010;
    localparam WRITE_REQ    = 3'b011;
    localparam WRITE_DATA   = 3'b100;
    localparam WRITE_WAIT   = 3'b101;
    localparam DONE_STATE   = 3'b110;
    
    reg [2:0]               state;
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [ADDR_WIDTH-1:0]    current_addr;
    reg [31:0]              bytes_remaining;
    reg [31:0]              bytes_transferred;
    reg [7:0]               burst_count;
    reg [7:0]               burst_remaining;
    reg                     dma_mode;           // Latched write_mode
    
    // FIFO for read data buffering
    reg [DDR_DATA_WIDTH-1:0] read_fifo [0:15];
    reg [3:0]               fifo_wr_ptr;
    reg [3:0]               fifo_rd_ptr;
    reg [4:0]               fifo_count;
    wire                    fifo_empty;
    wire                    fifo_full;
    
    assign fifo_empty = (fifo_count == 5'd0);
    assign fifo_full = (fifo_count == 5'd16);
    
    // Write data buffering
    reg [DDR_DATA_WIDTH-1:0] write_buffer;
    reg [5:0]               write_word_count;   // Count 32-bit words (max 16 for 512-bit)
    wire                    write_buffer_full;
    
    assign write_buffer_full = (write_word_count >= (DDR_DATA_WIDTH / DATA_WIDTH));
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            current_addr <= {ADDR_WIDTH{1'b0}};
            bytes_remaining <= 32'd0;
            bytes_transferred <= 32'd0;
            avmm_read <= 1'b0;
            avmm_write <= 1'b0;
            avmm_address <= {ADDR_WIDTH{1'b0}};
            avmm_burstcount <= 8'd0;
            avmm_writedata <= {DDR_DATA_WIDTH{1'b0}};
            avmm_byteenable <= {DDR_DATA_WIDTH/8{1'b1}};
            burst_count <= 8'd0;
            burst_remaining <= 8'd0;
            dma_mode <= 1'b0;
            stream_wr_ready <= 1'b0;
            write_buffer <= {DDR_DATA_WIDTH{1'b0}};
            write_word_count <= 6'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    stream_wr_ready <= 1'b0;
                    
                    if (start) begin
                        dma_mode <= write_mode;
                        bytes_remaining <= length;
                        bytes_transferred <= 32'd0;
                        write_word_count <= 6'd0;
                        
                        if (write_mode) begin
                            // Write mode: from fabric to DDR
                            current_addr <= dst_addr;
                            stream_wr_ready <= 1'b1;
                            state <= WRITE_REQ;
                        end else begin
                            // Read mode: from DDR to fabric
                            current_addr <= src_addr;
                            state <= READ_REQ;
                        end
                    end
                end
                
                READ_REQ: begin
                    if (!avmm_waitrequest) begin
                        // Calculate burst size
                        if (bytes_remaining >= (MAX_BURST * (DDR_DATA_WIDTH/8))) begin
                            burst_count <= MAX_BURST;
                        end else begin
                            burst_count <= bytes_remaining / (DDR_DATA_WIDTH/8);
                        end
                        
                        // Issue read request
                        avmm_address <= current_addr;
                        avmm_read <= 1'b1;
                        avmm_burstcount <= burst_count;
                        burst_remaining <= burst_count;
                        
                        state <= READ_DATA;
                    end
                end
                
                READ_DATA: begin
                    avmm_read <= 1'b0;
                    
                    if (avmm_readdatavalid) begin
                        // Store data in FIFO
                        if (!fifo_full) begin
                            read_fifo[fifo_wr_ptr] <= avmm_readdata;
                            fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
                        end
                        
                        burst_remaining <= burst_remaining - 1'b1;
                        bytes_transferred <= bytes_transferred + (DDR_DATA_WIDTH/8);
                        
                        if (burst_remaining == 8'd1) begin
                            bytes_remaining <= bytes_remaining - (burst_count * (DDR_DATA_WIDTH/8));
                            current_addr <= current_addr + (burst_count * (DDR_DATA_WIDTH/8));
                            
                            if (bytes_remaining <= (burst_count * (DDR_DATA_WIDTH/8))) begin
                                state <= DONE_STATE;
                            end else begin
                                state <= READ_REQ;  // More data to read
                            end
                        end
                    end
                end
                
                WRITE_REQ: begin
                    // Accumulate 32-bit words into 512-bit buffer
                    $display("  [%0t ns] DMA WRITE_REQ: stream_wr_valid=%b, stream_wr_ready=%b, bytes_remaining=%d", 
                             $time/1000.0, stream_wr_valid, stream_wr_ready, bytes_remaining);
                    
                    if (stream_wr_valid && stream_wr_ready) begin
                        $display("  [%0t ns] DMA WRITE_REQ: Got valid data 0x%h", $time/1000.0, stream_wr_data);
                        // Pack DATA_WIDTH data into DDR_DATA_WIDTH buffer
                        write_buffer[write_word_count * DATA_WIDTH +: DATA_WIDTH] <= stream_wr_data;
                        write_word_count <= write_word_count + 1'b1;
                        
                        // When buffer is full, proceed to write
                        if (write_buffer_full || (bytes_remaining <= (DATA_WIDTH/8))) begin
                            stream_wr_ready <= 1'b0;
                            
                            // Calculate burst (simplified: single beat for now)
                            burst_count <= 8'd1;
                            burst_remaining <= 8'd1;
                            state <= WRITE_DATA;
                        end
                    end else if (bytes_remaining == 0) begin
                        $display("  [%0t ns] DMA: No more bytes remaining, going to DONE_STATE", $time/1000.0);
                        state <= DONE_STATE;
                    end
                end
                
                WRITE_DATA: begin
                    if (!avmm_waitrequest) begin
                        // Issue write request
                        avmm_address <= current_addr;
                        avmm_write <= 1'b1;
                        avmm_writedata <= write_buffer;
                        avmm_burstcount <= burst_count;
                        avmm_byteenable <= {DDR_DATA_WIDTH/8{1'b1}};
                        
                        bytes_transferred <= bytes_transferred + (DDR_DATA_WIDTH/8);
                        current_addr <= current_addr + (DDR_DATA_WIDTH/8);
                        bytes_remaining <= bytes_remaining - (DDR_DATA_WIDTH/8);
                        
                        // Clear buffer
                        write_buffer <= {DDR_DATA_WIDTH{1'b0}};
                        write_word_count <= 6'd0;
                        
                        state <= WRITE_WAIT;
                    end
                end
                
                WRITE_WAIT: begin
                    avmm_write <= 1'b0;
                    
                    // Check if more data to write
                    if (bytes_remaining > 0) begin
                        stream_wr_ready <= 1'b1;
                        state <= WRITE_REQ;
                    end else begin
                        state <= DONE_STATE;
                    end
                end
                
                DONE_STATE: begin
                    done <= 1'b1;
                    stream_wr_ready <= 1'b0;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    //==========================================================================
    // FIFO Count Management
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_count <= 5'd0;
        end else begin
            case ({avmm_readdatavalid && !fifo_full, stream_rd_valid && stream_rd_ready})
                2'b10: fifo_count <= fifo_count + 1'b1;  // Write only
                2'b01: fifo_count <= fifo_count - 1'b1;  // Read only
                2'b11: fifo_count <= fifo_count;         // Both
                default: fifo_count <= fifo_count;
            endcase
        end
    end
    
    //==========================================================================
    // Stream Output (FIFO Read) - for read mode
    //==========================================================================
    
    reg [DDR_DATA_WIDTH-1:0] stream_data_reg;
    reg                      stream_valid_reg;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            stream_data_reg <= {DDR_DATA_WIDTH{1'b0}};
            stream_valid_reg <= 1'b0;
            fifo_rd_ptr <= 4'd0;
        end else begin
            if (!fifo_empty && stream_rd_ready) begin
                stream_data_reg <= read_fifo[fifo_rd_ptr];
                stream_valid_reg <= 1'b1;
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            end else begin
                stream_valid_reg <= 1'b0;
            end
        end
    end
    
    // Data width conversion (512-bit to 32-bit)
    assign stream_rd_data = stream_data_reg[DATA_WIDTH-1:0];
    assign stream_rd_valid = stream_valid_reg;

endmodule
