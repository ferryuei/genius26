#ifndef ATPG_H
#define ATPG_H

#include "circuit.h"
#include "logic.h"
#include <stdbool.h>

/**
 * ATPG Algorithm types
 */
typedef enum {
    ATPG_D_ALGORITHM,
    ATPG_PODEM,
    ATPG_FAN
} ATPGAlgorithm;

/**
 * ATPG Engine
 */
typedef struct {
    Circuit* circuit;               // Circuit to test
    Fault* faults;                  // Array of faults
    int num_faults;                 // Number of faults
    TestPattern* patterns;          // Test patterns
    int num_patterns;               // Number of patterns
    ATPGAlgorithm algorithm;        // ATPG algorithm
    int max_backtracks;             // Maximum backtracks
    int timeout_ms;                 // Timeout in milliseconds
} ATPGEngine;

/**
 * Create ATPG engine
 */
ATPGEngine* atpg_create(Circuit* circuit, ATPGAlgorithm algorithm);

/**
 * Free ATPG engine
 */
void atpg_free(ATPGEngine* atpg);

/**
 * Generate all stuck-at faults
 */
void atpg_generate_faults(ATPGEngine* atpg);

/**
 * Run ATPG to generate test patterns
 */
bool atpg_run(ATPGEngine* atpg);

/**
 * Generate test pattern for a specific fault
 */
bool atpg_generate_pattern(ATPGEngine* atpg, Fault* fault, TestPattern* pattern);

/**
 * Fault simulation - simulate all faults with a test pattern
 */
int atpg_fault_simulate(ATPGEngine* atpg, const TestPattern* pattern);

/**
 * Calculate fault coverage
 */
double atpg_calculate_coverage(const ATPGEngine* atpg);

/**
 * Print statistics
 */
void atpg_print_stats(const ATPGEngine* atpg);

/**
 * Save test patterns to file
 */
bool atpg_save_patterns(const ATPGEngine* atpg, const char* filename);

/**
 * D-Algorithm implementation
 */
bool atpg_d_algorithm(ATPGEngine* atpg, Fault* fault, TestPattern* pattern);

/**
 * PODEM algorithm implementation
 */
bool atpg_podem(ATPGEngine* atpg, Fault* fault, TestPattern* pattern);

#endif // ATPG_H
