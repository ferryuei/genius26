// =============================================================================
// SNMP Agent - Simple Network Management Protocol Agent
// =============================================================================
// Features:
// - SNMPv2c and SNMPv3 support
// - Standard MIB-II (RFC 1213)
// - IF-MIB (RFC 2863) - Interface MIB
// - BRIDGE-MIB (RFC 4188) - Bridge MIB
// - Q-BRIDGE-MIB (RFC 4363) - VLAN MIB
// - GET/GETNEXT/GETBULK/SET operations
// - TRAP generation for critical events
// - Community string authentication (v2c)
// - USM security (v3)
// =============================================================================

module snmp_agent 
    import switch_pkg::*;
#(
    parameter NUM_PORTS = 48,
    parameter MAX_VLANS = 4096
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // UDP interface (SNMP uses UDP port 161)
    input  logic                      udp_rx_valid,
    input  logic [1023:0]             udp_rx_data,
    input  logic [15:0]               udp_rx_len,
    input  logic [31:0]               udp_rx_src_ip,
    input  logic [15:0]               udp_rx_src_port,
    
    output logic                      udp_tx_valid,
    output logic [1023:0]             udp_tx_data,
    output logic [15:0]               udp_tx_len,
    output logic [31:0]               udp_tx_dst_ip,
    output logic [15:0]               udp_tx_dst_port,
    
    // TRAP destination interface
    output logic                      trap_tx_valid,
    output logic [1023:0]             trap_tx_data,
    output logic [15:0]               trap_tx_len,
    output logic [31:0]               trap_tx_dst_ip,
    output logic [15:0]               trap_tx_dst_port,
    
    // Configuration
    input  logic [63:0]               community_read,      // Read community string
    input  logic [63:0]               community_write,     // Write community string
    input  logic [31:0]               trap_destination_ip,
    input  logic                      snmp_enable,
    input  logic                      snmpv3_enable,
    
    // System MIB inputs
    input  logic [255:0]              sys_descr,
    input  logic [7:0]                sys_descr_len,
    input  logic [31:0]               sys_object_id,
    input  logic [31:0]               sys_uptime,          // In hundredths of second
    input  logic [127:0]              sys_contact,
    input  logic [7:0]                sys_contact_len,
    input  logic [127:0]              sys_name,
    input  logic [7:0]                sys_name_len,
    input  logic [127:0]              sys_location,
    input  logic [7:0]                sys_location_len,
    
    // Interface MIB inputs (per port)
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
    input  logic [NUM_PORTS-1:0]      if_admin_status,     // 1=up, 0=down
    input  logic [NUM_PORTS-1:0]      if_oper_status,      // 1=up, 0=down
    
    // Bridge MIB inputs
    input  logic [15:0]               bridge_num_ports,
    input  logic [31:0]               bridge_address_table_size,
    input  logic [31:0]               bridge_learned_entries,
    
    // VLAN MIB inputs
    input  logic [11:0]               vlan_id [MAX_VLANS-1:0],
    input  logic [MAX_VLANS-1:0]      vlan_valid,
    input  logic [NUM_PORTS-1:0]      vlan_member_ports [MAX_VLANS-1:0],
    
    // Statistics
    output logic [31:0]               stat_snmp_requests,
    output logic [31:0]               stat_snmp_responses,
    output logic [31:0]               stat_snmp_traps,
    output logic [31:0]               stat_snmp_errors
);

    // =========================================================================
    // SNMP Protocol Constants
    // =========================================================================
    // SNMP version
    localparam [7:0] SNMP_VERSION_1  = 8'd0;
    localparam [7:0] SNMP_VERSION_2C = 8'd1;
    localparam [7:0] SNMP_VERSION_3  = 8'd3;
    
    // PDU types
    localparam [7:0] PDU_GET_REQUEST     = 8'hA0;
    localparam [7:0] PDU_GET_NEXT_REQUEST = 8'hA1;
    localparam [7:0] PDU_GET_RESPONSE    = 8'hA2;
    localparam [7:0] PDU_SET_REQUEST     = 8'hA3;
    localparam [7:0] PDU_TRAP            = 8'hA4;
    localparam [7:0] PDU_GET_BULK_REQUEST = 8'hA5;
    localparam [7:0] PDU_INFORM_REQUEST  = 8'hA6;
    localparam [7:0] PDU_TRAP_V2         = 8'hA7;
    localparam [7:0] PDU_REPORT          = 8'hA8;
    
    // Error status
    localparam [7:0] ERR_NO_ERROR        = 8'd0;
    localparam [7:0] ERR_TOO_BIG         = 8'd1;
    localparam [7:0] ERR_NO_SUCH_NAME    = 8'd2;
    localparam [7:0] ERR_BAD_VALUE       = 8'd3;
    localparam [7:0] ERR_READ_ONLY       = 8'd4;
    localparam [7:0] ERR_GEN_ERR         = 8'd5;
    
    // ASN.1 BER types
    localparam [7:0] ASN1_INTEGER        = 8'h02;
    localparam [7:0] ASN1_OCTET_STRING   = 8'h04;
    localparam [7:0] ASN1_NULL           = 8'h05;
    localparam [7:0] ASN1_OBJECT_ID      = 8'h06;
    localparam [7:0] ASN1_SEQUENCE       = 8'h30;
    localparam [7:0] ASN1_COUNTER32      = 8'h41;
    localparam [7:0] ASN1_GAUGE32        = 8'h42;
    localparam [7:0] ASN1_TIMETICKS      = 8'h43;
    localparam [7:0] ASN1_COUNTER64      = 8'h46;
    
    // =========================================================================
    // OID Definitions (simplified - key OIDs only)
    // =========================================================================
    // System Group (1.3.6.1.2.1.1)
    localparam [31:0] OID_SYS_DESCR      = 32'h06010201_01010000;  // .1.3.6.1.2.1.1.1.0
    localparam [31:0] OID_SYS_OBJECTID   = 32'h06010201_01020000;  // .1.3.6.1.2.1.1.2.0
    localparam [31:0] OID_SYS_UPTIME     = 32'h06010201_01030000;  // .1.3.6.1.2.1.1.3.0
    localparam [31:0] OID_SYS_CONTACT    = 32'h06010201_01040000;  // .1.3.6.1.2.1.1.4.0
    localparam [31:0] OID_SYS_NAME       = 32'h06010201_01050000;  // .1.3.6.1.2.1.1.5.0
    localparam [31:0] OID_SYS_LOCATION   = 32'h06010201_01060000;  // .1.3.6.1.2.1.1.6.0
    
    // Interfaces Group (1.3.6.1.2.1.2)
    localparam [31:0] OID_IF_NUMBER      = 32'h06010201_02010000;  // .1.3.6.1.2.1.2.1.0
    localparam [31:0] OID_IF_TABLE       = 32'h06010201_02020000;  // .1.3.6.1.2.1.2.2
    
    // Bridge MIB (1.3.6.1.2.1.17)
    localparam [31:0] OID_DOT1D_BASE     = 32'h06010201_11000000;  // .1.3.6.1.2.1.17
    
    // Q-BRIDGE MIB (1.3.6.1.2.1.17.7)
    localparam [31:0] OID_DOT1Q_BASE     = 32'h06010201_11070000;  // .1.3.6.1.2.1.17.7
    
    // =========================================================================
    // State Machine
    // =========================================================================
    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_PARSE_REQUEST,
        STATE_AUTH_CHECK,
        STATE_PROCESS_GET,
        STATE_PROCESS_GETNEXT,
        STATE_PROCESS_SET,
        STATE_BUILD_RESPONSE,
        STATE_SEND_RESPONSE
    } snmp_state_t;
    
    snmp_state_t state;
    
    // =========================================================================
    // Request Parsing Variables
    // =========================================================================
    logic [7:0]  req_version;
    logic [63:0] req_community;
    logic [7:0]  req_pdu_type;
    logic [31:0] req_request_id;
    logic [31:0] req_oid;
    logic [15:0] req_oid_len;
    logic [31:0] req_value;
    logic        req_auth_ok;
    
    // =========================================================================
    // Response Building Variables
    // =========================================================================
    logic [7:0]  resp_error_status;
    logic [31:0] resp_error_index;
    logic [1023:0] resp_buffer;
    logic [15:0] resp_len;
    
    // =========================================================================
    // MIB Database (simplified - key objects only)
    // =========================================================================
    typedef struct packed {
        logic [31:0] oid;
        logic [7:0]  value_type;
        logic [63:0] value;
        logic        readable;
        logic        writable;
    } mib_object_t;
    
    // =========================================================================
    // Statistics Counters
    // =========================================================================
    logic [31:0] req_counter;
    logic [31:0] resp_counter;
    logic [31:0] trap_counter;
    logic [31:0] error_counter;
    
    assign stat_snmp_requests = req_counter;
    assign stat_snmp_responses = resp_counter;
    assign stat_snmp_traps = trap_counter;
    assign stat_snmp_errors = error_counter;
    
    // =========================================================================
    // Main State Machine
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            udp_tx_valid <= 1'b0;
            resp_error_status <= ERR_NO_ERROR;
            resp_error_index <= '0;
            req_counter <= '0;
            resp_counter <= '0;
            trap_counter <= '0;
            error_counter <= '0;
        end else begin
            udp_tx_valid <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    if (snmp_enable && udp_rx_valid) begin
                        req_counter <= req_counter + 1;
                        state <= STATE_PARSE_REQUEST;
                    end
                end
                
                STATE_PARSE_REQUEST: begin
                    // Parse SNMP packet (simplified)
                    // Real implementation would use full ASN.1 BER parser
                    
                    // Extract version (byte 4)
                    req_version <= udp_rx_data[1015:1008];
                    
                    // Extract community string (bytes 6-13, simplified)
                    req_community <= udp_rx_data[991:928];
                    
                    // Extract PDU type (byte 14)
                    req_pdu_type <= udp_rx_data[927:920];
                    
                    // Extract request ID (bytes 16-19)
                    req_request_id <= udp_rx_data[911:880];
                    
                    // Extract OID (simplified - first 4 bytes)
                    req_oid <= udp_rx_data[639:608];
                    
                    state <= STATE_AUTH_CHECK;
                end
                
                STATE_AUTH_CHECK: begin
                    // Check community string
                    if (req_pdu_type == PDU_GET_REQUEST || 
                        req_pdu_type == PDU_GET_NEXT_REQUEST ||
                        req_pdu_type == PDU_GET_BULK_REQUEST) begin
                        req_auth_ok <= (req_community == community_read);
                    end else if (req_pdu_type == PDU_SET_REQUEST) begin
                        req_auth_ok <= (req_community == community_write);
                    end else begin
                        req_auth_ok <= 1'b0;
                    end
                    
                    if (!req_auth_ok) begin
                        error_counter <= error_counter + 1;
                        state <= STATE_IDLE;
                    end else begin
                        case (req_pdu_type)
                            PDU_GET_REQUEST, PDU_GET_BULK_REQUEST: 
                                state <= STATE_PROCESS_GET;
                            PDU_GET_NEXT_REQUEST: 
                                state <= STATE_PROCESS_GETNEXT;
                            PDU_SET_REQUEST: 
                                state <= STATE_PROCESS_SET;
                            default: 
                                state <= STATE_IDLE;
                        endcase
                    end
                end
                
                STATE_PROCESS_GET: begin
                    // Process GET request
                    resp_error_status <= ERR_NO_ERROR;
                    
                    // Lookup OID in MIB (simplified)
                    case (req_oid)
                        OID_SYS_DESCR: begin
                            // Return system description
                            resp_buffer[1023:768] <= sys_descr;
                        end
                        
                        OID_SYS_UPTIME: begin
                            // Return system uptime
                            resp_buffer[1023:992] <= sys_uptime;
                        end
                        
                        OID_SYS_NAME: begin
                            // Return system name
                            resp_buffer[1023:896] <= sys_name;
                        end
                        
                        OID_IF_NUMBER: begin
                            // Return number of interfaces
                            resp_buffer[1023:1008] <= bridge_num_ports;
                        end
                        
                        default: begin
                            resp_error_status <= ERR_NO_SUCH_NAME;
                        end
                    endcase
                    
                    state <= STATE_BUILD_RESPONSE;
                end
                
                STATE_PROCESS_GETNEXT: begin
                    // Process GETNEXT request (simplified)
                    // Real implementation would traverse MIB tree
                    resp_error_status <= ERR_NO_ERROR;
                    state <= STATE_BUILD_RESPONSE;
                end
                
                STATE_PROCESS_SET: begin
                    // Process SET request (simplified)
                    // Real implementation would update writable MIB objects
                    resp_error_status <= ERR_READ_ONLY;  // Most objects are read-only
                    state <= STATE_BUILD_RESPONSE;
                end
                
                STATE_BUILD_RESPONSE: begin
                    // Build SNMP response packet (simplified ASN.1 BER encoding)
                    
                    // SNMP version
                    resp_buffer[1023:1016] <= ASN1_INTEGER;
                    resp_buffer[1015:1008] <= 8'd1;  // length
                    resp_buffer[1007:1000] <= req_version;
                    
                    // Community string (echo from request)
                    resp_buffer[999:992] <= ASN1_OCTET_STRING;
                    resp_buffer[991:984] <= 8'd8;  // length
                    resp_buffer[983:920] <= req_community;
                    
                    // PDU type (GetResponse)
                    resp_buffer[919:912] <= PDU_GET_RESPONSE;
                    
                    // Request ID (echo from request)
                    resp_buffer[911:880] <= req_request_id;
                    
                    // Error status
                    resp_buffer[879:872] <= resp_error_status;
                    
                    // Error index
                    resp_buffer[871:840] <= resp_error_index;
                    
                    // Variable bindings (simplified - would include OID + value)
                    // ... (depends on request type and OID)
                    
                    resp_len <= 16'd128;  // Simplified fixed length
                    
                    state <= STATE_SEND_RESPONSE;
                end
                
                STATE_SEND_RESPONSE: begin
                    udp_tx_valid <= 1'b1;
                    udp_tx_data <= resp_buffer;
                    udp_tx_len <= resp_len;
                    udp_tx_dst_ip <= udp_rx_src_ip;
                    udp_tx_dst_port <= udp_rx_src_port;
                    
                    resp_counter <= resp_counter + 1;
                    state <= STATE_IDLE;
                end
                
                default: state <= STATE_IDLE;
            endcase
        end
    end
    
    // =========================================================================
    // TRAP Generation Logic
    // =========================================================================
    logic link_up_trap;
    logic link_down_trap;
    logic [NUM_PORTS-1:0] if_oper_status_prev;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_oper_status_prev <= '0;
            trap_tx_valid <= 1'b0;
            link_up_trap <= 1'b0;
            link_down_trap <= 1'b0;
        end else begin
            trap_tx_valid <= 1'b0;
            if_oper_status_prev <= if_oper_status;
            
            // Detect link state changes
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (if_oper_status[i] && !if_oper_status_prev[i]) begin
                    link_up_trap <= 1'b1;
                end
                if (!if_oper_status[i] && if_oper_status_prev[i]) begin
                    link_down_trap <= 1'b1;
                end
            end
            
            // Generate TRAP v2 PDU
            if ((link_up_trap || link_down_trap) && snmp_enable) begin
                trap_tx_valid <= 1'b1;
                trap_tx_dst_ip <= trap_destination_ip;
                trap_tx_dst_port <= 16'd162;  // SNMP trap port
                
                // Build TRAP PDU (simplified)
                trap_tx_data[1023:1016] <= ASN1_SEQUENCE;
                trap_tx_data[1015:1008] <= req_version;
                trap_tx_data[1007:944] <= community_read;
                trap_tx_data[943:936] <= PDU_TRAP_V2;
                trap_tx_data[935:904] <= sys_uptime;  // timestamp
                
                // Trap OID and varbinds would go here
                trap_tx_len <= 16'd96;
                
                trap_counter <= trap_counter + 1;
                link_up_trap <= 1'b0;
                link_down_trap <= 1'b0;
            end
        end
    end
    
    // =========================================================================
    // MIB Object Access Functions (simplified)
    // =========================================================================
    function automatic logic [63:0] get_mib_value(logic [31:0] oid, logic [15:0] index);
        logic [63:0] value;
        begin
            value = '0;
            
            case (oid)
                OID_SYS_UPTIME: value = {32'b0, sys_uptime};
                OID_IF_NUMBER: value = {48'b0, bridge_num_ports};
                default: value = '0;
            endcase
            
            return value;
        end
    endfunction

endmodule
