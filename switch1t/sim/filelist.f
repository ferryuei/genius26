// Filelist for 1.2Tbps Switch Core
// 用于仿真和综合

// Package (必须首先编译)
+incdir+../rtl
../rtl/switch_pkg.sv

// RTL模块
../rtl/cell_allocator.sv
../rtl/packet_buffer.sv
../rtl/mac_table.sv
../rtl/acl_engine.sv
../rtl/ingress_pipeline.sv
../rtl/egress_scheduler.sv
../rtl/switch_core.sv

// Testbench
../tb/tb_switch_core.sv
