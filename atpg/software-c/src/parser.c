#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define MAX_LINE_LEN 4096
#define MAX_TOKENS 256

static void trim_whitespace(char* str) {
    if (!str) return;
    
    // Trim leading whitespace
    char* start = str;
    while (isspace(*start)) start++;
    
    // Trim trailing whitespace
    char* end = start + strlen(start) - 1;
    while (end > start && isspace(*end)) end--;
    *(end + 1) = '\0';
    
    // Move trimmed string to beginning
    if (start != str) {
        memmove(str, start, strlen(start) + 1);
    }
}

static int tokenize(char* line, char* tokens[], int max_tokens) {
    int count = 0;
    char* token = strtok(line, " \t\n\r,()=");
    
    while (token != NULL && count < max_tokens) {
        tokens[count++] = token;
        token = strtok(NULL, " \t\n\r,()=");
    }
    
    return count;
}

bool parse_bench_line(Circuit* circuit, const char* line) {
    if (!circuit || !line) return false;
    
    char buffer[MAX_LINE_LEN];
    strncpy(buffer, line, MAX_LINE_LEN - 1);
    buffer[MAX_LINE_LEN - 1] = '\0';
    
    trim_whitespace(buffer);
    
    // Skip empty lines and comments
    if (buffer[0] == '\0' || buffer[0] == '#') {
        return true;
    }
    
    char* tokens[MAX_TOKENS];
    int num_tokens = tokenize(buffer, tokens, MAX_TOKENS);
    
    if (num_tokens == 0) return true;
    
    // Parse INPUT line: INPUT(signal_name)
    if (strcmp(tokens[0], "INPUT") == 0) {
        if (num_tokens >= 2) {
            int gate_id = circuit_add_gate(circuit, tokens[1], GATE_INPUT);
            if (gate_id >= 0) {
                circuit_set_pi(circuit, gate_id);
            }
            return true;
        }
    }
    
    // Parse OUTPUT line: OUTPUT(signal_name)
    if (strcmp(tokens[0], "OUTPUT") == 0) {
        if (num_tokens >= 2) {
            Gate* gate = circuit_get_gate_by_name(circuit, tokens[1]);
            if (gate) {
                circuit_set_po(circuit, gate->id);
            } else {
                // Create output gate if it doesn't exist
                int gate_id = circuit_add_gate(circuit, tokens[1], GATE_BUF);
                if (gate_id >= 0) {
                    circuit_set_po(circuit, gate_id);
                }
            }
            return true;
        }
    }
    
    // Parse gate line: output = GATE(input1, input2, ...)
    // Format: tokens[0] = output, tokens[1] = GATE, tokens[2...] = inputs
    if (num_tokens >= 2) {
        char* output_name = tokens[0];
        char* gate_type_str = tokens[1];
        
        GateType gate_type = gate_type_from_str(gate_type_str);
        
        // Create output gate
        int output_id = circuit_add_gate(circuit, output_name, gate_type);
        if (output_id < 0) return false;
        
        // Connect inputs
        for (int i = 2; i < num_tokens; i++) {
            char* input_name = tokens[i];
            Gate* input_gate = circuit_get_gate_by_name(circuit, input_name);
            
            if (!input_gate) {
                // Create intermediate gate if it doesn't exist
                int input_id = circuit_add_gate(circuit, input_name, GATE_BUF);
                if (input_id < 0) continue;
                input_gate = circuit_get_gate(circuit, input_id);
            }
            
            circuit_add_connection(circuit, input_gate->id, output_id);
        }
        
        return true;
    }
    
    return true;
}

Circuit* parse_bench_file(const char* filename) {
    if (!filename) return NULL;
    
    FILE* file = fopen(filename, "r");
    if (!file) {
        fprintf(stderr, "Error: Cannot open file %s\n", filename);
        return NULL;
    }
    
    Circuit* circuit = circuit_create();
    if (!circuit) {
        fclose(file);
        return NULL;
    }
    
    char line[MAX_LINE_LEN];
    int line_num = 0;
    int parse_errors = 0;
    
    printf("Parsing BENCH file: %s\n", filename);
    
    while (fgets(line, sizeof(line), file)) {
        line_num++;
        if (!parse_bench_line(circuit, line)) {
            parse_errors++;
            if (parse_errors < 10) {  // Only show first 10 errors
                fprintf(stderr, "Warning: Failed to parse line %d: %s", line_num, line);
            }
        }
        
        // Progress indicator for large files
        if (line_num % 10000 == 0) {
            printf("\rParsed %d lines, %d gates...", line_num, circuit->num_gates);
            fflush(stdout);
        }
    }
    
    printf("\rParsed %d lines, %d gates total\n", line_num, circuit->num_gates);
    
    if (parse_errors > 0) {
        printf("Warning: %d lines had parse errors\n", parse_errors);
    }
    
    fclose(file);
    
    // Compute topological levels
    printf("Computing topological levels...\n");
    circuit_levelization(circuit);
    
    printf("Circuit parsed successfully:\n");
    printf("  Gates: %d\n", circuit->num_gates);
    printf("  Primary Inputs: %d\n", circuit->num_pis);
    printf("  Primary Outputs: %d\n", circuit->num_pos);
    printf("  Max Level: %d\n", circuit->max_level);
    
    return circuit;
}
