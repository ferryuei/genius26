# Switch1T RTL2

`rtl2` is a clean data-plane redesign. It does not import or instantiate files
from `rtl`; both trees can therefore be reviewed and built independently during
migration.

Current milestone:

- frozen 48x25G/500MHz sizing constants and corrected field widths;
- separate packet descriptors and egress queue nodes;
- explicit four-Cell ingress and four-Cell egress architecture budgets;
- one elastic FIFO per MAC receive lane, preserving simultaneous handshakes;
- a lossless per-port L2 parser with metadata backpressure;
- 128-byte per-port Cell assembly and a lossless 48-to-4 RR concentrator;
- a 16-bank Cell-ID pool with sequential initialization, ownership tracking and
  double-free detection;
- a conflict-aware 16-bank behavioral Cell/link store with synchronous,
  backpressured read responses;
- an atomic four-lane allocate/store/commit pipeline, per-source Cell ordering,
  forward-chain construction and link-before-complete enforcement;
- a four-lane descriptor allocator that joins completed chains to the matching
  held parser metadata;
- `switch2_ingress_storage`, an integrated ingress-to-admission milestone with
  atomic Cell pool/store invalidation on release;
- warning-gated Verilator lint and directed tests for each implemented block.

Run:

```sh
make -C rtl2 lint
make -C rtl2 test
```

`switch2_core_shell` remains the parser/Cell concentration boundary.
`switch2_ingress_storage` extends that boundary through Cell storage and
descriptor-tagged admission. Neither is yet a forwarding core. The next
milestone implements the four-lane VLAN/ACL/L2 lookup transaction, followed by
atomic queue-node replication and rollback.

The old RTL must not be deleted until the gates in
`../doc/RTL2_MIGRATION_AND_RETIREMENT.md` are satisfied.
