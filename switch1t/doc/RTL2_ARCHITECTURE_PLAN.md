# Switch1T RTL2 architecture and execution plan

## 1. Objective and status

The target remains an industrial 48x25GbE, full-duplex L2 switching data
plane. The core clock assumption is 500 MHz. RTL2 is a clean implementation;
the old `rtl` tree is a read-only migration source until retirement gates are
met.

Status of the current executable baseline:

- packet-level golden model: present and tested;
- analytical/cycle capacity model: present and tested;
- atomic resource-ownership model: present and tested;
- corrected RTL constants and transaction types: present;
- independent per-port ingress elasticity: implemented, linted and tested;
- parser and 128-byte Cell assembly: implemented, linted and tested;
- lossless 48-to-4 Cell arbitration: implemented, linted and tested;
- 16-bank Cell free pool and behavioral payload/link store: implemented,
  linted and tested as independent blocks;
- the integrated ingress-to-storage path, per-port Cell ordering, Cell-chain
  completion, parser-metadata join and four-lane descriptor allocation:
  implemented, linted and tested;
- forwarding lookup, queue-node admission/rollback, queueing and egress: not
  implemented yet.

No document in the old tree that claims synthesis, timing or protocol
completeness is accepted as signoff evidence.

## 2. Frozen first-pass capacity budget

| Quantity | Required line-rate value | RTL2 provision |
|---|---:|---:|
| Aggregate bandwidth, one direction | 1.2 Tbps | 1.2 Tbps target |
| Input bytes at 500 MHz | 300 B/cycle | 48 independent 64-bit lanes |
| 128-byte cells, one direction | 2.34375 cells/cycle | 4 cells/cycle |
| Shared-memory reads plus writes | 4.6875 operations/cycle | 4 write + 4 read |
| Minimum-frame issue rate | 3.5714 packets/cycle | 4 lookup lanes |
| Packet-memory banks | at least 8 simultaneous ports | 16 banks |
| Packet buffer | 65,536 x 128 B | 8 MiB |
| Packet descriptors | at least one per cell | 65,536 |
| Egress queues | 48 x 8 | 384 |

The four lookup lanes meet sustained minimum-frame load with limited margin.
Per-port metadata FIFOs must absorb phase alignment and short bursts. Before
freezing physical implementation, an eight-lane lookup option must be compared
for area, power and congestion margin.

## 3. Data-plane architecture

```text
48 x 64-bit RX MAC lanes
        |
48 elastic FIFOs / frame trackers / header captures / cell assembly buffers
        |                              |
        | up to 4 completed cells/cyc  | up to 4 packet metadata/cyc
        v                              v
  4-lane write fabric        Parser -> VLAN -> ACL -> L2/LAG/MC action
        |                              |
        +---------- Admission / replication transaction ----------+
                                  |
              16-bank shared packet and metadata memory
                   |                          |
          packet descriptor pool      independent queue-node pool
                   |                          |
                   +------ 48 x 8 queues -----+
                                  |
              48 schedulers -> 4-lane read request fabric
                                  |
                 per-port egress cell FIFO / deparser
                                  |
                         48 x 64-bit TX MAC lanes
```

### 3.1 Ingress

Every MAC lane owns its handshake and elastic FIFO. A frame tracker may not
change source port between SOP and EOP. The first header bytes are captured at
the same handshake that accepts them. Each port assembles cells locally; a
global arbiter only handles completed cells and metadata transactions, never
individual MAC beats.

### 3.2 Lookup transaction

Parser output, descriptor ID and source context travel as one tagged
transaction. VLAN, ACL, L2, multicast and LAG stages use ready/valid and return
the same transaction tag. Variable-latency tables cannot be joined by sampling
live ingress signals.

At least four lookups, four results and four admission decisions per cycle are
required. MAC learning uses a separately queued update path and must not stall
forwarding lookups.

### 3.3 Packet memory

Cell IDs are striped across 16 banks. Allocation is bank-aware and maintains a
free pool and ownership bitmap per bank. The write fabric accepts four
Cells/cycle and the read fabric accepts four Cells/cycle, subject to one
payload write and one payload read per bank per cycle. Cell forward links use
a separate metadata memory contract so link backfill cannot consume a payload
write port. Same-bank contenders remain on ready/valid inputs until selected.

Packet data, Cell linkage and descriptors use explicit SRAM contracts with one
logical write owner per memory. ECC/parity, repair and BIST ports are required
before macro integration.

### 3.4 Replication and resource ownership

A packet descriptor owns a Cell chain. Every accepted egress destination owns
a separate queue node referencing that descriptor. The packet reference count
is initialized atomically to the number of accepted queue nodes and is
decremented only after the corresponding egress completion. The descriptor and
Cells are freed when the count reaches zero.

Admission either commits all required resources or rolls the partial
allocation back. Resource exhaustion produces a precise drop reason and cannot
leak Cells, descriptors or queue nodes.

### 3.5 Egress

Each port owns eight queue heads/tails and an independent scheduler. Scheduler
dequeue is committed only after the downstream reader accepts the queue node.
The shared read fabric returns a tag identifying port, descriptor and Cell.
Per-port Cell FIFOs serialize 128-byte Cells onto the 64-bit MAC interface while
holding valid/data stable under backpressure.

## 4. Hardware/software split

RTL implements parsing, exact-match/ACL actions, VLAN edits, queueing, traffic
management, statistics, MAC control frames and control-frame trap/injection.

RSTP/MSTP, LACP state machines, LLDP databases, IGMP control, 802.1X/RADIUS,
SNMP and management protocols run on the embedded/control CPU. Software
programs hardware port, FDB, multicast, LAG, ACL and trap tables. This split is
part of the architecture, not a deferred workaround.

## 5. Implementation phases and exit gates

### Phase A - executable specification

- Functional forwarding model with deterministic decisions.
- Capacity/bank model with checked 48x25G assumptions.
- Trace schema for packets, configuration operations and expected actions.

Exit: model tests pass and all undecided behaviors are explicitly listed.

### Phase B - ingress and storage

- Per-port frame tracker, parser and Cell assembly.
- Four-lane completed-Cell arbiter.
- Bank-aware Cell allocator, descriptor allocator and rollback.
- 16-bank memory behavioral model.

Exit: simultaneous 48-port acceptance, multi-Cell integrity, backpressure and
resource-conservation tests pass.

Current result: the ingress/Cell/descriptor subset passes directed block tests
and a four-port plus multi-Cell end-to-end test. Queue-node atomic admission and
its RTL rollback path remain open, so Phase B as a whole is not signed off.

### Phase C - forwarding

- Four-lane VLAN/ACL/L2 pipeline with transaction tags.
- CPU-programmable FDB and multicast/LAG tables.
- Atomic replication into independent queue nodes.

Exit: every RTL decision matches the Python golden model for directed and
random traces; no packet is silently lost or duplicated.

### Phase D - egress and traffic management

- 384 queues, SP plus deficit/weighted round-robin.
- Four-lane banked read fabric and per-port egress Cell FIFOs.
- Tail drop, WRED/ECN and Pause/PFC after headroom modeling.

Exit: all packet sizes sustain the offered nonblocking load, scheduler fairness
is bounded and congested destinations do not block unrelated ports.

### Phase E - industrialization

- SRAM macro wrappers, ECC/parity, BIST and repair.
- CDC/RDC, reset sequencing, watchdogs and error containment.
- DFT/scan, assertions, formal resource proofs and coverage closure.
- Synthesis, STA, power, floorplan and traffic-based performance signoff.

Exit: reproducible reports are generated by scripts from checked-in inputs;
estimated or manually written timing reports are not signoff artifacts.

## 6. Mandatory invariants

- An accepted MAC beat is eventually consumed exactly once unless reset aborts
  the interface according to its contract.
- Every packet commits exactly one descriptor.
- Allocated Cells equal free Cells plus Cells owned by committed or in-flight
  packets.
- Queue nodes equal free nodes plus nodes reachable from exactly one queue.
- A packet is released after, and only after, its final egress reference.
- Output valid and data remain stable while ready is low.
- Drops have an enumerated reason and release all owned resources.
- No RAM or architectural state has multiple procedural writers.
