#ifndef DFT_DRC_H
#define DFT_DRC_H

#include "circuit.h"
#include <stdbool.h>

#define MAX_VIOLATIONS 10000
#define MAX_CLOCK_DOMAINS 64
#define MAX_RESET_DOMAINS 64

/**
 * DRC violation types
 */
typedef enum {
    DRC_CLOCK_UNCONTROLLABLE = 0,
    DRC_RESET_UNCONTROLLABLE,
    DRC_CLOCK_GATING_NO_BYPASS,
    DRC_ASYNC_RESET_NO_CONTROL,
    DRC_COMBINATIONAL_LOOP,
    DRC_TRISTATE_IN_SCAN,
    DRC_DFF_NO_CLOCK,
    DRC_DFF_NO_RESET,
    DRC_SCAN_CHAIN_INCOMPLETE,
    DRC_FLOATING_INPUT,
    DRC_MULTIPLE_CLOCKS_ON_DFF,
    DRC_GATED_CLOCK_ON_DFF
} DRCViolationType;

/**
 * Clock domain information
 */
typedef struct {
    int clock_gate_id;              // Clock source/gate ID
    char clock_name[MAX_NAME_LEN];  // Clock signal name
    int* controlled_dffs;           // DFFs controlled by this clock
    int num_dffs;                   // Number of DFFs
    bool is_controllable;           // Is clock controllable from PI
    bool has_gating;                // Has clock gating logic
    bool gating_bypassable;         // Clock gating can be bypassed
    int gating_control_id;          // Clock gating control signal ID
} ClockDomain;

/**
 * Reset domain information
 */
typedef struct {
    int reset_gate_id;              // Reset source/gate ID
    char reset_name[MAX_NAME_LEN];  // Reset signal name
    int* controlled_dffs;           // DFFs controlled by this reset
    int num_dffs;                   // Number of DFFs
    bool is_controllable;           // Is reset controllable from PI
    bool is_async;                  // Is asynchronous reset
    bool has_control_in_test;       // Has control in test mode
} ResetDomain;

/**
 * DRC violation record
 */
typedef struct {
    DRCViolationType type;          // Violation type
    int gate_id;                    // Gate where violation occurs
    char gate_name[MAX_NAME_LEN];   // Gate name
    char description[512];          // Detailed description
    int severity;                   // Severity level (0=info, 1=warning, 2=error, 3=critical)
} DRCViolation;

/**
 * DFT DRC checker engine
 */
typedef struct {
    Circuit* circuit;               // Circuit to check
    
    // Clock analysis
    ClockDomain* clock_domains;     // Clock domains
    int num_clock_domains;          // Number of clock domains
    
    // Reset analysis
    ResetDomain* reset_domains;     // Reset domains
    int num_reset_domains;          // Number of reset domains
    
    // Violations
    DRCViolation* violations;       // DRC violations
    int num_violations;             // Number of violations
    int capacity_violations;        // Violations array capacity
    
    // Statistics
    int num_errors;                 // Number of errors
    int num_warnings;               // Number of warnings
    int num_info;                   // Number of info messages
} DFTDRCEngine;

/**
 * Create DFT DRC checker
 */
DFTDRCEngine* dft_drc_create(Circuit* circuit);

/**
 * Free DFT DRC checker
 */
void dft_drc_free(DFTDRCEngine* drc);

/**
 * Run all DRC checks
 */
bool dft_drc_check_all(DFTDRCEngine* drc);

/**
 * Check clock controllability
 */
bool dft_drc_check_clock_controllability(DFTDRCEngine* drc);

/**
 * Check reset controllability
 */
bool dft_drc_check_reset_controllability(DFTDRCEngine* drc);

/**
 * Check for combinational loops
 */
bool dft_drc_check_combinational_loops(DFTDRCEngine* drc);

/**
 * Check DFF connectivity
 */
bool dft_drc_check_dff_connectivity(DFTDRCEngine* drc);

/**
 * Check for clock gating
 */
bool dft_drc_check_clock_gating(DFTDRCEngine* drc);

/**
 * Check for tristate logic in scan path
 */
bool dft_drc_check_tristate(DFTDRCEngine* drc);

/**
 * Identify clock domains
 */
int dft_drc_identify_clock_domains(DFTDRCEngine* drc);

/**
 * Identify reset domains
 */
int dft_drc_identify_reset_domains(DFTDRCEngine* drc);

/**
 * Add a violation
 */
void dft_drc_add_violation(DFTDRCEngine* drc, DRCViolationType type, 
                           int gate_id, const char* description, int severity);

/**
 * Print DRC report
 */
void dft_drc_print_report(const DFTDRCEngine* drc);

/**
 * Save DRC report to file
 */
bool dft_drc_save_report(const DFTDRCEngine* drc, const char* filename);

/**
 * Get violation type name
 */
const char* dft_drc_violation_type_str(DRCViolationType type);

/**
 * Check if gate is in path from source to target (for controllability)
 */
bool dft_drc_is_controllable_from_pi(Circuit* circuit, int gate_id);

/**
 * Trace clock source for a DFF
 */
int dft_drc_trace_clock_source(Circuit* circuit, int dff_id);

/**
 * Trace reset source for a DFF
 */
int dft_drc_trace_reset_source(Circuit* circuit, int dff_id);

#endif // DFT_DRC_H
