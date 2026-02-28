//******************************************************************************
// Inference Dataflow Controller
// Description: Orchestrates data movement for neural network inference
// Features:
//   - Layer-by-layer execution management
//   - Ping-pong buffer management for activations
//   - Automatic weight/activation loading
//   - Multi-array task distribution
//   - Synchronization between compute and data transfer
//******************************************************************************

module inference_controller #(
    parameter NUM_ARRAYS = 4,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter M20K_ADDR_WIDTH = 18
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // High-level Control
    input  wire                         start_inference,
    output reg                          inference_done,
    input  wire [7:0]                   num_layers,
    
    // Instruction Interface (from control_unit)
    input  wire [255:0]                 instruction,
    input  wire                         instr_valid,
    output reg                          instr_ready,
    
    // DMA Control
    output reg  [ADDR_WIDTH-1:0]        dma_src_addr,
    output reg  [ADDR_WIDTH-1:0]        dma_dst_addr,
    output reg  [31:0]                  dma_length,
    output reg                          dma_start,
    output reg                          dma_write_mode,
    input  wire                         dma_done,
    
    // DMA-to-M20K Bridge Control
    output reg  [1:0]                   bridge_target_buffer,
    output reg  [M20K_ADDR_WIDTH-1:0]   bridge_base_addr,
    output reg  [15:0]                  bridge_transfer_count,
    output reg                          bridge_start,
    input  wire                         bridge_done,
    
    // Activation Feeder Control (per array)
    output reg  [NUM_ARRAYS-1:0]        feeder_start,
    input  wire [NUM_ARRAYS-1:0]        feeder_done,
    output reg  [M20K_ADDR_WIDTH-1:0]   feeder_base_addr,
    
    // Systolic Array Control
    output reg  [NUM_ARRAYS-1:0]        array_start,
    input  wire [NUM_ARRAYS-1:0]        array_done,
    
    // Result Collector Control (per array)
    output reg  [NUM_ARRAYS-1:0]        collector_start,
    input  wire [NUM_ARRAYS-1:0]        collector_done,
    
    // Status and Debug
    output wire [7:0]                   current_layer,
    output wire [3:0]                   current_state
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE             = 4'b0000;
    localparam LOAD_WEIGHTS     = 4'b0001;
    localparam WAIT_WEIGHTS     = 4'b0010;
    localparam LOAD_ACTIVATION  = 4'b0011;
    localparam WAIT_ACTIVATION  = 4'b0100;
    localparam START_COMPUTE    = 4'b0101;
    localparam COMPUTE          = 4'b0110;
    localparam COLLECT_RESULTS  = 4'b0111;
    localparam WRITEBACK        = 4'b1000;
    localparam WAIT_WRITEBACK   = 4'b1001;
    localparam NEXT_LAYER       = 4'b1010;
    localparam DONE             = 4'b1011;
    
    reg [3:0]   state;
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [7:0]               layer_count;
    reg [15:0]              opcode;
    reg [15:0]              flags;
    reg [2:0]               target_array;
    
    // Ping-pong buffer management
    reg                     ping_pong;          // 0=ping, 1=pong
    reg [M20K_ADDR_WIDTH-1:0] weight_base_addr;
    reg [M20K_ADDR_WIDTH-1:0] activation_base_addr;
    reg [M20K_ADDR_WIDTH-1:0] result_base_addr;
    
    // DDR address tracking
    reg [ADDR_WIDTH-1:0]    weight_ddr_addr;
    reg [ADDR_WIDTH-1:0]    activation_ddr_addr;
    reg [ADDR_WIDTH-1:0]    result_ddr_addr;
    
    // Transfer sizes
    reg [15:0]              weight_size;
    reg [15:0]              activation_size;
    reg [15:0]              result_size;
    
    assign current_layer = layer_count;
    assign current_state = state;
    
    //==========================================================================
    // Instruction Decoding
    //==========================================================================
    
    wire [15:0] inst_opcode = instruction[255:240];
    wire [15:0] inst_flags = instruction[239:224];
    wire [31:0] inst_src_addr = instruction[223:192];
    wire [31:0] inst_dst_addr = instruction[191:160];
    wire [15:0] inst_size = instruction[159:144];
    wire [2:0]  inst_array_id = inst_flags[12:10];
    
    //==========================================================================
    // Main Control FSM
    //==========================================================================
    
    integer i;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            inference_done <= 1'b0;
            layer_count <= 8'd0;
            ping_pong <= 1'b0;
            
            dma_start <= 1'b0;
            dma_write_mode <= 1'b0;
            bridge_start <= 1'b0;
            feeder_start <= {NUM_ARRAYS{1'b0}};
            array_start <= {NUM_ARRAYS{1'b0}};
            collector_start <= {NUM_ARRAYS{1'b0}};
            instr_ready <= 1'b1;
            
            weight_ddr_addr <= 32'h0;
            activation_ddr_addr <= 32'h1000;
            result_ddr_addr <= 32'h2000;
            
            weight_size <= 16'd64;
            activation_size <= 16'd64;
            result_size <= 16'd64;
        end else begin
            // Default: clear one-shot signals
            dma_start <= 1'b0;
            bridge_start <= 1'b0;
            feeder_start <= {NUM_ARRAYS{1'b0}};
            array_start <= {NUM_ARRAYS{1'b0}};
            collector_start <= {NUM_ARRAYS{1'b0}};
            
            case (state)
                IDLE: begin
                    inference_done <= 1'b0;
                    layer_count <= 8'd0;
                    instr_ready <= 1'b1;
                    
                    if (start_inference || (instr_valid && instr_ready)) begin
                        if (instr_valid) begin
                            // Parse instruction for layer parameters
                            opcode <= inst_opcode;
                            flags <= inst_flags;
                            target_array <= inst_array_id;
                            weight_ddr_addr <= inst_src_addr;
                            activation_ddr_addr <= inst_src_addr + 32'h1000;
                            result_ddr_addr <= inst_dst_addr;
                            weight_size <= inst_size;
                            activation_size <= inst_size;
                        end
                        instr_ready <= 1'b0;
                        state <= LOAD_WEIGHTS;
                    end
                end
                
                LOAD_WEIGHTS: begin
                    // Start DMA transfer: DDR → M20K (weights)
                    dma_src_addr <= weight_ddr_addr;
                    dma_length <= {16'd0, weight_size};
                    dma_start <= 1'b1;
                    dma_write_mode <= 1'b0;  // Read from DDR
                    
                    // Configure bridge to write to weight buffer
                    bridge_target_buffer <= target_array[1:0];
                    bridge_base_addr <= 18'h0;  // Weight buffer base
                    bridge_transfer_count <= weight_size / 4;  // Convert bytes to words
                    bridge_start <= 1'b1;
                    
                    state <= WAIT_WEIGHTS;
                end
                
                WAIT_WEIGHTS: begin
                    if (bridge_done) begin
                        state <= LOAD_ACTIVATION;
                    end
                end
                
                LOAD_ACTIVATION: begin
                    // Start DMA transfer: DDR → M20K (activations)
                    dma_src_addr <= activation_ddr_addr;
                    dma_length <= {16'd0, activation_size};
                    dma_start <= 1'b1;
                    dma_write_mode <= 1'b0;
                    
                    // Use ping-pong buffer for activations
                    bridge_target_buffer <= target_array[1:0];
                    bridge_base_addr <= ping_pong ? 18'h8000 : 18'h4000;
                    bridge_transfer_count <= activation_size / 4;
                    bridge_start <= 1'b1;
                    
                    state <= WAIT_ACTIVATION;
                end
                
                WAIT_ACTIVATION: begin
                    if (bridge_done) begin
                        state <= START_COMPUTE;
                    end
                end
                
                START_COMPUTE: begin
                    // Start activation feeder
                    feeder_start[target_array] <= 1'b1;
                    feeder_base_addr <= ping_pong ? 18'h8000 : 18'h4000;
                    
                    // Start systolic array computation
                    array_start[target_array] <= 1'b1;
                    
                    state <= COMPUTE;
                end
                
                COMPUTE: begin
                    // Wait for computation to complete
                    if (array_done[target_array] && feeder_done[target_array]) begin
                        state <= COLLECT_RESULTS;
                    end
                end
                
                COLLECT_RESULTS: begin
                    // Start result collector
                    collector_start[target_array] <= 1'b1;
                    state <= WRITEBACK;
                end
                
                WRITEBACK: begin
                    // Wait for collector to buffer results
                    if (collector_done[target_array]) begin
                        // Start DMA write-back: M20K → DDR
                        dma_dst_addr <= result_ddr_addr;
                        dma_length <= {16'd0, result_size};
                        dma_start <= 1'b1;
                        dma_write_mode <= 1'b1;  // Write to DDR
                        
                        state <= WAIT_WRITEBACK;
                    end
                end
                
                WAIT_WRITEBACK: begin
                    if (dma_done) begin
                        state <= NEXT_LAYER;
                    end
                end
                
                NEXT_LAYER: begin
                    layer_count <= layer_count + 1'b1;
                    ping_pong <= ~ping_pong;  // Toggle buffer
                    
                    // Update addresses for next layer
                    weight_ddr_addr <= weight_ddr_addr + {16'd0, weight_size};
                    activation_ddr_addr <= result_ddr_addr;  // Output becomes next input
                    result_ddr_addr <= result_ddr_addr + {16'd0, result_size};
                    
                    if (layer_count >= num_layers - 1) begin
                        state <= DONE;
                    end else begin
                        instr_ready <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                DONE: begin
                    inference_done <= 1'b1;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
