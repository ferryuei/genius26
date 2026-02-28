#include "circuit.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

const char* gate_type_to_str(GateType type) {
    switch (type) {
        case GATE_INPUT: return "INPUT";
        case GATE_AND: return "AND";
        case GATE_OR: return "OR";
        case GATE_NOT: return "NOT";
        case GATE_NAND: return "NAND";
        case GATE_NOR: return "NOR";
        case GATE_XOR: return "XOR";
        case GATE_XNOR: return "XNOR";
        case GATE_BUF: return "BUF";
        case GATE_DFF: return "DFF";
        default: return "UNKNOWN";
    }
}

GateType gate_type_from_str(const char* str) {
    if (!str) return GATE_INPUT;
    if (strcmp(str, "INPUT") == 0) return GATE_INPUT;
    if (strcmp(str, "AND") == 0) return GATE_AND;
    if (strcmp(str, "OR") == 0) return GATE_OR;
    if (strcmp(str, "NOT") == 0) return GATE_NOT;
    if (strcmp(str, "NAND") == 0) return GATE_NAND;
    if (strcmp(str, "NOR") == 0) return GATE_NOR;
    if (strcmp(str, "XOR") == 0) return GATE_XOR;
    if (strcmp(str, "XNOR") == 0) return GATE_XNOR;
    if (strcmp(str, "BUF") == 0 || strcmp(str, "BUFF") == 0) return GATE_BUF;
    if (strcmp(str, "DFF") == 0) return GATE_DFF;
    return GATE_INPUT;
}

Circuit* circuit_create(void) {
    Circuit* circuit = (Circuit*)malloc(sizeof(Circuit));
    if (!circuit) return NULL;
    
    circuit->capacity = 10000;  // Start with smaller capacity
    circuit->gates = (Gate*)calloc(circuit->capacity, sizeof(Gate));
    if (!circuit->gates) {
        free(circuit);
        return NULL;
    }
    circuit->num_gates = 0;
    
    circuit->pi_ids = (int*)calloc(5000, sizeof(int));
    if (!circuit->pi_ids) {
        free(circuit->gates);
        free(circuit);
        return NULL;
    }
    circuit->num_pis = 0;
    
    circuit->po_ids = (int*)calloc(5000, sizeof(int));
    if (!circuit->po_ids) {
        free(circuit->pi_ids);
        free(circuit->gates);
        free(circuit);
        return NULL;
    }
    circuit->num_pos = 0;
    
    circuit->max_level = 0;
    
    return circuit;
}

void circuit_free(Circuit* circuit) {
    if (!circuit) return;
    free(circuit->gates);
    free(circuit->pi_ids);
    free(circuit->po_ids);
    free(circuit);
}

int circuit_add_gate(Circuit* circuit, const char* name, GateType type) {
    if (!circuit || !name) return -1;
    
    // Resize if needed
    if (circuit->num_gates >= circuit->capacity) {
        int new_capacity = circuit->capacity * 2;
        if (new_capacity > MAX_GATES) new_capacity = MAX_GATES;
        
        Gate* new_gates = (Gate*)realloc(circuit->gates, new_capacity * sizeof(Gate));
        if (!new_gates) {
            fprintf(stderr, "Error: Failed to allocate memory for %d gates\n", new_capacity);
            return -1;
        }
        
        // Initialize new memory
        memset(new_gates + circuit->capacity, 0, (new_capacity - circuit->capacity) * sizeof(Gate));
        
        circuit->gates = new_gates;
        circuit->capacity = new_capacity;
    }
    
    int id = circuit->num_gates;
    Gate* gate = &circuit->gates[id];
    
    gate->id = id;
    strncpy(gate->name, name, MAX_NAME_LEN - 1);
    gate->name[MAX_NAME_LEN - 1] = '\0';
    gate->type = type;
    gate->num_inputs = 0;
    gate->num_fanouts = 0;
    gate->value = LOGIC_X;
    gate->level = 0;
    gate->is_pi = false;
    gate->is_po = false;
    
    circuit->num_gates++;
    return id;
}

bool circuit_add_connection(Circuit* circuit, int from_id, int to_id) {
    if (!circuit || from_id < 0 || from_id >= circuit->num_gates || 
        to_id < 0 || to_id >= circuit->num_gates) {
        return false;
    }
    
    Gate* from_gate = &circuit->gates[from_id];
    Gate* to_gate = &circuit->gates[to_id];
    
    // Add to fanouts of from_gate
    if (from_gate->num_fanouts < MAX_FANOUTS) {
        from_gate->fanouts[from_gate->num_fanouts++] = to_id;
    }
    
    // Add to inputs of to_gate
    if (to_gate->num_inputs < MAX_INPUTS) {
        to_gate->inputs[to_gate->num_inputs++] = from_id;
        return true;
    }
    
    return false;
}

Gate* circuit_get_gate_by_name(Circuit* circuit, const char* name) {
    if (!circuit || !name) return NULL;
    
    for (int i = 0; i < circuit->num_gates; i++) {
        if (strcmp(circuit->gates[i].name, name) == 0) {
            return &circuit->gates[i];
        }
    }
    return NULL;
}

Gate* circuit_get_gate(Circuit* circuit, int gate_id) {
    if (!circuit || gate_id < 0 || gate_id >= circuit->num_gates) {
        return NULL;
    }
    return &circuit->gates[gate_id];
}

void circuit_set_pi(Circuit* circuit, int gate_id) {
    if (!circuit || gate_id < 0 || gate_id >= circuit->num_gates) return;
    
    circuit->gates[gate_id].is_pi = true;
    circuit->pi_ids[circuit->num_pis++] = gate_id;
}

void circuit_set_po(Circuit* circuit, int gate_id) {
    if (!circuit || gate_id < 0 || gate_id >= circuit->num_gates) return;
    
    circuit->gates[gate_id].is_po = true;
    circuit->po_ids[circuit->num_pos++] = gate_id;
}

void circuit_levelization(Circuit* circuit) {
    if (!circuit) return;
    
    // Initialize all levels to -1
    for (int i = 0; i < circuit->num_gates; i++) {
        circuit->gates[i].level = -1;
    }
    
    // Set primary inputs to level 0
    for (int i = 0; i < circuit->num_pis; i++) {
        circuit->gates[circuit->pi_ids[i]].level = 0;
    }
    
    // Iteratively compute levels
    bool changed = true;
    while (changed) {
        changed = false;
        for (int i = 0; i < circuit->num_gates; i++) {
            Gate* gate = &circuit->gates[i];
            if (gate->is_pi) continue;  // Skip primary inputs
            
            // Find max level of inputs
            int max_input_level = -1;
            bool all_inputs_valid = true;
            for (int j = 0; j < gate->num_inputs; j++) {
                int input_level = circuit->gates[gate->inputs[j]].level;
                if (input_level == -1) {
                    all_inputs_valid = false;
                    break;
                }
                if (input_level > max_input_level) {
                    max_input_level = input_level;
                }
            }
            
            if (all_inputs_valid && gate->level != max_input_level + 1) {
                gate->level = max_input_level + 1;
                changed = true;
                if (gate->level > circuit->max_level) {
                    circuit->max_level = gate->level;
                }
            }
        }
    }
}

Logic gate_evaluate(const Gate* gate, const Circuit* circuit) {
    if (!gate || !circuit) return LOGIC_X;
    
    // Collect input values
    Logic input_vals[MAX_INPUTS];
    for (int i = 0; i < gate->num_inputs; i++) {
        input_vals[i] = circuit->gates[gate->inputs[i]].value;
    }
    
    switch (gate->type) {
        case GATE_INPUT:
            return gate->value;  // Keep current value
            
        case GATE_NOT:
            if (gate->num_inputs > 0) {
                return logic_not(input_vals[0]);
            }
            return LOGIC_X;
            
        case GATE_BUF:
            if (gate->num_inputs > 0) {
                return input_vals[0];
            }
            return LOGIC_X;
            
        case GATE_AND:
            return logic_and_n(input_vals, gate->num_inputs);
            
        case GATE_OR:
            return logic_or_n(input_vals, gate->num_inputs);
            
        case GATE_NAND:
            return logic_not(logic_and_n(input_vals, gate->num_inputs));
            
        case GATE_NOR:
            return logic_not(logic_or_n(input_vals, gate->num_inputs));
            
        case GATE_XOR:
            return logic_xor_n(input_vals, gate->num_inputs);
            
        case GATE_XNOR:
            return logic_not(logic_xor_n(input_vals, gate->num_inputs));
            
        case GATE_DFF:
            // For combinational ATPG, DFF passes through
            if (gate->num_inputs > 0) {
                return input_vals[0];
            }
            return LOGIC_X;
            
        default:
            return LOGIC_X;
    }
}

void circuit_evaluate(Circuit* circuit, const Logic* pi_values) {
    if (!circuit || !pi_values) return;
    
    // Set primary input values
    for (int i = 0; i < circuit->num_pis; i++) {
        circuit->gates[circuit->pi_ids[i]].value = pi_values[i];
    }
    
    // Evaluate gates level by level
    for (int level = 0; level <= circuit->max_level; level++) {
        for (int i = 0; i < circuit->num_gates; i++) {
            Gate* gate = &circuit->gates[i];
            if (gate->level == level && !gate->is_pi) {
                gate->value = gate_evaluate(gate, circuit);
            }
        }
    }
}
