# ATPG - Automatic Test Pattern Generation (C Implementation)
# Makefile for building the high-performance C version

CC = gcc
CFLAGS = -Wall -Wextra -O3 -march=native -flto -std=c11
DEBUG_CFLAGS = -Wall -Wextra -g -O0 -std=c11 -DDEBUG
INCLUDE = -Iinclude
LDFLAGS = -lm

# Directories
SRC_DIR = src
INC_DIR = include
OBJ_DIR = obj
BIN_DIR = bin
TEST_DIR = tests

# Source files
ATPG_SOURCES = $(SRC_DIR)/logic.c \
               $(SRC_DIR)/circuit.c \
               $(SRC_DIR)/parser.c \
               $(SRC_DIR)/atpg.c \
               $(SRC_DIR)/main.c

SCAN_SOURCES = $(SRC_DIR)/logic.c \
               $(SRC_DIR)/circuit.c \
               $(SRC_DIR)/parser.c \
               $(SRC_DIR)/scan_insert.c \
               $(SRC_DIR)/scan_main.c

DFT_DRC_SOURCES = $(SRC_DIR)/logic.c \
                  $(SRC_DIR)/circuit.c \
                  $(SRC_DIR)/parser.c \
                  $(SRC_DIR)/dft_drc.c \
                  $(SRC_DIR)/dft_drc_main.c

# Object files
ATPG_OBJECTS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(ATPG_SOURCES))
SCAN_OBJECTS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(SCAN_SOURCES))
DFT_DRC_OBJECTS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(DFT_DRC_SOURCES))

# Target executables
ATPG_TARGET = $(BIN_DIR)/atpg
SCAN_TARGET = $(BIN_DIR)/scan_insert
DFT_DRC_TARGET = $(BIN_DIR)/dft_drc
TARGETS = $(ATPG_TARGET) $(SCAN_TARGET) $(DFT_DRC_TARGET)

# Default target
all: directories $(TARGETS)

# Create necessary directories
directories:
	@mkdir -p $(OBJ_DIR)
	@mkdir -p $(BIN_DIR)

# Build ATPG target
$(ATPG_TARGET): $(ATPG_OBJECTS)
	@echo "Linking $@..."
	@$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)
	@echo "Build complete: $@"

# Build Scan Insert target
$(SCAN_TARGET): $(SCAN_OBJECTS)
	@echo "Linking $@..."
	@$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)
	@echo "Build complete: $@"

# Build DFT DRC target
$(DFT_DRC_TARGET): $(DFT_DRC_OBJECTS)
	@echo "Linking $@..."
	@$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)
	@echo "Build complete: $@"

# Compile source files
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c
	@echo "Compiling $<..."
	@$(CC) $(CFLAGS) $(INCLUDE) -c $< -o $@

# Debug build
debug: CFLAGS = $(DEBUG_CFLAGS)
debug: clean all

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(OBJ_DIR) $(BIN_DIR)
	@rm -f *.txt *.pat *.log
	@echo "Clean complete"

# Install (optional)
install: $(TARGET)
	@echo "Installing to /usr/local/bin..."
	@sudo cp $(TARGET) /usr/local/bin/
	@echo "Installation complete"

# Uninstall
uninstall:
	@echo "Uninstalling from /usr/local/bin..."
	@sudo rm -f /usr/local/bin/atpg
	@echo "Uninstall complete"

# Run tests (if test circuits exist)
test: $(TARGETS)
	@echo "Running tests..."
	@if [ -f tests/test_simple.bench ]; then \
		echo "Testing ATPG..."; \
		$(ATPG_TARGET) tests/test_simple.bench -o test_c17.pat; \
		echo "Testing Scan Insert..."; \
		$(SCAN_TARGET) tests/test_simple.bench -n 4 -o test_scan; \
	fi
	@echo "Tests complete"

# Performance test with optimization flags
perf: CFLAGS += -pg
perf: clean all

# Help
help:
	@echo "ATPG Makefile - Available targets:"
	@echo "  all       - Build the ATPG tool (default)"
	@echo "  debug     - Build with debug symbols"
	@echo "  clean     - Remove build artifacts"
	@echo "  install   - Install to /usr/local/bin"
	@echo "  uninstall - Remove from /usr/local/bin"
	@echo "  test      - Run tests on benchmark circuits"
	@echo "  perf      - Build with profiling support"
	@echo "  help      - Show this help message"

.PHONY: all directories debug clean install uninstall test perf help
