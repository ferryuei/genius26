//============================================================================
// Flow Control Module - 流量控制 (IEEE 802.3x PAUSE & 802.1Qbb PFC)
// 功能: PAUSE frame generation/reception, PFC per-priority control
//============================================================================
`timescale 1ns/1ps

module pause_frame_ctrl
    import switch_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Port status
    input  logic [NUM_PORTS-1:0]      port_rx_valid,
    input  logic [NUM_PORTS-1:0]      port_tx_ready,
    
    // PAUSE frame generation
    input  logic [NUM_PORTS-1:0]      pause_req,
    input  logic [15:0]               pause_quanta [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      pause_sent,
    
    // PAUSE frame reception
    input  logic [NUM_PORTS-1:0]      pause_rx,
    input  logic [15:0]               pause_rx_quanta [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      port_paused,
    
    // PFC (Priority Flow Control - 802.1Qbb)
    input  logic [NUM_PORTS-1:0]      pfc_req,
    input  logic [7:0]                pfc_class_enable [NUM_PORTS-1:0],
    input  logic [15:0]               pfc_quanta [NUM_PORTS-1:0][7:0],
    output logic [NUM_PORTS-1:0]      pfc_sent,
    
    // Queue status
    input  logic [15:0]               queue_depth [NUM_PORTS-1:0][7:0],
    output logic [NUM_PORTS-1:0]      queue_xoff [7:0],
    
    // Configuration (per-system, not per-port)
    input  logic [15:0]               xoff_threshold,
    input  logic [15:0]               xon_threshold,
    input  logic [NUM_PORTS-1:0]      fc_enable,
    input  logic [NUM_PORTS-1:0]      pfc_enable,
    
    // Statistics
    output logic [31:0]               stat_pause_tx [NUM_PORTS-1:0],
    output logic [31:0]               stat_pause_rx [NUM_PORTS-1:0],
    output logic [31:0]               stat_pfc_tx [NUM_PORTS-1:0]
);

    //------------------------------------------------------------------------
    // PAUSE timer per port (counts down in 512 bit-times)
    //------------------------------------------------------------------------
    logic [15:0] pause_timer [NUM_PORTS-1:0];
    
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_pause_timer
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pause_timer[p] <= '0;
                    port_paused[p] <= 1'b0;
                end else begin
                    // Receive PAUSE frame
                    if (pause_rx[p] && fc_enable[p]) begin
                        pause_timer[p] <= pause_rx_quanta[p];
                        port_paused[p] <= (pause_rx_quanta[p] > 0);
                    end
                    // Countdown
                    else if (pause_timer[p] > 0) begin
                        pause_timer[p] <= pause_timer[p] - 1;
                        port_paused[p] <= (pause_timer[p] > 1);
                    end else begin
                        port_paused[p] <= 1'b0;
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // PAUSE frame transmission
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_pause_tx
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pause_sent[p] <= 1'b0;
                    stat_pause_tx[p] <= '0;
                end else begin
                    pause_sent[p] <= 1'b0;
                    
                    if (pause_req[p] && fc_enable[p]) begin
                        pause_sent[p] <= 1'b1;
                        stat_pause_tx[p] <= stat_pause_tx[p] + 1;
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // PAUSE frame reception statistics
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_pause_rx_stat
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    stat_pause_rx[p] <= '0;
                end else begin
                    if (pause_rx[p] && fc_enable[p]) begin
                        stat_pause_rx[p] <= stat_pause_rx[p] + 1;
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // PFC (Priority Flow Control) per-priority XOFF/XON
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_pfc_port
            for (genvar q = 0; q < 8; q++) begin : gen_pfc_queue
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        queue_xoff[q][p] <= 1'b0;
                    end else begin
                        if (pfc_enable[p]) begin
                            // XOFF when queue depth exceeds threshold
                            if (queue_depth[p][q] >= xoff_threshold) begin
                                queue_xoff[q][p] <= 1'b1;
                            end
                            // XON when queue depth below threshold
                            else if (queue_depth[p][q] <= xon_threshold) begin
                                queue_xoff[q][p] <= 1'b0;
                            end
                        end else begin
                            queue_xoff[q][p] <= 1'b0;
                        end
                    end
                end
            end
        end
    endgenerate
    
    //------------------------------------------------------------------------
    // PFC frame transmission
    //------------------------------------------------------------------------
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_pfc_tx
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pfc_sent[p] <= 1'b0;
                    stat_pfc_tx[p] <= '0;
                end else begin
                    pfc_sent[p] <= 1'b0;
                    
                    if (pfc_req[p] && pfc_enable[p]) begin
                        pfc_sent[p] <= 1'b1;
                        stat_pfc_tx[p] <= stat_pfc_tx[p] + 1;
                    end
                end
            end
        end
    endgenerate

endmodule
