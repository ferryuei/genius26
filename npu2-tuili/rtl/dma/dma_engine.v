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
    
    reg [3:0]               sub_word_ptr;   // Which 32-bit slice of the current 512-bit entry
    
    // Number of 32-bit sub-words per DDR word
    localparam WORDS_PER_DDR = DDR_DATA_WIDTH / DATA_WIDTH;  // 16
    
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
            // Debug: Always show current state
            if (state != IDLE) begin
                $display("  [%0t ns] DMA: state=%d, done=%b", $time/1000.0, state, done);
            end
            
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    // CRITICAL: Keep stream_wr_ready=1 in IDLE to allow Result Collector to drain FIFO
                    // BUT only when NOT currently processing a read/write operation
                    stream_wr_ready <= 1'b1;
                    
                    // Buffer incoming stream data while in IDLE
                    if (stream_wr_valid && !start) begin
                        $display("  [%0t ns] DMA IDLE: Buffering stream data 0x%h (count=%d)", 
                                 $time/1000.0, stream_wr_data, write_word_count);
                        write_buffer[write_word_count * DATA_WIDTH +: DATA_WIDTH] <= stream_wr_data;
                        write_word_count <= write_word_count + 1'b1;
                    end
                    
                    if (start) begin
                        $display("  [%0t ns] DMA IDLE: Received start, write_mode=%b, length=%d, buffered=%d words", 
                                 $time/1000.0, write_mode, length, write_word_count);
                        dma_mode <= write_mode;
                        bytes_remaining <= length;
                        bytes_transferred <= 32'd0;
                        // Don't reset write_word_count - keep buffered data
                        
                        if (write_mode) begin
                            // Write mode: from fabric to DDR
                            $display("  [%0t ns] DMA: Entering WRITE mode, dst_addr=0x%h", 
                                     $time/1000.0, dst_addr);
                            current_addr <= dst_addr;
                            stream_wr_ready <= 1'b1;
                            state <= WRITE_REQ;
                        end else begin
                            // Read mode: from DDR to fabric
                            $display("  [%0t ns] DMA: Entering READ mode, src_addr=0x%h", 
                                     $time/1000.0, src_addr);
                            current_addr <= src_addr;
                            write_word_count <= 6'd0;  // Clear buffer for read mode
                            sub_word_ptr <= 4'd0;      // Reset sub-word demux counter
                            stream_wr_ready <= 1'b0;  // Don't accept writes during read
                            state <= READ_REQ;
                        end
                    end
                end
                
                READ_REQ: begin
                    if (!avmm_waitrequest) begin
                        // Calculate burst size first, then assign burst_remaining
                        reg [7:0] calculated_burst;
                        
                        if (bytes_remaining >= (MAX_BURST * (DDR_DATA_WIDTH/8))) begin
                            calculated_burst = MAX_BURST;
                        end else if (bytes_remaining >= (DDR_DATA_WIDTH/8)) begin
                            calculated_burst = bytes_remaining / (DDR_DATA_WIDTH/8);
                        end else begin
                            // FIX: transfers smaller than one DDR word still need 1 burst;
                            // integer division would yield 0, causing READ_DATA deadlock.
                            calculated_burst = 8'd1;
                        end
                        
                        // Issue read request with calculated burst count
                        avmm_address <= current_addr;
                        avmm_read <= 1'b1;
                        avmm_burstcount <= calculated_burst;
                        burst_remaining <= calculated_burst;  // Use calculated value
                        burst_count <= calculated_burst;
                        
                        $display("  [%0t ns] DMA READ_REQ: burst_count=%d, burst_remaining=%d, bytes_remaining=%d", 
                                 $time/1000.0, calculated_burst, calculated_burst, bytes_remaining);
                        
                        state <= READ_DATA;
                    end
                end
                
                READ_DATA: begin
                    avmm_read <= 1'b0;
                    stream_wr_ready <= 1'b0;  // Don't accept writes during read mode
                    
                    $display("  [%0t ns] DMA READ_DATA: waiting for data, burst_remaining=%d, avmm_readdatavalid=%b", 
                             $time/1000.0, burst_remaining, avmm_readdatavalid);
                    
                    if (avmm_readdatavalid) begin
                        $display("  [%0t ns] DMA READ_DATA: Got data, burst_remaining=%d", 
                                 $time/1000.0, burst_remaining);
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
                            
                            $display("  [%0t ns] DMA READ_DATA: Burst complete, bytes_remaining=%d", 
                                     $time/1000.0, bytes_remaining - (burst_count * (DDR_DATA_WIDTH/8)));
                            
                            if (bytes_remaining <= (burst_count * (DDR_DATA_WIDTH/8))) begin
                                $display("  [%0t ns] DMA READ_DATA: All data read, going to DONE", $time/1000.0);
                                state <= DONE_STATE;
                            end else begin
                                $display("  [%0t ns] DMA READ_DATA: More data needed, going to READ_REQ", $time/1000.0);
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
                    $display("  [%0t ns] DMA: In DONE_STATE, asserting done", $time/1000.0);
                    done <= 1'b1;
                    stream_wr_ready <= 1'b0;
                    
                    // Stay in DONE_STATE for one cycle, then return to IDLE
                    // This ensures done signal is properly recognized
                    if (done) begin
                        $display("  [%0t ns] DMA: Done acknowledged, returning to IDLE", $time/1000.0);
                        done <= 1'b0;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    //==========================================================================
    // FIFO Count Management
    //==========================================================================
    
    // A FIFO entry is fully consumed only after all WORDS_PER_DDR sub-words are streamed
    wire fifo_rd_en = stream_rd_valid && stream_rd_ready &&
                      (sub_word_ptr == (WORDS_PER_DDR - 1)) && !fifo_empty;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_count <= 5'd0;
        end else begin
            case ({avmm_readdatavalid && !fifo_full, fifo_rd_en})
                2'b10: fifo_count <= fifo_count + 1'b1;  // Write only
                2'b01: fifo_count <= fifo_count - 1'b1;  // Read only (last sub-word)
                2'b11: fifo_count <= fifo_count;         // Both simultaneously
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
            sub_word_ptr <= 4'd0;
        end else begin
            // FIX: Properly demultiplex each 512-bit DDR FIFO entry into
            // (DDR_DATA_WIDTH/DATA_WIDTH)=16 consecutive 32-bit stream words.
            // sub_word_ptr counts which 32-bit slice is being output.
            // fifo_rd_ptr only advances after all 16 sub-words are consumed.
            if (!fifo_empty || (sub_word_ptr != 4'd0)) begin
                // Latch the current FIFO entry when starting a new one
                if (sub_word_ptr == 4'd0) begin
                    stream_data_reg <= read_fifo[fifo_rd_ptr];
                end
                stream_valid_reg <= 1'b1;
                
                if (stream_rd_valid && stream_rd_ready) begin
                    $display("  [%0t ns] DMA: Stream handshake completed, sub_word=%d, fifo_rd_ptr=%d", 
                             $time/1000.0, sub_word_ptr, fifo_rd_ptr);
                    if (sub_word_ptr == (WORDS_PER_DDR - 1)) begin
                        // Last sub-word of this FIFO entry: advance FIFO pointer
                        sub_word_ptr <= 4'd0;
                        if (!fifo_empty) begin
                            fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
                        end
                    end else begin
                        sub_word_ptr <= sub_word_ptr + 1'b1;
                    end
                end
            end else begin
                stream_valid_reg <= 1'b0;
            end
        end
    end
    
    // Output the correct 32-bit slice based on sub_word_ptr
    assign stream_rd_data = stream_data_reg[sub_word_ptr * DATA_WIDTH +: DATA_WIDTH];
    assign stream_rd_valid = stream_valid_reg;

endmodule
