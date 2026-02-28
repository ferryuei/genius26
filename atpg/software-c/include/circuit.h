#ifndef CIRCUIT_H
#define CIRCUIT_H

#include "logic.h"
#include <stdint.h>
#include <stdbool.h>

#define MAX_NAME_LEN 256
#define MAX_INPUTS 128
#define MAX_GATES 200000
#define MAX_FANOUTS 128

/**
 * Gate types
 */
typedef enum {
    GATE_INPUT = 0,
    GATE_AND,
    GATE_OR,
    GATE_NOT,
    GATE_NAND,
    GATE_NOR,
    GATE_XOR,
    GATE_XNOR,
    GATE_BUF,
    GATE_DFF
} GateType;

/**
 * Fault types
 */
typedef enum {
    FAULT_SA0 = 0,  // Stuck-at-0
    FAULT_SA1 = 1   // Stuck-at-1
} FaultType;

/**
 * Gate structure
 */
typedef struct {
    int id;                         // Gate ID
    char name[MAX_NAME_LEN];        // Gate name
    GateType type;                  // Gate type
    int inputs[MAX_INPUTS];         // Input gate IDs
    int num_inputs;                 // Number of inputs
    int fanouts[MAX_FANOUTS];       // Fanout gate IDs
    int num_fanouts;                // Number of fanouts
    Logic value;                    // Current logic value
    int level;                      // Topological level
    bool is_pi;                     // Is primary input
    bool is_po;                     // Is primary output
} Gate;

/**
 * Fault structure
 */
typedef struct {
    int gate_id;                    // Gate ID where fault occurs
    FaultType type;                 // Fault type (SA0/SA1)
    bool detected;                  // Is fault detected
    bool redundant;                 // Is fault redundant
    int pattern_id;                 // Test pattern ID that detects this fault
} Fault;

/**
 * Circuit structure
 */
typedef struct {
    Gate* gates;                    // Array of gates
    int num_gates;                  // Number of gates
    int capacity;                   // Array capacity
    int* pi_ids;                    // Primary input IDs
    int num_pis;                    // Number of primary inputs
    int* po_ids;                    // Primary output IDs
    int num_pos;                    // Number of primary outputs
    int max_level;                  // Maximum topological level
} Circuit;

/**
 * Test pattern structure
 */
typedef struct {
    Logic* pi_values;               // Primary input values
    int num_pis;                    // Number of primary inputs
    int* detected_faults;           // Detected fault IDs
    int num_detected;               // Number of detected faults
} TestPattern;

/**
 * Create a new circuit
 */
Circuit* circuit_create(void);

/**
 * Free circuit memory
 */
void circuit_free(Circuit* circuit);

/**
 * Add a gate to the circuit
 */
int circuit_add_gate(Circuit* circuit, const char* name, GateType type);

/**
 * Connect two gates
 */
bool circuit_add_connection(Circuit* circuit, int from_id, int to_id);

/**
 * Get gate by name
 */
Gate* circuit_get_gate_by_name(Circuit* circuit, const char* name);

/**
 * Get gate by ID
 */
Gate* circuit_get_gate(Circuit* circuit, int gate_id);

/**
 * Set gate as primary input
 */
void circuit_set_pi(Circuit* circuit, int gate_id);

/**
 * Set gate as primary output
 */
void circuit_set_po(Circuit* circuit, int gate_id);

/**
 * Compute topological levels
 */
void circuit_levelization(Circuit* circuit);

/**
 * Evaluate the circuit with given inputs
 */
void circuit_evaluate(Circuit* circuit, const Logic* pi_values);

/**
 * Evaluate a single gate
 */
Logic gate_evaluate(const Gate* gate, const Circuit* circuit);

/**
 * Convert gate type to string
 */
const char* gate_type_to_str(GateType type);

/**
 * Parse gate type from string
 */
GateType gate_type_from_str(const char* str);

#endif // CIRCUIT_H
