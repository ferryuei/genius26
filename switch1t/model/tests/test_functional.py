import unittest

from model.switch_model.frame import EthernetFrame, mac_from_text
from model.switch_model.functional import (
    AclAction,
    AclRule,
    Destination,
    FunctionalSwitchModel,
)


MAC_A = mac_from_text("00:00:00:00:00:0a")
MAC_B = mac_from_text("00:00:00:00:00:0b")
MAC_C = mac_from_text("00:00:00:00:00:0c")
BROADCAST = b"\xff" * 6
MULTICAST = mac_from_text("01:00:5e:01:02:03")


class FrameTest(unittest.TestCase):
    def test_tagged_round_trip(self):
        frame = EthernetFrame(
            dmac=MAC_B,
            smac=MAC_A,
            ethertype=0x86DD,
            payload=b"payload",
            vid=123,
            pcp=5,
            dei=True,
        )
        parsed = EthernetFrame.parse(frame.serialize())
        self.assertEqual(parsed.dmac, frame.dmac)
        self.assertEqual(parsed.smac, frame.smac)
        self.assertEqual(parsed.ethertype, frame.ethertype)
        self.assertEqual(parsed.payload, frame.payload)
        self.assertEqual(parsed.vid, 123)
        self.assertEqual(parsed.pcp, 5)
        self.assertTrue(parsed.dei)


class ForwardingTest(unittest.TestCase):
    def setUp(self):
        self.switch = FunctionalSwitchModel()
        self.switch.configure_vlan(1, members=[0, 1, 2, 3], untagged=[0, 1])

    def test_unknown_unicast_flood_then_learned_unicast(self):
        first = EthernetFrame(dmac=MAC_B, smac=MAC_A, payload=b"first")
        decision = self.switch.process(first, 0)
        self.assertTrue(decision.flooded)
        self.assertEqual([action.port for action in decision.actions], [1, 2, 3])
        self.assertEqual(
            [action.vlan_action for action in decision.actions],
            ["none", "push", "push"],
        )

        reply = EthernetFrame(dmac=MAC_A, smac=MAC_B, payload=b"reply")
        decision = self.switch.process(reply, 1)
        self.assertFalse(decision.flooded)
        self.assertEqual([action.port for action in decision.actions], [0])

    def test_source_port_filter(self):
        self.switch.add_fdb_entry(MAC_A, 1, Destination.port(0))
        frame = EthernetFrame(dmac=MAC_A, smac=MAC_C)
        decision = self.switch.process(frame, 0)
        self.assertTrue(decision.dropped)
        self.assertEqual(decision.drop_reason, "source_filtered_or_no_destination")

    def test_acl_deny_is_first_match(self):
        self.switch.add_acl_rule(
            AclRule(
                priority=10,
                action=AclAction.DENY,
                ethertype=0x0806,
                vid=1,
            )
        )
        frame = EthernetFrame(
            dmac=BROADCAST,
            smac=MAC_A,
            ethertype=0x0806,
        )
        decision = self.switch.process(frame, 0)
        self.assertEqual(decision.drop_reason, "acl_deny")
        self.assertEqual(decision.actions, ())

    def test_multicast_group_replication(self):
        self.switch.configure_multicast(MULTICAST, 1, ports=[1, 3])
        frame = EthernetFrame(dmac=MULTICAST, smac=MAC_A, vid=1, pcp=6)
        decision = self.switch.process(frame, 0)
        self.assertFalse(decision.flooded)
        self.assertEqual([action.port for action in decision.actions], [1, 3])
        self.assertEqual([action.queue for action in decision.actions], [6, 6])

    def test_lag_selection_is_stable_and_active(self):
        self.switch.configure_lag(2, [2, 3])
        self.switch.add_fdb_entry(MAC_B, 1, Destination.lag(2))
        frame = EthernetFrame(dmac=MAC_B, smac=MAC_A, vid=1)
        first = self.switch.process(frame, 0)
        second = self.switch.process(frame, 0)
        self.assertEqual(first.actions[0].port, second.actions[0].port)
        self.assertIn(first.actions[0].port, (2, 3))

    def test_link_local_control_frame_is_trapped(self):
        frame = EthernetFrame(
            dmac=mac_from_text("01:80:c2:00:00:00"),
            smac=MAC_A,
        )
        decision = self.switch.process(frame, 0)
        self.assertTrue(decision.trapped_to_cpu)
        self.assertEqual(decision.actions, ())


if __name__ == "__main__":
    unittest.main()
