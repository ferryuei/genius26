//******************************************************************************
// Systolic Array
// Description: 96x96 Processing Element array for matrix multiplication
// Architecture: Weight Stationary
// Features:
//   - Supports INT8 and BF16 precision
//   - Pipelined data flow (left to right, top to bottom)
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
    output reg                          done,
    input  wire                         precision_mode,  // 0=INT8, 1=BF16
    
    // Weight Memory Interface
    output wire [WEIGHT_ADDR_WIDTH-1:0] weight_addr,
    input  wire [DATA_WIDTH-1:0]        weight_data,
    output wire                         weight_re,
    
    // Input Activation Stream (from left edge)
    input  wire [7:0]                   int8_a_in,
    input  wire [7:0]                   int8_w_in,
    input  wire [15:0]                  bf16_a_in,
    input  wire [15:0]                  bf16_w_in,
    
    // Output Results (from bottom edge)
    output wire [DATA_WIDTH-1:0]        result_out,
    output wire                         result_valid
);

    //==========================================================================
    // Internal Signals
    //==========================================================================
    
    // PE Grid Interconnects
    wire [7:0]              int8_a_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [7:0]              int8_w_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [15:0]             bf16_a_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [15:0]             bf16_w_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0]   acc_grid        [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0]   result_grid     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire                    valid_grid      [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    
    // Control FSM
    localparam IDLE     = 2'b00;
    localparam LOAD_W   = 2'b01;
    localparam COMPUTE  = 2'b10;
    localparam DRAIN    = 2'b11;
    
    reg [1:0]               state;
    reg [15:0]              cycle_count;
    reg [15:0]              compute_cycles;
    reg                     pe_enable;
    reg                     accumulate_mode;
    
    // Weight Loading
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_load_addr;
    reg                         weight_load_en;
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state           <= IDLE;
            done            <= 1'b0;
            cycle_count     <= 16'd0;
            compute_cycles  <= 16'd96;  // Default for 96x96
            pe_enable       <= 1'b0;
            accumulate_mode <= 1'b0;
            weight_load_addr<= {WEIGHT_ADDR_WIDTH{1'b0}};
            weight_load_en  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    cycle_count <= 16'd0;
                    if (start) begin
                        state <= LOAD_W;
                        weight_load_addr <= {WEIGHT_ADDR_WIDTH{1'b0}};
                        weight_load_en <= 1'b1;
                    end
                end
                
                LOAD_W: begin
                    // Load weights into PE array (simplified - assumes pre-loaded)
                    weight_load_addr <= weight_load_addr + 1'b1;
                    if (weight_load_addr == (ARRAY_SIZE * ARRAY_SIZE - 1)) begin
                        state <= COMPUTE;
                        weight_load_en <= 1'b0;
                        pe_enable <= 1'b1;
                        accumulate_mode <= 1'b0;
                    end
                end
                
                COMPUTE: begin
                    cycle_count <= cycle_count + 1'b1;
                    accumulate_mode <= 1'b1;
                    
                    if (cycle_count == compute_cycles) begin
                        state <= DRAIN;
                        pe_enable <= 1'b0;
                        cycle_count <= 16'd0;
                    end
                end
                
                DRAIN: begin
                    // Wait for pipeline to drain
                    cycle_count <= cycle_count + 1'b1;
                    if (cycle_count == ARRAY_SIZE + 16'd10) begin
                        state <= IDLE;
                        done <= 1'b1;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    assign weight_addr = weight_load_addr;
    assign weight_re = weight_load_en;
    
    //==========================================================================
    // PE Array Instantiation (96x96 Grid)
    //==========================================================================
    
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : gen_rows
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_cols
                
                // PE Input Connections
                wire [7:0]  pe_int8_a;
                wire [7:0]  pe_int8_w;
                wire [15:0] pe_bf16_a;
                wire [15:0] pe_bf16_w;
                wire [DATA_WIDTH-1:0] pe_acc_in;
                
                // Activation flows from left to right
                assign pe_int8_a = (col == 0) ? int8_a_in : int8_a_grid[row][col-1];
                assign pe_bf16_a = (col == 0) ? bf16_a_in : bf16_a_grid[row][col-1];
                
                // Weight flows from top to bottom (stationary in this design)
                assign pe_int8_w = int8_w_in;  // Broadcast or from memory
                assign pe_bf16_w = bf16_w_in;
                
                // Partial sum flows from top to bottom
                assign pe_acc_in = (row == 0) ? {DATA_WIDTH{1'b0}} : result_grid[row-1][col];
                
                // Instantiate PE
                vp_pe #(
                    .DATA_WIDTH(DATA_WIDTH)
                ) u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .enable         (pe_enable),
                    .precision_mode (precision_mode),
                    .accumulate     (accumulate_mode),
                    .int8_a_in      (pe_int8_a),
                    .int8_w_in      (pe_int8_w),
                    .bf16_a_in      (pe_bf16_a),
                    .bf16_w_in      (pe_bf16_w),
                    .acc_in         (pe_acc_in),
                    .result_out     (result_grid[row][col]),
                    .bf16_out       (),  // Not used in this connection
                    .valid_out      (valid_grid[row][col])
                );
                
                // Store to grid for next PE
                assign int8_a_grid[row][col] = pe_int8_a;
                assign bf16_a_grid[row][col] = pe_bf16_a;
                
            end
        end
    endgenerate
    
    //==========================================================================
    // Output Extraction (Bottom Row)
    //==========================================================================
    
    // Output from bottom-right corner (or collect from entire bottom row)
    assign result_out = result_grid[ARRAY_SIZE-1][ARRAY_SIZE-1];
    assign result_valid = valid_grid[ARRAY_SIZE-1][ARRAY_SIZE-1];

endmodule
