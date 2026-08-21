// Switch1T RTL2 architectural constants and transaction types.
// This package is intentionally independent from rtl/switch_pkg.sv.
`timescale 1ns/1ps

package switch2_pkg;

    parameter int unsigned NUM_PORTS             = 48;
    parameter int unsigned PORT_SPEED_GBPS       = 25;
    parameter int unsigned CORE_FREQUENCY_MHZ    = 500;
    parameter int unsigned PORT_DATA_WIDTH       = 64;
    parameter int unsigned PORT_DATA_BYTES       = PORT_DATA_WIDTH / 8;
    parameter int unsigned PORT_EMPTY_WIDTH      = $clog2(PORT_DATA_BYTES);
    parameter int unsigned PORT_ID_WIDTH         = $clog2(NUM_PORTS);

    parameter int unsigned CELL_BYTES            = 128;
    parameter int unsigned CELL_DATA_WIDTH       = CELL_BYTES * 8;
    parameter int unsigned CELL_VALID_BYTES_WIDTH = $clog2(CELL_BYTES + 1);
    parameter int unsigned TOTAL_CELLS           = 65536;
    parameter int unsigned CELL_ID_WIDTH         = $clog2(TOTAL_CELLS);
    parameter int unsigned NUM_MEMORY_BANKS       = 16;
    parameter int unsigned BANK_ID_WIDTH         = $clog2(NUM_MEMORY_BANKS);
    parameter int unsigned INGRESS_CELL_LANES    = 4;
    parameter int unsigned EGRESS_CELL_LANES     = 4;

    parameter int unsigned MAX_PACKET_BYTES      = 16384;
    parameter int unsigned MAX_CELLS_PER_PACKET  =
        (MAX_PACKET_BYTES + CELL_BYTES - 1) / CELL_BYTES;
    parameter int unsigned PACKET_LENGTH_WIDTH   =
        $clog2(MAX_PACKET_BYTES + 1);
    parameter int unsigned CELL_COUNT_WIDTH      =
        $clog2(MAX_CELLS_PER_PACKET + 1);
    parameter int unsigned PACKET_REF_WIDTH      = $clog2(NUM_PORTS + 1);

    // One descriptor per cell prevents descriptor starvation for minimum frames.
    parameter int unsigned DESCRIPTOR_COUNT      = TOTAL_CELLS;
    parameter int unsigned DESCRIPTOR_ID_WIDTH   = $clog2(DESCRIPTOR_COUNT);

    // Queue nodes are separate from packet descriptors so multicast destinations
    // never share a queue-link pointer. Admission control handles exhaustion.
    parameter int unsigned QUEUE_NODE_COUNT      = 131072;
    parameter int unsigned QUEUE_NODE_ID_WIDTH   = $clog2(QUEUE_NODE_COUNT);
    parameter int unsigned QUEUES_PER_PORT       = 8;
    parameter int unsigned QUEUE_ID_WIDTH        = $clog2(QUEUES_PER_PORT);
    parameter int unsigned LOOKUP_LANES          = 4;

    typedef logic [PORT_ID_WIDTH-1:0]       port_id_t;
    typedef logic [CELL_ID_WIDTH-1:0]       cell_id_t;
    typedef logic [DESCRIPTOR_ID_WIDTH-1:0] descriptor_id_t;
    typedef logic [QUEUE_NODE_ID_WIDTH-1:0] queue_node_id_t;

    typedef enum logic [1:0] {
        PORT_DISABLED,
        PORT_BLOCKING,
        PORT_LEARNING,
        PORT_FORWARDING
    } port_state_e;

    typedef enum logic [1:0] {
        VLAN_ACTION_NONE,
        VLAN_ACTION_PUSH,
        VLAN_ACTION_POP,
        VLAN_ACTION_REPLACE
    } vlan_action_e;

    typedef enum logic [3:0] {
        DROP_NONE,
        DROP_INGRESS_DISABLED,
        DROP_VLAN_FILTER,
        DROP_STP_STATE,
        DROP_ACL,
        DROP_SOURCE_FILTER,
        DROP_NO_BUFFER,
        DROP_NO_DESCRIPTOR,
        DROP_NO_QUEUE_NODE,
        DROP_EGRESS_DISABLED
    } drop_reason_e;

    typedef struct packed {
        logic [47:0] dmac;
        logic [47:0] smac;
        logic [11:0] vid;
        logic [2:0]  pcp;
        logic        dei;
        logic        vlan_tagged;
        logic [15:0] ethertype;
        logic [PACKET_LENGTH_WIDTH-1:0] packet_length;
        port_id_t src_port;
    } parsed_packet_t;

    typedef struct packed {
        logic [47:0] dmac;
        logic [47:0] smac;
        logic [11:0] vid;
        logic [2:0]  pcp;
        logic        dei;
        logic        vlan_tagged;
        logic [15:0] ethertype;
        logic [PACKET_LENGTH_WIDTH-1:0] packet_length;
        port_id_t src_port;
        descriptor_id_t descriptor_id;
    } ingress_metadata_t;

    typedef struct packed {
        logic [NUM_PORTS-1:0] destination_mask;
        logic [QUEUE_ID_WIDTH-1:0] queue_id;
        vlan_action_e vlan_action;
        logic [11:0] new_vid;
        logic [2:0] new_pcp;
        logic trap_to_cpu;
        logic mirror;
        logic drop;
        drop_reason_e drop_reason;
        descriptor_id_t descriptor_id;
    } forwarding_action_t;

    typedef struct packed {
        cell_id_t next_cell;
        logic eop;
        logic valid;
    } cell_metadata_t;

    typedef struct packed {
        logic [CELL_DATA_WIDTH-1:0] data;
        logic [CELL_VALID_BYTES_WIDTH-1:0] valid_bytes;
        logic first_cell;
        logic last_cell;
        port_id_t src_port;
    } assembled_cell_t;

    typedef struct packed {
        cell_id_t cell_id;
        assembled_cell_t payload;
    } committed_cell_t;

    typedef struct packed {
        cell_id_t head_cell;
        cell_id_t tail_cell;
        logic [CELL_COUNT_WIDTH-1:0] cell_count;
        port_id_t src_port;
    } packet_cell_chain_t;

    typedef struct packed {
        descriptor_id_t descriptor_id;
        packet_cell_chain_t chain;
        parsed_packet_t metadata;
    } admitted_packet_t;

    typedef struct packed {
        cell_id_t head_cell;
        cell_id_t tail_cell;
        logic [CELL_COUNT_WIDTH-1:0] cell_count;
        logic [PACKET_LENGTH_WIDTH-1:0] packet_length;
        logic [PACKET_REF_WIDTH-1:0] reference_count;
        port_id_t src_port;
        logic valid;
    } packet_descriptor_t;

    typedef struct packed {
        descriptor_id_t descriptor_id;
        queue_node_id_t next_node;
        logic [QUEUE_ID_WIDTH-1:0] queue_id;
        logic valid;
    } queue_node_t;

endpackage : switch2_pkg
