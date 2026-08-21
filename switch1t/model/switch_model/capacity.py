"""Analytical and small cycle model for shared-buffer sizing."""

import math
import random
from collections import deque

from .config import SwitchConfig


class CapacityReport(object):
    def __init__(self, config):
        self.aggregate_line_bps = config.aggregate_line_bps
        self.ingress_bytes_per_cycle = config.ingress_bytes_per_cycle
        self.line_cells_per_cycle = config.line_cells_per_cycle
        self.memory_cell_ops_per_cycle = config.memory_cell_ops_per_cycle
        self.minimum_frame_packets_per_cycle = config.minimum_frame_packets_per_cycle
        self.required_ingress_cell_lanes = int(math.ceil(config.line_cells_per_cycle))
        self.required_egress_cell_lanes = int(math.ceil(config.line_cells_per_cycle))
        self.required_lookup_lanes = int(
            math.ceil(config.minimum_frame_packets_per_cycle)
        )
        self.provided_ingress_cell_lanes = config.ingress_cell_lanes
        self.provided_egress_cell_lanes = config.egress_cell_lanes
        self.provided_lookup_lanes = config.lookup_lanes
        self.num_banks = config.num_banks
        self.validation_errors = config.validation_errors()

    @property
    def passes(self):
        return not self.validation_errors

    def as_dict(self):
        return {
            "aggregate_line_bps": self.aggregate_line_bps,
            "ingress_bytes_per_cycle": self.ingress_bytes_per_cycle,
            "line_cells_per_cycle": self.line_cells_per_cycle,
            "memory_cell_ops_per_cycle": self.memory_cell_ops_per_cycle,
            "minimum_frame_packets_per_cycle": self.minimum_frame_packets_per_cycle,
            "required_ingress_cell_lanes": self.required_ingress_cell_lanes,
            "required_egress_cell_lanes": self.required_egress_cell_lanes,
            "required_lookup_lanes": self.required_lookup_lanes,
            "provided_ingress_cell_lanes": self.provided_ingress_cell_lanes,
            "provided_egress_cell_lanes": self.provided_egress_cell_lanes,
            "provided_lookup_lanes": self.provided_lookup_lanes,
            "num_banks": self.num_banks,
            "validation_errors": list(self.validation_errors),
        }


class BankSimulationReport(object):
    def __init__(self):
        self.offered_cycles = 0
        self.total_requests = 0
        self.max_backlog = 0
        self.max_bank_depth = 0
        self.backlog_after_offer = 0
        self.drain_cycles = 0
        self.issued_reads = 0
        self.issued_writes = 0

    @property
    def drained(self):
        return self.backlog_after_offer >= 0 and self.total_requests == (
            self.issued_reads + self.issued_writes
        )


class _BankedMemory(object):
    def __init__(self, num_banks, read_lanes, write_lanes):
        self.queues = [deque() for _ in range(num_banks)]
        self.read_lanes = read_lanes
        self.write_lanes = write_lanes
        self.rr_bank = 0
        self.issued_reads = 0
        self.issued_writes = 0

    def enqueue(self, kind, bank):
        self.queues[bank].append(kind)

    def backlog(self):
        return sum(len(queue) for queue in self.queues)

    def max_bank_depth(self):
        return max(len(queue) for queue in self.queues)

    def step(self):
        read_budget = self.read_lanes
        write_budget = self.write_lanes
        num_banks = len(self.queues)
        for offset in range(num_banks):
            bank = (self.rr_bank + offset) % num_banks
            if not self.queues[bank]:
                continue
            kind = self.queues[bank][0]
            if kind == "read" and read_budget:
                self.queues[bank].popleft()
                read_budget -= 1
                self.issued_reads += 1
            elif kind == "write" and write_budget:
                self.queues[bank].popleft()
                write_budget -= 1
                self.issued_writes += 1
        self.rr_bank = (self.rr_bank + 1) % num_banks


def analyze_capacity(config=None):
    return CapacityReport(config or SwitchConfig())


def simulate_line_rate(config=None, offered_cycles=10000, seed=1):
    """Exercise bank queues at 1.2 Tbps write plus 1.2 Tbps read load.

    Requests use a deterministic pseudo-random bank distribution. This model
    validates gross service capacity and queue behavior; it is not a timing
    model for a particular SRAM macro or allocator.
    """

    config = config or SwitchConfig()
    config.validate()
    rng = random.Random(seed)
    memory = _BankedMemory(
        config.num_banks,
        config.egress_cell_lanes,
        config.ingress_cell_lanes,
    )
    report = BankSimulationReport()
    report.offered_cycles = offered_cycles
    write_credit = 0.0
    read_credit = 0.0

    for _ in range(offered_cycles):
        write_credit += config.line_cells_per_cycle
        read_credit += config.line_cells_per_cycle
        while write_credit >= 1.0:
            memory.enqueue("write", rng.randrange(config.num_banks))
            write_credit -= 1.0
            report.total_requests += 1
        while read_credit >= 1.0:
            memory.enqueue("read", rng.randrange(config.num_banks))
            read_credit -= 1.0
            report.total_requests += 1
        memory.step()
        report.max_backlog = max(report.max_backlog, memory.backlog())
        report.max_bank_depth = max(report.max_bank_depth, memory.max_bank_depth())

    report.backlog_after_offer = memory.backlog()
    drain_limit = offered_cycles * 4 + report.backlog_after_offer + 1
    while memory.backlog() and report.drain_cycles < drain_limit:
        memory.step()
        report.drain_cycles += 1

    report.issued_reads = memory.issued_reads
    report.issued_writes = memory.issued_writes
    if memory.backlog():
        raise RuntimeError("bank queues failed to drain")
    return report
