#include "circuit.h"
#include "parser.h"
#include "dft_drc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void print_usage(const char* prog) {
    printf("Usage: %s <circuit.bench> [options]\n", prog);
    printf("Options:\n");
    printf("  -o <file>    Output report file (default: dft_drc_report.txt)\n");
    printf("  -h           Show this help message\n");
    printf("\nExample:\n");
    printf("  %s circuit.bench -o report.txt\n", prog);
}

int main(int argc, char** argv) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }
    
    const char* input_file = argv[1];
    const char* output_file = "dft_drc_report.txt";
    
    // Parse command line arguments
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            output_file = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
    }
    
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║           DFT Design Rule Checker (DRC)                     ║\n");
    printf("║                 C Implementation                             ║\n");
    printf("╚══════════════════════════════════════════════════════════════╝\n");
    printf("\n");
    
    clock_t start_time = clock();
    
    // Parse circuit
    printf("Reading circuit from '%s'...\n", input_file);
    Circuit* circuit = parse_bench_file(input_file);
    if (!circuit) {
        printf("Error: Failed to parse circuit file\n");
        return 1;
    }
    
    printf("\nCircuit Statistics:\n");
    printf("  Total gates:       %d\n", circuit->num_gates);
    printf("  Primary inputs:    %d\n", circuit->num_pis);
    printf("  Primary outputs:   %d\n", circuit->num_pos);
    printf("  Maximum level:     %d\n", circuit->max_level);
    
    // Count DFFs
    int num_dffs = 0;
    for (int i = 0; i < circuit->num_gates; i++) {
        if (circuit->gates[i].type == GATE_DFF) {
            num_dffs++;
        }
    }
    printf("  DFFs:              %d\n", num_dffs);
    
    // Create DRC checker
    printf("\nCreating DFT DRC checker...\n");
    DFTDRCEngine* drc = dft_drc_create(circuit);
    if (!drc) {
        printf("Error: Failed to create DRC checker\n");
        circuit_free(circuit);
        return 1;
    }
    
    // Run DRC checks
    bool passed = dft_drc_check_all(drc);
    
    // Print report
    dft_drc_print_report(drc);
    
    // Save report to file
    dft_drc_save_report(drc, output_file);
    
    // Calculate execution time
    clock_t end_time = clock();
    double exec_time = (double)(end_time - start_time) / CLOCKS_PER_SEC;
    
    printf("\nExecution time: %.2f seconds\n", exec_time);
    
    // Clean up
    dft_drc_free(drc);
    circuit_free(circuit);
    
    return passed ? 0 : 1;
}
