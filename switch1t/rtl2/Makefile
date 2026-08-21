VERILATOR ?= verilator
IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR_FLAGS = --timing -Wall -Wno-fatal \
	-Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
	-Werror-MULTIDRIVEN -Werror-UNDRIVEN -Werror-WIDTH

RTL_FILES = switch2_pkg.sv \
	switch2_sync_fifo.sv \
	switch2_ingress_frontend.sv \
	switch2_frame_parser.sv \
	switch2_cell_assembler.sv \
	switch2_port_inflight_guard.sv \
	switch2_cell_arbiter.sv \
	switch2_cell_bank_pool.sv \
	switch2_cell_pool.sv \
	switch2_cell_store_bank.sv \
	switch2_cell_store.sv \
	switch2_cell_write_pipeline.sv \
	switch2_packet_chain_tracker.sv \
	switch2_descriptor_pool.sv \
	switch2_packet_admission.sv \
	switch2_cell_release_fanout.sv \
	switch2_ingress_pipeline.sv \
	switch2_core_shell.sv \
	switch2_ingress_storage.sv

.PHONY: all lint test test-ingress test-parser test-assembler test-port-guard \
	test-arbiter \
	test-cell-pool test-cell-store test-cell-write-pipeline test-chain-tracker \
	test-packet-admission test-ingress-storage clean

all: lint test

lint:
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_core_shell $(RTL_FILES)
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_cell_pool switch2_pkg.sv \
		switch2_cell_bank_pool.sv switch2_cell_pool.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_cell_store switch2_pkg.sv \
		switch2_cell_store_bank.sv switch2_cell_store.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_cell_write_pipeline switch2_pkg.sv \
		switch2_cell_bank_pool.sv switch2_cell_pool.sv \
		switch2_cell_store_bank.sv switch2_cell_store.sv \
		switch2_cell_write_pipeline.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_packet_chain_tracker switch2_pkg.sv \
		switch2_packet_chain_tracker.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_packet_admission switch2_pkg.sv \
		switch2_cell_bank_pool.sv switch2_cell_pool.sv \
		switch2_descriptor_pool.sv switch2_packet_admission.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --lint-only \
		--top-module switch2_ingress_storage $(RTL_FILES)

build:
	mkdir -p build

test: test-ingress test-parser test-assembler test-port-guard test-arbiter test-cell-pool \
	test-cell-store test-cell-write-pipeline test-chain-tracker \
	test-packet-admission test-ingress-storage

test-ingress: | build
	$(IVERILOG) -g2012 -o build/rtl2_ingress_smoke.vvp \
		switch2_pkg.sv switch2_sync_fifo.sv \
		switch2_ingress_frontend.sv tb/tb_switch2_ingress_frontend.sv
	$(VVP) build/rtl2_ingress_smoke.vvp

test-parser: | build
	$(IVERILOG) -g2012 -o build/rtl2_parser_smoke.vvp \
		switch2_pkg.sv switch2_frame_parser.sv tb/tb_switch2_frame_parser.sv
	$(VVP) build/rtl2_parser_smoke.vvp

test-assembler: | build
	$(IVERILOG) -g2012 -o build/rtl2_assembler_smoke.vvp \
		switch2_pkg.sv switch2_cell_assembler.sv \
		tb/tb_switch2_cell_assembler.sv
	$(VVP) build/rtl2_assembler_smoke.vvp

test-port-guard: | build
	$(IVERILOG) -g2012 -o build/rtl2_port_guard_smoke.vvp \
		switch2_pkg.sv switch2_port_inflight_guard.sv \
		tb/tb_switch2_port_inflight_guard.sv
	$(VVP) build/rtl2_port_guard_smoke.vvp

test-arbiter: | build
	$(IVERILOG) -g2012 -o build/rtl2_arbiter_smoke.vvp \
		switch2_pkg.sv switch2_cell_arbiter.sv \
		tb/tb_switch2_cell_arbiter.sv
	$(VVP) build/rtl2_arbiter_smoke.vvp

test-cell-pool: | build
	$(IVERILOG) -g2012 -o build/rtl2_cell_pool_smoke.vvp \
		switch2_pkg.sv switch2_cell_bank_pool.sv switch2_cell_pool.sv \
		tb/tb_switch2_cell_pool.sv
	$(VVP) build/rtl2_cell_pool_smoke.vvp

test-cell-store: | build
	$(IVERILOG) -g2012 -o build/rtl2_cell_store_smoke.vvp \
		switch2_pkg.sv switch2_cell_store_bank.sv switch2_cell_store.sv \
		tb/tb_switch2_cell_store.sv
	$(VVP) build/rtl2_cell_store_smoke.vvp

test-cell-write-pipeline: | build
	$(IVERILOG) -g2012 -o build/rtl2_cell_write_pipeline_smoke.vvp \
		switch2_pkg.sv switch2_cell_bank_pool.sv switch2_cell_pool.sv \
		switch2_cell_store_bank.sv switch2_cell_store.sv \
		switch2_cell_write_pipeline.sv \
		tb/tb_switch2_cell_write_pipeline.sv
	$(VVP) build/rtl2_cell_write_pipeline_smoke.vvp

test-chain-tracker: | build
	$(IVERILOG) -g2012 -o build/rtl2_chain_tracker_smoke.vvp \
		switch2_pkg.sv switch2_packet_chain_tracker.sv \
		tb/tb_switch2_packet_chain_tracker.sv
	$(VVP) build/rtl2_chain_tracker_smoke.vvp

test-packet-admission: | build
	$(IVERILOG) -g2012 -o build/rtl2_packet_admission_smoke.vvp \
		switch2_pkg.sv switch2_cell_bank_pool.sv switch2_cell_pool.sv \
		switch2_descriptor_pool.sv switch2_packet_admission.sv \
		tb/tb_switch2_packet_admission.sv
	$(VVP) build/rtl2_packet_admission_smoke.vvp

test-ingress-storage: | build
	$(IVERILOG) -g2012 -o build/rtl2_ingress_storage_smoke.vvp \
		switch2_pkg.sv switch2_sync_fifo.sv switch2_ingress_frontend.sv \
		switch2_frame_parser.sv switch2_cell_assembler.sv \
		switch2_port_inflight_guard.sv switch2_cell_arbiter.sv \
		switch2_cell_bank_pool.sv switch2_cell_pool.sv \
		switch2_cell_store_bank.sv switch2_cell_store.sv \
		switch2_cell_write_pipeline.sv switch2_packet_chain_tracker.sv \
		switch2_descriptor_pool.sv switch2_packet_admission.sv \
		switch2_cell_release_fanout.sv switch2_ingress_pipeline.sv \
		switch2_core_shell.sv switch2_ingress_storage.sv \
		tb/tb_switch2_ingress_storage.sv
	$(VVP) build/rtl2_ingress_storage_smoke.vvp

clean:
	rm -rf build
