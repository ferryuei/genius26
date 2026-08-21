import random
import unittest

from model.switch_model.config import SwitchConfig
from model.switch_model.resources import (
    OwnershipError,
    ResourceExhausted,
    SwitchResourceModel,
)


class ResourceModelTest(unittest.TestCase):
    def small_model(self):
        return SwitchResourceModel(
            SwitchConfig(
                total_cells=64,
                num_banks=16,
                descriptor_count=64,
                queue_node_count=128,
            )
        )

    def test_multicast_releases_only_after_final_reference(self):
        model = self.small_model()
        descriptor_id = model.admit(cell_count=3, destination_count=4)
        packet = model.packets[descriptor_id]
        nodes = sorted(packet.queue_node_ids)
        self.assertEqual(model.snapshot()["free_cells"], 61)

        for node_id in nodes[:-1]:
            model.complete_egress(descriptor_id, node_id)
            self.assertIn(descriptor_id, model.packets)
            self.assertEqual(model.snapshot()["free_cells"], 61)

        model.complete_egress(descriptor_id, nodes[-1])
        self.assertEqual(
            model.snapshot(),
            {
                "free_cells": 64,
                "free_descriptors": 64,
                "free_queue_nodes": 128,
                "inflight_packets": 0,
            },
        )

    def test_failed_admission_rolls_back_every_pool(self):
        model = SwitchResourceModel(
            SwitchConfig(
                total_cells=16,
                num_banks=16,
                descriptor_count=2,
                queue_node_count=4,
            )
        )
        model.admit(cell_count=3, destination_count=3)
        before = model.snapshot()
        with self.assertRaises(ResourceExhausted):
            model.admit(cell_count=2, destination_count=2)
        self.assertEqual(model.snapshot(), before)
        model.assert_consistent()

    def test_bank_round_robin_spreads_first_sixteen_cells(self):
        model = self.small_model()
        descriptor_id = model.admit(cell_count=16, destination_count=1)
        banks = [cell_id % 16 for cell_id in model.packets[descriptor_id].cell_ids]
        self.assertEqual(banks, list(range(16)))

    def test_duplicate_completion_is_rejected(self):
        model = self.small_model()
        descriptor_id = model.admit(cell_count=1, destination_count=2)
        nodes = sorted(model.packets[descriptor_id].queue_node_ids)
        model.complete_egress(descriptor_id, nodes[0])
        with self.assertRaises(OwnershipError):
            model.complete_egress(descriptor_id, nodes[0])

    def test_random_lifecycle_conserves_all_resources(self):
        rng = random.Random(23)
        model = self.small_model()
        for _ in range(2000):
            if model.packets and rng.random() < 0.58:
                descriptor_id = rng.choice(list(model.packets))
                node_id = rng.choice(
                    list(model.packets[descriptor_id].queue_node_ids)
                )
                model.complete_egress(descriptor_id, node_id)
            else:
                try:
                    model.admit(
                        cell_count=rng.randint(1, 5),
                        destination_count=rng.randint(1, 8),
                    )
                except ResourceExhausted:
                    pass
            model.assert_consistent()

        while model.packets:
            descriptor_id = next(iter(model.packets))
            node_id = next(iter(model.packets[descriptor_id].queue_node_ids))
            model.complete_egress(descriptor_id, node_id)
        self.assertEqual(model.cells.free_count, 64)
        self.assertEqual(model.descriptors.free_count, 64)
        self.assertEqual(model.queue_nodes.free_count, 128)


if __name__ == "__main__":
    unittest.main()
