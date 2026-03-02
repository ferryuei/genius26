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

    // One-shot guards for load states
    reg                     load_weights_issued;
    reg                     load_activation_issued;
    
    // Counter to hold START_COMPUTE state
    reg [1:0]               start_hold_counter;
    
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
    
    // Debug: Monitor the actual done signals
    always @(posedge clk) begin
        if (rst_n && state == COMPUTE) begin
            $display("  [%0t ns] IC DEBUG: array_done=%b, feeder_done=%b, target_array=%d", 
                     $time/1000.0, array_done, feeder_done, target_array);
            $display("        array_done[0]=%b, feeder_done[0]=%b", 
                     array_done[0], feeder_done[0]);
        end
    end
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            inference_done <= 1'b0;
            layer_count <= 8'd0;
            ping_pong <= 1'b0;
            
            dma_start <= 1'b0;
            dma_write_mode <= 1'b0;
            bridge_start <= 1'b0;
            bridge_transfer_count <= 16'd0;  // Initialize bridge_transfer_count
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

            load_weights_issued <= 1'b0;
            load_activation_issued <= 1'b0;
            start_hold_counter <= 2'd0;
        end else begin
            
            case (state)
                IDLE: begin
                    inference_done <= 1'b0;
                    instr_ready <= 1'b1;
                    
                    // Only clear signals when NOT transitioning out of IDLE
                    if (!(start_inference && instr_valid && instr_ready)) begin
                        dma_start <= 1'b0;
                        bridge_start <= 1'b0;
                        feeder_start <= {NUM_ARRAYS{1'b0}};
                        array_start <= {NUM_ARRAYS{1'b0}};
                        collector_start <= {NUM_ARRAYS{1'b0}};
                    end
                    
                    // Debug: print when entering IDLE state
                    if (state != IDLE) begin
                        $display("  [%0t ns] IC: Entering IDLE state, feeder_start=%b, array_start=%b", 
                                 $time/1000.0, feeder_start, array_start);
                    end
                    
                    // Only process instruction when start_inference is asserted
                    if (start_inference && instr_valid && instr_ready) begin
                        // Parse instruction for layer parameters
                        opcode <= inst_opcode;
                        flags <= inst_flags;
                        target_array <= inst_array_id;
                        weight_ddr_addr <= inst_src_addr;
                        activation_ddr_addr <= inst_src_addr + 32'h1000;
                        result_ddr_addr <= inst_dst_addr;
                        weight_size <= inst_size;
                        activation_size <= inst_size;
                        instr_ready <= 1'b0;
                        state <= LOAD_WEIGHTS;
                        load_weights_issued <= 1'b0;
                        load_activation_issued <= 1'b0;
                        $display("  [%0t ns] IC: Processing instruction, setting state to LOAD_WEIGHTS", $time/1000.0);
                    end
                end
                
                LOAD_WEIGHTS: begin
                    // Clear collector signal only
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Don't clear feeder_start/array_start - they will be set in START_COMPUTE
                    
                    if (!load_weights_issued) begin
                        // Start DMA transfer: DDR → M20K (weights)
                        dma_src_addr <= weight_ddr_addr;
                        dma_length <= {16'd0, weight_size};
                        dma_start <= 1'b1;
                        dma_write_mode <= 1'b0;  // Read from DDR
                        
                        // Configure bridge to write to weight buffer
                        bridge_target_buffer <= target_array[1:0];
                        bridge_base_addr <= 18'h0;  // Weight buffer base
                        // Divide by 4: shift right by 2 bits, ensure proper bit width
                        bridge_transfer_count <= {14'd0, weight_size[15:2]};
                        bridge_start <= 1'b1;
                        
                        load_weights_issued <= 1'b1;
                    end else begin
                        dma_start <= 1'b0;
                        bridge_start <= 1'b0;
                    end
                    
                    // Immediately transition to WAIT_WEIGHTS to avoid re-triggering
                    state <= WAIT_WEIGHTS;
                end
                
                WAIT_WEIGHTS: begin
                    // Clear DMA/Bridge signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Don't clear feeder_start and array_start - they will be set in START_COMPUTE
                    
                    // DEBUG: Print bridge_done status
                    if ($time > 1390000 && $time < 1400000) begin  // Around 1391ns when bridge sends DONE
                        $display("  [%0t ns] IC WAIT_WEIGHTS: bridge_done=%b", $time/1000.0, bridge_done);
                    end
                    
                    if (bridge_done) begin
                        $display("  [%0t ns] IC: bridge_done detected, transitioning to LOAD_ACTIVATION", $time/1000.0);
                        state <= LOAD_ACTIVATION;
                        load_activation_issued <= 1'b0;
                    end
                end
                
                LOAD_ACTIVATION: begin
                    // Clear collector signal only
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Don't clear feeder_start/array_start - they will be set in START_COMPUTE
                    
                    if (!load_activation_issued) begin
                        // Start DMA transfer: DDR → M20K (activations)
                        dma_src_addr <= activation_ddr_addr;
                        dma_length <= {16'd0, activation_size};
                        dma_start <= 1'b1;
                        dma_write_mode <= 1'b0;
                        
                        // Use ping-pong buffer for activations
                        bridge_target_buffer <= target_array[1:0];
                        bridge_base_addr <= ping_pong ? 18'h8000 : 18'h4000;
                        // Divide by 4: shift right by 2 bits, ensure proper bit width
                        bridge_transfer_count <= {14'd0, activation_size[15:2]};
                        bridge_start <= 1'b1;
                        
                        load_activation_issued <= 1'b1;
                        $display("  [%0t ns] IC LOAD_ACTIVATION: Started activation loading", $time/1000.0);
                    end else begin
                        dma_start <= 1'b0;
                        bridge_start <= 1'b0;
                        
                        // FIXED: Transition to WAIT_ACTIVATION when bridge is done
                        if (bridge_done) begin
                            $display("  [%0t ns] IC LOAD_ACTIVATION: bridge_done detected, transitioning to WAIT_ACTIVATION", $time/1000.0);
                            state <= WAIT_ACTIVATION;
                            load_activation_issued <= 1'b0;  // Reset for next layer
                        end
                    end
                end
                
                WAIT_ACTIVATION: begin
                    // Clear DMA/Bridge signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Clear feeder_start and array_start to prepare for rising edge
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    
                    // FIX: bridge_done was already consumed in LOAD_ACTIVATION state
                    // (bridge_done pulses for exactly 1 cycle in DONE_STATE, then deasserts).
                    // This state's sole purpose is to clear start signals for one cycle
                    // so START_COMPUTE can create a clean rising edge; no need to re-check bridge_done.
                    $display("  [%0t ns] IC WAIT_ACTIVATION: signals cleared, transitioning to START_COMPUTE", $time/1000.0);
                    state <= START_COMPUTE;
                end
                
                START_COMPUTE: begin
                    // Clear other one-shot signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Set start signals immediately on entering START_COMPUTE
                    // This creates 0→1 edge from WAIT_ACTIVATION state
                    feeder_start[target_array] <= 1'b1;
                    feeder_base_addr <= ping_pong ? 18'h8000 : 18'h4000;
                    array_start[target_array] <= 1'b1;
                    
                    // Hold in START_COMPUTE for 2 cycles total
                    // Cycle 0: set signals (create edge)
                    // Cycle 1: hold signals (let modules sample)
                    // Then transition to COMPUTE
                    if (start_hold_counter < 2'd1) begin
                        start_hold_counter <= start_hold_counter + 1'b1;
                    end else begin
                        state <= COMPUTE;
                        start_hold_counter <= 2'd0;
                    end
                end
                
                COMPUTE: begin
                    // Clear DMA/Bridge signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Keep start signals high for first cycle, then clear
                    // This ensures edge detection modules sample the signal correctly
                    if (start_hold_counter == 2'd0) begin
                        // First cycle: keep signals high
                        start_hold_counter <= 2'd1;
                    end else begin
                        // After first cycle: clear the signals
                        feeder_start <= {NUM_ARRAYS{1'b0}};
                        array_start <= {NUM_ARRAYS{1'b0}};
                        start_hold_counter <= 2'd0;  // Reset for next use
                    end
                    
                    // Wait for computation to complete
                    // Debug: always show the status in COMPUTE state
                    if (state == COMPUTE) begin
                        $display("  [%0t ns] IC DEBUG: target_array=%d, array_done[0]=%b, feeder_done[0]=%b", 
                                 $time/1000.0, target_array, array_done[0], feeder_done[0]);
                    end
                    
                    if (array_done[target_array] || feeder_done[target_array]) begin
                        $display("  [%0t ns] IC: One module completed, transitioning to COLLECT_RESULTS", $time/1000.0);
                        $display("        array_done[%d]=%b, feeder_done[%d]=%b", 
                                 target_array, array_done[target_array], target_array, feeder_done[target_array]);
                        state <= COLLECT_RESULTS;
                    end
                end
                
                COLLECT_RESULTS: begin
                    // Clear other one-shot signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Start result collector
                    collector_start[target_array] <= 1'b1;
                    
                    // Wait for result collector to finish collecting
                    if (collector_done[target_array]) begin
                        $display("  [%0t ns] IC COLLECT_RESULTS: Collector done, moving to WRITEBACK", $time/1000.0);
                        state <= WRITEBACK;
                    end
                end
                
                WRITEBACK: begin
                    // Clear other one-shot signals
                    bridge_start <= 1'b0;
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    // Wait for DMA to be idle (done signal low) before starting write-back
                    // This ensures previous DMA read operations have completed
                    if (!dma_done && !dma_start) begin
                        // DMA is idle, safe to start write-back
                        dma_dst_addr <= result_ddr_addr;
                        dma_length <= {16'd0, result_size};
                        dma_start <= 1'b1;
                        dma_write_mode <= 1'b1;  // Write to DDR
                        
                        $display("  [%0t ns] IC WRITEBACK: Starting DMA write-back, addr=0x%h, length=%d", 
                                 $time/1000.0, result_ddr_addr, result_size);
                        
                        state <= WAIT_WRITEBACK;
                    end else begin
                        // DMA is still busy, wait
                        dma_start <= 1'b0;
                        $display("  [%0t ns] IC WRITEBACK: Waiting for DMA to be idle (done=%b)", 
                                 $time/1000.0, dma_done);
                    end
                end
                
                WAIT_WRITEBACK: begin
                    // Clear all one-shot signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    if (dma_done) begin
                        state <= NEXT_LAYER;
                    end
                end
                
                NEXT_LAYER: begin
                    // Clear all one-shot signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    layer_count <= layer_count + 1'b1;
                    ping_pong <= ~ping_pong;  // Toggle buffer
                    
                    // Update addresses for next layer
                    weight_ddr_addr <= weight_ddr_addr + {16'd0, weight_size};
                    activation_ddr_addr <= result_ddr_addr;  // Output becomes next input
                    result_ddr_addr <= result_ddr_addr + {16'd0, result_size};
                    
                    if (layer_count >= num_layers - 1) begin
                        state <= DONE;
                    end else begin
                        // Bypass IDLE for multi-layer: addresses already advanced
                        // above; no need to re-fetch the instruction from comm_interface.
                        // (instr_valid was already consumed and cleared for layer 1.)
                        load_weights_issued   <= 1'b0;
                        load_activation_issued <= 1'b0;
                        state <= LOAD_WEIGHTS;
                    end
                end
                
                DONE: begin
                    // Clear all one-shot signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    inference_done <= 1'b1;
                    layer_count <= 8'd0;  // Reset for next inference run
                    state <= IDLE;
                end
                
                default: begin
                    // Clear all one-shot signals
                    dma_start <= 1'b0;
                    bridge_start <= 1'b0;
                    feeder_start <= {NUM_ARRAYS{1'b0}};
                    array_start <= {NUM_ARRAYS{1'b0}};
                    collector_start <= {NUM_ARRAYS{1'b0}};
                    
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
