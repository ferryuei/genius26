#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "circuit.h"
#include "parser.h"
#include "atpg.h"

void print_usage(const char* prog_name) {
    printf("Usage: %s [OPTIONS] <bench_file>\n", prog_name);
    printf("\nOptions:\n");
    printf("  -a, --algorithm <algo>  ATPG algorithm (d-algo, podem, fan) [default: podem]\n");
    printf("  -o, --output <file>     Output test patterns file [default: patterns.txt]\n");
    printf("  -b, --backtracks <num>  Maximum backtracks [default: 10000]\n");
    printf("  -t, --timeout <ms>      Timeout in milliseconds [default: 60000]\n");
    printf("  -h, --help              Show this help message\n");
    printf("\nExample:\n");
    printf("  %s -a podem -o test.pat circuit.bench\n", prog_name);
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }
    
    // Parse command line arguments
    char* bench_file = NULL;
    char* output_file = "patterns.txt";
    ATPGAlgorithm algorithm = ATPG_PODEM;
    int max_backtracks = 10000;
    int timeout_ms = 60000;
    
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-a") == 0 || strcmp(argv[i], "--algorithm") == 0) {
            if (i + 1 < argc) {
                i++;
                if (strcmp(argv[i], "d-algo") == 0) {
                    algorithm = ATPG_D_ALGORITHM;
                } else if (strcmp(argv[i], "podem") == 0) {
                    algorithm = ATPG_PODEM;
                } else if (strcmp(argv[i], "fan") == 0) {
                    algorithm = ATPG_FAN;
                } else {
                    fprintf(stderr, "Unknown algorithm: %s\n", argv[i]);
                    return 1;
                }
            }
        } else if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) {
            if (i + 1 < argc) {
                i++;
                output_file = argv[i];
            }
        } else if (strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--backtracks") == 0) {
            if (i + 1 < argc) {
                i++;
                max_backtracks = atoi(argv[i]);
            }
        } else if (strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "--timeout") == 0) {
            if (i + 1 < argc) {
                i++;
                timeout_ms = atoi(argv[i]);
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
    
    printf("ATPG - Automatic Test Pattern Generation (C Implementation)\n");
    printf("============================================================\n\n");
    
    // Parse circuit
    printf("Parsing circuit from %s...\n", bench_file);
    Circuit* circuit = parse_bench_file(bench_file);
    if (!circuit) {
        fprintf(stderr, "Error: Failed to parse circuit\n");
        return 1;
    }
    
    // Create ATPG engine
    printf("\nCreating ATPG engine...\n");
    ATPGEngine* atpg = atpg_create(circuit, algorithm);
    if (!atpg) {
        fprintf(stderr, "Error: Failed to create ATPG engine\n");
        circuit_free(circuit);
        return 1;
    }
    
    atpg->max_backtracks = max_backtracks;
    atpg->timeout_ms = timeout_ms;
    
    // Run ATPG
    printf("\nRunning ATPG...\n");
    bool success = atpg_run(atpg);
    
    if (success) {
        // Save patterns
        printf("\nSaving test patterns to %s...\n", output_file);
        atpg_save_patterns(atpg, output_file);
    } else {
        fprintf(stderr, "Error: ATPG failed\n");
    }
    
    // Cleanup
    atpg_free(atpg);
    circuit_free(circuit);
    
    printf("\nDone!\n");
    return success ? 0 : 1;
}
