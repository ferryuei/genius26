//******************************************************************************
// DMA to M20K Bridge Controller
// Description: Bridges DMA stream output to M20K memory write interface
// Features:
//   - Stream to memory interface conversion
//   - Multi-buffer arbitration (4 M20K buffers)
//   - Address management and auto-increment
//   - Configurable buffer selection
//******************************************************************************

module dma_to_m20k_bridge #(
    parameter NUM_BUFFERS = 4,
    parameter ADDR_WIDTH = 18,
    parameter DATA_WIDTH = 32
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // DMA Stream Input
    input  wire [DATA_WIDTH-1:0]        stream_data,
    input  wire                         stream_valid,
    output reg                          stream_ready,
    
    // Control Interface
    input  wire [1:0]                   target_buffer,      // Which M20K buffer (0-3)
    input  wire [ADDR_WIDTH-1:0]        base_addr,          // Starting address
    input  wire [15:0]                  transfer_count,     // Number of words to transfer
    input  wire                         start,
    output reg                          done,
    
    // M20K Write Interfaces (to all buffers)
    output reg  [ADDR_WIDTH-1:0]        m20k_waddr  [NUM_BUFFERS-1:0],
    output reg  [DATA_WIDTH-1:0]        m20k_wdata  [NUM_BUFFERS-1:0],
    output reg  [NUM_BUFFERS-1:0]       m20k_we
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE         = 2'b00;
    localparam TRANSFER     = 2'b01;
    localparam DONE_STATE   = 2'b10;
    
    reg [1:0]   state;
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [ADDR_WIDTH-1:0]    current_addr;
    reg [15:0]              words_remaining;
    reg [1:0]               active_buffer;
    reg                     start_prev;  // Store previous start signal
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    integer i;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            stream_ready <= 1'b0;
            current_addr <= {ADDR_WIDTH{1'b0}};
            words_remaining <= 16'd0;
            active_buffer <= 2'd0;
            m20k_we <= {NUM_BUFFERS{1'b0}};
            start_prev <= 1'b0;
            
            for (i = 0; i < NUM_BUFFERS; i = i + 1) begin
                m20k_waddr[i] <= {ADDR_WIDTH{1'b0}};
                m20k_wdata[i] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            // Capture previous start signal for edge detection
            start_prev <= start;
            
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    stream_ready <= 1'b0;
                    m20k_we <= {NUM_BUFFERS{1'b0}};
                    
                    // Trigger only on rising edge of start signal
                    if (start && !start_prev) begin
                        current_addr <= base_addr;
                        words_remaining <= transfer_count;
                        active_buffer <= target_buffer;
                        // Zero-word transfer: nothing to do, complete immediately
                        if (transfer_count == 16'd0) begin
                            state <= DONE_STATE;
                        end else begin
                            stream_ready <= 1'b1;
                            state <= TRANSFER;
                        end
                    end
                end
                
                TRANSFER: begin
                    if (stream_valid && stream_ready) begin
                        // Write to selected M20K buffer
                        m20k_waddr[active_buffer] <= current_addr;
                        m20k_wdata[active_buffer] <= stream_data;
                        m20k_we[active_buffer] <= 1'b1;
                        
                        $display("  [%0t ns] Bridge: Writing to M20K buffer %d, addr 0x%h, data 0x%h", 
                                 $time/1000.0, active_buffer, current_addr, stream_data);
                        
                        // Update counters
                        current_addr <= current_addr + 1'b1;
                        words_remaining <= words_remaining - 1'b1;
                        
                        // FIXED: Check if we've processed all words (when decremented to 0)
                        if (words_remaining == 16'd1) begin
                            stream_ready <= 1'b0;
                            state <= DONE_STATE;
                        end
                    end else begin
                        // No valid data, clear write enable
                        m20k_we <= {NUM_BUFFERS{1'b0}};
                    end
                end
                
                DONE_STATE: begin
                    m20k_we <= {NUM_BUFFERS{1'b0}};
                    done <= 1'b1;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
