//******************************************************************************
// SFU Datapath Bridge
// Description: Connects SFU to M20K buffers and result collectors
// Features:
//   - M20K read interface for SFU input
//   - Stream output for results
//   - Vector processing support
//******************************************************************************

module sfu_datapath_bridge #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 18,
    parameter VECTOR_LEN = 128
)(
    // Clock and Reset
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Control
    input  wire                         start,
    output reg                          done,
    input  wire [7:0]                   vector_length,
    input  wire [ADDR_WIDTH-1:0]        src_addr,
    input  wire [ADDR_WIDTH-1:0]        dst_addr,
    
    // M20K Read Interface
    output reg  [ADDR_WIDTH-1:0]        m20k_raddr,
    input  wire [DATA_WIDTH-1:0]        m20k_rdata,
    output reg                          m20k_re,
    
    // M20K Write Interface (for results)
    output reg  [ADDR_WIDTH-1:0]        m20k_waddr,
    output reg  [DATA_WIDTH-1:0]        m20k_wdata,
    output reg                          m20k_we,
    
    // SFU Interface
    output reg  [DATA_WIDTH-1:0]        sfu_data_in,
    input  wire [DATA_WIDTH-1:0]        sfu_data_out,
    input  wire                         sfu_data_valid
);

    //==========================================================================
    // FSM States
    //==========================================================================
    
    localparam IDLE         = 2'b00;
    localparam READ_DATA    = 2'b01;
    localparam WRITE_RESULT = 2'b10;
    
    reg [1:0]   state;
    
    //==========================================================================
    // Internal Registers
    //==========================================================================
    
    reg [ADDR_WIDTH-1:0]    read_addr;
    reg [ADDR_WIDTH-1:0]    write_addr;
    reg [7:0]               element_count;
    reg [1:0]               read_delay;
    
    //==========================================================================
    // Control FSM
    //==========================================================================
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            m20k_raddr <= {ADDR_WIDTH{1'b0}};
            m20k_re <= 1'b0;
            m20k_waddr <= {ADDR_WIDTH{1'b0}};
            m20k_wdata <= {DATA_WIDTH{1'b0}};
            m20k_we <= 1'b0;
            sfu_data_in <= {DATA_WIDTH{1'b0}};
            read_addr <= {ADDR_WIDTH{1'b0}};
            write_addr <= {ADDR_WIDTH{1'b0}};
            element_count <= 8'd0;
            read_delay <= 2'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    m20k_re <= 1'b0;
                    m20k_we <= 1'b0;
                    
                    if (start) begin
                        read_addr <= src_addr;
                        write_addr <= dst_addr;
                        element_count <= 8'd0;
                        state <= READ_DATA;
                    end
                end
                
                READ_DATA: begin
                    // Read from M20K
                    m20k_raddr <= read_addr;
                    m20k_re <= 1'b1;
                    
                    // Wait for M20K latency
                    if (read_delay < 2'd1) begin
                        read_delay <= read_delay + 1'b1;
                    end else begin
                        read_delay <= 2'd0;
                        // Feed data to SFU
                        sfu_data_in <= m20k_rdata;
                        read_addr <= read_addr + 1'b1;
                        state <= WRITE_RESULT;
                    end
                end
                
                WRITE_RESULT: begin
                    m20k_re <= 1'b0;
                    
                    // Wait for SFU result
                    if (sfu_data_valid) begin
                        // Write result back to M20K
                        m20k_waddr <= write_addr;
                        m20k_wdata <= sfu_data_out;
                        m20k_we <= 1'b1;
                        write_addr <= write_addr + 1'b1;
                        
                        element_count <= element_count + 1'b1;
                        
                        if (element_count >= vector_length - 1) begin
                            done <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= READ_DATA;
                        end
                    end else begin
                        m20k_we <= 1'b0;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
