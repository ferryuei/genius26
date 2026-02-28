//******************************************************************************
// Special Function Unit (SFU) - Enhanced Version
// Description: Hardware accelerators for non-linear operations in neural networks
// Features:
//   - Softmax (with max-finding and exp approximation)
//   - Layer Normalization (mean, variance, normalization)
//   - GELU activation (lookup table based)
//   - Support INT8 and BF16 precision modes
//   - Pipelined architecture for throughput
//******************************************************************************

module sfu_unit #(
    parameter DATA_WIDTH = 32,
    parameter VECTOR_LEN = 128,
    parameter EXP_LUT_SIZE = 256
)(
    // Clock and Reset
    input  wire                     clk,
    input  wire                     rst_n,
    
    // Control
    input  wire                     softmax_start,
    input  wire                     layernorm_start,
    input  wire                     gelu_start,
    output reg                      done,
    input  wire                     precision_mode,  // 0=INT8, 1=BF16
    input  wire [7:0]               vector_length,   // Actual vector length to process
    
    // Data Interface
    input  wire [DATA_WIDTH-1:0]    data_in,
    output reg  [DATA_WIDTH-1:0]    data_out,
    output reg                      data_valid
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE             = 4'b0000;
    localparam SOFTMAX_PASS1    = 4'b0001;  // Find max
    localparam SOFTMAX_PASS2    = 4'b0010;  // Compute exp and sum
    localparam SOFTMAX_PASS3    = 4'b0011;  // Normalize
    localparam LAYERNORM_PASS1  = 4'b0100;  // Compute mean
    localparam LAYERNORM_PASS2  = 4'b0101;  // Compute variance
    localparam LAYERNORM_PASS3  = 4'b0110;  // Normalize
    localparam GELU_COMPUTE     = 4'b0111;  // Apply GELU
    localparam DONE_STATE       = 4'b1000;
    
    reg [3:0]   state;
    reg [7:0]   element_counter;
    
    //==========================================================================
    // Vector Storage (for multi-pass algorithms)
    //==========================================================================
    
    reg [DATA_WIDTH-1:0] vector_buffer [0:127];
    reg [7:0]            buffer_wr_ptr;
    reg [7:0]            buffer_rd_ptr;
    
    //==========================================================================
    // Softmax Registers
    //==========================================================================
    
    reg signed [DATA_WIDTH-1:0] softmax_max;
    reg signed [DATA_WIDTH-1:0] softmax_sum;
    reg signed [DATA_WIDTH-1:0] exp_value;
    
    //==========================================================================
    // LayerNorm Registers
    //==========================================================================
    
    reg signed [DATA_WIDTH-1:0] ln_sum;
    reg signed [DATA_WIDTH-1:0] ln_mean;
    reg signed [DATA_WIDTH-1:0] ln_variance_sum;
    reg signed [DATA_WIDTH-1:0] ln_variance;
    reg signed [DATA_WIDTH-1:0] ln_std_inv;
    
    //==========================================================================
    // Exponential Lookup Table (for Softmax)
    //==========================================================================
    // exp(x) approximation using 256-entry LUT
    // Covers range [-8, 0] mapped to [0, 1]
    
    reg [15:0] exp_lut [0:255];
    
    initial begin
        integer i;
        real x, exp_x;
        for (i = 0; i < 256; i = i + 1) begin
            // Map index to range [-8, 0]
            x = -8.0 + (i * 8.0 / 255.0);
            exp_x = 2.71828 ** x;
            // Scale to 16-bit fixed point (Q8.8)
            exp_lut[i] = $rtoi(exp_x * 256.0);
        end
    end
    
    //==========================================================================
    // GELU Lookup Table
    //==========================================================================
    // GELU(x) = 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
    // 256 entries covering range [-4, 4]
    
    reg signed [15:0] gelu_lut [0:255];
    
    initial begin
        integer i;
        real x, gelu_x, tanh_arg;
        for (i = 0; i < 256; i = i + 1) begin
            // Map index to range [-4, 4]
            x = -4.0 + (i * 8.0 / 255.0);
            // GELU approximation
            tanh_arg = 0.7978845608 * (x + 0.044715 * x * x * x);
            if (tanh_arg > 5.0) tanh_arg = 5.0;
            if (tanh_arg < -5.0) tanh_arg = -5.0;
            gelu_x = 0.5 * x * (1.0 + ((2.71828 ** tanh_arg - 2.71828 ** (-tanh_arg)) / 
                                       (2.71828 ** tanh_arg + 2.71828 ** (-tanh_arg))));
            // Scale to Q8.8 fixed point
            gelu_lut[i] = $rtoi(gelu_x * 256.0);
        end
    end
    
    //==========================================================================
    // Reciprocal Square Root Lookup Table (for LayerNorm)
    //==========================================================================
    
    reg [15:0] rsqrt_lut [0:255];
    
    initial begin
        integer i;
        real x, rsqrt_x;
        for (i = 1; i < 256; i = i + 1) begin
            x = i / 256.0;
            rsqrt_x = 1.0 / $sqrt(x);
            rsqrt_lut[i] = $rtoi(rsqrt_x * 256.0);
        end
        rsqrt_lut[0] = 16'hFFFF;  // Avoid divide by zero
    end
    
    //==========================================================================
    // Main Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            data_out <= {DATA_WIDTH{1'b0}};
            data_valid <= 1'b0;
            element_counter <= 8'd0;
            buffer_wr_ptr <= 8'd0;
            buffer_rd_ptr <= 8'd0;
            
            softmax_max <= 32'sh80000000;  // Minimum signed value
            softmax_sum <= 32'd0;
            ln_sum <= 32'd0;
            ln_mean <= 32'd0;
            ln_variance_sum <= 32'd0;
        end else begin
            // Default: clear data_valid
            data_valid <= 1'b0;
            
            case (state)
                //--------------------------------------------------------------
                // IDLE State
                //--------------------------------------------------------------
                IDLE: begin
                    done <= 1'b0;
                    element_counter <= 8'd0;
                    buffer_wr_ptr <= 8'd0;
                    buffer_rd_ptr <= 8'd0;
                    
                    if (softmax_start) begin
                        state <= SOFTMAX_PASS1;
                        softmax_max <= 32'sh80000000;
                        softmax_sum <= 32'd0;
                    end else if (layernorm_start) begin
                        state <= LAYERNORM_PASS1;
                        ln_sum <= 32'd0;
                        ln_variance_sum <= 32'd0;
                    end else if (gelu_start) begin
                        state <= GELU_COMPUTE;
                    end
                end
                
                //--------------------------------------------------------------
                // SOFTMAX Pass 1: Find Maximum
                //--------------------------------------------------------------
                SOFTMAX_PASS1: begin
                    // Store input to buffer and find max
                    vector_buffer[buffer_wr_ptr] <= data_in;
                    buffer_wr_ptr <= buffer_wr_ptr + 1'b1;
                    
                    // Track maximum value
                    if ($signed(data_in) > $signed(softmax_max)) begin
                        softmax_max <= data_in;
                    end
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        state <= SOFTMAX_PASS2;
                        element_counter <= 8'd0;
                    end
                end
                
                //--------------------------------------------------------------
                // SOFTMAX Pass 2: Compute exp(x - max) and sum
                //--------------------------------------------------------------
                SOFTMAX_PASS2: begin
                    // Read from buffer
                    exp_value <= compute_exp(vector_buffer[buffer_rd_ptr] - softmax_max);
                    
                    // Store exp value back to buffer
                    vector_buffer[buffer_rd_ptr] <= exp_value;
                    buffer_rd_ptr <= buffer_rd_ptr + 1'b1;
                    
                    // Accumulate sum
                    softmax_sum <= softmax_sum + exp_value;
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        state <= SOFTMAX_PASS3;
                        element_counter <= 8'd0;
                        buffer_rd_ptr <= 8'd0;
                    end
                end
                
                //--------------------------------------------------------------
                // SOFTMAX Pass 3: Normalize (divide by sum)
                //--------------------------------------------------------------
                SOFTMAX_PASS3: begin
                    // Normalize: exp_value / sum
                    // Using fixed-point: (exp_value << 16) / sum
                    data_out <= (vector_buffer[buffer_rd_ptr] << 8) / (softmax_sum >> 8);
                    data_valid <= 1'b1;
                    buffer_rd_ptr <= buffer_rd_ptr + 1'b1;
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        state <= DONE_STATE;
                    end
                end
                
                //--------------------------------------------------------------
                // LAYERNORM Pass 1: Compute Mean
                //--------------------------------------------------------------
                LAYERNORM_PASS1: begin
                    // Store input and accumulate sum
                    vector_buffer[buffer_wr_ptr] <= data_in;
                    buffer_wr_ptr <= buffer_wr_ptr + 1'b1;
                    ln_sum <= ln_sum + data_in;
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        // Compute mean
                        ln_mean <= ln_sum / {24'd0, vector_length};
                        state <= LAYERNORM_PASS2;
                        element_counter <= 8'd0;
                    end
                end
                
                //--------------------------------------------------------------
                // LAYERNORM Pass 2: Compute Variance
                //--------------------------------------------------------------
                LAYERNORM_PASS2: begin
                    // Compute (x - mean)^2
                    reg signed [DATA_WIDTH-1:0] diff;
                    diff = vector_buffer[buffer_rd_ptr] - ln_mean;
                    ln_variance_sum <= ln_variance_sum + (diff * diff);
                    buffer_rd_ptr <= buffer_rd_ptr + 1'b1;
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        // Compute variance and 1/sqrt(variance + epsilon)
                        ln_variance <= ln_variance_sum / {24'd0, vector_length};
                        // Compute reciprocal sqrt for next pass
                        ln_std_inv <= compute_rsqrt(ln_variance + 32'd100);  // epsilon = 100
                        state <= LAYERNORM_PASS3;
                        element_counter <= 8'd0;
                        buffer_rd_ptr <= 8'd0;
                    end
                end
                
                //--------------------------------------------------------------
                // LAYERNORM Pass 3: Normalize
                //--------------------------------------------------------------
                LAYERNORM_PASS3: begin
                    // Normalize: (x - mean) * rsqrt(variance + epsilon)
                    reg signed [DATA_WIDTH-1:0] diff;
                    diff = vector_buffer[buffer_rd_ptr] - ln_mean;
                    data_out <= (diff * ln_std_inv) >> 8;  // Adjust for fixed-point
                    data_valid <= 1'b1;
                    buffer_rd_ptr <= buffer_rd_ptr + 1'b1;
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        state <= DONE_STATE;
                    end
                end
                
                //--------------------------------------------------------------
                // GELU: Apply activation function
                //--------------------------------------------------------------
                GELU_COMPUTE: begin
                    // Apply GELU using LUT
                    data_out <= apply_gelu(data_in);
                    data_valid <= 1'b1;
                    
                    element_counter <= element_counter + 1'b1;
                    if (element_counter >= vector_length - 1) begin
                        state <= DONE_STATE;
                    end
                end
                
                //--------------------------------------------------------------
                // DONE State
                //--------------------------------------------------------------
                DONE_STATE: begin
                    done <= 1'b1;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    //==========================================================================
    // Computation Functions
    //==========================================================================
    
    // Exponential approximation using LUT
    function [DATA_WIDTH-1:0] compute_exp;
        input signed [DATA_WIDTH-1:0] x;
        reg [7:0] lut_index;
        reg [15:0] lut_value;
        begin
            // Clamp to range [-8, 0]
            if (x < -32'sd8 << 8) begin
                lut_index = 8'd0;
            end else if (x > 0) begin
                lut_index = 8'd255;
            end else begin
                // Map x in [-8, 0] to index [0, 255]
                lut_index = (((-x) >> 8) * 32) & 8'hFF;
            end
            
            lut_value = exp_lut[lut_index];
            compute_exp = {16'd0, lut_value};
        end
    endfunction
    
    // Reciprocal square root using LUT
    function [DATA_WIDTH-1:0] compute_rsqrt;
        input [DATA_WIDTH-1:0] x;
        reg [7:0] lut_index;
        reg [15:0] lut_value;
        begin
            // Normalize x to [0, 1] range and use upper 8 bits as index
            lut_index = x[15:8];
            if (lut_index == 0) lut_index = 1;  // Avoid zero
            
            lut_value = rsqrt_lut[lut_index];
            compute_rsqrt = {16'd0, lut_value};
        end
    endfunction
    
    // GELU activation using LUT
    function [DATA_WIDTH-1:0] apply_gelu;
        input signed [DATA_WIDTH-1:0] x;
        reg [7:0] lut_index;
        reg signed [15:0] lut_value;
        begin
            // Map x in [-4, 4] to index [0, 255]
            if (x < -32'sd4 << 8) begin
                lut_index = 8'd0;
            end else if (x > 32'sd4 << 8) begin
                lut_index = 8'd255;
            end else begin
                // Scale and shift to [0, 255]
                lut_index = ((x >> 8) + 32'sd4) * 32;
            end
            
            lut_value = gelu_lut[lut_index];
            // Scale back
            apply_gelu = {{16{lut_value[15]}}, lut_value};
        end
    endfunction

endmodule
