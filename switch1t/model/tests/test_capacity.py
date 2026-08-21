import unittest

from model.switch_model.capacity import analyze_capacity, simulate_line_rate
from model.switch_model.config import SwitchConfig


class CapacityTest(unittest.TestCase):
    def test_48x25g_budget(self):
        report = analyze_capacity()
        self.assertTrue(report.passes, report.validation_errors)
        self.assertAlmostEqual(report.aggregate_line_bps, 1.2e12)
        self.assertAlmostEqual(report.ingress_bytes_per_cycle, 300.0)
        self.assertAlmostEqual(report.line_cells_per_cycle, 2.34375)
        self.assertAlmostEqual(report.memory_cell_ops_per_cycle, 4.6875)
        self.assertAlmostEqual(
            report.minimum_frame_packets_per_cycle,
            3.571428571428571,
        )
        self.assertEqual(report.required_lookup_lanes, 4)
        self.assertEqual(report.provided_ingress_cell_lanes, 4)
        self.assertEqual(report.provided_egress_cell_lanes, 4)

    def test_underprovisioned_lookup_is_rejected(self):
        config = SwitchConfig(lookup_lanes=3)
        self.assertIn(
            "insufficient minimum-frame lookup bandwidth",
            config.validation_errors(),
        )

    def test_random_bank_traffic_drains(self):
        report = simulate_line_rate(offered_cycles=5000, seed=7)
        self.assertTrue(report.drained)
        self.assertGreater(report.total_requests, 20000)
        self.assertLess(report.backlog_after_offer, 128)
        self.assertLess(report.max_bank_depth, 32)


if __name__ == "__main__":
    unittest.main()
