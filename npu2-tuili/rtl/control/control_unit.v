//******************************************************************************
// Control Unit
// Description: Instruction decoder, scheduler, and array controller
// Features:
//   - 256-bit instruction decoding
//   - Multi-array scheduling (4-way)
//   - Precision mode control
//   - Performance counters
//******************************************************************************

module control_unit #(
    parameter NUM_ARRAYS = 4,
    parameter INSTR_WIDTH = 256
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Instruction Input
    input  wire [INSTR_WIDTH-1:0]       instruction,
    input  wire                         instr_valid,
    output reg                          instr_ready,
    
    // Array Control
    output reg  [NUM_ARRAYS-1:0]        array_start,
    input  wire [NUM_ARRAYS-1:0]        array_done,
    output wire [NUM_ARRAYS-1:0]        array_busy,
    output reg                          precision_mode,
    
    // SFU Control
    output reg                          sfu_softmax_start,
    output reg                          sfu_layernorm_start,
    output reg                          sfu_gelu_start,
    input  wire                         sfu_done,
    
    // Performance Counters
    output reg  [31:0]                  perf_cycles,
    output reg  [31:0]                  perf_ops
);

    //==========================================================================
    // Instruction Format Decoding
    //==========================================================================
    // Instruction[255:240] = Opcode (16-bit)
    // Instruction[239:224] = Flags (16-bit)
    // Instruction[223:0]   = Operands (224-bit)
    
    wire [15:0] opcode = instruction[255:240];
    wire [15:0] flags  = instruction[239:224];
    wire [223:0] operands = instruction[223:0];
    
    // Opcode definitions
    localparam OP_NOP           = 16'h0000;
    localparam OP_GEMM          = 16'h0010;
    localparam OP_GEMM_ACC      = 16'h0011;
    localparam OP_SOFTMAX       = 16'h0020;
    localparam OP_LAYERNORM     = 16'h0021;
    localparam OP_GELU          = 16'h0022;
    localparam OP_ADD           = 16'h0030;
    localparam OP_MUL           = 16'h0031;
    localparam OP_SYNC          = 16'h00FF;
    localparam OP_CONFIG_PREC   = 16'h0100;
    
    // Flag fields
    wire        flag_accumulate = flags[15];
    wire [2:0]  flag_array_id   = flags[12:10];
    wire [1:0]  flag_priority   = flags[9:8];
    wire        flag_precision  = flags[0];  // 0=INT8, 1=BF16
    
    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE         = 3'b000;
    localparam DECODE       = 3'b001;
    localparam ISSUE        = 3'b010;
    localparam EXECUTE      = 3'b011;
    localparam WAIT_DONE    = 3'b100;
    localparam SYNC_WAIT    = 3'b101;
    
    reg [2:0]   state;
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [15:0]              current_opcode;
    reg [15:0]              current_flags;
    reg [NUM_ARRAYS-1:0]    array_busy_reg;
    reg [NUM_ARRAYS-1:0]    array_allocated;
    reg [7:0]               wait_counter;
    
    assign array_busy = array_busy_reg;
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            instr_ready <= 1'b1;
            array_start <= {NUM_ARRAYS{1'b0}};
            array_busy_reg <= {NUM_ARRAYS{1'b0}};
            array_allocated <= {NUM_ARRAYS{1'b0}};
            precision_mode <= 1'b0;
            sfu_softmax_start <= 1'b0;
            sfu_layernorm_start <= 1'b0;
            sfu_gelu_start <= 1'b0;
            current_opcode <= 16'h0;
            current_flags <= 16'h0;
            wait_counter <= 8'd0;
        end else begin
            // Clear start signals after 1 cycle
            array_start <= {NUM_ARRAYS{1'b0}};
            sfu_softmax_start <= 1'b0;
            sfu_layernorm_start <= 1'b0;
            sfu_gelu_start <= 1'b0;
            
            case (state)
                IDLE: begin
                    instr_ready <= 1'b1;
                    if (instr_valid && instr_ready) begin
                        state <= DECODE;
                        instr_ready <= 1'b0;
                        current_opcode <= opcode;
                        current_flags <= flags;
                    end
                end
                
                DECODE: begin
                    // Decode and check resource availability
                    state <= ISSUE;
                end
                
                ISSUE: begin
                    case (current_opcode)
                        OP_GEMM, OP_GEMM_ACC: begin
                            // Check if target array is available
                            if (flag_array_id < NUM_ARRAYS && !array_busy_reg[flag_array_id]) begin
                                array_start[flag_array_id] <= 1'b1;
                                array_busy_reg[flag_array_id] <= 1'b1;
                                precision_mode <= flag_precision;
                                state <= EXECUTE;
                            end else begin
                                // Wait for array to become available
                                state <= WAIT_DONE;
                            end
                        end
                        
                        OP_SOFTMAX: begin
                            sfu_softmax_start <= 1'b1;
                            precision_mode <= flag_precision;
                            state <= EXECUTE;
                        end
                        
                        OP_LAYERNORM: begin
                            sfu_layernorm_start <= 1'b1;
                            precision_mode <= flag_precision;
                            state <= EXECUTE;
                        end
                        
                        OP_GELU: begin
                            sfu_gelu_start <= 1'b1;
                            precision_mode <= flag_precision;
                            state <= EXECUTE;
                        end
                        
                        OP_SYNC: begin
                            // Wait for all arrays to complete
                            if (array_busy_reg == {NUM_ARRAYS{1'b0}}) begin
                                state <= IDLE;
                            end else begin
                                state <= SYNC_WAIT;
                            end
                        end
                        
                        OP_CONFIG_PREC: begin
                            precision_mode <= flag_precision;
                            state <= IDLE;
                        end
                        
                        OP_NOP: begin
                            state <= IDLE;
                        end
                        
                        default: begin
                            // Unknown opcode, skip
                            state <= IDLE;
                        end
                    endcase
                end
                
                EXECUTE: begin
                    state <= WAIT_DONE;
                end
                
                WAIT_DONE: begin
                    // Wait for operation to complete
                    case (current_opcode)
                        OP_GEMM, OP_GEMM_ACC: begin
                            if (array_done[flag_array_id]) begin
                                array_busy_reg[flag_array_id] <= 1'b0;
                                state <= IDLE;
                            end
                        end
                        
                        OP_SOFTMAX, OP_LAYERNORM, OP_GELU: begin
                            if (sfu_done) begin
                                state <= IDLE;
                            end
                        end
                        
                        default: state <= IDLE;
                    endcase
                end
                
                SYNC_WAIT: begin
                    // Wait for all arrays
                    if (array_busy_reg == {NUM_ARRAYS{1'b0}}) begin
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    //==========================================================================
    // Array Done Processing
    //==========================================================================
    
    genvar i;
    generate
        for (i = 0; i < NUM_ARRAYS; i = i + 1) begin : gen_array_done
            always @(posedge clk) begin
                if (!rst_n) begin
                    // Reset handled above
                end else if (array_done[i]) begin
                    array_busy_reg[i] <= 1'b0;
                end
            end
        end
    endgenerate
    
    //==========================================================================
    // Performance Counters
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            perf_cycles <= 32'd0;
            perf_ops <= 32'd0;
        end else begin
            // Increment cycle counter
            perf_cycles <= perf_cycles + 1'b1;
            
            // Count operations (simplified)
            if (state == EXECUTE) begin
                case (current_opcode)
                    OP_GEMM, OP_GEMM_ACC: begin
                        // 96x96 array = 9216 MACs per cycle
                        perf_ops <= perf_ops + 32'd18432;  // 2 ops per MAC
                    end
                    default: perf_ops <= perf_ops;
                endcase
            end
        end
    end

endmodule
