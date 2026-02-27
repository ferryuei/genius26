//******************************************************************************
// Variable Precision Processing Element (PE)
// Description: Single PE supporting INT8 and BF16 operations
// Features:
//   - INT8 MAC: 8-bit x 8-bit -> 32-bit accumulator
//   - BF16 MAC: bfloat16 multiply-accumulate
//   - Runtime switchable precision
//   - Uses Stratix 10 Variable Precision DSP block (model)
//******************************************************************************

module vp_pe #(
    parameter DATA_WIDTH = 32
)(
    // Clock and Reset
    input  wire                     clk,
    input  wire                     rst_n,
    
    // Control
    input  wire                     enable,
    input  wire                     precision_mode,  // 0=INT8, 1=BF16
    input  wire                     accumulate,      // 1=accumulate, 0=replace
    
    // INT8 Inputs
    input  wire [7:0]               int8_a_in,
    input  wire [7:0]               int8_w_in,
    
    // BF16 Inputs (bfloat16: 1-sign, 8-exp, 7-mantissa)
    input  wire [15:0]              bf16_a_in,
    input  wire [15:0]              bf16_w_in,
    
    // Accumulator Input (for systolic array chaining)
    input  wire [DATA_WIDTH-1:0]    acc_in,
    
    // Output
    output reg  [DATA_WIDTH-1:0]    result_out,
    output reg  [15:0]              bf16_out,
    output reg                      valid_out
);

    //==========================================================================
    // Internal Signals
    //==========================================================================
    
    reg  [DATA_WIDTH-1:0]   accumulator;
    wire [DATA_WIDTH-1:0]   mac_result;
    wire [DATA_WIDTH-1:0]   int8_product;
    wire [DATA_WIDTH-1:0]   bf16_product;
    
    // Pipeline registers
    reg  [7:0]              int8_a_r, int8_w_r;
    reg  [15:0]             bf16_a_r, bf16_w_r;
    reg                     precision_mode_r;
    reg                     enable_r1, enable_r2, enable_r3;
    
    //==========================================================================
    // INT8 Multiplication (DSP Block Model)
    //==========================================================================
    
    wire signed [15:0]      int8_a_ext = {{8{int8_a_r[7]}}, int8_a_r};
    wire signed [15:0]      int8_w_ext = {{8{int8_w_r[7]}}, int8_w_r};
    wire signed [31:0]      int8_mult  = int8_a_ext * int8_w_ext;
    
    assign int8_product = int8_mult;
    
    //==========================================================================
    // BF16 Multiplication (DSP Block Model - Simplified)
    //==========================================================================
    // Note: This is a behavioral model. In real hardware, use Intel Variable
    // Precision DSP IP or instantiate twentynm_mac primitive
    
    reg [31:0] bf16_mult_result;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            bf16_mult_result <= 32'd0;
        end else if (enable_r1) begin
            // BF16 multiplication (simplified model)
            // In real design: use Intel FP multiplier IP
            bf16_mult_result <= bf16_multiply(bf16_a_r, bf16_w_r);
        end
    end
    
    assign bf16_product = bf16_mult_result;
    
    //==========================================================================
    // MAC Operation (Multiply-Accumulate)
    //==========================================================================
    
    // Pipeline Stage 1: Input Register
    always @(posedge clk) begin
        if (!rst_n) begin
            int8_a_r        <= 8'd0;
            int8_w_r        <= 8'd0;
            bf16_a_r        <= 16'd0;
            bf16_w_r        <= 16'd0;
            precision_mode_r<= 1'b0;
            enable_r1       <= 1'b0;
        end else begin
            int8_a_r        <= int8_a_in;
            int8_w_r        <= int8_w_in;
            bf16_a_r        <= bf16_a_in;
            bf16_w_r        <= bf16_w_in;
            precision_mode_r<= precision_mode;
            enable_r1       <= enable;
        end
    end
    
    // Pipeline Stage 2: Multiply
    always @(posedge clk) begin
        if (!rst_n) begin
            enable_r2 <= 1'b0;
        end else begin
            enable_r2 <= enable_r1;
        end
    end
    
    // Pipeline Stage 3: Accumulate
    always @(posedge clk) begin
        if (!rst_n) begin
            accumulator <= 32'd0;
            enable_r3   <= 1'b0;
        end else if (enable_r2) begin
            if (accumulate) begin
                if (precision_mode_r) begin
                    // BF16 accumulation
                    accumulator <= bf16_add(accumulator, bf16_product);
                end else begin
                    // INT8 accumulation
                    accumulator <= accumulator + int8_product;
                end
            end else begin
                // Replace mode (first accumulation or reset)
                accumulator <= precision_mode_r ? bf16_product : int8_product;
            end
            enable_r3 <= 1'b1;
        end else begin
            enable_r3 <= 1'b0;
        end
    end
    
    // Output Register
    always @(posedge clk) begin
        if (!rst_n) begin
            result_out <= 32'd0;
            bf16_out   <= 16'd0;
            valid_out  <= 1'b0;
        end else begin
            result_out <= accumulator;
            bf16_out   <= accumulator[31:16]; // Extract BF16 (upper 16 bits)
            valid_out  <= enable_r3;
        end
    end
    
    //==========================================================================
    // BF16 Arithmetic Functions (Behavioral Model)
    //==========================================================================
    // Note: Replace with Intel FP IP in real design
    
    function [31:0] bf16_multiply;
        input [15:0] a;
        input [15:0] b;
        reg sign_a, sign_b, sign_result;
        reg [7:0] exp_a, exp_b, exp_result;
        reg [7:0] mant_a, mant_b;
        reg [15:0] mant_result;
        begin
            // Extract fields
            sign_a = a[15];
            exp_a  = a[14:7];
            mant_a = {1'b1, a[6:0]}; // Add implicit 1
            
            sign_b = b[15];
            exp_b  = b[14:7];
            mant_b = {1'b1, b[6:0]};
            
            // Multiply
            sign_result = sign_a ^ sign_b;
            exp_result  = exp_a + exp_b - 8'd127; // Remove bias
            mant_result = mant_a * mant_b;
            
            // Normalize and pack
            bf16_multiply = {sign_result, exp_result, mant_result[14:8], 16'd0};
        end
    endfunction
    
    function [31:0] bf16_add;
        input [31:0] a;
        input [31:0] b;
        begin
            // Simplified: direct integer add (not correct BF16 semantics)
            // In real design: use Intel FP adder IP
            bf16_add = a + b;
        end
    endfunction

endmodule
