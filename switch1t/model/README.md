# Switch1T executable specification

This directory contains the executable specification for the `rtl2` redesign.
It has two deliberately separate roles:

- `switch_model/functional.py` is the packet-level golden model. It defines
  forwarding behavior, not RTL latency.
- `switch_model/capacity.py` is the architecture sizing and bank-queue model.
  It proves gross service rates and exposes assumptions that must be replaced
  with measured RTL behavior later.
- `switch_model/resources.py` is the executable Cell/descriptor/queue-node
  ownership model. It checks atomic admission rollback, multicast reference
  completion, bank-aware Cell allocation and exact resource conservation.

The models use only the Python 3.6 standard library.

Run all checks from the repository root:

```sh
python3 -m unittest discover -s model/tests -v
python3 -m model.capacity_report
```

`switch_core.py` is the legacy model. It is retained temporarily for vocabulary
and scenario mining, but it is not imported by the new package and is not a
golden reference. In particular, its descriptor count, multicast reference
handling and shared queue-link representation mirror limitations of the old
RTL.

The next model increments are packet policing, WRED/ECN, PFC headroom, dynamic
FDB aging and a trace format suitable for a cocotb or SystemVerilog scoreboard.
