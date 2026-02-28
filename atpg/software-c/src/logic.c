#include "logic.h"
#include <string.h>
#include <stdio.h>

const char* logic_to_str(Logic l) {
    switch (l) {
        case LOGIC_0: return "0";
        case LOGIC_1: return "1";
        case LOGIC_X: return "X";
        case LOGIC_D: return "D";
        case LOGIC_D_BAR: return "D'";
        default: return "?";
    }
}

Logic logic_from_str(const char* s) {
    if (!s) return LOGIC_X;
    if (strcmp(s, "0") == 0) return LOGIC_0;
    if (strcmp(s, "1") == 0) return LOGIC_1;
    if (strcmp(s, "X") == 0 || strcmp(s, "x") == 0) return LOGIC_X;
    if (strcmp(s, "D") == 0) return LOGIC_D;
    if (strcmp(s, "D'") == 0 || strcmp(s, "DB") == 0) return LOGIC_D_BAR;
    return LOGIC_X;
}

Logic logic_not(Logic a) {
    switch (a) {
        case LOGIC_0: return LOGIC_1;
        case LOGIC_1: return LOGIC_0;
        case LOGIC_X: return LOGIC_X;
        case LOGIC_D: return LOGIC_D_BAR;
        case LOGIC_D_BAR: return LOGIC_D;
        default: return LOGIC_X;
    }
}

Logic logic_and(Logic a, Logic b) {
    // 0 AND anything = 0
    if (a == LOGIC_0 || b == LOGIC_0) {
        return LOGIC_0;
    }
    // 1 AND x = x
    if (a == LOGIC_1) return b;
    if (b == LOGIC_1) return a;
    // X AND anything (except 0) = X
    if (a == LOGIC_X || b == LOGIC_X) {
        return LOGIC_X;
    }
    // D AND D = D, D' AND D' = D'
    if (a == b) return a;
    // D AND D' = 0
    return LOGIC_0;
}

Logic logic_or(Logic a, Logic b) {
    // 1 OR anything = 1
    if (a == LOGIC_1 || b == LOGIC_1) {
        return LOGIC_1;
    }
    // 0 OR x = x
    if (a == LOGIC_0) return b;
    if (b == LOGIC_0) return a;
    // X OR anything (except 1) = X
    if (a == LOGIC_X || b == LOGIC_X) {
        return LOGIC_X;
    }
    // D OR D = D, D' OR D' = D'
    if (a == b) return a;
    // D OR D' = 1
    return LOGIC_1;
}

Logic logic_xor(Logic a, Logic b) {
    // XOR with X
    if (a == LOGIC_X || b == LOGIC_X) {
        return LOGIC_X;
    }
    // XOR with 0
    if (a == LOGIC_0) return b;
    if (b == LOGIC_0) return a;
    // XOR with 1
    if (a == LOGIC_1) return logic_not(b);
    if (b == LOGIC_1) return logic_not(a);
    // D XOR D = 0, D' XOR D' = 0
    if (a == b) return LOGIC_0;
    // D XOR D' = 1
    return LOGIC_1;
}

Logic logic_nand(Logic a, Logic b) {
    return logic_not(logic_and(a, b));
}

Logic logic_nor(Logic a, Logic b) {
    return logic_not(logic_or(a, b));
}

Logic logic_xnor(Logic a, Logic b) {
    return logic_not(logic_xor(a, b));
}

Logic logic_and_n(const Logic* inputs, int n) {
    if (n == 0) return LOGIC_X;
    if (n == 1) return inputs[0];
    
    Logic result = inputs[0];
    for (int i = 1; i < n; i++) {
        result = logic_and(result, inputs[i]);
        if (result == LOGIC_0) {
            return LOGIC_0;  // Early termination
        }
    }
    return result;
}

Logic logic_or_n(const Logic* inputs, int n) {
    if (n == 0) return LOGIC_X;
    if (n == 1) return inputs[0];
    
    Logic result = inputs[0];
    for (int i = 1; i < n; i++) {
        result = logic_or(result, inputs[i]);
        if (result == LOGIC_1) {
            return LOGIC_1;  // Early termination
        }
    }
    return result;
}

Logic logic_xor_n(const Logic* inputs, int n) {
    if (n == 0) return LOGIC_X;
    if (n == 1) return inputs[0];
    
    Logic result = inputs[0];
    for (int i = 1; i < n; i++) {
        result = logic_xor(result, inputs[i]);
    }
    return result;
}
