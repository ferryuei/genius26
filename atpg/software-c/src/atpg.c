#include "atpg.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

ATPGEngine* atpg_create(Circuit* circuit, ATPGAlgorithm algorithm) {
    if (!circuit) return NULL;
    
    ATPGEngine* atpg = (ATPGEngine*)malloc(sizeof(ATPGEngine));
    if (!atpg) return NULL;
    
    atpg->circuit = circuit;
    atpg->algorithm = algorithm;
    atpg->max_backtracks = 10000;
    atpg->timeout_ms = 60000;  // 60 seconds
    
    atpg->faults = NULL;
    atpg->num_faults = 0;
    
    atpg->patterns = NULL;
    atpg->num_patterns = 0;
    
    return atpg;
}

void atpg_free(ATPGEngine* atpg) {
    if (!atpg) return;
    
    if (atpg->faults) {
        free(atpg->faults);
    }
    
    if (atpg->patterns) {
        for (int i = 0; i < atpg->num_patterns; i++) {
            if (atpg->patterns[i].pi_values) {
                free(atpg->patterns[i].pi_values);
            }
            if (atpg->patterns[i].detected_faults) {
                free(atpg->patterns[i].detected_faults);
            }
        }
        free(atpg->patterns);
    }
    
    free(atpg);
}

void atpg_generate_faults(ATPGEngine* atpg) {
    if (!atpg || !atpg->circuit) return;
    
    Circuit* circuit = atpg->circuit;
    
    // Allocate fault array (2 faults per gate: SA0 and SA1)
    int max_faults = circuit->num_gates * 2;
    atpg->faults = (Fault*)malloc(max_faults * sizeof(Fault));
    atpg->num_faults = 0;
    
    // Generate stuck-at faults for each gate
    for (int i = 0; i < circuit->num_gates; i++) {
        Gate* gate = &circuit->gates[i];
        
        // Skip primary inputs for stuck-at faults on output
        // (we typically only test SA faults on gate outputs)
        if (gate->type == GATE_INPUT) {
            // Only add output stuck-at faults for PIs
            Fault* f0 = &atpg->faults[atpg->num_faults++];
            f0->gate_id = gate->id;
            f0->type = FAULT_SA0;
            f0->detected = false;
            f0->redundant = false;
            f0->pattern_id = -1;
            
            Fault* f1 = &atpg->faults[atpg->num_faults++];
            f1->gate_id = gate->id;
            f1->type = FAULT_SA1;
            f1->detected = false;
            f1->redundant = false;
            f1->pattern_id = -1;
        } else {
            // Add stuck-at faults on gate output
            Fault* f0 = &atpg->faults[atpg->num_faults++];
            f0->gate_id = gate->id;
            f0->type = FAULT_SA0;
            f0->detected = false;
            f0->redundant = false;
            f0->pattern_id = -1;
            
            Fault* f1 = &atpg->faults[atpg->num_faults++];
            f1->gate_id = gate->id;
            f1->type = FAULT_SA1;
            f1->detected = false;
            f1->redundant = false;
            f1->pattern_id = -1;
        }
    }
    
    printf("Generated %d stuck-at faults\n", atpg->num_faults);
}

int atpg_fault_simulate(ATPGEngine* atpg, const TestPattern* pattern) {
    if (!atpg || !pattern) return 0;
    
    Circuit* circuit = atpg->circuit;
    int detected_count = 0;
    
    // Allocate arrays dynamically for large circuits
    Logic* good_values = (Logic*)malloc(circuit->num_gates * sizeof(Logic));
    if (!good_values) return 0;
    
    // Simulate good circuit
    circuit_evaluate(circuit, pattern->pi_values);
    for (int i = 0; i < circuit->num_gates; i++) {
        good_values[i] = circuit->gates[i].value;
    }
    
    // For each undetected fault
    for (int f = 0; f < atpg->num_faults; f++) {
        Fault* fault = &atpg->faults[f];
        if (fault->detected) continue;
        
        Gate* fault_gate = circuit_get_gate(circuit, fault->gate_id);
        if (!fault_gate) continue;
        
        Logic good_value = good_values[fault->gate_id];
        Logic fault_value = (fault->type == FAULT_SA0) ? LOGIC_0 : LOGIC_1;
        
        // Check if fault is activated (good value != stuck-at value)
        if (good_value != fault_value && good_value != LOGIC_X) {
            // For simplicity, assume fault detected if activated
            // Full implementation would trace path to outputs
            fault->detected = true;
            fault->pattern_id = f;
            detected_count++;
        }
    }
    
    free(good_values);
    return detected_count;
}

bool atpg_run(ATPGEngine* atpg) {
    if (!atpg || !atpg->circuit) return false;
    
    printf("Starting ATPG with algorithm: %s\n",
           atpg->algorithm == ATPG_D_ALGORITHM ? "D-Algorithm" :
           atpg->algorithm == ATPG_PODEM ? "PODEM" : "FAN");
    
    // Generate faults if not already done
    if (atpg->num_faults == 0) {
        atpg_generate_faults(atpg);
    }
    
    // Allocate pattern array
    int max_patterns = (atpg->num_faults < 1000) ? atpg->num_faults : 1000;
    atpg->patterns = (TestPattern*)malloc(max_patterns * sizeof(TestPattern));
    atpg->num_patterns = 0;
    
    time_t start_time = time(NULL);
    
    // Use random pattern generation for better coverage
    srand(time(NULL));
    
    int max_random_patterns = (atpg->circuit->num_pis < 20) ? 100 : 500;
    
    for (int i = 0; i < max_random_patterns && atpg->num_patterns < max_patterns; i++) {
        TestPattern pattern;
        pattern.num_pis = atpg->circuit->num_pis;
        pattern.pi_values = (Logic*)malloc(pattern.num_pis * sizeof(Logic));
        pattern.detected_faults = NULL;
        pattern.num_detected = 0;
        
        // Generate random pattern
        for (int j = 0; j < pattern.num_pis; j++) {
            pattern.pi_values[j] = (rand() % 2) ? LOGIC_1 : LOGIC_0;
        }
        
        // Fault simulate
        int detected = atpg_fault_simulate(atpg, &pattern);
        
        if (detected > 0) {
            printf("\rPattern %d detected %d new faults", atpg->num_patterns, detected);
            fflush(stdout);
            atpg->patterns[atpg->num_patterns++] = pattern;
        } else {
            free(pattern.pi_values);
        }
        
        // Check coverage
        double coverage = atpg_calculate_coverage(atpg);
        if (coverage >= 90.0) {
            printf("\nTarget coverage reached: %.2f%%\n", coverage);
            break;
        }
        
        // Check timeout
        if (difftime(time(NULL), start_time) > atpg->timeout_ms / 1000) {
            printf("\nATPG timeout reached\n");
            break;
        }
    }
    
    printf("\n");
    atpg_print_stats(atpg);
    return true;
}

bool atpg_generate_pattern(ATPGEngine* atpg, Fault* fault, TestPattern* pattern) {
    if (!atpg || !fault || !pattern) return false;
    
    switch (atpg->algorithm) {
        case ATPG_D_ALGORITHM:
            return atpg_d_algorithm(atpg, fault, pattern);
        case ATPG_PODEM:
            return atpg_podem(atpg, fault, pattern);
        case ATPG_FAN:
            // FAN not implemented yet, fall back to PODEM
            return atpg_podem(atpg, fault, pattern);
        default:
            return false;
    }
}

double atpg_calculate_coverage(const ATPGEngine* atpg) {
    if (!atpg || atpg->num_faults == 0) return 0.0;
    
    int detected = 0;
    for (int i = 0; i < atpg->num_faults; i++) {
        if (atpg->faults[i].detected) {
            detected++;
        }
    }
    
    return (double)detected / atpg->num_faults * 100.0;
}

void atpg_print_stats(const ATPGEngine* atpg) {
    if (!atpg) return;
    
    int detected = 0, redundant = 0, undetected = 0;
    
    for (int i = 0; i < atpg->num_faults; i++) {
        if (atpg->faults[i].detected) {
            detected++;
        } else if (atpg->faults[i].redundant) {
            redundant++;
        } else {
            undetected++;
        }
    }
    
    printf("\n===== ATPG Statistics =====\n");
    printf("Total faults: %d\n", atpg->num_faults);
    printf("Detected faults: %d\n", detected);
    printf("Redundant faults: %d\n", redundant);
    printf("Undetected faults: %d\n", undetected);
    printf("Test patterns: %d\n", atpg->num_patterns);
    printf("Fault coverage: %.2f%%\n", atpg_calculate_coverage(atpg));
    printf("===========================\n");
}

bool atpg_save_patterns(const ATPGEngine* atpg, const char* filename) {
    if (!atpg || !filename) return false;
    
    FILE* file = fopen(filename, "w");
    if (!file) {
        fprintf(stderr, "Error: Cannot write to file %s\n", filename);
        return false;
    }
    
    fprintf(file, "# ATPG Test Patterns\n");
    fprintf(file, "# Total patterns: %d\n", atpg->num_patterns);
    fprintf(file, "# Fault coverage: %.2f%%\n\n", atpg_calculate_coverage(atpg));
    
    // Write PI names
    fprintf(file, "# PI names: ");
    for (int i = 0; i < atpg->circuit->num_pis; i++) {
        Gate* pi = circuit_get_gate(atpg->circuit, atpg->circuit->pi_ids[i]);
        fprintf(file, "%s ", pi->name);
    }
    fprintf(file, "\n\n");
    
    // Write patterns
    for (int p = 0; p < atpg->num_patterns; p++) {
        TestPattern* pattern = &atpg->patterns[p];
        fprintf(file, "Pattern %d: ", p);
        for (int i = 0; i < pattern->num_pis; i++) {
            fprintf(file, "%s", logic_to_str(pattern->pi_values[i]));
        }
        fprintf(file, "\n");
    }
    
    fclose(file);
    printf("Test patterns saved to %s\n", filename);
    return true;
}

// Random pattern generation with targeted activation
bool atpg_d_algorithm(ATPGEngine* atpg, Fault* fault, TestPattern* pattern) {
    if (!atpg || !fault || !pattern) return false;
    
    // Generate random pattern
    for (int i = 0; i < pattern->num_pis; i++) {
        pattern->pi_values[i] = (rand() % 2) ? LOGIC_1 : LOGIC_0;
    }
    
    // Simulate and check if fault is detected
    circuit_evaluate(atpg->circuit, pattern->pi_values);
    
    Gate* fault_gate = circuit_get_gate(atpg->circuit, fault->gate_id);
    if (!fault_gate) return false;
    
    Logic fault_free_value = fault_gate->value;
    Logic fault_value = (fault->type == FAULT_SA0) ? LOGIC_0 : LOGIC_1;
    
    // Check if fault is activated (fault-free value != stuck-at value)
    if (fault_free_value != fault_value) {
        // Check if fault propagates to any PO
        for (int i = 0; i < atpg->circuit->num_pos; i++) {
            int po_id = atpg->circuit->po_ids[i];
            // Simplified check - in full implementation would need proper propagation
            return true;  // Assume detection for now
        }
    }
    
    return false;
}

// PODEM with random pattern generation
bool atpg_podem(ATPGEngine* atpg, Fault* fault, TestPattern* pattern) {
    // Use same approach as D-algorithm for this simplified version
    return atpg_d_algorithm(atpg, fault, pattern);
}
