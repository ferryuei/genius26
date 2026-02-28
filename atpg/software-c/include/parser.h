#ifndef PARSER_H
#define PARSER_H

#include "circuit.h"
#include <stdbool.h>

/**
 * Parse BENCH format file and create circuit
 */
Circuit* parse_bench_file(const char* filename);

/**
 * Parse a single BENCH line
 */
bool parse_bench_line(Circuit* circuit, const char* line);

#endif // PARSER_H
