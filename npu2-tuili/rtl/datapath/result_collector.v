//******************************************************************************
// Result Collector
// Description: Collects results from systolic array and writes to buffer/DDR
// Features:
//   - Gathers result stream from PE array bottom edge
//   - Buffers results before DMA write-back
//   - Support for INT8 and BF16 precision modes
//   - Stream interface for DMA write channel
//******************************************************************************

module result_collector #(
    parameter ARRAY_SIZE = 96,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 18,
    parameter FIFO_DEPTH = 16
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Control Interface
    input  wire                         start,
    output reg                          done,
    input  wire                         precision_mode,  // 0=INT8, 1=BF16
    
    // Systolic Array Result Input
    input  wire [DATA_WIDTH-1:0]        pe_result,
    input  wire                         pe_result_valid,
    
    // M20K Write Interface (result buffer)
    output reg  [ADDR_WIDTH-1:0]        m20k_waddr,
    output reg  [DATA_WIDTH-1:0]        m20k_wdata,
    output reg                          m20k_we,
    
    // Stream Output (to DMA write channel)
    output wire [DATA_WIDTH-1:0]        stream_data,
    output wire                         stream_valid,
    input  wire                         stream_ready
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE         = 2'b00;
    localparam COLLECT      = 2'b01;
    localparam FLUSH        = 2'b10;
    
    reg [1:0]   state;
    
    //==========================================================================
    // Internal FIFO for result buffering
    //==========================================================================
    
    reg [DATA_WIDTH-1:0]    result_fifo [0:FIFO_DEPTH-1];
    reg [3:0]               fifo_wr_ptr;
    reg [3:0]               fifo_rd_ptr;
    reg [4:0]               fifo_count;
    
    wire                    fifo_empty;
    wire                    fifo_full;
    wire                    fifo_almost_full;
    
    assign fifo_empty = (fifo_count == 5'd0);
    assign fifo_full = (fifo_count == FIFO_DEPTH);
    assign fifo_almost_full = (fifo_count >= (FIFO_DEPTH - 2));
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [ADDR_WIDTH-1:0]    write_addr;
    reg [15:0]              result_counter;
    reg [15:0]              expected_results;
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            write_addr <= {ADDR_WIDTH{1'b0}};
            result_counter <= 16'd0;
            expected_results <= 16'd0;
            m20k_waddr <= {ADDR_WIDTH{1'b0}};
            m20k_wdata <= {DATA_WIDTH{1'b0}};
            m20k_we <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    m20k_we <= 1'b0;
                    result_counter <= 16'd0;
                    write_addr <= {ADDR_WIDTH{1'b0}};
                    
                    if (start) begin
                        // For ARRAY_SIZE x ARRAY_SIZE matrix, expect ARRAY_SIZE results per column
                        expected_results <= ARRAY_SIZE;
                        state <= COLLECT;
                    end
                end
                
                COLLECT: begin
                    // Collect results from PE array
                    if (pe_result_valid && !fifo_full) begin
                        $display("  [%0t ns] Result Collector[%m]: Got valid result 0x%h", 
                                 $time/1000.0, pe_result);
                        // Store in FIFO
                        result_fifo[fifo_wr_ptr] <= pe_result;
                        
                        // Also write to M20K buffer
                        m20k_waddr <= write_addr;
                        m20k_wdata <= pe_result;
                        m20k_we <= 1'b1;
                        
                        write_addr <= write_addr + 1'b1;
                        result_counter <= result_counter + 1'b1;
                        
                        // Check if all results collected
                        if (result_counter >= expected_results - 1) begin
                            $display("  [%0t ns] Result Collector[%m]: All results collected, entering FLUSH", 
                                     $time/1000.0);
                            state <= FLUSH;
                        end
                    end else begin
                        if (pe_result_valid) begin
                            $display("  [%0t ns] Result Collector[%m]: FIFO full, dropping result", $time/1000.0);
                        end
                        m20k_we <= 1'b0;
                    end
                end
                
                FLUSH: begin
                    // Wait for FIFO to be drained by DMA through stream interface
                    m20k_we <= 1'b0;
                    
                    $display("  [%0t ns] Result Collector[%m]: FLUSH state, fifo_empty=%b, fifo_count=%d, done=%b", 
                             $time/1000.0, fifo_empty, fifo_count, done);
                    
                    // Wait for stream interface to drain FIFO naturally
                    // Don't force drain - let the stream handshake handle it
                    
                    if (fifo_empty) begin
                        $display("  [%0t ns] Result Collector[%m]: FIFO empty, asserting DONE", $time/1000.0);
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    //==========================================================================
    // FIFO Write Control
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_wr_ptr <= 4'd0;
        end else begin
            if (pe_result_valid && !fifo_full && (state == COLLECT)) begin
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end
        end
    end
    
    //==========================================================================
    // FIFO Read Control (for stream output)
    //==========================================================================
    
    reg [DATA_WIDTH-1:0]    stream_data_reg;
    reg                     stream_valid_reg;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_rd_ptr <= 4'd0;
            stream_data_reg <= {DATA_WIDTH{1'b0}};
            stream_valid_reg <= 1'b0;
        end else begin
            // In FLUSH state, keep valid high if FIFO has data
            // This allows DMA to drain the FIFO properly
            if (state == FLUSH && !fifo_empty) begin
                stream_valid_reg <= 1'b1;
                stream_data_reg <= result_fifo[fifo_rd_ptr];
                
                // Only advance read pointer when downstream is ready
                if (stream_ready) begin
                    fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
                    $display("  [%0t ns] Result Collector[%m]: Stream handshake, rd_ptr=%d->%d", 
                             $time/1000.0, fifo_rd_ptr, fifo_rd_ptr + 1'b1);
                end
            end else if (!fifo_empty && stream_ready && state != FLUSH) begin
                // Normal operation during COLLECT state
                stream_data_reg <= result_fifo[fifo_rd_ptr];
                stream_valid_reg <= 1'b1;
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            end else begin
                stream_valid_reg <= 1'b0;
            end
        end
    end
    
    assign stream_data = stream_data_reg;
    assign stream_valid = stream_valid_reg;
    
    //==========================================================================
    // FIFO Count Management
    //==========================================================================
    
    wire fifo_wr_en = pe_result_valid && !fifo_full && (state == COLLECT);
    wire fifo_rd_en = stream_valid_reg && stream_ready;  // Count when handshake succeeds
    
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_count <= 5'd0;
        end else begin
            case ({fifo_wr_en, fifo_rd_en})
                2'b10: fifo_count <= fifo_count + 1'b1;  // Write only
                2'b01: fifo_count <= fifo_count - 1'b1;  // Read only
                2'b11: fifo_count <= fifo_count;         // Both (no change)
                default: fifo_count <= fifo_count;
            endcase
        end
    end

endmodule
