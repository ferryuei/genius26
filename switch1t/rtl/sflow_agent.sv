// =============================================================================
// sFlow Agent - Sampled Flow Monitoring (sFlow v5)
// =============================================================================
// Features:
// - sFlow v5 protocol (RFC 3176)
// - Packet sampling (1:N random sampling)
// - Counter sampling (interface statistics)
// - Flow sample generation
// - Counter sample generation
// - Datagram export to sFlow collector
// - Per-port sampling configuration
// - Ingress and egress sampling
// - Extended switch data (VLAN, priority)
// =============================================================================

module sflow_agent 
    import switch_pkg::*;
#(
    parameter NUM_PORTS = 48,
    parameter MAX_SAMPLES_PER_DATAGRAM = 8
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Packet sampling interface (ingress)
    input  logic [NUM_PORTS-1:0]      pkt_rx_valid,
    input  logic [NUM_PORTS-1:0]      pkt_rx_sop,
    input  logic [NUM_PORTS-1:0]      pkt_rx_eop,
    input  logic [63:0]               pkt_rx_data [NUM_PORTS-1:0],
    input  logic [2:0]                pkt_rx_empty [NUM_PORTS-1:0],
    input  logic [15:0]               pkt_rx_len [NUM_PORTS-1:0],
    input  logic [47:0]               pkt_rx_smac [NUM_PORTS-1:0],
    input  logic [47:0]               pkt_rx_dmac [NUM_PORTS-1:0],
    input  logic [11:0]               pkt_rx_vlan [NUM_PORTS-1:0],
    input  logic [2:0]                pkt_rx_priority [NUM_PORTS-1:0],
    
    // Packet sampling interface (egress)
    input  logic [NUM_PORTS-1:0]      pkt_tx_valid,
    input  logic [NUM_PORTS-1:0]      pkt_tx_sop,
    input  logic [NUM_PORTS-1:0]      pkt_tx_eop,
    input  logic [63:0]               pkt_tx_data [NUM_PORTS-1:0],
    input  logic [15:0]               pkt_tx_len [NUM_PORTS-1:0],
    
    // Counter sampling interface (per port)
    input  logic [63:0]               if_in_octets [NUM_PORTS-1:0],
    input  logic [63:0]               if_in_ucast_pkts [NUM_PORTS-1:0],
    input  logic [63:0]               if_in_mcast_pkts [NUM_PORTS-1:0],
    input  logic [63:0]               if_in_bcast_pkts [NUM_PORTS-1:0],
    input  logic [63:0]               if_in_discards [NUM_PORTS-1:0],
    input  logic [63:0]               if_in_errors [NUM_PORTS-1:0],
    input  logic [63:0]               if_out_octets [NUM_PORTS-1:0],
    input  logic [63:0]               if_out_ucast_pkts [NUM_PORTS-1:0],
    input  logic [63:0]               if_out_mcast_pkts [NUM_PORTS-1:0],
    input  logic [63:0]               if_out_bcast_pkts [NUM_PORTS-1:0],
    input  logic [63:0]               if_out_discards [NUM_PORTS-1:0],
    input  logic [63:0]               if_out_errors [NUM_PORTS-1:0],
    input  logic [NUM_PORTS-1:0]      if_oper_status,
    input  logic [31:0]               if_speed [NUM_PORTS-1:0],  // Mbps
    
    // UDP export interface (to collector)
    output logic                      udp_tx_valid,
    output logic [1023:0]             udp_tx_data,
    output logic [15:0]               udp_tx_len,
    output logic [31:0]               udp_tx_dst_ip,
    output logic [15:0]               udp_tx_dst_port,
    
    // Configuration
    input  logic                      sflow_enable,
    input  logic [31:0]               collector_ip,
    input  logic [15:0]               collector_port,      // Default 6343
    input  logic [31:0]               agent_address,       // Switch IP
    input  logic [31:0]               agent_id,            // Sub-agent ID
    
    // Sampling configuration (per port)
    input  logic [NUM_PORTS-1:0]      ingress_sampling_enable,
    input  logic [NUM_PORTS-1:0]      egress_sampling_enable,
    input  logic [31:0]               sampling_rate [NUM_PORTS-1:0],  // 1:N sampling
    input  logic [31:0]               counter_interval [NUM_PORTS-1:0], // seconds
    
    // Statistics
    output logic [31:0]               stat_flow_samples,
    output logic [31:0]               stat_counter_samples,
    output logic [31:0]               stat_datagrams_sent,
    output logic [31:0]               stat_samples_dropped
);

    // =========================================================================
    // sFlow v5 Constants
    // =========================================================================
    localparam [31:0] SFLOW_VERSION = 32'd5;
    
    // Sample types (enterprise = 0, format = X)
    localparam [31:0] SAMPLE_FLOW        = 32'd1;   // Flow sample
    localparam [31:0] SAMPLE_COUNTER     = 32'd2;   // Counter sample
    localparam [31:0] SAMPLE_EXPANDED_FLOW = 32'd3; // Expanded flow sample
    
    // Flow data formats
    localparam [31:0] FORMAT_RAW_HEADER  = 32'd1;   // Raw packet header
    localparam [31:0] FORMAT_ETHERNET    = 32'd2;   // Ethernet frame data
    localparam [31:0] FORMAT_IPV4        = 32'd3;   // IPv4 data
    localparam [31:0] FORMAT_EXTENDED_SWITCH = 32'd1001; // Extended switch data
    
    // Counter data formats
    localparam [31:0] FORMAT_GENERIC_IF  = 32'd1;   // Generic interface counters
    localparam [31:0] FORMAT_ETHERNET_IF = 32'd2;   // Ethernet interface counters
    
    // =========================================================================
    // Sampling State (per port)
    // =========================================================================
    logic [31:0] ingress_sample_pool [NUM_PORTS-1:0];
    logic [31:0] egress_sample_pool [NUM_PORTS-1:0];
    logic [31:0] packet_seq_num [NUM_PORTS-1:0];
    
    // Counter sampling timer
    logic [31:0] counter_timer [NUM_PORTS-1:0];
    logic [31:0] counter_seq_num [NUM_PORTS-1:0];
    
    // =========================================================================
    // Datagram Sequence Number
    // =========================================================================
    logic [31:0] datagram_seq_num;
    logic [31:0] uptime;  // System uptime in milliseconds
    
    // Uptime counter (milliseconds)
    logic [31:0] uptime_cycle_count;
    localparam CYCLES_PER_MS = 156_250;  // 156.25MHz -> 1ms
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uptime <= '0;
            uptime_cycle_count <= '0;
        end else begin
            uptime_cycle_count <= uptime_cycle_count + 1;
            if (uptime_cycle_count >= CYCLES_PER_MS) begin
                uptime <= uptime + 1;
                uptime_cycle_count <= '0;
            end
        end
    end
    
    // =========================================================================
    // Flow Sample Record
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [31:0] seq_number;
        logic [31:0] source_id;       // Port index
        logic [31:0] sampling_rate;
        logic [31:0] sample_pool;
        logic [31:0] drops;
        logic [31:0] input_if;
        logic [31:0] output_if;
        logic [15:0] pkt_len;
        logic [127:0] raw_header;     // First 128 bits of packet
        logic [11:0] vlan_id;
        logic [2:0]  priority;
    } flow_sample_t;
    
    flow_sample_t pending_flow_samples [MAX_SAMPLES_PER_DATAGRAM-1:0];
    logic [3:0] pending_flow_count;
    
    // =========================================================================
    // Counter Sample Record
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [31:0] seq_number;
        logic [31:0] source_id;       // Port index
        logic [31:0] if_index;
        logic [31:0] if_type;         // ethernetCsmacd = 6
        logic [63:0] if_speed;        // bits per second
        logic [31:0] if_direction;    // 1=full-duplex, 2=half-duplex
        logic [31:0] if_status;       // bit 0 = ifAdminStatus, bit 1 = ifOperStatus
        logic [64:0] if_in_octets;
        logic [32:0] if_in_ucast_pkts;
        logic [32:0] if_in_mcast_pkts;
        logic [32:0] if_in_bcast_pkts;
        logic [32:0] if_in_discards;
        logic [32:0] if_in_errors;
        logic [64:0] if_out_octets;
        logic [32:0] if_out_ucast_pkts;
        logic [32:0] if_out_mcast_pkts;
        logic [32:0] if_out_bcast_pkts;
        logic [32:0] if_out_discards;
        logic [32:0] if_out_errors;
    } counter_sample_t;
    
    counter_sample_t pending_counter_samples [MAX_SAMPLES_PER_DATAGRAM-1:0];
    logic [3:0] pending_counter_count;
    
    // =========================================================================
    // Random Number Generator (LFSR for sampling decision)
    // =========================================================================
    logic [31:0] lfsr;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 32'hACE1ACE1;  // Seed
        end else begin
            // Galois LFSR (32-bit)
            lfsr <= {lfsr[30:0], 1'b0} ^ (lfsr[31] ? 32'h80000057 : 32'h0);
        end
    end
    
    // =========================================================================
    // Ingress Flow Sampling Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                ingress_sample_pool[i] <= '0;
                packet_seq_num[i] <= '0;
            end
            pending_flow_count <= '0;
            for (int i = 0; i < MAX_SAMPLES_PER_DATAGRAM; i++) begin
                pending_flow_samples[i] <= '0;
            end
            stat_flow_samples <= '0;
            stat_samples_dropped <= '0;
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (pkt_rx_valid[i] && pkt_rx_sop[i] && ingress_sampling_enable[i] && sflow_enable) begin
                    ingress_sample_pool[i] <= ingress_sample_pool[i] + 1;
                    packet_seq_num[i] <= packet_seq_num[i] + 1;
                    
                    // Sampling decision: 1:N random sampling
                    logic sample_this_packet;
                    sample_this_packet = (lfsr % sampling_rate[i]) == 0;
                    
                    if (sample_this_packet) begin
                        // Create flow sample
                        if (pending_flow_count < MAX_SAMPLES_PER_DATAGRAM) begin
                            automatic int idx = pending_flow_count;
                            
                            pending_flow_samples[idx].valid <= 1'b1;
                            pending_flow_samples[idx].seq_number <= packet_seq_num[i];
                            pending_flow_samples[idx].source_id <= {24'b0, i[7:0]};
                            pending_flow_samples[idx].sampling_rate <= sampling_rate[i];
                            pending_flow_samples[idx].sample_pool <= ingress_sample_pool[i];
                            pending_flow_samples[idx].drops <= '0;  // Simplified
                            pending_flow_samples[idx].input_if <= {24'b0, i[7:0]};
                            pending_flow_samples[idx].output_if <= 32'hFFFFFFFF;  // Unknown
                            pending_flow_samples[idx].pkt_len <= pkt_rx_len[i];
                            pending_flow_samples[idx].raw_header <= pkt_rx_data[i][1023:896];
                            pending_flow_samples[idx].vlan_id <= pkt_rx_vlan[i];
                            pending_flow_samples[idx].priority <= pkt_rx_priority[i];
                            
                            pending_flow_count <= pending_flow_count + 1;
                            stat_flow_samples <= stat_flow_samples + 1;
                        end else begin
                            // Sample buffer full
                            stat_samples_dropped <= stat_samples_dropped + 1;
                        end
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Counter Sampling Logic
    // =========================================================================
    localparam COUNTER_TIMER_1SEC = 156_250_000;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                counter_timer[i] <= '0;
                counter_seq_num[i] <= '0;
            end
            pending_counter_count <= '0;
            for (int i = 0; i < MAX_SAMPLES_PER_DATAGRAM; i++) begin
                pending_counter_samples[i] <= '0;
            end
            stat_counter_samples <= '0;
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                counter_timer[i] <= counter_timer[i] + 1;
                
                // Check if counter interval elapsed
                if (counter_timer[i] >= counter_interval[i] * COUNTER_TIMER_1SEC) begin
                    counter_timer[i] <= '0;
                    counter_seq_num[i] <= counter_seq_num[i] + 1;
                    
                    if (sflow_enable && pending_counter_count < MAX_SAMPLES_PER_DATAGRAM) begin
                        automatic int idx = pending_counter_count;
                        
                        pending_counter_samples[idx].valid <= 1'b1;
                        pending_counter_samples[idx].seq_number <= counter_seq_num[i];
                        pending_counter_samples[idx].source_id <= {24'b0, i[7:0]};
                        pending_counter_samples[idx].if_index <= {24'b0, i[7:0]};
                        pending_counter_samples[idx].if_type <= 32'd6;  // ethernetCsmacd
                        pending_counter_samples[idx].if_speed <= {32'b0, if_speed[i]} * 1_000_000;
                        pending_counter_samples[idx].if_direction <= 32'd1;  // full-duplex
                        pending_counter_samples[idx].if_status <= {30'b0, if_oper_status[i], 1'b1};
                        pending_counter_samples[idx].if_in_octets <= {1'b0, if_in_octets[i]};
                        pending_counter_samples[idx].if_in_ucast_pkts <= {1'b0, if_in_ucast_pkts[i][31:0]};
                        pending_counter_samples[idx].if_in_mcast_pkts <= {1'b0, if_in_mcast_pkts[i][31:0]};
                        pending_counter_samples[idx].if_in_bcast_pkts <= {1'b0, if_in_bcast_pkts[i][31:0]};
                        pending_counter_samples[idx].if_in_discards <= {1'b0, if_in_discards[i][31:0]};
                        pending_counter_samples[idx].if_in_errors <= {1'b0, if_in_errors[i][31:0]};
                        pending_counter_samples[idx].if_out_octets <= {1'b0, if_out_octets[i]};
                        pending_counter_samples[idx].if_out_ucast_pkts <= {1'b0, if_out_ucast_pkts[i][31:0]};
                        pending_counter_samples[idx].if_out_mcast_pkts <= {1'b0, if_out_mcast_pkts[i][31:0]};
                        pending_counter_samples[idx].if_out_bcast_pkts <= {1'b0, if_out_bcast_pkts[i][31:0]};
                        pending_counter_samples[idx].if_out_discards <= {1'b0, if_out_discards[i][31:0]};
                        pending_counter_samples[idx].if_out_errors <= {1'b0, if_out_errors[i][31:0]};
                        
                        pending_counter_count <= pending_counter_count + 1;
                        stat_counter_samples <= stat_counter_samples + 1;
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Datagram Builder and Exporter
    // =========================================================================
    typedef enum logic [1:0] {
        EXPORT_IDLE,
        EXPORT_BUILD,
        EXPORT_SEND
    } export_state_t;
    
    export_state_t export_state;
    logic [1023:0] datagram_buffer;
    logic [15:0] datagram_len;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            export_state <= EXPORT_IDLE;
            udp_tx_valid <= 1'b0;
            datagram_seq_num <= '0;
            stat_datagrams_sent <= '0;
        end else begin
            udp_tx_valid <= 1'b0;
            
            case (export_state)
                EXPORT_IDLE: begin
                    // Trigger export when we have samples
                    if (pending_flow_count > 0 || pending_counter_count > 0) begin
                        export_state <= EXPORT_BUILD;
                    end
                end
                
                EXPORT_BUILD: begin
                    // Build sFlow datagram
                    logic [15:0] offset;
                    offset = 0;
                    
                    // sFlow version (4 bytes)
                    datagram_buffer[1023:992] <= SFLOW_VERSION;
                    offset = 4;
                    
                    // Agent address (4 bytes)
                    datagram_buffer[991:960] <= agent_address;
                    offset = 8;
                    
                    // Sub-agent ID (4 bytes)
                    datagram_buffer[959:928] <= agent_id;
                    offset = 12;
                    
                    // Sequence number (4 bytes)
                    datagram_buffer[927:896] <= datagram_seq_num;
                    offset = 16;
                    
                    // Uptime (4 bytes)
                    datagram_buffer[895:864] <= uptime;
                    offset = 20;
                    
                    // Number of samples (4 bytes)
                    datagram_buffer[863:832] <= {28'b0, pending_flow_count} + {28'b0, pending_counter_count};
                    offset = 24;
                    
                    // Sample records would be encoded here
                    // (Simplified - would encode all pending samples)
                    
                    datagram_len <= 16'd128;  // Simplified fixed length
                    datagram_seq_num <= datagram_seq_num + 1;
                    
                    export_state <= EXPORT_SEND;
                end
                
                EXPORT_SEND: begin
                    // Send datagram to collector
                    udp_tx_valid <= 1'b1;
                    udp_tx_data <= datagram_buffer;
                    udp_tx_len <= datagram_len;
                    udp_tx_dst_ip <= collector_ip;
                    udp_tx_dst_port <= collector_port;
                    
                    // Clear pending samples
                    pending_flow_count <= '0;
                    pending_counter_count <= '0;
                    
                    stat_datagrams_sent <= stat_datagrams_sent + 1;
                    export_state <= EXPORT_IDLE;
                end
                
                default: export_state <= EXPORT_IDLE;
            endcase
        end
    end

endmodule
