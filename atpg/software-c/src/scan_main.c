#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "circuit.h"
#include "parser.h"
#include "scan_insert.h"

void print_usage(const char* prog_name) {
    printf("Usage: %s [OPTIONS] <bench_file>\n", prog_name);
    printf("\nOptions:\n");
    printf("  -n, --num-chains <num>  Number of scan chains [default: 8]\n");
    printf("  -o, --output <file>     Output file prefix [default: output]\n");
    printf("  -s, --scandef <file>    Scan definition output file\n");
    printf("  -h, --help              Show this help message\n");
    printf("\nExample:\n");
    printf("  %s -n 16 -o scan_circuit circuit.bench\n", prog_name);
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }
    
    // Parse command line arguments
    char* bench_file = NULL;
    char* output_prefix = "output";
    char* scandef_file = NULL;
    int num_chains = 8;
    
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--num-chains") == 0) {
            if (i + 1 < argc) {
                num_chains = atoi(argv[++i]);
            }
        } else if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) {
            if (i + 1 < argc) {
                output_prefix = argv[++i];
            }
        } else if (strcmp(argv[i], "-s") == 0 || strcmp(argv[i], "--scandef") == 0) {
            if (i + 1 < argc) {
                scandef_file = argv[++i];
            }
        } else {
            bench_file = argv[i];
        }
    }
    
    if (!bench_file) {
        fprintf(stderr, "Error: No BENCH file specified\n");
        print_usage(argv[0]);
        return 1;
    }
    
    printf("============================================================\n");
    printf("DFT SCAN CHAIN INSERTION TOOL (C Implementation)\n");
    printf("============================================================\n\n");
    
    // Start timing
    clock_t start_time = clock();
    
    // Parse circuit
    printf("Reading netlist: %s\n\n", bench_file);
    Circuit* circuit = parse_bench_file(bench_file);
    if (!circuit) {
        fprintf(stderr, "Error: Failed to parse circuit\n");
        return 1;
    }
    
    // Create scan engine
    ScanEngine* engine = scan_create(circuit);
    if (!engine) {
        fprintf(stderr, "Error: Failed to create scan engine\n");
        circuit_free(circuit);
        return 1;
    }
    
    // Find DFFs
    int num_dffs = scan_find_dffs(engine);
    if (num_dffs == 0) {
        fprintf(stderr, "Warning: No DFFs found in circuit\n");
        scan_free(engine);
        circuit_free(circuit);
        return 0;
    }
    
    // Insert scan chains
    if (!scan_insert_chains(engine, num_chains)) {
        fprintf(stderr, "Error: Failed to insert scan chains\n");
        scan_free(engine);
        circuit_free(circuit);
        return 1;
    }
    
    // Print statistics
    scan_print_stats(engine);
    
    // Save scan definition
    char scandef_path[512];
    if (scandef_file) {
        strcpy(scandef_path, scandef_file);
    } else {
        snprintf(scandef_path, sizeof(scandef_path), "%s.scandef", output_prefix);
    }
    scan_save_scandef(engine, scandef_path);
    
    // Calculate elapsed time
    clock_t end_time = clock();
    double elapsed = (double)(end_time - start_time) / CLOCKS_PER_SEC;
    
    printf("============================================================\n");
    printf("SUMMARY\n");
    printf("============================================================\n");
    printf("Total scan cells: %d\n", num_dffs);
    printf("Number of chains: %d\n", num_chains);
    printf("Elapsed time: %.2f seconds\n", elapsed);
    printf("============================================================\n\n");
    
    printf("Done!\n");
    
    // Cleanup - don't double-free circuit
    if (engine) {
        // Set circuit to NULL before freeing to avoid double-free
        engine->circuit = NULL;
        scan_free(engine);
    }
    if (circuit) {
        circuit_free(circuit);
    }
    
    return 0;
}
