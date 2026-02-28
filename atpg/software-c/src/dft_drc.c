#include "dft_drc.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

DFTDRCEngine* dft_drc_create(Circuit* circuit) {
    if (!circuit) return NULL;
    
    DFTDRCEngine* drc = (DFTDRCEngine*)calloc(1, sizeof(DFTDRCEngine));
    if (!drc) return NULL;
    
    drc->circuit = circuit;
    drc->capacity_violations = 1000;
    drc->violations = (DRCViolation*)calloc(drc->capacity_violations, sizeof(DRCViolation));
    
    drc->clock_domains = (ClockDomain*)calloc(MAX_CLOCK_DOMAINS, sizeof(ClockDomain));
    drc->reset_domains = (ResetDomain*)calloc(MAX_RESET_DOMAINS, sizeof(ResetDomain));
    
    return drc;
}

void dft_drc_free(DFTDRCEngine* drc) {
    if (!drc) return;
    
    if (drc->violations) free(drc->violations);
    
    if (drc->clock_domains) {
        for (int i = 0; i < drc->num_clock_domains; i++) {
            if (drc->clock_domains[i].controlled_dffs) {
                free(drc->clock_domains[i].controlled_dffs);
            }
        }
        free(drc->clock_domains);
    }
    
    if (drc->reset_domains) {
        for (int i = 0; i < drc->num_reset_domains; i++) {
            if (drc->reset_domains[i].controlled_dffs) {
                free(drc->reset_domains[i].controlled_dffs);
            }
        }
        free(drc->reset_domains);
    }
    
    free(drc);
}

void dft_drc_add_violation(DFTDRCEngine* drc, DRCViolationType type, 
                           int gate_id, const char* description, int severity) {
    if (!drc) return;
    
    // Resize if needed
    if (drc->num_violations >= drc->capacity_violations) {
        drc->capacity_violations *= 2;
        drc->violations = (DRCViolation*)realloc(drc->violations, 
                                                 drc->capacity_violations * sizeof(DRCViolation));
    }
    
    DRCViolation* v = &drc->violations[drc->num_violations++];
    v->type = type;
    v->gate_id = gate_id;
    v->severity = severity;
    strncpy(v->description, description, sizeof(v->description) - 1);
    
    if (gate_id >= 0 && gate_id < drc->circuit->num_gates) {
        strncpy(v->gate_name, drc->circuit->gates[gate_id].name, MAX_NAME_LEN - 1);
    } else {
        strcpy(v->gate_name, "N/A");
    }
    
    // Update statistics
    switch (severity) {
        case 0: drc->num_info++; break;
        case 1: drc->num_warnings++; break;
        case 2: 
        case 3: drc->num_errors++; break;
    }
}

const char* dft_drc_violation_type_str(DRCViolationType type) {
    switch (type) {
        case DRC_CLOCK_UNCONTROLLABLE: return "Clock Uncontrollable";
        case DRC_RESET_UNCONTROLLABLE: return "Reset Uncontrollable";
        case DRC_CLOCK_GATING_NO_BYPASS: return "Clock Gating No Bypass";
        case DRC_ASYNC_RESET_NO_CONTROL: return "Async Reset No Control";
        case DRC_COMBINATIONAL_LOOP: return "Combinational Loop";
        case DRC_TRISTATE_IN_SCAN: return "Tristate in Scan";
        case DRC_DFF_NO_CLOCK: return "DFF No Clock";
        case DRC_DFF_NO_RESET: return "DFF No Reset";
        case DRC_SCAN_CHAIN_INCOMPLETE: return "Scan Chain Incomplete";
        case DRC_FLOATING_INPUT: return "Floating Input";
        case DRC_MULTIPLE_CLOCKS_ON_DFF: return "Multiple Clocks on DFF";
        case DRC_GATED_CLOCK_ON_DFF: return "Gated Clock on DFF";
        default: return "Unknown";
    }
}

bool dft_drc_is_controllable_from_pi(Circuit* circuit, int gate_id) {
    if (gate_id < 0 || gate_id >= circuit->num_gates) return false;
    
    Gate* gate = &circuit->gates[gate_id];
    
    // Primary inputs are controllable
    if (gate->is_pi) return true;
    
    // Use BFS to check if there's a path from any PI to this gate
    bool* visited = (bool*)calloc(circuit->num_gates, sizeof(bool));
    int* queue = (int*)malloc(circuit->num_gates * sizeof(int));
    int front = 0, rear = 0;
    
    // Start from the target gate
    queue[rear++] = gate_id;
    visited[gate_id] = true;
    
    bool controllable = false;
    
    // Backward trace through inputs
    while (front < rear && !controllable) {
        int current = queue[front++];
        Gate* curr_gate = &circuit->gates[current];
        
        // Check if we reached a PI
        if (curr_gate->is_pi) {
            controllable = true;
            break;
        }
        
        // Add all inputs to queue
        for (int i = 0; i < curr_gate->num_inputs; i++) {
            int input_id = curr_gate->inputs[i];
            if (input_id >= 0 && input_id < circuit->num_gates && !visited[input_id]) {
                visited[input_id] = true;
                queue[rear++] = input_id;
            }
        }
    }
    
    free(visited);
    free(queue);
    return controllable;
}

int dft_drc_trace_clock_source(Circuit* circuit, int dff_id) {
    if (dff_id < 0 || dff_id >= circuit->num_gates) return -1;
    
    Gate* dff = &circuit->gates[dff_id];
    if (dff->type != GATE_DFF) return -1;
    
    // In a simple model, we assume the second input (if exists) is the clock
    // This is a simplified model - in reality, we'd need to parse this from netlist
    if (dff->num_inputs >= 2) {
        return dff->inputs[1];
    }
    
    return -1;
}

int dft_drc_trace_reset_source(Circuit* circuit, int dff_id) {
    if (dff_id < 0 || dff_id >= circuit->num_gates) return -1;
    
    Gate* dff = &circuit->gates[dff_id];
    if (dff->type != GATE_DFF) return -1;
    
    // In a simple model, we assume the third input (if exists) is the reset
    // This is a simplified model - in reality, we'd need to parse this from netlist
    if (dff->num_inputs >= 3) {
        return dff->inputs[2];
    }
    
    return -1;
}

int dft_drc_identify_clock_domains(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return 0;
    
    Circuit* circuit = drc->circuit;
    printf("\nIdentifying clock domains...\n");
    
    // Find all DFFs and their clock sources
    for (int i = 0; i < circuit->num_gates; i++) {
        if (circuit->gates[i].type != GATE_DFF) continue;
        
        int clock_src = dft_drc_trace_clock_source(circuit, i);
        if (clock_src < 0) {
            // DFF has no identifiable clock
            char desc[512];
            snprintf(desc, sizeof(desc), "DFF '%s' has no identifiable clock input", 
                     circuit->gates[i].name);
            dft_drc_add_violation(drc, DRC_DFF_NO_CLOCK, i, desc, 2);
            continue;
        }
        
        // Find or create clock domain
        int domain_idx = -1;
        for (int d = 0; d < drc->num_clock_domains; d++) {
            if (drc->clock_domains[d].clock_gate_id == clock_src) {
                domain_idx = d;
                break;
            }
        }
        
        if (domain_idx < 0) {
            // Create new clock domain
            if (drc->num_clock_domains >= MAX_CLOCK_DOMAINS) continue;
            
            domain_idx = drc->num_clock_domains++;
            ClockDomain* cd = &drc->clock_domains[domain_idx];
            cd->clock_gate_id = clock_src;
            strncpy(cd->clock_name, circuit->gates[clock_src].name, MAX_NAME_LEN - 1);
            cd->controlled_dffs = (int*)malloc(1000 * sizeof(int));
            cd->num_dffs = 0;
            cd->is_controllable = dft_drc_is_controllable_from_pi(circuit, clock_src);
            cd->has_gating = false;
            cd->gating_bypassable = false;
        }
        
        // Add DFF to domain
        ClockDomain* cd = &drc->clock_domains[domain_idx];
        cd->controlled_dffs[cd->num_dffs++] = i;
    }
    
    printf("Found %d clock domain(s)\n", drc->num_clock_domains);
    return drc->num_clock_domains;
}

int dft_drc_identify_reset_domains(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return 0;
    
    Circuit* circuit = drc->circuit;
    printf("Identifying reset domains...\n");
    
    // Find all DFFs and their reset sources
    for (int i = 0; i < circuit->num_gates; i++) {
        if (circuit->gates[i].type != GATE_DFF) continue;
        
        int reset_src = dft_drc_trace_reset_source(circuit, i);
        if (reset_src < 0) {
            // DFF has no identifiable reset - this might be OK for some designs
            // Record as info rather than error
            continue;
        }
        
        // Find or create reset domain
        int domain_idx = -1;
        for (int d = 0; d < drc->num_reset_domains; d++) {
            if (drc->reset_domains[d].reset_gate_id == reset_src) {
                domain_idx = d;
                break;
            }
        }
        
        if (domain_idx < 0) {
            // Create new reset domain
            if (drc->num_reset_domains >= MAX_RESET_DOMAINS) continue;
            
            domain_idx = drc->num_reset_domains++;
            ResetDomain* rd = &drc->reset_domains[domain_idx];
            rd->reset_gate_id = reset_src;
            strncpy(rd->reset_name, circuit->gates[reset_src].name, MAX_NAME_LEN - 1);
            rd->controlled_dffs = (int*)malloc(1000 * sizeof(int));
            rd->num_dffs = 0;
            rd->is_controllable = dft_drc_is_controllable_from_pi(circuit, reset_src);
            rd->is_async = true;  // Conservative assumption
            rd->has_control_in_test = rd->is_controllable;
        }
        
        // Add DFF to domain
        ResetDomain* rd = &drc->reset_domains[domain_idx];
        rd->controlled_dffs[rd->num_dffs++] = i;
    }
    
    printf("Found %d reset domain(s)\n", drc->num_reset_domains);
    return drc->num_reset_domains;
}

bool dft_drc_check_clock_controllability(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return false;
    
    printf("\n=== Checking Clock Controllability ===\n");
    
    // First identify clock domains
    dft_drc_identify_clock_domains(drc);
    
    int uncontrollable_clocks = 0;
    
    // Check each clock domain
    for (int i = 0; i < drc->num_clock_domains; i++) {
        ClockDomain* cd = &drc->clock_domains[i];
        
        if (!cd->is_controllable) {
            char desc[512];
            snprintf(desc, sizeof(desc), 
                     "Clock '%s' is not controllable from primary inputs. "
                     "This affects %d DFF(s). Clock must be controllable for scan testing.",
                     cd->clock_name, cd->num_dffs);
            dft_drc_add_violation(drc, DRC_CLOCK_UNCONTROLLABLE, 
                                  cd->clock_gate_id, desc, 3);
            uncontrollable_clocks++;
            printf("  [ERROR] Clock '%s' is NOT controllable (%d DFFs affected)\n", 
                   cd->clock_name, cd->num_dffs);
        } else {
            printf("  [OK] Clock '%s' is controllable (%d DFFs)\n", 
                   cd->clock_name, cd->num_dffs);
        }
    }
    
    printf("\nClock Controllability Summary:\n");
    printf("  Total clock domains: %d\n", drc->num_clock_domains);
    printf("  Controllable clocks: %d\n", drc->num_clock_domains - uncontrollable_clocks);
    printf("  Uncontrollable clocks: %d\n", uncontrollable_clocks);
    
    return (uncontrollable_clocks == 0);
}

bool dft_drc_check_reset_controllability(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return false;
    
    printf("\n=== Checking Reset Controllability ===\n");
    
    // First identify reset domains
    dft_drc_identify_reset_domains(drc);
    
    int uncontrollable_resets = 0;
    
    // Check each reset domain
    for (int i = 0; i < drc->num_reset_domains; i++) {
        ResetDomain* rd = &drc->reset_domains[i];
        
        if (!rd->is_controllable) {
            char desc[512];
            snprintf(desc, sizeof(desc), 
                     "Reset '%s' is not controllable from primary inputs. "
                     "This affects %d DFF(s). Reset must be controllable for scan testing.",
                     rd->reset_name, rd->num_dffs);
            dft_drc_add_violation(drc, DRC_RESET_UNCONTROLLABLE, 
                                  rd->reset_gate_id, desc, 3);
            uncontrollable_resets++;
            printf("  [ERROR] Reset '%s' is NOT controllable (%d DFFs affected)\n", 
                   rd->reset_name, rd->num_dffs);
        } else {
            printf("  [OK] Reset '%s' is controllable (%d DFFs)\n", 
                   rd->reset_name, rd->num_dffs);
        }
        
        // Check for async resets
        if (rd->is_async && !rd->has_control_in_test) {
            char desc[512];
            snprintf(desc, sizeof(desc), 
                     "Asynchronous reset '%s' should have control in test mode. "
                     "Consider adding test mode bypass or making it synchronous.",
                     rd->reset_name);
            dft_drc_add_violation(drc, DRC_ASYNC_RESET_NO_CONTROL, 
                                  rd->reset_gate_id, desc, 1);
            printf("  [WARNING] Reset '%s' is asynchronous without test mode control\n", 
                   rd->reset_name);
        }
    }
    
    printf("\nReset Controllability Summary:\n");
    printf("  Total reset domains: %d\n", drc->num_reset_domains);
    printf("  Controllable resets: %d\n", drc->num_reset_domains - uncontrollable_resets);
    printf("  Uncontrollable resets: %d\n", uncontrollable_resets);
    
    return (uncontrollable_resets == 0);
}

bool dft_drc_check_clock_gating(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return false;
    
    printf("\n=== Checking Clock Gating ===\n");
    
    Circuit* circuit = drc->circuit;
    int gated_clocks = 0;
    int bypassable_gates = 0;
    
    // Look for potential clock gating: AND/OR gates that feed DFF clocks
    for (int i = 0; i < circuit->num_gates; i++) {
        Gate* gate = &circuit->gates[i];
        
        // Check if this is an AND/OR/NAND/NOR gate
        if (gate->type != GATE_AND && gate->type != GATE_OR && 
            gate->type != GATE_NAND && gate->type != GATE_NOR) {
            continue;
        }
        
        // Check if any fanout is a DFF clock
        bool feeds_dff_clock = false;
        for (int j = 0; j < gate->num_fanouts; j++) {
            int fanout_id = gate->fanouts[j];
            if (fanout_id >= 0 && fanout_id < circuit->num_gates) {
                if (circuit->gates[fanout_id].type == GATE_DFF) {
                    feeds_dff_clock = true;
                    break;
                }
            }
        }
        
        if (feeds_dff_clock) {
            gated_clocks++;
            
            // Check if gating is bypassable (one input is a primary input or test signal)
            bool bypassable = false;
            for (int k = 0; k < gate->num_inputs; k++) {
                int input_id = gate->inputs[k];
                if (input_id >= 0 && input_id < circuit->num_gates) {
                    if (circuit->gates[input_id].is_pi) {
                        bypassable = true;
                        break;
                    }
                }
            }
            
            if (!bypassable) {
                char desc[512];
                snprintf(desc, sizeof(desc), 
                         "Clock gating cell '%s' has no bypass mechanism. "
                         "Add test mode to disable clock gating during scan.",
                         gate->name);
                dft_drc_add_violation(drc, DRC_CLOCK_GATING_NO_BYPASS, 
                                      i, desc, 2);
                printf("  [ERROR] Clock gate '%s' has no bypass\n", gate->name);
            } else {
                bypassable_gates++;
                printf("  [OK] Clock gate '%s' appears bypassable\n", gate->name);
            }
        }
    }
    
    printf("\nClock Gating Summary:\n");
    printf("  Clock gating cells found: %d\n", gated_clocks);
    printf("  Bypassable gates: %d\n", bypassable_gates);
    printf("  Gates without bypass: %d\n", gated_clocks - bypassable_gates);
    
    return (gated_clocks == bypassable_gates);
}

bool dft_drc_check_combinational_loops(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return false;
    
    printf("\n=== Checking Combinational Loops ===\n");
    
    Circuit* circuit = drc->circuit;
    bool* visited = (bool*)calloc(circuit->num_gates, sizeof(bool));
    bool* in_stack = (bool*)calloc(circuit->num_gates, sizeof(bool));
    int loops_found = 0;
    
    // DFS to detect cycles
    for (int i = 0; i < circuit->num_gates; i++) {
        if (!visited[i]) {
            // Perform DFS from this node
            int* stack = (int*)malloc(circuit->num_gates * sizeof(int));
            int top = 0;
            stack[top++] = i;
            
            while (top > 0) {
                int current = stack[--top];
                
                if (visited[current]) continue;
                visited[current] = true;
                in_stack[current] = true;
                
                Gate* gate = &circuit->gates[current];
                
                // Don't trace through DFFs
                if (gate->type == GATE_DFF) {
                    in_stack[current] = false;
                    continue;
                }
                
                // Check all fanouts
                for (int j = 0; j < gate->num_fanouts; j++) {
                    int fanout = gate->fanouts[j];
                    if (fanout >= 0 && fanout < circuit->num_gates) {
                        if (in_stack[fanout]) {
                            // Found a loop
                            char desc[512];
                            snprintf(desc, sizeof(desc), 
                                     "Combinational loop detected involving gate '%s'",
                                     gate->name);
                            dft_drc_add_violation(drc, DRC_COMBINATIONAL_LOOP, 
                                                  current, desc, 3);
                            loops_found++;
                            printf("  [ERROR] Loop detected at gate '%s'\n", gate->name);
                        } else if (!visited[fanout]) {
                            stack[top++] = fanout;
                        }
                    }
                }
                
                in_stack[current] = false;
            }
            
            free(stack);
        }
    }
    
    free(visited);
    free(in_stack);
    
    printf("\nCombinational Loop Summary:\n");
    printf("  Loops found: %d\n", loops_found);
    
    return (loops_found == 0);
}

bool dft_drc_check_dff_connectivity(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return false;
    
    printf("\n=== Checking DFF Connectivity ===\n");
    
    Circuit* circuit = drc->circuit;
    int dffs_no_input = 0;
    int dffs_no_output = 0;
    
    for (int i = 0; i < circuit->num_gates; i++) {
        Gate* gate = &circuit->gates[i];
        if (gate->type != GATE_DFF) continue;
        
        // Check if DFF has data input
        if (gate->num_inputs == 0) {
            char desc[512];
            snprintf(desc, sizeof(desc), "DFF '%s' has no data input", gate->name);
            dft_drc_add_violation(drc, DRC_FLOATING_INPUT, i, desc, 2);
            dffs_no_input++;
            printf("  [ERROR] DFF '%s' has no input\n", gate->name);
        }
        
        // Check if DFF has fanout (or is a PO)
        if (gate->num_fanouts == 0 && !gate->is_po) {
            char desc[512];
            snprintf(desc, sizeof(desc), 
                     "DFF '%s' has no fanout and is not a primary output", 
                     gate->name);
            dft_drc_add_violation(drc, DRC_FLOATING_INPUT, i, desc, 1);
            dffs_no_output++;
            printf("  [WARNING] DFF '%s' has no fanout\n", gate->name);
        }
    }
    
    printf("\nDFF Connectivity Summary:\n");
    printf("  DFFs without input: %d\n", dffs_no_input);
    printf("  DFFs without fanout: %d\n", dffs_no_output);
    
    return (dffs_no_input == 0);
}

bool dft_drc_check_tristate(DFTDRCEngine* drc) {
    if (!drc || !drc->circuit) return false;
    
    printf("\n=== Checking Tristate Logic ===\n");
    
    // In the current BENCH format, we don't have explicit tristate gates
    // This is a placeholder for more advanced netlists
    printf("  [INFO] No tristate gates detected in BENCH format\n");
    
    return true;
}

bool dft_drc_check_all(DFTDRCEngine* drc) {
    if (!drc) return false;
    
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║              DFT Design Rule Check (DRC)                    ║\n");
    printf("╚══════════════════════════════════════════════════════════════╝\n");
    
    bool all_pass = true;
    
    // Run all checks
    all_pass &= dft_drc_check_clock_controllability(drc);
    all_pass &= dft_drc_check_reset_controllability(drc);
    all_pass &= dft_drc_check_clock_gating(drc);
    all_pass &= dft_drc_check_combinational_loops(drc);
    all_pass &= dft_drc_check_dff_connectivity(drc);
    all_pass &= dft_drc_check_tristate(drc);
    
    return all_pass;
}

void dft_drc_print_report(const DFTDRCEngine* drc) {
    if (!drc) return;
    
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║                    DFT DRC Report                            ║\n");
    printf("╚══════════════════════════════════════════════════════════════╝\n");
    
    printf("\nStatistics:\n");
    printf("  Total violations: %d\n", drc->num_violations);
    printf("  Errors:           %d\n", drc->num_errors);
    printf("  Warnings:         %d\n", drc->num_warnings);
    printf("  Info:             %d\n", drc->num_info);
    
    if (drc->num_violations > 0) {
        printf("\nViolations:\n");
        printf("%-8s %-30s %-30s %s\n", "Severity", "Type", "Gate", "Description");
        printf("────────────────────────────────────────────────────────────────────────────────\n");
        
        for (int i = 0; i < drc->num_violations; i++) {
            const DRCViolation* v = &drc->violations[i];
            const char* sev_str;
            switch (v->severity) {
                case 0: sev_str = "INFO"; break;
                case 1: sev_str = "WARNING"; break;
                case 2: sev_str = "ERROR"; break;
                case 3: sev_str = "CRITICAL"; break;
                default: sev_str = "UNKNOWN"; break;
            }
            
            printf("%-8s %-30s %-30s %s\n", 
                   sev_str, 
                   dft_drc_violation_type_str(v->type),
                   v->gate_name,
                   v->description);
        }
    }
    
    printf("\n");
    if (drc->num_errors > 0) {
        printf("❌ DFT DRC FAILED - %d error(s) found\n", drc->num_errors);
    } else if (drc->num_warnings > 0) {
        printf("⚠️  DFT DRC PASSED with %d warning(s)\n", drc->num_warnings);
    } else {
        printf("✅ DFT DRC PASSED - No violations found\n");
    }
}

bool dft_drc_save_report(const DFTDRCEngine* drc, const char* filename) {
    if (!drc || !filename) return false;
    
    FILE* f = fopen(filename, "w");
    if (!f) {
        printf("Error: Cannot open file '%s' for writing\n", filename);
        return false;
    }
    
    fprintf(f, "DFT Design Rule Check (DRC) Report\n");
    fprintf(f, "===================================\n\n");
    
    fprintf(f, "Statistics:\n");
    fprintf(f, "  Total violations: %d\n", drc->num_violations);
    fprintf(f, "  Errors:           %d\n", drc->num_errors);
    fprintf(f, "  Warnings:         %d\n", drc->num_warnings);
    fprintf(f, "  Info:             %d\n\n", drc->num_info);
    
    fprintf(f, "Clock Domains: %d\n", drc->num_clock_domains);
    for (int i = 0; i < drc->num_clock_domains; i++) {
        const ClockDomain* cd = &drc->clock_domains[i];
        fprintf(f, "  Clock '%s': %d DFFs, Controllable: %s\n",
                cd->clock_name, cd->num_dffs, cd->is_controllable ? "Yes" : "No");
    }
    fprintf(f, "\n");
    
    fprintf(f, "Reset Domains: %d\n", drc->num_reset_domains);
    for (int i = 0; i < drc->num_reset_domains; i++) {
        const ResetDomain* rd = &drc->reset_domains[i];
        fprintf(f, "  Reset '%s': %d DFFs, Controllable: %s\n",
                rd->reset_name, rd->num_dffs, rd->is_controllable ? "Yes" : "No");
    }
    fprintf(f, "\n");
    
    if (drc->num_violations > 0) {
        fprintf(f, "Violations:\n");
        fprintf(f, "%-10s %-35s %-30s %s\n", 
                "Severity", "Type", "Gate", "Description");
        fprintf(f, "────────────────────────────────────────────────────────────────────────────────\n");
        
        for (int i = 0; i < drc->num_violations; i++) {
            const DRCViolation* v = &drc->violations[i];
            const char* sev_str;
            switch (v->severity) {
                case 0: sev_str = "INFO"; break;
                case 1: sev_str = "WARNING"; break;
                case 2: sev_str = "ERROR"; break;
                case 3: sev_str = "CRITICAL"; break;
                default: sev_str = "UNKNOWN"; break;
            }
            
            fprintf(f, "%-10s %-35s %-30s %s\n", 
                    sev_str, 
                    dft_drc_violation_type_str(v->type),
                    v->gate_name,
                    v->description);
        }
    }
    
    fprintf(f, "\n");
    if (drc->num_errors > 0) {
        fprintf(f, "Result: FAILED - %d error(s) found\n", drc->num_errors);
    } else if (drc->num_warnings > 0) {
        fprintf(f, "Result: PASSED with %d warning(s)\n", drc->num_warnings);
    } else {
        fprintf(f, "Result: PASSED - No violations found\n");
    }
    
    fclose(f);
    printf("DRC report saved to '%s'\n", filename);
    return true;
}
