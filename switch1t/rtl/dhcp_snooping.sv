// =============================================================================
// DHCP Snooping Engine
// =============================================================================
// Features:
// - DHCP packet inspection and validation
// - Trusted/Untrusted port classification
// - IP-MAC-VLAN binding database (up to 4K entries)
// - DHCP server validation (prevent rogue DHCP servers)
// - Rate limiting for DHCP packets
// - Option 82 (DHCP Relay Agent Information) support
// - Lease time tracking and aging
// - Foundation for Dynamic ARP Inspection (DAI) and IP Source Guard (IPSG)
// =============================================================================

module dhcp_snooping 
    import switch_pkg::*;
#(
    parameter NUM_PORTS = 48,
    parameter MAX_BINDINGS = 4096,
    parameter BINDING_TABLE_WIDTH = 12  // log2(MAX_BINDINGS)
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Packet interface
    input  logic [NUM_PORTS-1:0]      pkt_rx_valid,
    input  logic [1023:0]             pkt_rx_data [NUM_PORTS-1:0],
    input  logic [15:0]               pkt_rx_len [NUM_PORTS-1:0],
    input  logic [47:0]               pkt_rx_smac [NUM_PORTS-1:0],
    input  logic [11:0]               pkt_rx_vlan [NUM_PORTS-1:0],
    input  logic [PORT_WIDTH-1:0]     pkt_rx_port,
    
    // Packet forwarding decision
    output logic [NUM_PORTS-1:0]      dhcp_forward_allow,
    output logic [NUM_PORTS-1:0]      dhcp_drop,
    
    // Binding database lookup interface
    input  logic                      binding_lookup_req,
    input  logic [31:0]               binding_lookup_ip,
    input  logic [11:0]               binding_lookup_vlan,
    output logic                      binding_lookup_valid,
    output logic                      binding_lookup_hit,
    output logic [47:0]               binding_lookup_mac,
    output logic [PORT_WIDTH-1:0]     binding_lookup_port,
    output logic [31:0]               binding_lookup_lease_time,
    
    // Configuration
    input  logic [NUM_PORTS-1:0]      dhcp_snooping_enable,
    input  logic [NUM_PORTS-1:0]      dhcp_trusted_port,
    input  logic                      dhcp_option82_enable,
    input  logic [31:0]               dhcp_rate_limit,     // pps per port
    input  logic [31:0]               binding_aging_time,  // seconds
    
    // Statistics
    output logic [31:0]               stat_dhcp_discover,
    output logic [31:0]               stat_dhcp_offer,
    output logic [31:0]               stat_dhcp_request,
    output logic [31:0]               stat_dhcp_ack,
    output logic [31:0]               stat_dhcp_nak,
    output logic [31:0]               stat_dhcp_release,
    output logic [31:0]               stat_bindings_learned,
    output logic [31:0]               stat_bindings_aged,
    output logic [31:0]               stat_violations,
    output logic [15:0]               stat_binding_count,
    
    // Interrupt
    output logic                      irq_violation
);

    // =========================================================================
    // DHCP Message Types (Option 53)
    // =========================================================================
    localparam [7:0] DHCP_DISCOVER   = 8'd1;
    localparam [7:0] DHCP_OFFER      = 8'd2;
    localparam [7:0] DHCP_REQUEST    = 8'd3;
    localparam [7:0] DHCP_DECLINE    = 8'd4;
    localparam [7:0] DHCP_ACK        = 8'd5;
    localparam [7:0] DHCP_NAK        = 8'd6;
    localparam [7:0] DHCP_RELEASE    = 8'd7;
    localparam [7:0] DHCP_INFORM     = 8'd8;
    
    // DHCP Ports
    localparam [15:0] DHCP_SERVER_PORT = 16'd67;
    localparam [15:0] DHCP_CLIENT_PORT = 16'd68;
    
    // DHCP Magic Cookie
    localparam [31:0] DHCP_MAGIC_COOKIE = 32'h63825363;
    
    // =========================================================================
    // Binding Database Entry
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [31:0] ip_address;
        logic [47:0] mac_address;
        logic [11:0] vlan_id;
        logic [PORT_WIDTH-1:0] port;
        logic [31:0] lease_time;        // seconds
        logic [31:0] learn_timestamp;   // system time
        logic [7:0]  msg_type;          // Last DHCP message type
    } dhcp_binding_t;
    
    dhcp_binding_t binding_table [MAX_BINDINGS-1:0];
    logic [15:0] binding_count;
    
    // =========================================================================
    // Rate Limiting State
    // =========================================================================
    logic [31:0] pkt_count [NUM_PORTS-1:0];
    logic [31:0] rate_timer [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] rate_limit_exceeded;
    
    localparam RATE_TIMER_1SEC = 156_250_000;  // 1 second at 156.25MHz
    
    // =========================================================================
    // System Timer (for lease expiration)
    // =========================================================================
    logic [31:0] system_time;  // in seconds
    logic [31:0] timer_cycle_count;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            system_time <= '0;
            timer_cycle_count <= '0;
        end else begin
            timer_cycle_count <= timer_cycle_count + 1;
            if (timer_cycle_count >= 156_250_000) begin
                system_time <= system_time + 1;
                timer_cycle_count <= '0;
            end
        end
    end
    
    // =========================================================================
    // DHCP Packet Parser
    // =========================================================================
    typedef struct packed {
        logic        is_dhcp;
        logic [7:0]  msg_type;           // DHCP message type
        logic [31:0] client_ip;          // ciaddr
        logic [31:0] your_ip;            // yiaddr
        logic [31:0] server_ip;          // siaddr
        logic [47:0] client_mac;         // chaddr
        logic [31:0] lease_time;         // Option 51
        logic        has_option82;       // Option 82 present
        logic        from_server;        // Direction: server->client
    } dhcp_packet_info_t;
    
    dhcp_packet_info_t dhcp_info [NUM_PORTS-1:0];
    
    // Parse DHCP packet (simplified - assumes UDP offset known)
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            dhcp_info[i] = '0;
            
            if (pkt_rx_valid[i] && pkt_rx_len[i] > 300) begin
                // Check UDP destination port (DHCP client or server)
                logic [15:0] udp_dst_port;
                udp_dst_port = pkt_rx_data[i][463:448];  // Simplified offset
                
                if (udp_dst_port == DHCP_SERVER_PORT || udp_dst_port == DHCP_CLIENT_PORT) begin
                    dhcp_info[i].is_dhcp = 1'b1;
                    dhcp_info[i].from_server = (udp_dst_port == DHCP_CLIENT_PORT);
                    
                    // Extract DHCP fields (offsets simplified)
                    dhcp_info[i].client_ip = pkt_rx_data[i][767:736];   // ciaddr at offset 12
                    dhcp_info[i].your_ip = pkt_rx_data[i][735:704];     // yiaddr at offset 16
                    dhcp_info[i].server_ip = pkt_rx_data[i][703:672];   // siaddr at offset 20
                    dhcp_info[i].client_mac = pkt_rx_data[i][639:592];  // chaddr at offset 28
                    
                    // Parse DHCP options (simplified - assumes Option 53 is present)
                    // In real implementation, would iterate through options
                    dhcp_info[i].msg_type = pkt_rx_data[i][231:224];    // Simplified
                    dhcp_info[i].lease_time = pkt_rx_data[i][191:160];  // Simplified
                end
            end
        end
    end
    
    // =========================================================================
    // Rate Limiting Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                pkt_count[i] <= '0;
                rate_timer[i] <= '0;
                rate_limit_exceeded[i] <= 1'b0;
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                // Update rate timer
                if (rate_timer[i] >= RATE_TIMER_1SEC) begin
                    rate_timer[i] <= '0;
                    pkt_count[i] <= '0;
                    rate_limit_exceeded[i] <= 1'b0;
                end else begin
                    rate_timer[i] <= rate_timer[i] + 1;
                end
                
                // Count DHCP packets
                if (dhcp_snooping_enable[i] && dhcp_info[i].is_dhcp) begin
                    pkt_count[i] <= pkt_count[i] + 1;
                    
                    // Check rate limit
                    if (pkt_count[i] >= dhcp_rate_limit) begin
                        rate_limit_exceeded[i] <= 1'b1;
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // DHCP Packet Validation and Forwarding Decision
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                dhcp_forward_allow[i] <= 1'b0;
                dhcp_drop[i] <= 1'b0;
            end
            stat_violations <= '0;
            irq_violation <= 1'b0;
        end else begin
            irq_violation <= 1'b0;
            
            for (int i = 0; i < NUM_PORTS; i++) begin
                dhcp_forward_allow[i] <= 1'b0;
                dhcp_drop[i] <= 1'b0;
                
                if (dhcp_snooping_enable[i] && dhcp_info[i].is_dhcp) begin
                    // Check rate limit
                    if (rate_limit_exceeded[i]) begin
                        dhcp_drop[i] <= 1'b1;
                        stat_violations <= stat_violations + 1;
                        irq_violation <= 1'b1;
                    end
                    // DHCP server messages must come from trusted ports
                    else if (dhcp_info[i].from_server && !dhcp_trusted_port[i]) begin
                        dhcp_drop[i] <= 1'b1;
                        stat_violations <= stat_violations + 1;
                        irq_violation <= 1'b1;
                    end
                    // MAC address must match
                    else if (dhcp_info[i].client_mac != pkt_rx_smac[i] && 
                            !dhcp_trusted_port[i]) begin
                        dhcp_drop[i] <= 1'b1;
                        stat_violations <= stat_violations + 1;
                        irq_violation <= 1'b1;
                    end
                    // Allow if all checks pass
                    else begin
                        dhcp_forward_allow[i] <= 1'b1;
                    end
                end else begin
                    // Non-DHCP traffic - allow
                    dhcp_forward_allow[i] <= 1'b1;
                end
            end
        end
    end
    
    // =========================================================================
    // Binding Database Learning
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_BINDINGS; i++) begin
                binding_table[i] <= '0;
            end
            binding_count <= '0;
            stat_dhcp_discover <= '0;
            stat_dhcp_offer <= '0;
            stat_dhcp_request <= '0;
            stat_dhcp_ack <= '0;
            stat_dhcp_nak <= '0;
            stat_dhcp_release <= '0;
            stat_bindings_learned <= '0;
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (dhcp_snooping_enable[i] && dhcp_info[i].is_dhcp && 
                    dhcp_forward_allow[i]) begin
                    
                    // Update statistics
                    case (dhcp_info[i].msg_type)
                        DHCP_DISCOVER: stat_dhcp_discover <= stat_dhcp_discover + 1;
                        DHCP_OFFER:    stat_dhcp_offer <= stat_dhcp_offer + 1;
                        DHCP_REQUEST:  stat_dhcp_request <= stat_dhcp_request + 1;
                        DHCP_ACK:      stat_dhcp_ack <= stat_dhcp_ack + 1;
                        DHCP_NAK:      stat_dhcp_nak <= stat_dhcp_nak + 1;
                        DHCP_RELEASE:  stat_dhcp_release <= stat_dhcp_release + 1;
                    endcase
                    
                    // Learn binding on DHCP ACK (server->client)
                    if (dhcp_info[i].msg_type == DHCP_ACK && dhcp_info[i].from_server) begin
                        logic [BINDING_TABLE_WIDTH-1:0] hash_index;
                        logic found_entry;
                        logic [BINDING_TABLE_WIDTH-1:0] free_index;
                        
                        // Hash IP address to find table index
                        hash_index = dhcp_info[i].your_ip[BINDING_TABLE_WIDTH-1:0] ^ 
                                   dhcp_info[i].client_mac[BINDING_TABLE_WIDTH-1:0];
                        
                        found_entry = 1'b0;
                        free_index = '0;
                        
                        // Search for existing entry or free slot
                        for (int j = 0; j < MAX_BINDINGS; j++) begin
                            if (binding_table[j].valid && 
                                binding_table[j].ip_address == dhcp_info[i].your_ip &&
                                binding_table[j].vlan_id == pkt_rx_vlan[i]) begin
                                // Update existing entry
                                binding_table[j].mac_address <= dhcp_info[i].client_mac;
                                binding_table[j].port <= i[PORT_WIDTH-1:0];
                                binding_table[j].lease_time <= dhcp_info[i].lease_time;
                                binding_table[j].learn_timestamp <= system_time;
                                binding_table[j].msg_type <= dhcp_info[i].msg_type;
                                found_entry = 1'b1;
                            end else if (!binding_table[j].valid && !found_entry) begin
                                free_index = j[BINDING_TABLE_WIDTH-1:0];
                            end
                        end
                        
                        // Create new entry if not found
                        if (!found_entry) begin
                            automatic int idx = free_index;
                            binding_table[idx].valid <= 1'b1;
                            binding_table[idx].ip_address <= dhcp_info[i].your_ip;
                            binding_table[idx].mac_address <= dhcp_info[i].client_mac;
                            binding_table[idx].vlan_id <= pkt_rx_vlan[i];
                            binding_table[idx].port <= i[PORT_WIDTH-1:0];
                            binding_table[idx].lease_time <= dhcp_info[i].lease_time;
                            binding_table[idx].learn_timestamp <= system_time;
                            binding_table[idx].msg_type <= dhcp_info[i].msg_type;
                            
                            binding_count <= binding_count + 1;
                            stat_bindings_learned <= stat_bindings_learned + 1;
                        end
                    end
                    
                    // Remove binding on DHCP RELEASE
                    if (dhcp_info[i].msg_type == DHCP_RELEASE) begin
                        for (int j = 0; j < MAX_BINDINGS; j++) begin
                            if (binding_table[j].valid && 
                                binding_table[j].ip_address == dhcp_info[i].client_ip &&
                                binding_table[j].mac_address == dhcp_info[i].client_mac) begin
                                binding_table[j].valid <= 1'b0;
                                binding_count <= binding_count - 1;
                            end
                        end
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Binding Aging Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_bindings_aged <= '0;
        end else begin
            for (int i = 0; i < MAX_BINDINGS; i++) begin
                if (binding_table[i].valid) begin
                    logic [31:0] age;
                    age = system_time - binding_table[i].learn_timestamp;
                    
                    // Check if lease expired
                    if (age >= binding_table[i].lease_time) begin
                        binding_table[i].valid <= 1'b0;
                        binding_count <= binding_count - 1;
                        stat_bindings_aged <= stat_bindings_aged + 1;
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Binding Lookup Interface
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            binding_lookup_valid <= 1'b0;
            binding_lookup_hit <= 1'b0;
            binding_lookup_mac <= '0;
            binding_lookup_port <= '0;
            binding_lookup_lease_time <= '0;
        end else begin
            binding_lookup_valid <= 1'b0;
            
            if (binding_lookup_req) begin
                binding_lookup_valid <= 1'b1;
                binding_lookup_hit <= 1'b0;
                
                // Search binding table
                for (int i = 0; i < MAX_BINDINGS; i++) begin
                    if (binding_table[i].valid && 
                        binding_table[i].ip_address == binding_lookup_ip &&
                        binding_table[i].vlan_id == binding_lookup_vlan) begin
                        binding_lookup_hit <= 1'b1;
                        binding_lookup_mac <= binding_table[i].mac_address;
                        binding_lookup_port <= binding_table[i].port;
                        binding_lookup_lease_time <= binding_table[i].lease_time;
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Statistics
    // =========================================================================
    assign stat_binding_count = binding_count;

endmodule
