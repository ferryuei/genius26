# RTL-to-RTL2 migration and retirement policy

## Current decision

The `rtl` directory is retained. It is not compiled into RTL2 and must not be
used as a fallback implementation. Deleting it now would remove useful scenario
and register vocabulary before equivalent executable specifications exist.

## Material selected for migration

The following concepts are useful, but implementations are not copied:

- Ethernet/VLAN packet vocabulary from `switch_pkg.sv` and `tb/tb_pkg.sv`.
- MAC/FDB, ACL, LAG, multicast, Pause and QoS scenario intent.
- Counter names and error categories from `port_statistics.sv`.
- Existing directed packet generators after they are changed to drive a real
  RTL2 DUT and compare against the Python model.

The new `switch2_pkg.sv` already replaces the unsafe widths and separates
packet descriptors from queue nodes.

## Files treated as legacy reference only

- `model/switch_core.py`: useful packet/configuration vocabulary, but not a
  golden model.
- Protocol-engine RTL: useful control-frame formats and scenario ideas, while
  protocol state machines move to control software.
- Old architecture and gap documents: useful requirement leads, but their
  completion percentages and timing/synthesis claims are not accepted.

## Implementations to retire rather than port

- `ingress_pipeline.sv`
- `cell_allocator.sv`
- `packet_buffer.sv`
- `egress_scheduler.sv`
- `egress_output_ctrl.sv`
- `switch_core.sv` and `switch_core_backup.sv`
- standalone RTL implementations of SNMP, RADIUS-facing 802.1X state, LLDP
  databases and spanning-tree state machines
- self-modeling performance/VLAN/storm tests that do not instantiate the DUT
- manually authored synthesis/timing reports without generated tool evidence

## Required gates before deleting `rtl`

1. Every retained requirement has an owner in the Python model, RTL2, control
   software specification or an explicitly deferred list.
2. RTL2 passes warning-gated whole-tree lint with no undriven, width or
   multi-driven diagnostics.
3. End-to-end unicast, flood, multicast, ACL, LAG, backpressure, multi-Cell and
   resource-exhaustion tests instantiate RTL2 and compare against the model.
4. Cell, descriptor and queue-node conservation properties pass formal or
   assertion-based proofs over bounded configurations.
5. A real synthesis run completes with explicit SRAM black boxes and checked-in
   timing constraints.
6. Any useful frame-format vectors and register definitions have been moved to
   non-legacy locations.
7. The last pre-deletion commit/tag is recorded and a final deletion diff is
   reviewed explicitly.

Only after all seven gates pass should a separate, explicitly approved change
delete `rtl`, obsolete tests and invalid reports. Until then the two trees stay
independent and no new functionality is added to `rtl`.
