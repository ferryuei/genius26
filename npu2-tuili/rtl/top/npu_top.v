//******************************************************************************
// NPU Top Module
// Description: Top-level integration of NPU accelerator for Stratix 10
// Features:
//   - 4x Systolic Arrays (96x96 PEs each)
//   - Variable Precision (INT8/BF16)
//   - M20K memory subsystem
//   - DDR4 interface (4 channels)
//   - High-speed transceiver interface
//******************************************************************************

module npu_top #(
    parameter NUM_ARRAYS        = 4,
    parameter ARRAY_SIZE        = 96,
    parameter DATA_WIDTH        = 32,
    parameter ADDR_WIDTH        = 32,
    parameter M20K_ADDR_WIDTH   = 18,
    parameter DDR_DATA_WIDTH    = 512,
    parameter INSTR_WIDTH       = 256
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // High-Speed Transceiver Interface (Model)
    input  wire [511:0]                 xcvr_rx_data,
    input  wire                         xcvr_rx_valid,
    output wire                         xcvr_rx_ready,
    output wire [511:0]                 xcvr_tx_data,
    output wire                         xcvr_tx_valid,
    input  wire                         xcvr_tx_ready,
    
    // DDR4 Memory Interface (Avalon-MM, to EMIF IP)
    output wire [ADDR_WIDTH-1:0]        ddr_avmm_address,
    output wire                         ddr_avmm_read,
    output wire                         ddr_avmm_write,
    output wire [DDR_DATA_WIDTH-1:0]    ddr_avmm_writedata,
    output wire [DDR_DATA_WIDTH/8-1:0]  ddr_avmm_byteenable,
    input  wire [DDR_DATA_WIDTH-1:0]    ddr_avmm_readdata,
    input  wire                         ddr_avmm_readdatavalid,
    input  wire                         ddr_avmm_waitrequest,
    output wire [7:0]                   ddr_avmm_burstcount,
    
    // Debug and Status
    output wire [31:0]                  debug_status,
    output wire [NUM_ARRAYS-1:0]        array_busy,
    output wire [31:0]                  perf_counter_cycles,
    output wire [31:0]                  perf_counter_ops
);

    //==========================================================================
    // Internal Signals
    //==========================================================================
    
    // DMA Engine Signals
    wire [ADDR_WIDTH-1:0]       dma_src_addr;
    wire [ADDR_WIDTH-1:0]       dma_dst_addr;
    wire [31:0]                 dma_length;
    wire                        dma_start;
    wire                        dma_done;
    wire [DATA_WIDTH-1:0]       dma_rd_data;
    wire                        dma_rd_valid;
    wire                        dma_rd_ready;
    
    // Control Unit Signals
    wire [INSTR_WIDTH-1:0]      instruction;
    wire                        instr_valid;
    wire                        instr_ready;
    wire [NUM_ARRAYS-1:0]       array_start;
    wire [NUM_ARRAYS-1:0]       array_done;
    wire                        precision_mode; // 0=INT8, 1=BF16
    
    // M20K Memory Interface (Weight Buffer)
    wire [M20K_ADDR_WIDTH-1:0]  m20k_waddr [NUM_ARRAYS-1:0];
    wire [DATA_WIDTH-1:0]       m20k_wdata [NUM_ARRAYS-1:0];
    wire                        m20k_we    [NUM_ARRAYS-1:0];
    wire [M20K_ADDR_WIDTH-1:0]  m20k_raddr [NUM_ARRAYS-1:0];
    wire [DATA_WIDTH-1:0]       m20k_rdata [NUM_ARRAYS-1:0];
    wire                        m20k_re    [NUM_ARRAYS-1:0];
    
    // Systolic Array Data Interface
    wire [7:0]                  pe_int8_a  [NUM_ARRAYS-1:0];
    wire [7:0]                  pe_int8_w  [NUM_ARRAYS-1:0];
    wire [15:0]                 pe_bf16_a  [NUM_ARRAYS-1:0];
    wire [15:0]                 pe_bf16_w  [NUM_ARRAYS-1:0];
    wire [DATA_WIDTH-1:0]       pe_result  [NUM_ARRAYS-1:0];
    wire                        pe_valid   [NUM_ARRAYS-1:0];
    
    // Special Function Unit Interface
    wire                        sfu_softmax_start;
    wire                        sfu_layernorm_start;
    wire                        sfu_gelu_start;
    wire                        sfu_done;
    wire [DATA_WIDTH-1:0]       sfu_data_in;
    wire [DATA_WIDTH-1:0]       sfu_data_out;
    wire                        sfu_data_valid;
    
    //==========================================================================
    // Submodule Instantiation
    //==========================================================================
    
    // Communication Interface (Transceiver Model)
    comm_interface u_comm_interface (
        .clk                (clk),
        .rst_n              (rst_n),
        // Transceiver
        .xcvr_rx_data       (xcvr_rx_data),
        .xcvr_rx_valid      (xcvr_rx_valid),
        .xcvr_rx_ready      (xcvr_rx_ready),
        .xcvr_tx_data       (xcvr_tx_data),
        .xcvr_tx_valid      (xcvr_tx_valid),
        .xcvr_tx_ready      (xcvr_tx_ready),
        // Internal DMA Interface
        .dma_src_addr       (dma_src_addr),
        .dma_dst_addr       (dma_dst_addr),
        .dma_length         (dma_length),
        .dma_start          (dma_start),
        .dma_done           (dma_done),
        // Instruction Stream
        .instruction        (instruction),
        .instr_valid        (instr_valid),
        .instr_ready        (instr_ready)
    );
    
    // DMA Engine
    dma_engine #(
        .ADDR_WIDTH         (ADDR_WIDTH),
        .DATA_WIDTH         (DATA_WIDTH),
        .DDR_DATA_WIDTH     (DDR_DATA_WIDTH)
    ) u_dma_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        // Control Interface
        .src_addr           (dma_src_addr),
        .dst_addr           (dma_dst_addr),
        .length             (dma_length),
        .start              (dma_start),
        .done               (dma_done),
        // DDR4 Avalon-MM Master
        .avmm_address       (ddr_avmm_address),
        .avmm_read          (ddr_avmm_read),
        .avmm_write         (ddr_avmm_write),
        .avmm_writedata     (ddr_avmm_writedata),
        .avmm_byteenable    (ddr_avmm_byteenable),
        .avmm_readdata      (ddr_avmm_readdata),
        .avmm_readdatavalid (ddr_avmm_readdatavalid),
        .avmm_waitrequest   (ddr_avmm_waitrequest),
        .avmm_burstcount    (ddr_avmm_burstcount),
        // Internal Data Stream
        .stream_data        (dma_rd_data),
        .stream_valid       (dma_rd_valid),
        .stream_ready       (dma_rd_ready)
    );
    
    // Control Unit (Instruction Decoder & Scheduler)
    control_unit #(
        .NUM_ARRAYS         (NUM_ARRAYS),
        .INSTR_WIDTH        (INSTR_WIDTH)
    ) u_control_unit (
        .clk                (clk),
        .rst_n              (rst_n),
        // Instruction Input
        .instruction        (instruction),
        .instr_valid        (instr_valid),
        .instr_ready        (instr_ready),
        // Array Control
        .array_start        (array_start),
        .array_done         (array_done),
        .array_busy         (array_busy),
        .precision_mode     (precision_mode),
        // SFU Control
        .sfu_softmax_start  (sfu_softmax_start),
        .sfu_layernorm_start(sfu_layernorm_start),
        .sfu_gelu_start     (sfu_gelu_start),
        .sfu_done           (sfu_done),
        // Performance Counters
        .perf_cycles        (perf_counter_cycles),
        .perf_ops           (perf_counter_ops)
    );
    
    // M20K Memory Subsystem (Weight & Activation Buffers)
    genvar i;
    generate
        for (i = 0; i < NUM_ARRAYS; i = i + 1) begin : gen_m20k_buffers
            m20k_buffer #(
                .ADDR_WIDTH     (M20K_ADDR_WIDTH),
                .DATA_WIDTH     (DATA_WIDTH),
                .DEPTH          (1 << M20K_ADDR_WIDTH)
            ) u_m20k_buffer (
                .clk            (clk),
                .rst_n          (rst_n),
                // Write Port
                .waddr          (m20k_waddr[i]),
                .wdata          (m20k_wdata[i]),
                .we             (m20k_we[i]),
                // Read Port
                .raddr          (m20k_raddr[i]),
                .rdata          (m20k_rdata[i]),
                .re             (m20k_re[i])
            );
        end
    endgenerate
    
    // Systolic Array Cluster (4 Arrays)
    generate
        for (i = 0; i < NUM_ARRAYS; i = i + 1) begin : gen_systolic_arrays
            systolic_array #(
                .ARRAY_SIZE     (ARRAY_SIZE),
                .DATA_WIDTH     (DATA_WIDTH)
            ) u_systolic_array (
                .clk            (clk),
                .rst_n          (rst_n),
                // Control
                .start          (array_start[i]),
                .done           (array_done[i]),
                .precision_mode (precision_mode),
                // Weight Memory
                .weight_addr    (m20k_raddr[i]),
                .weight_data    (m20k_rdata[i]),
                .weight_re      (m20k_re[i]),
                // Input Data
                .int8_a_in      (pe_int8_a[i]),
                .int8_w_in      (pe_int8_w[i]),
                .bf16_a_in      (pe_bf16_a[i]),
                .bf16_w_in      (pe_bf16_w[i]),
                // Output Data
                .result_out     (pe_result[i]),
                .result_valid   (pe_valid[i])
            );
        end
    endgenerate
    
    // Special Function Unit (Softmax, LayerNorm, GELU)
    sfu_unit #(
        .DATA_WIDTH         (DATA_WIDTH)
    ) u_sfu_unit (
        .clk                (clk),
        .rst_n              (rst_n),
        // Control
        .softmax_start      (sfu_softmax_start),
        .layernorm_start    (sfu_layernorm_start),
        .gelu_start         (sfu_gelu_start),
        .done               (sfu_done),
        .precision_mode     (precision_mode),
        // Data Interface
        .data_in            (sfu_data_in),
        .data_out           (sfu_data_out),
        .data_valid         (sfu_data_valid)
    );
    
    // Debug Status
    assign debug_status = {
        4'b0,
        array_busy,
        8'b0,
        precision_mode,
        dma_start,
        dma_done,
        instr_valid,
        instr_ready,
        sfu_done,
        8'b0
    };

endmodule
