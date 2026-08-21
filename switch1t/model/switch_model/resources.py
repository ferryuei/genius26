"""Executable ownership model for Cells, descriptors and queue nodes."""

from collections import deque

from .config import SwitchConfig


class ResourceExhausted(Exception):
    """An atomic admission could not reserve all required resources."""


class OwnershipError(Exception):
    """A resource was released by something that did not own it."""


class IndexedPool(object):
    def __init__(self, capacity, name):
        if capacity <= 0:
            raise ValueError("%s capacity must be positive" % name)
        self.capacity = capacity
        self.name = name
        self._free = deque(range(capacity))
        self._allocated = set()

    @property
    def free_count(self):
        return len(self._free)

    @property
    def allocated(self):
        return frozenset(self._allocated)

    def allocate_many(self, count):
        if count < 0:
            raise ValueError("allocation count cannot be negative")
        if count > self.free_count:
            raise ResourceExhausted(
                "%s needs %d entries, only %d free"
                % (self.name, count, self.free_count)
            )
        result = []
        for _ in range(count):
            resource_id = self._free.popleft()
            self._allocated.add(resource_id)
            result.append(resource_id)
        return result

    def release(self, resource_id):
        if resource_id not in self._allocated:
            raise OwnershipError(
                "%s %d is not allocated" % (self.name, resource_id)
            )
        self._allocated.remove(resource_id)
        self._free.append(resource_id)

    def assert_consistent(self):
        if len(self._allocated) + len(self._free) != self.capacity:
            raise AssertionError("%s conservation failure" % self.name)
        if len(set(self._free)) != len(self._free):
            raise AssertionError("%s free list contains duplicates" % self.name)
        if self._allocated.intersection(self._free):
            raise AssertionError("%s is both free and allocated" % self.name)


class BankedCellPool(object):
    """Cell IDs striped by ``cell_id % num_banks`` with RR allocation."""

    def __init__(self, capacity, num_banks):
        if capacity <= 0 or num_banks <= 0 or capacity % num_banks:
            raise ValueError("Cell capacity must divide evenly across banks")
        self.capacity = capacity
        self.num_banks = num_banks
        self._free_by_bank = [deque() for _ in range(num_banks)]
        for cell_id in range(capacity):
            self._free_by_bank[cell_id % num_banks].append(cell_id)
        self._allocated = set()
        self._rr_bank = 0

    @property
    def free_count(self):
        return sum(len(entries) for entries in self._free_by_bank)

    @property
    def allocated(self):
        return frozenset(self._allocated)

    def allocate_many(self, count):
        if count < 0:
            raise ValueError("allocation count cannot be negative")
        if count > self.free_count:
            raise ResourceExhausted(
                "Cells need %d entries, only %d free" % (count, self.free_count)
            )
        result = []
        for _ in range(count):
            for offset in range(self.num_banks):
                bank = (self._rr_bank + offset) % self.num_banks
                if self._free_by_bank[bank]:
                    cell_id = self._free_by_bank[bank].popleft()
                    self._allocated.add(cell_id)
                    result.append(cell_id)
                    self._rr_bank = (bank + 1) % self.num_banks
                    break
        return result

    def release(self, cell_id):
        if cell_id not in self._allocated:
            raise OwnershipError("Cell %d is not allocated" % cell_id)
        self._allocated.remove(cell_id)
        self._free_by_bank[cell_id % self.num_banks].append(cell_id)

    def assert_consistent(self):
        free_ids = []
        for bank, entries in enumerate(self._free_by_bank):
            for cell_id in entries:
                if cell_id % self.num_banks != bank:
                    raise AssertionError("Cell is present in the wrong bank")
                free_ids.append(cell_id)
        if len(free_ids) + len(self._allocated) != self.capacity:
            raise AssertionError("Cell conservation failure")
        if len(set(free_ids)) != len(free_ids):
            raise AssertionError("Cell free lists contain duplicates")
        if self._allocated.intersection(free_ids):
            raise AssertionError("Cell is both free and allocated")


class PacketOwnership(object):
    def __init__(self, descriptor_id, cell_ids, queue_node_ids):
        self.descriptor_id = descriptor_id
        self.cell_ids = tuple(cell_ids)
        self.queue_node_ids = set(queue_node_ids)


class SwitchResourceModel(object):
    """Atomic packet admission and final-reference release model."""

    def __init__(self, config=None):
        self.config = config or SwitchConfig()
        self.cells = BankedCellPool(
            self.config.total_cells,
            self.config.num_banks,
        )
        self.descriptors = IndexedPool(
            self.config.descriptor_count,
            "descriptor",
        )
        self.queue_nodes = IndexedPool(
            self.config.queue_node_count,
            "queue node",
        )
        self.packets = {}

    def snapshot(self):
        return {
            "free_cells": self.cells.free_count,
            "free_descriptors": self.descriptors.free_count,
            "free_queue_nodes": self.queue_nodes.free_count,
            "inflight_packets": len(self.packets),
        }

    def admit(self, cell_count, destination_count):
        if cell_count <= 0:
            raise ValueError("a packet must own at least one Cell")
        if destination_count <= 0:
            raise ValueError("an admitted packet needs at least one destination")

        descriptor_ids = []
        cell_ids = []
        queue_node_ids = []
        try:
            descriptor_ids = self.descriptors.allocate_many(1)
            cell_ids = self.cells.allocate_many(cell_count)
            queue_node_ids = self.queue_nodes.allocate_many(destination_count)
        except ResourceExhausted:
            for queue_node_id in queue_node_ids:
                self.queue_nodes.release(queue_node_id)
            for cell_id in cell_ids:
                self.cells.release(cell_id)
            for descriptor_id in descriptor_ids:
                self.descriptors.release(descriptor_id)
            self.assert_consistent()
            raise

        descriptor_id = descriptor_ids[0]
        self.packets[descriptor_id] = PacketOwnership(
            descriptor_id,
            cell_ids,
            queue_node_ids,
        )
        self.assert_consistent()
        return descriptor_id

    def complete_egress(self, descriptor_id, queue_node_id):
        packet = self.packets.get(descriptor_id)
        if packet is None:
            raise OwnershipError("descriptor %d is not in flight" % descriptor_id)
        if queue_node_id not in packet.queue_node_ids:
            raise OwnershipError(
                "queue node %d does not reference descriptor %d"
                % (queue_node_id, descriptor_id)
            )

        packet.queue_node_ids.remove(queue_node_id)
        self.queue_nodes.release(queue_node_id)
        if not packet.queue_node_ids:
            for cell_id in packet.cell_ids:
                self.cells.release(cell_id)
            self.descriptors.release(packet.descriptor_id)
            del self.packets[descriptor_id]
        self.assert_consistent()

    def assert_consistent(self):
        self.cells.assert_consistent()
        self.descriptors.assert_consistent()
        self.queue_nodes.assert_consistent()

        expected_descriptors = set(self.packets)
        expected_cells = set()
        expected_nodes = set()
        for descriptor_id, packet in self.packets.items():
            if packet.descriptor_id != descriptor_id:
                raise AssertionError("packet descriptor key mismatch")
            expected_cells.update(packet.cell_ids)
            expected_nodes.update(packet.queue_node_ids)
        if expected_descriptors != set(self.descriptors.allocated):
            raise AssertionError("descriptor ownership is not reachable")
        if expected_cells != set(self.cells.allocated):
            raise AssertionError("Cell ownership is not reachable")
        if expected_nodes != set(self.queue_nodes.allocated):
            raise AssertionError("queue-node ownership is not reachable")
