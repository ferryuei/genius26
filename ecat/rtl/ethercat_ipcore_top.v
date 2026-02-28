// ============================================================================
// EtherCAT IP Core - Top Level Module
// Complete Integration of P0-P2 Modules
// ============================================================================

`include "ecat_pkg.vh"

module ethercat_ipcore_top #(
    // ========================================================================
    // Configuration Parameters
    // ========================================================================
    parameter FEATURE_VECTOR_SIZE = `FEATURE_VECTOR_SIZE,
    parameter [`FEATURE_VECTOR_SIZE-1:0] FEATURE_VECTOR = {`FEATURE_VECTOR_SIZE{1'b0}},
    
    // PDI Configuration
    parameter PDI_TYPE = "AVALON",
    parameter PDI_DATA_WIDTH = 32,
    parameter PDI_ADDR_WIDTH = 16,
    
    // PHY Configuration
    parameter PHY_COUNT = 2,
    parameter PHY_TYPE = "MII",
    
    // Clock Configuration
    parameter CLK_FREQ_HZ = 50000000,
    parameter ECAT_CLK_FREQ_HZ = 25000000,
    
    // Memory Configuration
    parameter NUM_FMMU = 8,
    parameter NUM_SM = 8,
    parameter DP_RAM_SIZE = 4096,
    
    // Feature Flags
    parameter DC_SUPPORT = 1,
    
    // Vendor/Product Identification
    parameter [31:0] VENDOR_ID = 32'h00000000,
    parameter [31:0] PRODUCT_CODE = 32'h00000000,
    parameter [31:0] REVISION_NUM = 32'h00010000,
    parameter [31:0] SERIAL_NUM = 32'h00000001
)(
    // ========================================================================
    // System Interfaces
    // ========================================================================
    input  wire                         sys_rst_n,
    input  wire                         sys_clk,
    input  wire                         ecat_clk,
    input  wire                         ecat_clk_ddr,
    
    // ========================================================================
    // Process Data Interface (PDI) - Avalon Bus
    // ========================================================================
    input  wire                         pdi_clk,
    input  wire [PDI_ADDR_WIDTH-1:0]    pdi_address,
    input  wire                         pdi_read,
    output wire [PDI_DATA_WIDTH-1:0]    pdi_readdata,
    output wire                         pdi_readdatavalid,
    input  wire                         pdi_write,
    input  wire [PDI_DATA_WIDTH-1:0]    pdi_writedata,
    input  wire [(PDI_DATA_WIDTH/8)-1:0] pdi_byteenable,
    output wire                         pdi_waitrequest,
    output wire                         pdi_irq,
    
    // ========================================================================
    // Ethernet PHY Interfaces
    // ========================================================================
    output wire [PHY_COUNT-1:0]         phy_tx_clk,
    output wire [PHY_COUNT-1:0]         phy_tx_en,
    output wire [PHY_COUNT-1:0]         phy_tx_er,
    output wire [PHY_COUNT*8-1:0]       phy_tx_data,
    
    input  wire [PHY_COUNT-1:0]         phy_rx_clk,
    input  wire [PHY_COUNT-1:0]         phy_rx_dv,
    input  wire [PHY_COUNT-1:0]         phy_rx_er,
    input  wire [PHY_COUNT*8-1:0]       phy_rx_data,
    
    // PHY Management (MDIO)
    output wire                         phy_mdc,
    output wire                         phy_mdio_o,
    output wire                         phy_mdio_oe,
    input  wire                         phy_mdio_i,
    
    output wire [PHY_COUNT-1:0]         phy_reset_n,
    
    // ========================================================================
    // EEPROM Interface (I2C)
    // ========================================================================
    output wire                         eeprom_scl_o,
    output wire                         eeprom_scl_oe,
    input  wire                         eeprom_scl_i,
    output wire                         eeprom_sda_o,
    output wire                         eeprom_sda_oe,
    input  wire                         eeprom_sda_i,
    
    // ========================================================================
    // LED Outputs
    // ========================================================================
    output wire [PHY_COUNT-1:0]         led_link,
    output wire [PHY_COUNT-1:0]         led_act,
    output wire                         led_run,
    output wire                         led_err,
    
    // ========================================================================
    // Distributed Clock (DC) Interface
    // ========================================================================
    input  wire                         dc_latch0_in,
    input  wire                         dc_latch1_in,
    output wire                         dc_sync0_out,
    output wire                         dc_sync1_out
);

    // ========================================================================
    // Internal Signals - Reset Synchronization
    // ========================================================================
    reg [2:0] sys_rst_sync;
    reg [2:0] ecat_rst_sync;
    wire sys_rst_n_sync;
    wire ecat_rst_n_sync;
    
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            sys_rst_sync <= 3'b000;
        else
            sys_rst_sync <= {sys_rst_sync[1:0], 1'b1};
    end
    assign sys_rst_n_sync = sys_rst_sync[2];
    
    always @(posedge ecat_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            ecat_rst_sync <= 3'b000;
        else
            ecat_rst_sync <= {ecat_rst_sync[1:0], 1'b1};
    end
    assign ecat_rst_n_sync = ecat_rst_sync[2];

    // ========================================================================
    // Internal Signals - PHY Interface
    // ========================================================================
    wire [PHY_COUNT-1:0] link_up;
    wire [PHY_COUNT-1:0] link_speed_100;
    wire [PHY_COUNT-1:0] link_duplex;
    
    // RX from PHY (active port selection)
    wire [3:0]  rx_port_id;
    wire        rx_valid;
    wire [7:0]  rx_data;
    wire        rx_sof;
    wire        rx_eof;
    wire        rx_error;
    
    // TX to PHY
    wire [3:0]  tx_port_id;
    wire        tx_valid;
    wire [7:0]  tx_data;
    wire        tx_sof;
    wire        tx_eof;
    wire        tx_ready;

    // ========================================================================
    // Internal Signals - Frame Receiver/Transmitter
    // ========================================================================
    // Frame receiver outputs
    wire [15:0] fr_mem_addr;
    wire [15:0] fr_mem_wdata;
    wire [1:0]  fr_mem_be;
    wire        fr_mem_wr_en;
    wire        fr_mem_rd_en;
    wire [15:0] fr_mem_rdata;
    wire        fr_mem_ready;
    
    // Frame forwarding
    wire        fwd_valid;
    wire [7:0]  fwd_data;
    wire        fwd_sof;
    wire        fwd_eof;
    wire        fwd_modified;
    
    // Statistics
    wire [15:0] rx_frame_count;
    wire [15:0] rx_error_count;
    wire [15:0] rx_crc_error_count;
    wire [15:0] tx_frame_count;
    wire [15:0] tx_error_count;

    // ========================================================================
    // Internal Signals - Register Map
    // ========================================================================
    wire        reg_req;
    wire        reg_wr;
    wire [15:0] reg_addr;
    wire [15:0] reg_wdata;
    wire [1:0]  reg_be;
    wire [15:0] reg_rdata;
    wire        reg_ack;
    
    // AL Control/Status
    wire [4:0]  al_control;
    wire        al_control_changed;
    wire [4:0]  al_status;
    wire [15:0] al_status_code;
    
    // DL Control/Status
    wire        dl_control_fwd_en;
    wire        dl_control_temp_loop;
    wire [15:0] dl_status;
    
    // Port configuration
    wire [3:0]  port_enable;
    wire [3:0]  port_link_status;
    wire [3:0]  port_loop_status;
    
    // Station address
    wire [15:0] station_address;
    wire [15:0] station_alias;
    
    // IRQ
    wire [15:0] irq_mask;
    wire [15:0] irq_request;
    
    // SM/FMMU status
    wire [7:0]  sm_status;
    wire [7:0]  fmmu_status;
    
    // DC
    wire [63:0] dc_system_time;
    wire [31:0] dc_sync0_cycle;
    wire [31:0] dc_sync1_cycle;
    
    // Statistics
    wire [31:0] rx_error_counter;
    wire [31:0] lost_link_counter;

    // ========================================================================
    // Internal Signals - AL State Machine
    // ========================================================================
    wire        sm_enable_al;
    wire        fmmu_enable_al;
    wire        pdi_enable;
    wire        watchdog_enable_al;
    wire        al_event_irq;

    // ========================================================================
    // Internal Signals - SII/EEPROM
    // ========================================================================
    wire        sii_reg_req;
    wire        sii_reg_wr;
    wire [15:0] sii_reg_addr;
    wire [31:0] sii_reg_wdata;
    wire [31:0] sii_reg_rdata;
    wire        sii_reg_ack;
    wire        eeprom_loaded;
    wire        eeprom_busy;
    wire        eeprom_error;

    // ========================================================================
    // Internal Signals - DC
    // ========================================================================
    wire        dc_reg_req;
    wire        dc_reg_wr;
    wire [15:0] dc_reg_addr;
    wire [15:0] dc_reg_wdata;
    wire [15:0] dc_reg_rdata;
    wire        dc_reg_ack;
    wire        dc_active;
    wire        sync0_active;
    wire        sync1_active;

    // ========================================================================
    // Internal Signals - DPRAM
    // ========================================================================
    wire        dpram_ecat_req;
    wire        dpram_ecat_wr;
    wire [12:0] dpram_ecat_addr;
    wire [7:0]  dpram_ecat_wdata;
    wire        dpram_ecat_ack;
    wire [7:0]  dpram_ecat_rdata;
    wire        dpram_ecat_collision;
    
    wire        dpram_pdi_req;
    wire        dpram_pdi_wr;
    wire [12:0] dpram_pdi_addr;
    wire [7:0]  dpram_pdi_wdata;
    wire        dpram_pdi_ack;
    wire [7:0]  dpram_pdi_rdata;
    wire        dpram_pdi_collision;
    wire [15:0] collision_count;

    // ========================================================================
    // Internal Signals - PDI Avalon
    // ========================================================================
    wire        pdi_reg_req;
    wire        pdi_reg_wr;
    wire [15:0] pdi_reg_addr;
    wire [15:0] pdi_reg_wdata;
    wire [1:0]  pdi_reg_be;
    wire [15:0] pdi_reg_rdata;
    wire        pdi_reg_ack;
    
    wire [7:0]  pdi_sm_id;
    wire        pdi_sm_req;
    wire        pdi_sm_wr;
    wire [15:0] pdi_sm_addr;
    wire [PDI_DATA_WIDTH-1:0] pdi_sm_wdata;
    wire [PDI_DATA_WIDTH-1:0] pdi_sm_rdata;
    wire        pdi_sm_ack;
    wire        pdi_operational;
    wire        pdi_watchdog_timeout;

    // ========================================================================
    // PHY Interface
    // ========================================================================
    ecat_phy_interface #(
        .PHY_COUNT          (PHY_COUNT),
        .PHY_TYPE           (PHY_TYPE),
        .USE_DDR            (1)
    ) phy_if_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        .clk_ddr            (ecat_clk_ddr),
        .feature_vector     (FEATURE_VECTOR),
        // TX
        .tx_clk             (phy_tx_clk),
        .tx_en              (phy_tx_en),
        .tx_er              (phy_tx_er),
        .tx_data            (phy_tx_data),
        // RX
        .rx_clk             (phy_rx_clk),
        .rx_dv              (phy_rx_dv),
        .rx_er              (phy_rx_er),
        .rx_data            (phy_rx_data),
        // MDIO
        .mdio_mdc           (phy_mdc),
        .mdio_mdio          (), // Connect to MDIO master when implemented
        .mdio_oe            (),
        // Reset
        .phy_reset_n        (phy_reset_n),
        // Status
        .link_up            (link_up),
        .link_speed_100     (link_speed_100),
        .link_duplex        (link_duplex)
    );
    
    // Assign PHY status to port signals
    assign port_link_status = link_up[PHY_COUNT-1:0];
    assign port_loop_status = 4'b0000;  // No loop detected

    // ========================================================================
    // Frame Receiver
    // ========================================================================
    ecat_frame_receiver #(
        .ADDR_WIDTH         (16),
        .DATA_WIDTH         (16),
        .STATION_ADDR       (16'h0000)
    ) frame_rx_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Port interface
        .port_id            (rx_port_id),
        .rx_valid           (rx_valid),
        .rx_data            (rx_data),
        .rx_sof             (rx_sof),
        .rx_eof             (rx_eof),
        .rx_error           (rx_error),
        // Register interface
        .station_address    (station_address),
        .station_alias      ({16'b0, station_alias}),
        // Memory interface
        .mem_addr           (fr_mem_addr),
        .mem_wdata          (fr_mem_wdata),
        .mem_be             (fr_mem_be),
        .mem_wr_en          (fr_mem_wr_en),
        .mem_rd_en          (fr_mem_rd_en),
        .mem_rdata          (fr_mem_rdata),
        .mem_ready          (fr_mem_ready),
        // Frame forwarding
        .fwd_valid          (fwd_valid),
        .fwd_data           (fwd_data),
        .fwd_sof            (fwd_sof),
        .fwd_eof            (fwd_eof),
        .fwd_modified       (fwd_modified),
        // Statistics
        .rx_frame_count     (rx_frame_count),
        .rx_error_count     (rx_error_count),
        .rx_crc_error_count (rx_crc_error_count)
    );

    // ========================================================================
    // Frame Transmitter
    // ========================================================================
    ecat_frame_transmitter #(
        .DATA_WIDTH         (16)
    ) frame_tx_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Port interface
        .port_id            (tx_port_id),
        .tx_valid           (tx_valid),
        .tx_data            (tx_data),
        .tx_sof             (tx_sof),
        .tx_eof             (tx_eof),
        .tx_ready           (tx_ready),
        // Frame input
        .fwd_valid          (fwd_valid),
        .fwd_data           (fwd_data),
        .fwd_sof            (fwd_sof),
        .fwd_eof            (fwd_eof),
        .fwd_modified       (fwd_modified),
        .fwd_from_port      (rx_port_id),
        // Modified data injection
        .inject_enable      (1'b0),
        .inject_offset      (11'b0),
        .inject_data        (8'b0),
        // Port control
        .port_enable        (port_enable),
        .port_link_status   (port_link_status),
        // Statistics
        .tx_frame_count     (tx_frame_count),
        .tx_error_count     (tx_error_count)
    );

    // ========================================================================
    // Register Map
    // ========================================================================
    ecat_register_map #(
        .VENDOR_ID          (VENDOR_ID),
        .PRODUCT_CODE       (PRODUCT_CODE),
        .REVISION_NUM       (REVISION_NUM),
        .SERIAL_NUM         (SERIAL_NUM),
        .NUM_FMMU           (NUM_FMMU),
        .NUM_SM             (NUM_SM)
    ) register_map_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Register access interface
        .reg_req            (reg_req),
        .reg_wr             (reg_wr),
        .reg_addr           (reg_addr),
        .reg_wdata          (reg_wdata),
        .reg_be             (reg_be),
        .reg_rdata          (reg_rdata),
        .reg_ack            (reg_ack),
        // AL Control interface
        .al_control         (al_control),
        .al_control_changed (al_control_changed),
        .al_status          (al_status),
        .al_status_code     (al_status_code),
        // DL Control interface
        .dl_control_fwd_en  (dl_control_fwd_en),
        .dl_control_temp_loop(dl_control_temp_loop),
        .dl_status          (dl_status),
        // Port configuration
        .port_enable        (port_enable),
        .port_link_status   (port_link_status),
        .port_loop_status   (port_loop_status),
        // Station address
        .station_address    (station_address),
        .station_alias      (station_alias),
        // IRQ
        .irq_mask           (irq_mask),
        .irq_request        (irq_request),
        // SM/FMMU status
        .sm_status          (sm_status),
        .fmmu_status        (fmmu_status),
        // DC
        .dc_system_time     (dc_system_time),
        .dc_sync0_cycle     (dc_sync0_cycle),
        .dc_sync1_cycle     (dc_sync1_cycle),
        // Statistics
        .rx_error_counter   (rx_error_counter),
        .lost_link_counter  (lost_link_counter),
        // FMMU Configuration (directly to FMMU array - directly wired)
        .fmmu_log_start_addr(),
        .fmmu_length        (),
        .fmmu_log_start_bit (),
        .fmmu_log_end_bit   (),
        .fmmu_phys_start_addr(),
        .fmmu_phys_start_bit(),
        .fmmu_read_enable   (),
        .fmmu_write_enable  (),
        .fmmu_enable        (),
        // SM Configuration (directly to SM array - directly wired)
        .sm_phys_start_addr (),
        .sm_length          (),
        .sm_control         (),
        .sm_enable          (),
        .sm_repeat          (),
        .sm_status_in       ({NUM_SM{8'h00}}),
        // Watchdog
        .watchdog_divider   (),
        .watchdog_time_pdi  (),
        .watchdog_time_sm   (),
        .watchdog_enable    (),
        .watchdog_expired   (1'b0)
    );

    // ========================================================================
    // AL State Machine
    // ========================================================================
    ecat_al_statemachine al_sm_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // AL Control
        .al_control_req     (al_control),
        .al_control_changed (al_control_changed),
        // AL Status
        .al_status          (al_status),
        .al_status_code     (al_status_code),
        // SM/FMMU status
        .sm_activate        (sm_status),
        .sm_error           (8'h00),
        .fmmu_activate      (fmmu_status),
        // PDI status
        .pdi_operational    (pdi_operational),
        .pdi_watchdog_timeout(pdi_watchdog_timeout),
        // DC status
        .dc_sync_active     (dc_active),
        .dc_sync_error      (1'b0),
        // EEPROM status
        .eeprom_loaded      (eeprom_loaded),
        .eeprom_error       (eeprom_error),
        // Link status
        .port_link_status   (port_link_status),
        // Control outputs
        .sm_enable          (sm_enable_al),
        .fmmu_enable        (fmmu_enable_al),
        .pdi_enable         (pdi_enable),
        .watchdog_enable    (watchdog_enable_al),
        // IRQ
        .al_event_irq       (al_event_irq)
    );

    // ========================================================================
    // SII/EEPROM Controller
    // ========================================================================
    ecat_sii_controller #(
        .CLK_FREQ_HZ        (ECAT_CLK_FREQ_HZ),
        .I2C_FREQ_HZ        (100000),
        .EEPROM_ADDR        (7'b1010000)
    ) sii_ctrl_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Register interface
        .reg_req            (sii_reg_req),
        .reg_wr             (sii_reg_wr),
        .reg_addr           (sii_reg_addr),
        .reg_wdata          (sii_reg_wdata),
        .reg_rdata          (sii_reg_rdata),
        .reg_ack            (sii_reg_ack),
        // I2C interface
        .i2c_scl_o          (eeprom_scl_o),
        .i2c_scl_oe         (eeprom_scl_oe),
        .i2c_scl_i          (eeprom_scl_i),
        .i2c_sda_o          (eeprom_sda_o),
        .i2c_sda_oe         (eeprom_sda_oe),
        .i2c_sda_i          (eeprom_sda_i),
        // Status
        .eeprom_loaded      (eeprom_loaded),
        .eeprom_busy        (eeprom_busy),
        .eeprom_error       (eeprom_error)
    );

    // ========================================================================
    // Distributed Clock (DC)
    // ========================================================================
    generate
        if (DC_SUPPORT) begin : gen_dc
            ecat_dc #(
                .CLK_PERIOD_NS      (1000000000 / ECAT_CLK_FREQ_HZ),
                .NUM_PORTS          (PHY_COUNT)
            ) dc_inst (
                .rst_n              (ecat_rst_n_sync),
                .clk                (ecat_clk),
                // Register interface
                .reg_req            (dc_reg_req),
                .reg_wr             (dc_reg_wr),
                .reg_addr           (dc_reg_addr),
                .reg_wdata          (dc_reg_wdata),
                .reg_rdata          (dc_reg_rdata),
                .reg_ack            (dc_reg_ack),
                // Port receive time
                .port_rx_sof        ({PHY_COUNT{rx_sof}}),
                // SYNC I/O
                .sync0_out          (dc_sync0_out),
                .sync1_out          (dc_sync1_out),
                // Latch I/O
                .latch0_in          (dc_latch0_in),
                .latch1_in          (dc_latch1_in),
                // Status
                .system_time        (dc_system_time),
                .dc_active          (dc_active),
                .sync0_active       (sync0_active),
                .sync1_active       (sync1_active)
            );
        end else begin : gen_no_dc
            assign dc_sync0_out = 1'b0;
            assign dc_sync1_out = 1'b0;
            assign dc_system_time = 64'h0;
            assign dc_active = 1'b0;
            assign sync0_active = 1'b0;
            assign sync1_active = 1'b0;
            assign dc_reg_rdata = 16'h0;
            assign dc_reg_ack = 1'b0;
        end
    endgenerate

    // ========================================================================
    // Dual-Port RAM
    // ========================================================================
    ecat_dpram #(
        .ADDR_WIDTH         (13),
        .DATA_WIDTH         (8),
        .RAM_SIZE           (DP_RAM_SIZE),
        .ECAT_PRIORITY      (1)
    ) dpram_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // ECAT Port
        .ecat_req           (dpram_ecat_req),
        .ecat_wr            (dpram_ecat_wr),
        .ecat_addr          (dpram_ecat_addr),
        .ecat_wdata         (dpram_ecat_wdata),
        .ecat_ack           (dpram_ecat_ack),
        .ecat_rdata         (dpram_ecat_rdata),
        .ecat_collision     (dpram_ecat_collision),
        // PDI Port
        .pdi_req            (dpram_pdi_req),
        .pdi_wr             (dpram_pdi_wr),
        .pdi_addr           (dpram_pdi_addr),
        .pdi_wdata          (dpram_pdi_wdata),
        .pdi_ack            (dpram_pdi_ack),
        .pdi_rdata          (dpram_pdi_rdata),
        .pdi_collision      (dpram_pdi_collision),
        // Status
        .collision_count    (collision_count)
    );

    // ========================================================================
    // PDI Avalon Interface
    // ========================================================================
    ecat_pdi_avalon #(
        .ADDR_WIDTH         (PDI_ADDR_WIDTH),
        .DATA_WIDTH         (PDI_DATA_WIDTH)
    ) pdi_avalon_inst (
        .rst_n              (sys_rst_n_sync),
        .clk                (pdi_clk),
        // Avalon interface
        .avs_address        (pdi_address),
        .avs_read           (pdi_read),
        .avs_readdata       (pdi_readdata),
        .avs_readdatavalid  (pdi_readdatavalid),
        .avs_write          (pdi_write),
        .avs_writedata      (pdi_writedata),
        .avs_byteenable     (pdi_byteenable),
        .avs_waitrequest    (pdi_waitrequest),
        // Register access
        .reg_req            (pdi_reg_req),
        .reg_wr             (pdi_reg_wr),
        .reg_addr           (pdi_reg_addr),
        .reg_wdata          (pdi_reg_wdata),
        .reg_be             (pdi_reg_be),
        .reg_rdata          (pdi_reg_rdata),
        .reg_ack            (pdi_reg_ack),
        // SM access
        .sm_id              (pdi_sm_id),
        .sm_pdi_req         (pdi_sm_req),
        .sm_pdi_wr          (pdi_sm_wr),
        .sm_pdi_addr        (pdi_sm_addr),
        .sm_pdi_wdata       (pdi_sm_wdata),
        .sm_pdi_rdata       (pdi_sm_rdata),
        .sm_pdi_ack         (pdi_sm_ack),
        // Control
        .pdi_enable         (pdi_enable),
        .pdi_operational    (pdi_operational),
        .pdi_watchdog_timeout(pdi_watchdog_timeout),
        // IRQ
        .pdi_irq            (pdi_irq),
        .irq_sources        (irq_request)
    );

    // ========================================================================
    // Register Access Arbitration
    // ========================================================================
    // Priority: Frame Receiver > PDI > SII > DC
    // Address-based routing for different register ranges
    
    // Address range detection
    wire is_sii_addr = (fr_mem_addr >= 16'h0500) && (fr_mem_addr <= 16'h050F);
    wire is_dc_addr  = (fr_mem_addr >= 16'h0900) && (fr_mem_addr <= 16'h09FF);
    wire is_reg_addr = !is_sii_addr && !is_dc_addr;
    
    // Route requests based on address
    assign reg_req = (fr_mem_rd_en || fr_mem_wr_en) && is_reg_addr;
    assign reg_wr = fr_mem_wr_en && is_reg_addr;
    assign reg_addr = fr_mem_addr;
    assign reg_wdata = fr_mem_wdata;
    assign reg_be = fr_mem_be;
    
    // SII register access (for address range 0x0500-0x050F)
    assign sii_reg_req = (fr_mem_rd_en || fr_mem_wr_en) && is_sii_addr;
    assign sii_reg_wr = fr_mem_wr_en && is_sii_addr;
    assign sii_reg_addr = fr_mem_addr;
    assign sii_reg_wdata = {16'h0, fr_mem_wdata};
    
    // DC register access (for address range 0x0900-0x09FF)
    assign dc_reg_req = (fr_mem_rd_en || fr_mem_wr_en) && is_dc_addr;
    assign dc_reg_wr = fr_mem_wr_en && is_dc_addr;
    assign dc_reg_addr = fr_mem_addr;
    assign dc_reg_wdata = fr_mem_wdata;
    
    // Mux read data and ready signals based on address
    assign fr_mem_rdata = is_sii_addr ? sii_reg_rdata[15:0] :
                          is_dc_addr  ? dc_reg_rdata :
                                        reg_rdata;
    assign fr_mem_ready = is_sii_addr ? sii_reg_ack :
                          is_dc_addr  ? dc_reg_ack :
                                        reg_ack;
    
    // PDI to register map connection
    assign pdi_reg_rdata = reg_rdata;
    assign pdi_reg_ack = reg_ack;

    // ========================================================================
    // DPRAM Connections (simplified)
    // ========================================================================
    assign dpram_ecat_req = fr_mem_rd_en || fr_mem_wr_en;
    assign dpram_ecat_wr = fr_mem_wr_en;
    assign dpram_ecat_addr = fr_mem_addr[12:0];
    assign dpram_ecat_wdata = fr_mem_wdata[7:0];
    
    assign dpram_pdi_req = pdi_sm_req;
    assign dpram_pdi_wr = pdi_sm_wr;
    assign dpram_pdi_addr = pdi_sm_addr[12:0];
    assign dpram_pdi_wdata = pdi_sm_wdata[7:0];
    assign pdi_sm_rdata = {{(PDI_DATA_WIDTH-8){1'b0}}, dpram_pdi_rdata};
    assign pdi_sm_ack = dpram_pdi_ack;

    // ========================================================================
    // Statistics Aggregation
    // ========================================================================
    assign rx_error_counter = {rx_crc_error_count, rx_error_count};
    
    // Link loss counter - tracks link down events per port
    reg [15:0] link_loss_cnt_0;
    reg [15:0] link_loss_cnt_1;
    reg [PHY_COUNT-1:0] link_up_prev;
    
    always @(posedge ecat_clk or negedge ecat_rst_n_sync) begin
        if (!ecat_rst_n_sync) begin
            link_loss_cnt_0 <= 16'h0;
            link_loss_cnt_1 <= 16'h0;
            link_up_prev <= {PHY_COUNT{1'b0}};
        end else begin
            link_up_prev <= link_up;
            // Detect falling edge on link_up (link lost)
            if (link_up_prev[0] && !link_up[0])
                link_loss_cnt_0 <= link_loss_cnt_0 + 1'b1;
            if (PHY_COUNT > 1 && link_up_prev[1] && !link_up[1])
                link_loss_cnt_1 <= link_loss_cnt_1 + 1'b1;
        end
    end
    assign lost_link_counter = {link_loss_cnt_1, link_loss_cnt_0};

    // ========================================================================
    // IRQ Generation
    // ========================================================================
    assign irq_request = {8'h00, al_event_irq, 7'h00};

    // ========================================================================
    // LED Control
    // ========================================================================
    assign led_link = link_up;
    assign led_act = {PHY_COUNT{rx_valid | tx_valid}};
    assign led_run = (al_status == 5'h08);  // Operational state
    assign led_err = (al_status[4]);         // Error bit set

    // ========================================================================
    // Stub Signals for Incomplete Connections
    // ========================================================================
    // These will be properly connected when FMMU/SM arrays are integrated
    assign sm_status = 8'h00;
    assign fmmu_status = 8'h00;
    assign dl_status = {12'h000, port_link_status};
    
    // PHY RX stub - needs proper port selection logic
    assign rx_port_id = 4'h0;
    assign rx_valid = phy_rx_dv[0];
    assign rx_data = phy_rx_data[7:0];
    assign rx_sof = phy_rx_dv[0] && !phy_rx_dv[0];  // Edge detect needed
    assign rx_eof = !phy_rx_dv[0] && phy_rx_dv[0];  // Edge detect needed
    assign rx_error = phy_rx_er[0];
    
    // TX ready stub
    assign tx_ready = 1'b1;

    // ========================================================================
    // MDIO Stub (until MDIO master is implemented)
    // ========================================================================
    assign phy_mdio_o = 1'b1;
    assign phy_mdio_oe = 1'b0;

endmodule
