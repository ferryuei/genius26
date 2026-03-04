//******************************************************************************
// Systolic Array - Fixed Version
// Description: 96x96 Processing Element array for matrix multiplication
// Architecture: Weight Stationary
// Data Flow:
//   - Activations: Horizontal (left to right), each row has independent input
//   - Weights: Stationary (pre-loaded into each PE column)
//   - Partial Sums: Vertical (top to bottom), accumulated per column
//   - Outputs: Collected from bottom row (all columns)
// Features:
//   - Supports INT8 and BF16 precision
//   - Pipelined data flow
//   - Configurable array size
//******************************************************************************

module systolic_array #(
    parameter ARRAY_SIZE = 96,
    parameter DATA_WIDTH = 32,
    parameter WEIGHT_ADDR_WIDTH = 18
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,

    // Control Signals
    input  wire                         start,
    output reg                          done = 1'b0,
    input  wire                         precision_mode,  // 0=INT8, 1=BF16

    // Weight Memory Interface (for loading weights into array)
    output wire [WEIGHT_ADDR_WIDTH-1:0] weight_addr,
    input  wire [DATA_WIDTH-1:0]        weight_data,
    output wire                         weight_re,

    // Input Activation Stream (from left edge, per row)
    // For INT8: each row gets one byte per cycle
    // For BF16: each row gets one half-word per cycle
    input  wire [7:0]                   int8_a_in [0:ARRAY_SIZE-1],
    input  wire [15:0]                  bf16_a_in [0:ARRAY_SIZE-1],

    // Output Results (from bottom edge, per column)
    // Results are valid sequentially as pipeline drains
    output wire [DATA_WIDTH-1:0]        result_out [0:ARRAY_SIZE-1],
    output wire                         result_valid [0:ARRAY_SIZE-1]
);

    //==========================================================================
    // Internal Signals
    //==========================================================================

    // PE Grid Interconnects
    // Activation: flows left to right
    wire [7:0]              int8_a_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [15:0]             bf16_a_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Partial sums: flows top to bottom (accumulated)
    wire [DATA_WIDTH-1:0]   psum_grid       [0:ARRAY_SIZE][0:ARRAY_SIZE-1];  // Extra row for input

    // Results: from each PE
    wire [DATA_WIDTH-1:0]   result_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire                    valid_grid      [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Weights: stored in each PE (stationary)
    // We load weights via separate interface during LOAD_W state
    wire [7:0]              pe_int8_w       [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [15:0]             pe_bf16_w       [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Control FSM
    localparam IDLE     = 3'b000;
    localparam LOAD_W   = 3'b001;
    localparam COMPUTE  = 3'b010;
    localparam DRAIN    = 3'b011;
    localparam DONE     = 3'b100;

    reg [2:0]               state = 3'b000;
    reg [15:0]              cycle_count = 16'd0;
    reg [15:0]              compute_cycles = 16'd0;
    reg                     pe_enable = 1'b0;
    reg                     accumulate_mode = 1'b0;

    // Weight Loading
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_load_addr = {WEIGHT_ADDR_WIDTH{1'b0}};
    reg                         weight_load_en = 1'b0;
    reg [15:0]                  weights_loaded = 16'd0;

    // Output collection
    reg [15:0]              output_col = 16'd0;
    reg                     output_ready = 1'b0;

    //==========================================================================
    // Control FSM
    //==========================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            state           <= IDLE;
            cycle_count     <= 16'd0;
            compute_cycles  <= ARRAY_SIZE * 2;  // Need 2*ARRAY_SIZE for full pipeline
            pe_enable       <= 1'b0;
            accumulate_mode <= 1'b0;
            weight_load_addr<= {WEIGHT_ADDR_WIDTH{1'b0}};
            weight_load_en  <= 1'b0;
            weights_loaded  <= 16'd0;
            done            <= 1'b0;
            output_col      <= 16'd0;
            output_ready    <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    cycle_count <= 16'd0;
                    output_ready <= 1'b0;
                    output_col <= 16'd0;

                    if (start) begin
                        $display("  [%0t ns] Systolic Array[%m]: START received, entering LOAD_W", $time/1000.0);
                        state <= LOAD_W;
                        weight_load_addr <= {WEIGHT_ADDR_WIDTH{1'b0}};
                        weight_load_en <= 1'b1;
                        weights_loaded <= 16'd0;
                    end
                end

                LOAD_W: begin
                    // Load weights column by column
                    // Each column needs ARRAY_SIZE weights
                    weight_load_addr <= weight_load_addr + 1'b1;
                    weights_loaded <= weights_loaded + 1'b1;

                    if (weights_loaded >= ARRAY_SIZE * ARRAY_SIZE - 1) begin
                        $display("  [%0t ns] Systolic Array[%m]: Weight loading complete (%d weights), entering COMPUTE",
                                 $time/1000.0, ARRAY_SIZE * ARRAY_SIZE);
                        state <= COMPUTE;
                        weight_load_en <= 1'b0;
                        pe_enable <= 1'b1;
                        accumulate_mode <= 1'b0;
                        cycle_count <= 16'd0;
                    end
                end

                COMPUTE: begin
                    cycle_count <= cycle_count + 1'b1;
                    accumulate_mode <= 1'b1;

                    // Compute phase: feed activations for ARRAY_SIZE cycles
                    // Plus ARRAY_SIZE cycles for pipeline fill
                    if (cycle_count >= compute_cycles + ARRAY_SIZE) begin
                        $display("  [%0t ns] Systolic Array[%m]: Compute complete (%d cycles), entering DRAIN",
                                 $time/1000.0, cycle_count);
                        state <= DRAIN;
                        pe_enable <= 1'b0;
                        cycle_count <= 16'd0;
                    end
                end

                DRAIN: begin
                    // Wait for pipeline to drain
                    cycle_count <= cycle_count + 1'b1;
                    output_ready <= 1'b1;

                    // Results become available column by column
                    if (cycle_count >= ARRAY_SIZE) begin
                        $display("  [%0t ns] Systolic Array[%m]: Pipeline drain complete, asserting DONE",
                                 $time/1000.0);
                        state <= DONE;
                        output_ready <= 1'b0;
                        done <= 1'b1;
                    end
                end

                DONE: begin
                    done <= 1'b0;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign weight_addr = weight_load_addr;
    assign weight_re = weight_load_en;

    //==========================================================================
    // Weight Storage (distributed to each PE column)
    //==========================================================================

    // Weight memory for each PE - loaded during LOAD_W state
    reg [7:0]  weight_mem_int8 [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg [15:0] weight_mem_bf16 [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer r, c;
    always @(posedge clk) begin
        if (weight_load_en) begin
            // Calculate row and column from linear address
            // weights_loaded = row * ARRAY_SIZE + col
            automatic int load_row = weights_loaded / ARRAY_SIZE;
            automatic int load_col = weights_loaded % ARRAY_SIZE;
            if (load_row < ARRAY_SIZE && load_col < ARRAY_SIZE) begin
                if (!precision_mode) begin
                    // INT8: extract lower byte from 32-bit weight_data
                    weight_mem_int8[load_row][load_col] <= weight_data[7:0];
                end else begin
                    // BF16: extract upper 16 bits from 32-bit weight_data
                    weight_mem_bf16[load_row][load_col] <= weight_data[31:16];
                end
            end
        end
    end

    //==========================================================================
    // PE Array Instantiation (96x96 Grid)
    //==========================================================================

    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : gen_rows
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_cols

                // PE Input Connections
                wire [7:0]  pe_int8_a;
                wire [7:0]  pe_int8_w_local;
                wire [15:0] pe_bf16_a;
                wire [15:0] pe_bf16_w_local;
                wire [DATA_WIDTH-1:0] pe_acc_in;

                // Activation flows from left to right
                // First column gets external input, others get from left neighbor
                assign pe_int8_a = (col == 0) ? int8_a_in[row] : int8_a_grid[row][col-1];
                assign pe_bf16_a = (col == 0) ? bf16_a_in[row] : bf16_a_grid[row][col-1];

                // Weights are stationary (loaded into local storage)
                assign pe_int8_w_local = weight_mem_int8[row][col];
                assign pe_bf16_w_local = weight_mem_bf16[row][col];

                // Partial sum flows from top to bottom
                // First row gets zero, others get from row above
                assign pe_acc_in = psum_grid[row][col];

                // Instantiate PE
                vp_pe_fixed #(
                    .DATA_WIDTH(DATA_WIDTH)
                ) u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .enable         (pe_enable),
                    .precision_mode (precision_mode),
                    .accumulate     (accumulate_mode),
                    .int8_a_in      (pe_int8_a),
                    .int8_w_in      (pe_int8_w_local),
                    .bf16_a_in      (pe_bf16_a),
                    .bf16_w_in      (pe_bf16_w_local),
                    .acc_in         (pe_acc_in),
                    .result_out     (result_grid[row][col]),
                    .valid_out      (valid_grid[row][col])
                );

                // Connect activation output to right neighbor
                assign int8_a_grid[row][col] = pe_int8_a;
                assign bf16_a_grid[row][col] = pe_bf16_a;

                // Connect partial sum to next row
                // For row 0, psum_grid[0][col] is the input (zero)
                // For other rows, psum_grid[row][col] comes from result_grid[row-1][col]
                if (row == 0) begin
                    assign psum_grid[0][col] = {DATA_WIDTH{1'b0}};
                end else begin
                    assign psum_grid[row][col] = result_grid[row-1][col];
                end

            end
        end
    endgenerate

    //==========================================================================
    // Output Extraction (Bottom Row - All Columns)
    //==========================================================================

    // Generate output for each column from the bottom row
    generate
        for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_outputs
            assign result_out[col] = result_grid[ARRAY_SIZE-1][col];
            assign result_valid[col] = valid_grid[ARRAY_SIZE-1][col] && output_ready;
        end
    endgenerate

endmodule


//******************************************************************************
// Fixed Variable Precision Processing Element (PE)
// Description: Single PE supporting INT8 and BF16 operations
// Features:
//   - INT8 MAC: 8-bit x 8-bit -> 32-bit accumulator
//   - BF16 MAC: bfloat16 multiply-accumulate (placeholder for IP)
//   - Runtime switchable precision
//******************************************************************************

module vp_pe_fixed #(
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

    // Accumulator Input (from PE above)
    input  wire [DATA_WIDTH-1:0]    acc_in,

    // Output
    output reg  [DATA_WIDTH-1:0]    result_out,
    output reg                      valid_out
);

    //==========================================================================
    // Internal Signals
    //==========================================================================

    reg  [DATA_WIDTH-1:0]   accumulator;
    wire [DATA_WIDTH-1:0]   mac_result;
    wire [DATA_WIDTH-1:0]   int8_product;
    reg  [DATA_WIDTH-1:0]   bf16_product;

    // Pipeline registers
    reg  [7:0]              int8_a_r, int8_w_r;
    reg  [15:0]             bf16_a_r, bf16_w_r;
    reg                     precision_mode_r;
    reg                     enable_r1, enable_r2, enable_r3;
    reg  [DATA_WIDTH-1:0]   acc_in_r;

    //==========================================================================
    // INT8 Multiplication (Signed)
    //==========================================================================

    wire signed [7:0]       int8_a_signed = $signed(int8_a_r);
    wire signed [7:0]       int8_w_signed = $signed(int8_w_r);
    wire signed [15:0]      int8_mult     = int8_a_signed * int8_w_signed;

    assign int8_product = {{16{int8_mult[15]}}, int8_mult};  // Sign extend to 32-bit

    //==========================================================================
    // BF16 Multiplication (Placeholder - needs Intel FP IP)
    //==========================================================================

    // Simplified BF16 multiply - treats as integer for now
    // In production: replace with Intel twentynm_fp_mac or similar
    always @(posedge clk) begin
        if (!rst_n) begin
            bf16_product <= 32'd0;
        end else if (enable_r1) begin
            // Placeholder: pack BF16 into upper 16 bits of 32-bit result
            // Real implementation needs proper FP multiplier
            bf16_product <= {bf16_a_r, 16'd0};  // Just pass through for now
        end
    end

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
            acc_in_r        <= {DATA_WIDTH{1'b0}};
            enable_r1       <= 1'b0;
        end else begin
            int8_a_r        <= int8_a_in;
            int8_w_r        <= int8_w_in;
            bf16_a_r        <= bf16_a_in;
            bf16_w_r        <= bf16_w_in;
            precision_mode_r<= precision_mode;
            acc_in_r        <= acc_in;
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
                // Add partial sum from above + this PE's product
                if (precision_mode_r) begin
                    // BF16 accumulation (placeholder)
                    accumulator <= acc_in_r + bf16_product;
                end else begin
                    // INT8 accumulation
                    accumulator <= acc_in_r + int8_product;
                end
            end else begin
                // First accumulation: product only
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
            valid_out  <= 1'b0;
        end else begin
            result_out <= accumulator;
            valid_out  <= enable_r3;
        end
    end

endmodule
