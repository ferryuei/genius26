// =============================================================================
// 802.1X Engine - Port-Based Network Access Control (IEEE 802.1X-2010)
// =============================================================================
// Features:
// - IEEE 802.1X-2010 Authenticator implementation
// - PAE (Port Access Entity) state machines
// - Authenticator state machine
// - Backend authentication state machine
// - Re-authentication timer
// - EAPOL frame processing (EAP over LAN)
// - Controlled/Uncontrolled port model
// - RADIUS client interface for authentication server
// - Guest VLAN support for unauthorized devices
// - MAC-based authentication bypass (MAB)
// - Port security with violation actions
// =============================================================================

module dot1x_engine 
    import switch_pkg::*;
#(
    parameter NUM_PORTS = 48,
    parameter REAUTH_PERIOD = 3600,    // seconds (default 1 hour)
    parameter QUIET_PERIOD = 60,        // seconds
    parameter TX_PERIOD = 30            // seconds
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Port interface
    input  logic [NUM_PORTS-1:0]      port_enable,
    input  logic [NUM_PORTS-1:0]      port_link_up,
    
    // EAPOL frame interface
    input  logic [NUM_PORTS-1:0]      eapol_rx_valid,
    input  logic [1023:0]             eapol_rx_data [NUM_PORTS-1:0],
    input  logic [15:0]               eapol_rx_len [NUM_PORTS-1:0],
    input  logic [47:0]               eapol_rx_src_mac [NUM_PORTS-1:0],
    
    output logic [NUM_PORTS-1:0]      eapol_tx_valid,
    output logic [1023:0]             eapol_tx_data [NUM_PORTS-1:0],
    output logic [15:0]               eapol_tx_len [NUM_PORTS-1:0],
    output logic [47:0]               eapol_tx_dst_mac [NUM_PORTS-1:0],
    
    // RADIUS interface (simplified)
    output logic [NUM_PORTS-1:0]      radius_req_valid,
    output logic [47:0]               radius_req_mac [NUM_PORTS-1:0],
    output logic [127:0]              radius_req_identity [NUM_PORTS-1:0],
    output logic [255:0]              radius_req_credentials [NUM_PORTS-1:0],
    
    input  logic [NUM_PORTS-1:0]      radius_resp_valid,
    input  logic                      radius_resp_accept [NUM_PORTS-1:0],
    input  logic [11:0]               radius_resp_vlan [NUM_PORTS-1:0],
    
    // Configuration
    input  logic [NUM_PORTS-1:0]      dot1x_enable,
    input  logic [NUM_PORTS-1:0]      mab_enable,          // MAC Authentication Bypass
    input  logic [NUM_PORTS-1:0]      reauth_enable,
    input  logic [31:0]               reauth_period_cfg,   // configurable reauth period
    input  logic [11:0]               guest_vlan_id,       // VLAN for unauthorized devices
    
    // Port authorization status
    output logic [NUM_PORTS-1:0]      port_authorized,
    output logic [NUM_PORTS-1:0]      port_authenticating,
    output logic [47:0]               authenticated_mac [NUM_PORTS-1:0],
    output logic [11:0]               dynamic_vlan [NUM_PORTS-1:0],
    
    // Port security
    input  logic [NUM_PORTS-1:0]      port_security_enable,
    input  logic [7:0]                max_mac_per_port [NUM_PORTS-1:0],
    output logic [NUM_PORTS-1:0]      security_violation
);

    // =========================================================================
    // EAPOL Packet Type Definitions (IEEE 802.1X)
    // =========================================================================
    localparam [7:0] EAPOL_TYPE_EAP_PACKET      = 8'h00;
    localparam [7:0] EAPOL_TYPE_START           = 8'h01;
    localparam [7:0] EAPOL_TYPE_LOGOFF          = 8'h02;
    localparam [7:0] EAPOL_TYPE_KEY             = 8'h03;
    localparam [7:0] EAPOL_TYPE_ASF_ALERT       = 8'h04;
    
    // EAP Code values
    localparam [7:0] EAP_CODE_REQUEST           = 8'h01;
    localparam [7:0] EAP_CODE_RESPONSE          = 8'h02;
    localparam [7:0] EAP_CODE_SUCCESS           = 8'h03;
    localparam [7:0] EAP_CODE_FAILURE           = 8'h04;
    
    // EAP Type values
    localparam [7:0] EAP_TYPE_IDENTITY          = 8'h01;
    localparam [7:0] EAP_TYPE_NAK               = 8'h03;
    localparam [7:0] EAP_TYPE_MD5_CHALLENGE     = 8'h04;
    localparam [7:0] EAP_TYPE_TLS               = 8'h0D;
    localparam [7:0] EAP_TYPE_PEAP              = 8'h19;
    
    // EAPOL version
    localparam [7:0] EAPOL_VERSION              = 8'h02;  // 802.1X-2010
    
    // =========================================================================
    // Authenticator State Machine States
    // =========================================================================
    typedef enum logic [3:0] {
        AUTH_INITIALIZE,
        AUTH_DISCONNECTED,
        AUTH_CONNECTING,
        AUTH_AUTHENTICATING,
        AUTH_AUTHENTICATED,
        AUTH_ABORTING,
        AUTH_HELD,
        AUTH_FORCE_AUTH,
        AUTH_FORCE_UNAUTH
    } auth_state_t;
    
    auth_state_t auth_state [NUM_PORTS-1:0];
    
    // =========================================================================
    // Backend Authentication State Machine States
    // =========================================================================
    typedef enum logic [2:0] {
        BACKEND_IDLE,
        BACKEND_REQUEST,
        BACKEND_RESPONSE,
        BACKEND_SUCCESS,
        BACKEND_FAIL,
        BACKEND_TIMEOUT,
        BACKEND_IGNORE
    } backend_state_t;
    
    backend_state_t backend_state [NUM_PORTS-1:0];
    
    // =========================================================================
    // Supplicant Information
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [47:0] mac_address;
        logic [127:0] identity;
        logic [7:0]  eap_id;
        logic [31:0] session_timeout;
        logic [11:0] assigned_vlan;
        logic        authenticated;
    } supplicant_info_t;
    
    supplicant_info_t supplicant [NUM_PORTS-1:0];
    
    // =========================================================================
    // Timers
    // =========================================================================
    logic [31:0] reauth_timer [NUM_PORTS-1:0];
    logic [31:0] quiet_timer [NUM_PORTS-1:0];
    logic [31:0] tx_timer [NUM_PORTS-1:0];
    logic [31:0] auth_timeout_timer [NUM_PORTS-1:0];
    
    logic [31:0] reauth_period_cycles;
    logic [31:0] quiet_period_cycles;
    logic [31:0] tx_period_cycles;
    logic [31:0] auth_timeout_cycles;
    
    // Convert to clock cycles (assuming 156.25MHz)
    assign reauth_period_cycles = reauth_period_cfg * 156_250_000;
    assign quiet_period_cycles = QUIET_PERIOD * 156_250_000;
    assign tx_period_cycles = TX_PERIOD * 156_250_000;
    assign auth_timeout_cycles = 30 * 156_250_000; // 30 second timeout
    
    // =========================================================================
    // Port Security - MAC Address Table per Port
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [47:0] mac_address;
    } port_mac_entry_t;
    
    port_mac_entry_t port_mac_table [NUM_PORTS-1:0][7:0]; // Max 8 MACs per port
    logic [7:0] mac_count [NUM_PORTS-1:0];
    
    // =========================================================================
    // Authenticator State Machine
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                auth_state[i] <= AUTH_INITIALIZE;
                supplicant[i] <= '0;
                reauth_timer[i] <= '0;
                quiet_timer[i] <= '0;
                tx_timer[i] <= '0;
                auth_timeout_timer[i] <= '0;
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                // Timer updates
                if (reauth_enable[i] && auth_state[i] == AUTH_AUTHENTICATED) begin
                    if (reauth_timer[i] >= reauth_period_cycles) begin
                        reauth_timer[i] <= '0;
                    end else begin
                        reauth_timer[i] <= reauth_timer[i] + 1;
                    end
                end
                
                if (quiet_timer[i] > 0) begin
                    quiet_timer[i] <= quiet_timer[i] - 1;
                end
                
                if (tx_timer[i] > 0) begin
                    tx_timer[i] <= tx_timer[i] - 1;
                end
                
                if (auth_timeout_timer[i] > 0) begin
                    auth_timeout_timer[i] <= auth_timeout_timer[i] - 1;
                end
                
                // State machine
                case (auth_state[i])
                    AUTH_INITIALIZE: begin
                        supplicant[i] <= '0;
                        reauth_timer[i] <= '0;
                        
                        if (port_enable[i] && port_link_up[i]) begin
                            if (!dot1x_enable[i]) begin
                                auth_state[i] <= AUTH_FORCE_AUTH;
                            end else begin
                                auth_state[i] <= AUTH_DISCONNECTED;
                            end
                        end
                    end
                    
                    AUTH_DISCONNECTED: begin
                        supplicant[i].valid <= 1'b0;
                        supplicant[i].authenticated <= 1'b0;
                        
                        if (!port_enable[i] || !port_link_up[i]) begin
                            auth_state[i] <= AUTH_INITIALIZE;
                        end else if (eapol_rx_valid[i]) begin
                            // Received EAPOL-Start or other EAPOL frame
                            auth_state[i] <= AUTH_CONNECTING;
                        end else if (mab_enable[i]) begin
                            // MAC Authentication Bypass - auto-start authentication
                            auth_state[i] <= AUTH_CONNECTING;
                        end
                    end
                    
                    AUTH_CONNECTING: begin
                        supplicant[i].valid <= 1'b1;
                        tx_timer[i] <= tx_period_cycles;
                        auth_state[i] <= AUTH_AUTHENTICATING;
                    end
                    
                    AUTH_AUTHENTICATING: begin
                        auth_timeout_timer[i] <= auth_timeout_cycles;
                        
                        // Wait for backend authentication
                        if (backend_state[i] == BACKEND_SUCCESS) begin
                            auth_state[i] <= AUTH_AUTHENTICATED;
                            supplicant[i].authenticated <= 1'b1;
                            reauth_timer[i] <= '0;
                        end else if (backend_state[i] == BACKEND_FAIL || 
                                   auth_timeout_timer[i] == 0) begin
                            auth_state[i] <= AUTH_HELD;
                            quiet_timer[i] <= quiet_period_cycles;
                        end else if (!port_link_up[i]) begin
                            auth_state[i] <= AUTH_DISCONNECTED;
                        end
                    end
                    
                    AUTH_AUTHENTICATED: begin
                        // Check for re-authentication trigger
                        if (reauth_enable[i] && reauth_timer[i] >= reauth_period_cycles) begin
                            auth_state[i] <= AUTH_CONNECTING;
                        end else if (eapol_rx_valid[i]) begin
                            // Check for EAPOL-Logoff
                            logic [7:0] eapol_type;
                            eapol_type = eapol_rx_data[i][1015:1008];
                            if (eapol_type == EAPOL_TYPE_LOGOFF) begin
                                auth_state[i] <= AUTH_DISCONNECTED;
                            end
                        end else if (!port_link_up[i]) begin
                            auth_state[i] <= AUTH_DISCONNECTED;
                        end
                    end
                    
                    AUTH_HELD: begin
                        if (quiet_timer[i] == 0) begin
                            auth_state[i] <= AUTH_DISCONNECTED;
                        end
                    end
                    
                    AUTH_FORCE_AUTH: begin
                        // Always authorized (802.1X disabled)
                        supplicant[i].authenticated <= 1'b1;
                        if (dot1x_enable[i]) begin
                            auth_state[i] <= AUTH_DISCONNECTED;
                        end
                    end
                    
                    AUTH_FORCE_UNAUTH: begin
                        // Never authorized
                        supplicant[i].authenticated <= 1'b0;
                        if (dot1x_enable[i]) begin
                            auth_state[i] <= AUTH_DISCONNECTED;
                        end
                    end
                    
                    default: begin
                        auth_state[i] <= AUTH_INITIALIZE;
                    end
                endcase
            end
        end
    end
    
    // =========================================================================
    // Backend Authentication State Machine
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                backend_state[i] <= BACKEND_IDLE;
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                case (backend_state[i])
                    BACKEND_IDLE: begin
                        if (auth_state[i] == AUTH_AUTHENTICATING && 
                            eapol_rx_valid[i]) begin
                            backend_state[i] <= BACKEND_REQUEST;
                        end
                    end
                    
                    BACKEND_REQUEST: begin
                        // Send RADIUS request
                        backend_state[i] <= BACKEND_RESPONSE;
                    end
                    
                    BACKEND_RESPONSE: begin
                        if (radius_resp_valid[i]) begin
                            if (radius_resp_accept[i]) begin
                                backend_state[i] <= BACKEND_SUCCESS;
                                supplicant[i].assigned_vlan <= radius_resp_vlan[i];
                            end else begin
                                backend_state[i] <= BACKEND_FAIL;
                            end
                        end else if (auth_timeout_timer[i] == 0) begin
                            backend_state[i] <= BACKEND_TIMEOUT;
                        end
                    end
                    
                    BACKEND_SUCCESS: begin
                        backend_state[i] <= BACKEND_IDLE;
                    end
                    
                    BACKEND_FAIL: begin
                        backend_state[i] <= BACKEND_IDLE;
                    end
                    
                    BACKEND_TIMEOUT: begin
                        backend_state[i] <= BACKEND_IDLE;
                    end
                    
                    default: begin
                        backend_state[i] <= BACKEND_IDLE;
                    end
                endcase
            end
        end
    end
    
    // =========================================================================
    // EAPOL Transmission Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                eapol_tx_valid[i] <= 1'b0;
                eapol_tx_data[i] <= '0;
                eapol_tx_len[i] <= '0;
                eapol_tx_dst_mac[i] <= '0;
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                eapol_tx_valid[i] <= 1'b0;
                
                // Send EAP-Request/Identity when entering authenticating state
                if (auth_state[i] == AUTH_AUTHENTICATING && tx_timer[i] == 1) begin
                    eapol_tx_valid[i] <= 1'b1;
                    eapol_tx_dst_mac[i] <= supplicant[i].mac_address;
                    
                    // Build EAP-Request/Identity packet
                    // EAPOL header: Version(1) + Type(1) + Length(2)
                    // EAP header: Code(1) + ID(1) + Length(2) + Type(1)
                    eapol_tx_data[i][1023:1016] <= EAPOL_VERSION;
                    eapol_tx_data[i][1015:1008] <= EAPOL_TYPE_EAP_PACKET;
                    eapol_tx_data[i][1007:992]  <= 16'd5;  // EAP length
                    eapol_tx_data[i][991:984]   <= EAP_CODE_REQUEST;
                    eapol_tx_data[i][983:976]   <= supplicant[i].eap_id;
                    eapol_tx_data[i][975:960]   <= 16'd5;  // EAP length
                    eapol_tx_data[i][959:952]   <= EAP_TYPE_IDENTITY;
                    
                    eapol_tx_len[i] <= 16'd9; // 4 bytes EAPOL header + 5 bytes EAP
                    
                    supplicant[i].eap_id <= supplicant[i].eap_id + 1;
                end
                
                // Send EAP-Success when authenticated
                else if (backend_state[i] == BACKEND_SUCCESS) begin
                    eapol_tx_valid[i] <= 1'b1;
                    eapol_tx_dst_mac[i] <= supplicant[i].mac_address;
                    
                    eapol_tx_data[i][1023:1016] <= EAPOL_VERSION;
                    eapol_tx_data[i][1015:1008] <= EAPOL_TYPE_EAP_PACKET;
                    eapol_tx_data[i][1007:992]  <= 16'd4;
                    eapol_tx_data[i][991:984]   <= EAP_CODE_SUCCESS;
                    eapol_tx_data[i][983:976]   <= supplicant[i].eap_id;
                    eapol_tx_data[i][975:960]   <= 16'd4;
                    
                    eapol_tx_len[i] <= 16'd8;
                end
                
                // Send EAP-Failure when authentication fails
                else if (backend_state[i] == BACKEND_FAIL) begin
                    eapol_tx_valid[i] <= 1'b1;
                    eapol_tx_dst_mac[i] <= supplicant[i].mac_address;
                    
                    eapol_tx_data[i][1023:1016] <= EAPOL_VERSION;
                    eapol_tx_data[i][1015:1008] <= EAPOL_TYPE_EAP_PACKET;
                    eapol_tx_data[i][1007:992]  <= 16'd4;
                    eapol_tx_data[i][991:984]   <= EAP_CODE_FAILURE;
                    eapol_tx_data[i][983:976]   <= supplicant[i].eap_id;
                    eapol_tx_data[i][975:960]   <= 16'd4;
                    
                    eapol_tx_len[i] <= 16'd8;
                end
            end
        end
    end
    
    // =========================================================================
    // EAPOL Reception and Parsing
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                radius_req_valid[i] <= 1'b0;
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                radius_req_valid[i] <= 1'b0;
                
                if (eapol_rx_valid[i]) begin
                    logic [7:0] eapol_type;
                    logic [7:0] eap_code;
                    logic [7:0] eap_type;
                    
                    eapol_type = eapol_rx_data[i][1015:1008];
                    
                    // Store supplicant MAC
                    supplicant[i].mac_address <= eapol_rx_src_mac[i];
                    
                    if (eapol_type == EAPOL_TYPE_START) begin
                        // Supplicant initiated authentication
                        supplicant[i].valid <= 1'b1;
                        supplicant[i].eap_id <= 8'd1;
                    end
                    else if (eapol_type == EAPOL_TYPE_EAP_PACKET) begin
                        eap_code = eapol_rx_data[i][991:984];
                        
                        if (eap_code == EAP_CODE_RESPONSE) begin
                            eap_type = eapol_rx_data[i][959:952];
                            supplicant[i].eap_id <= eapol_rx_data[i][983:976];
                            
                            if (eap_type == EAP_TYPE_IDENTITY) begin
                                // Extract identity (simplified)
                                supplicant[i].identity <= eapol_rx_data[i][951:824];
                                
                                // Send RADIUS request
                                radius_req_valid[i] <= 1'b1;
                                radius_req_mac[i] <= eapol_rx_src_mac[i];
                                radius_req_identity[i] <= eapol_rx_data[i][951:824];
                            end
                        end
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Port Security - MAC Address Learning and Violation Detection
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                mac_count[i] <= '0;
                security_violation[i] <= 1'b0;
                for (int j = 0; j < 8; j++) begin
                    port_mac_table[i][j] <= '0;
                end
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                security_violation[i] <= 1'b0;
                
                if (!port_link_up[i]) begin
                    // Clear MAC table on link down
                    mac_count[i] <= '0;
                    for (int j = 0; j < 8; j++) begin
                        port_mac_table[i][j].valid <= 1'b0;
                    end
                end
                else if (port_security_enable[i] && eapol_rx_valid[i]) begin
                    logic mac_found;
                    logic [7:0] empty_slot;
                    
                    mac_found = 1'b0;
                    empty_slot = 8'hFF;
                    
                    // Check if MAC already exists
                    for (int j = 0; j < 8; j++) begin
                        if (port_mac_table[i][j].valid && 
                            port_mac_table[i][j].mac_address == eapol_rx_src_mac[i]) begin
                            mac_found = 1'b1;
                        end
                        if (!port_mac_table[i][j].valid && empty_slot == 8'hFF) begin
                            empty_slot = j[7:0];
                        end
                    end
                    
                    // Learn new MAC if not found
                    if (!mac_found) begin
                        if (mac_count[i] < max_mac_per_port[i] && empty_slot != 8'hFF) begin
                            port_mac_table[i][empty_slot].valid <= 1'b1;
                            port_mac_table[i][empty_slot].mac_address <= eapol_rx_src_mac[i];
                            mac_count[i] <= mac_count[i] + 1;
                        end else begin
                            // Violation: too many MACs
                            security_violation[i] <= 1'b1;
                        end
                    end
                end
            end
        end
    end
    
    // =========================================================================
    // Status Outputs
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            port_authorized[i] = supplicant[i].authenticated || 
                                (auth_state[i] == AUTH_FORCE_AUTH);
            port_authenticating[i] = (auth_state[i] == AUTH_AUTHENTICATING);
            authenticated_mac[i] = supplicant[i].mac_address;
            
            // Dynamic VLAN assignment
            if (supplicant[i].authenticated && supplicant[i].assigned_vlan != 0) begin
                dynamic_vlan[i] = supplicant[i].assigned_vlan;
            end else if (!supplicant[i].authenticated && guest_vlan_id != 0) begin
                dynamic_vlan[i] = guest_vlan_id;  // Assign guest VLAN
            end else begin
                dynamic_vlan[i] = 12'd1;  // Default VLAN
            end
        end
    end
    
    // =========================================================================
    // RADIUS Request Output
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            radius_req_mac[i] = supplicant[i].mac_address;
            radius_req_identity[i] = supplicant[i].identity;
            radius_req_credentials[i] = '0;  // Simplified - would contain EAP data
        end
    end

endmodule
