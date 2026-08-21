"""Frozen first-pass sizing assumptions for the Switch1T redesign.

The model intentionally uses only the Python 3.6 standard library so it can
run on the project server without installing packages.
"""

import math


class SwitchConfig(object):
    """Architecture parameters shared by the functional and capacity models."""

    def __init__(
        self,
        num_ports=48,
        port_speed_gbps=25,
        core_frequency_mhz=500,
        port_data_width=64,
        cell_bytes=128,
        total_cells=65536,
        num_banks=16,
        ingress_cell_lanes=4,
        egress_cell_lanes=4,
        lookup_lanes=4,
        queues_per_port=8,
        max_packet_bytes=16384,
        descriptor_count=65536,
        queue_node_count=131072,
    ):
        self.num_ports = num_ports
        self.port_speed_gbps = port_speed_gbps
        self.core_frequency_mhz = core_frequency_mhz
        self.port_data_width = port_data_width
        self.cell_bytes = cell_bytes
        self.total_cells = total_cells
        self.num_banks = num_banks
        self.ingress_cell_lanes = ingress_cell_lanes
        self.egress_cell_lanes = egress_cell_lanes
        self.lookup_lanes = lookup_lanes
        self.queues_per_port = queues_per_port
        self.max_packet_bytes = max_packet_bytes
        self.descriptor_count = descriptor_count
        self.queue_node_count = queue_node_count

    @property
    def aggregate_line_bps(self):
        return self.num_ports * self.port_speed_gbps * 1.0e9

    @property
    def core_frequency_hz(self):
        return self.core_frequency_mhz * 1.0e6

    @property
    def ingress_bytes_per_cycle(self):
        return self.aggregate_line_bps / 8.0 / self.core_frequency_hz

    @property
    def line_cells_per_cycle(self):
        return self.ingress_bytes_per_cycle / self.cell_bytes

    @property
    def memory_cell_ops_per_cycle(self):
        # Store-and-forward traffic writes once and reads once.
        return 2.0 * self.line_cells_per_cycle

    @property
    def minimum_frame_packets_per_cycle(self):
        # 64-byte MAC frame including FCS, plus 8-byte preamble/SFD and 12-byte IFG.
        wire_bytes = 64 + 8 + 12
        packets_per_second = self.aggregate_line_bps / (wire_bytes * 8.0)
        return packets_per_second / self.core_frequency_hz

    @property
    def provided_ingress_bps(self):
        return (
            self.ingress_cell_lanes
            * self.cell_bytes
            * 8
            * self.core_frequency_hz
        )

    @property
    def provided_egress_bps(self):
        return (
            self.egress_cell_lanes
            * self.cell_bytes
            * 8
            * self.core_frequency_hz
        )

    @property
    def max_cells_per_packet(self):
        return int(math.ceil(float(self.max_packet_bytes) / self.cell_bytes))

    def validation_errors(self):
        errors = []
        if self.num_ports <= 0:
            errors.append("num_ports must be positive")
        if self.num_banks < self.ingress_cell_lanes + self.egress_cell_lanes:
            errors.append("num_banks must cover simultaneous read and write lanes")
        if self.ingress_cell_lanes < math.ceil(self.line_cells_per_cycle):
            errors.append("insufficient ingress cell bandwidth")
        if self.egress_cell_lanes < math.ceil(self.line_cells_per_cycle):
            errors.append("insufficient egress cell bandwidth")
        if self.lookup_lanes < math.ceil(self.minimum_frame_packets_per_cycle):
            errors.append("insufficient minimum-frame lookup bandwidth")
        if self.descriptor_count < self.total_cells:
            errors.append("descriptor_count strands cells for one-cell packets")
        if self.max_cells_per_packet > 255:
            errors.append("max packet requires more than an 8-bit cell count")
        return errors

    def validate(self):
        errors = self.validation_errors()
        if errors:
            raise ValueError("; ".join(errors))
