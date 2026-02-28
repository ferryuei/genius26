//==============================================================================
// APB UART - Simple UART with APB Interface
// Features:
//   - APB slave interface
//   - 8-bit data, no parity, 1 stop bit (8N1)
//   - Configurable baud rate via divider register
//   - TX/RX with status flags
//==============================================================================

module apb_uart (
    // APB Interface
    input  wire        pclk,
    input  wire        presetn,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [3:0]  paddr,
    input  wire [7:0]  pwdata,
    output reg  [7:0]  prdata,
    output wire        pready,
    
    // UART Interface
    input  wire        uart_rx,
    output wire        uart_tx
);

//==============================================================================
// Register Map
//==============================================================================
// 0x0: TX_DATA  - Write: transmit data
// 0x4: RX_DATA  - Read: received data
// 0x8: STATUS   - [0]: TX_BUSY, [1]: RX_VALID, [2]: RX_OVERRUN
// 0xC: BAUD_DIV - Baud rate divider (clk_freq / baud_rate / 16)

localparam ADDR_TX_DATA  = 4'h0;
localparam ADDR_RX_DATA  = 4'h4;
localparam ADDR_STATUS   = 4'h8;
localparam ADDR_BAUD_DIV = 4'hC;

//==============================================================================
// Registers
//==============================================================================
reg [7:0] tx_data_reg;
reg [7:0] rx_data_reg;
reg [7:0] baud_div_reg;
reg       tx_start;
reg       rx_valid;
reg       rx_overrun;

//==============================================================================
// Baud Rate Generator
//==============================================================================
reg [7:0]  baud_cnt;
reg        baud_tick;

always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        baud_cnt  <= 8'd0;
        baud_tick <= 1'b0;
    end else begin
        if (baud_cnt >= baud_div_reg) begin
            baud_cnt  <= 8'd0;
            baud_tick <= 1'b1;
        end else begin
            baud_cnt  <= baud_cnt + 1'b1;
            baud_tick <= 1'b0;
        end
    end
end

//==============================================================================
// TX State Machine
//==============================================================================
localparam TX_IDLE  = 2'b00;
localparam TX_START = 2'b01;
localparam TX_DATA  = 2'b10;
localparam TX_STOP  = 2'b11;

reg [1:0] tx_state;
reg [3:0] tx_bit_cnt;
reg [3:0] tx_baud_cnt;
reg [7:0] tx_shift_reg;
reg       tx_out;

wire tx_busy = (tx_state != TX_IDLE);

always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        tx_state     <= TX_IDLE;
        tx_bit_cnt   <= 4'd0;
        tx_baud_cnt  <= 4'd0;
        tx_shift_reg <= 8'hFF;
        tx_out       <= 1'b1;
    end else begin
        case (tx_state)
            TX_IDLE: begin
                tx_out <= 1'b1;
                if (tx_start) begin
                    tx_state     <= TX_START;
                    tx_shift_reg <= tx_data_reg;
                    tx_baud_cnt  <= 4'd0;
                end
            end
            
            TX_START: begin
                tx_out <= 1'b0;  // Start bit
                if (baud_tick) begin
                    if (tx_baud_cnt >= 4'd15) begin
                        tx_state    <= TX_DATA;
                        tx_bit_cnt  <= 4'd0;
                        tx_baud_cnt <= 4'd0;
                    end else begin
                        tx_baud_cnt <= tx_baud_cnt + 1'b1;
                    end
                end
            end
            
            TX_DATA: begin
                tx_out <= tx_shift_reg[0];
                if (baud_tick) begin
                    if (tx_baud_cnt >= 4'd15) begin
                        tx_baud_cnt  <= 4'd0;
                        tx_shift_reg <= {1'b1, tx_shift_reg[7:1]};
                        if (tx_bit_cnt >= 4'd7) begin
                            tx_state <= TX_STOP;
                        end else begin
                            tx_bit_cnt <= tx_bit_cnt + 1'b1;
                        end
                    end else begin
                        tx_baud_cnt <= tx_baud_cnt + 1'b1;
                    end
                end
            end
            
            TX_STOP: begin
                tx_out <= 1'b1;  // Stop bit
                if (baud_tick) begin
                    if (tx_baud_cnt >= 4'd15) begin
                        tx_state <= TX_IDLE;
                    end else begin
                        tx_baud_cnt <= tx_baud_cnt + 1'b1;
                    end
                end
            end
        endcase
    end
end

assign uart_tx = tx_out;

//==============================================================================
// RX State Machine
//==============================================================================
localparam RX_IDLE  = 2'b00;
localparam RX_START = 2'b01;
localparam RX_DATA  = 2'b10;
localparam RX_STOP  = 2'b11;

reg [1:0] rx_state;
reg [3:0] rx_bit_cnt;
reg [3:0] rx_baud_cnt;
reg [7:0] rx_shift_reg;
reg [2:0] rx_sync;

// Synchronize RX input
always @(posedge pclk or negedge presetn) begin
    if (!presetn)
        rx_sync <= 3'b111;
    else
        rx_sync <= {rx_sync[1:0], uart_rx};
end

wire rx_in = rx_sync[2];

always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        rx_state     <= RX_IDLE;
        rx_bit_cnt   <= 4'd0;
        rx_baud_cnt  <= 4'd0;
        rx_shift_reg <= 8'd0;
    end else begin
        case (rx_state)
            RX_IDLE: begin
                if (!rx_in) begin  // Start bit detected
                    rx_state    <= RX_START;
                    rx_baud_cnt <= 4'd0;
                end
            end
            
            RX_START: begin
                if (baud_tick) begin
                    if (rx_baud_cnt >= 4'd7) begin  // Sample at middle
                        if (!rx_in) begin  // Valid start bit
                            rx_state    <= RX_DATA;
                            rx_bit_cnt  <= 4'd0;
                            rx_baud_cnt <= 4'd0;
                        end else begin
                            rx_state <= RX_IDLE;  // False start
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
            end
            
            RX_DATA: begin
                if (baud_tick) begin
                    if (rx_baud_cnt >= 4'd15) begin
                        rx_baud_cnt  <= 4'd0;
                        rx_shift_reg <= {rx_in, rx_shift_reg[7:1]};
                        if (rx_bit_cnt >= 4'd7) begin
                            rx_state <= RX_STOP;
                        end else begin
                            rx_bit_cnt <= rx_bit_cnt + 1'b1;
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
            end
            
            RX_STOP: begin
                if (baud_tick) begin
                    if (rx_baud_cnt >= 4'd15) begin
                        rx_state <= RX_IDLE;
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
            end
        endcase
    end
end

// RX data and flags
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        rx_data_reg <= 8'd0;
        rx_valid    <= 1'b0;
        rx_overrun  <= 1'b0;
    end else begin
        // Capture received data
        if (rx_state == RX_STOP && baud_tick && rx_baud_cnt >= 4'd15) begin
            rx_data_reg <= rx_shift_reg;
            if (rx_valid)
                rx_overrun <= 1'b1;  // Overrun if previous data not read
            rx_valid <= 1'b1;
        end
        
        // Clear flags on read
        if (psel && penable && !pwrite && paddr == ADDR_RX_DATA) begin
            rx_valid   <= 1'b0;
            rx_overrun <= 1'b0;
        end
    end
end

//==============================================================================
// APB Interface
//==============================================================================
assign pready = 1'b1;  // Always ready (no wait states)

// Write logic
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        tx_data_reg  <= 8'd0;
        baud_div_reg <= 8'd26;  // Default: ~115200 @ 50MHz
        tx_start     <= 1'b0;
    end else begin
        tx_start <= 1'b0;
        
        if (psel && penable && pwrite) begin
            case (paddr)
                ADDR_TX_DATA: begin
                    tx_data_reg <= pwdata;
                    tx_start    <= 1'b1;
                end
                ADDR_BAUD_DIV: begin
                    baud_div_reg <= pwdata;
                end
            endcase
        end
    end
end

// Read logic
always @(*) begin
    prdata = 8'd0;
    case (paddr)
        ADDR_TX_DATA:  prdata = tx_data_reg;
        ADDR_RX_DATA:  prdata = rx_data_reg;
        ADDR_STATUS:   prdata = {5'd0, rx_overrun, rx_valid, tx_busy};
        ADDR_BAUD_DIV: prdata = baud_div_reg;
        default:       prdata = 8'd0;
    endcase
end

endmodule
