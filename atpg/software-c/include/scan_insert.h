#ifndef SCAN_INSERT_H
#define SCAN_INSERT_H

#include "circuit.h"
#include <stdbool.h>

#define MAX_CHAINS 64

/**
 * Scan chain configuration
 */
typedef struct {
    int chain_id;                   // Chain ID
    char si_port[MAX_NAME_LEN];     // Scan input port name
    char so_port[MAX_NAME_LEN];     // Scan output port name
    int* dff_ids;                   // DFF gate IDs in this chain
    int num_dffs;                   // Number of DFFs in this chain
    int capacity;                   // Array capacity
} ScanChain;

/**
 * Scan insertion engine
 */
typedef struct {
    Circuit* circuit;               // Original circuit
    Circuit* scan_circuit;          // Circuit with scan chains
    ScanChain* chains;              // Scan chains
    int num_chains;                 // Number of chains
    int* dff_list;                  // List of all DFF IDs
    int num_dffs;                   // Total number of DFFs
    bool scan_enable_added;         // Scan enable signal added
    char scan_enable[MAX_NAME_LEN]; // Scan enable port name
} ScanEngine;

/**
 * Create scan insertion engine
 */
ScanEngine* scan_create(Circuit* circuit);

/**
 * Free scan insertion engine
 */
void scan_free(ScanEngine* engine);

/**
 * Find all DFFs in the circuit
 */
int scan_find_dffs(ScanEngine* engine);

/**
 * Insert scan chains
 */
bool scan_insert_chains(ScanEngine* engine, int num_chains);

/**
 * Generate scan definition file
 */
bool scan_save_scandef(const ScanEngine* engine, const char* filename);

/**
 * Print scan insertion statistics
 */
void scan_print_stats(const ScanEngine* engine);

#endif // SCAN_INSERT_H
