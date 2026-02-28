#ifndef LOGIC_H
#define LOGIC_H

#include <stdint.h>
#include <stdbool.h>

/**
 * 5-valued logic for D-algorithm
 * ATPG 使用的5值逻辑
 */
typedef enum {
    LOGIC_0 = 0,      // Logic 0
    LOGIC_1 = 1,      // Logic 1
    LOGIC_X = 2,      // Unknown
    LOGIC_D = 3,      // 1 in good circuit, 0 in faulty (D)
    LOGIC_D_BAR = 4   // 0 in good circuit, 1 in faulty (D')
} Logic;

/**
 * Convert logic value to string
 */
const char* logic_to_str(Logic l);

/**
 * Parse logic value from string
 */
Logic logic_from_str(const char* s);

/**
 * Logic NOT operation
 */
Logic logic_not(Logic a);

/**
 * Logic AND operation
 */
Logic logic_and(Logic a, Logic b);

/**
 * Logic OR operation
 */
Logic logic_or(Logic a, Logic b);

/**
 * Logic XOR operation
 */
Logic logic_xor(Logic a, Logic b);

/**
 * Logic NAND operation
 */
Logic logic_nand(Logic a, Logic b);

/**
 * Logic NOR operation
 */
Logic logic_nor(Logic a, Logic b);

/**
 * Logic XNOR operation
 */
Logic logic_xnor(Logic a, Logic b);

/**
 * Multi-input AND operation
 */
Logic logic_and_n(const Logic* inputs, int n);

/**
 * Multi-input OR operation
 */
Logic logic_or_n(const Logic* inputs, int n);

/**
 * Multi-input XOR operation
 */
Logic logic_xor_n(const Logic* inputs, int n);

#endif // LOGIC_H
