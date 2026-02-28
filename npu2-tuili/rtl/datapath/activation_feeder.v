//******************************************************************************
// Activation Feeder
// Description: Feeds activation data from M20K to systolic array edge
// Features:
//   - Streaming data from M20K buffer to PE array
//   - Support for INT8 and BF16 precision modes
//   - Configurable for different array sizes
//   - Automatic address generation
//******************************************************************************

module activation_feeder #(
    parameter ARRAY_SIZE = 96,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 18
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Control Interface
    input  wire                         start,
    output reg                          done,
    input  wire                         precision_mode,  // 0=INT8, 1=BF16
    input  wire [ADDR_WIDTH-1:0]        base_addr,
    
    // M20K Read Interface
    output reg  [ADDR_WIDTH-1:0]        m20k_raddr,
    input  wire [DATA_WIDTH-1:0]        m20k_rdata,
    output reg                          m20k_re,
    
    // Systolic Array Input (broadcast to left edge)
    output reg  [7:0]                   int8_a_out,
    output reg  [7:0]                   int8_w_out,
    output reg  [15:0]                  bf16_a_out,
    output reg  [15:0]                  bf16_w_out,
    output reg                          data_valid
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE         = 2'b00;
    localparam READ_ADDR    = 2'b01;
    localparam READ_DATA    = 2'b10;
    localparam FEED_ARRAY   = 2'b11;
    
    reg [1:0]   state;
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [ADDR_WIDTH-1:0]    current_addr;
    reg [15:0]              feed_counter;
    reg [15:0]              total_cycles;
    reg [DATA_WIDTH-1:0]    data_buffer;
    reg [2:0]               byte_index;      // For INT8: 0-3 (4 bytes per word)
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            m20k_raddr <= {ADDR_WIDTH{1'b0}};
            m20k_re <= 1'b0;
            current_addr <= {ADDR_WIDTH{1'b0}};
            feed_counter <= 16'd0;
            total_cycles <= 16'd0;
            data_valid <= 1'b0;
            int8_a_out <= 8'd0;
            int8_w_out <= 8'd0;
            bf16_a_out <= 16'd0;
            bf16_w_out <= 16'd0;
            data_buffer <= 32'd0;
            byte_index <= 3'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    data_valid <= 1'b0;
                    m20k_re <= 1'b0;
                    
                    if (start) begin
                        current_addr <= base_addr;
                        feed_counter <= 16'd0;
                        // Total cycles = ARRAY_SIZE for feeding one column
                        total_cycles <= ARRAY_SIZE;
                        byte_index <= 3'd0;
                        state <= READ_ADDR;
                    end
                end
                
                READ_ADDR: begin
                    // Issue read request to M20K
                    m20k_raddr <= current_addr;
                    m20k_re <= 1'b1;
                    state <= READ_DATA;
                end
                
                READ_DATA: begin
                    // Wait one cycle for M20K read latency
                    m20k_re <= 1'b0;
                    data_buffer <= m20k_rdata;
                    state <= FEED_ARRAY;
                end
                
                FEED_ARRAY: begin
                    // Feed data to systolic array based on precision
                    data_valid <= 1'b1;
                    
                    if (!precision_mode) begin
                        // INT8 mode: Extract bytes from 32-bit word
                        case (byte_index)
                            3'd0: begin
                                int8_a_out <= data_buffer[7:0];
                                int8_w_out <= data_buffer[7:0];
                            end
                            3'd1: begin
                                int8_a_out <= data_buffer[15:8];
                                int8_w_out <= data_buffer[15:8];
                            end
                            3'd2: begin
                                int8_a_out <= data_buffer[23:16];
                                int8_w_out <= data_buffer[23:16];
                            end
                            3'd3: begin
                                int8_a_out <= data_buffer[31:24];
                                int8_w_out <= data_buffer[31:24];
                            end
                            default: begin
                                int8_a_out <= 8'd0;
                                int8_w_out <= 8'd0;
                            end
                        endcase
                        
                        byte_index <= byte_index + 1'b1;
                        
                        // Need new word every 4 bytes
                        if (byte_index == 3'd3) begin
                            current_addr <= current_addr + 1'b1;
                            state <= READ_ADDR;
                        end
                    end else begin
                        // BF16 mode: Extract 16-bit values from 32-bit word
                        if (byte_index[0] == 1'b0) begin
                            bf16_a_out <= data_buffer[15:0];
                            bf16_w_out <= data_buffer[15:0];
                        end else begin
                            bf16_a_out <= data_buffer[31:16];
                            bf16_w_out <= data_buffer[31:16];
                        end
                        
                        byte_index <= byte_index + 1'b1;
                        
                        // Need new word every 2 BF16 values
                        if (byte_index[0] == 1'b1) begin
                            current_addr <= current_addr + 1'b1;
                            state <= READ_ADDR;
                        end
                    end
                    
                    // Check if feeding is complete
                    feed_counter <= feed_counter + 1'b1;
                    if (feed_counter >= total_cycles - 1) begin
                        data_valid <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
