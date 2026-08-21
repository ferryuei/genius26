"""Packet-level executable specification for the RTL2 forwarding pipeline."""

import zlib
from enum import Enum

from .config import SwitchConfig
from .frame import is_broadcast, is_link_local_control, is_multicast


class PortState(Enum):
    DISABLED = 0
    BLOCKING = 1
    LEARNING = 2
    FORWARDING = 3


class AclAction(Enum):
    PERMIT = 0
    DENY = 1
    MIRROR = 2
    SET_QUEUE = 3


class Destination(object):
    __slots__ = ("kind", "identifier")

    def __init__(self, kind, identifier):
        if kind not in ("port", "lag"):
            raise ValueError("destination kind must be port or lag")
        self.kind = kind
        self.identifier = int(identifier)

    @classmethod
    def port(cls, port):
        return cls("port", port)

    @classmethod
    def lag(cls, lag_id):
        return cls("lag", lag_id)

    def __eq__(self, other):
        return (
            isinstance(other, Destination)
            and self.kind == other.kind
            and self.identifier == other.identifier
        )

    def __repr__(self):
        return "Destination(%r, %r)" % (self.kind, self.identifier)


class PortConfig(object):
    __slots__ = ("enabled", "link_up", "state", "pvid", "default_pcp")

    def __init__(
        self,
        enabled=True,
        link_up=True,
        state=PortState.FORWARDING,
        pvid=1,
        default_pcp=0,
    ):
        self.enabled = bool(enabled)
        self.link_up = bool(link_up)
        self.state = state
        self.pvid = pvid
        self.default_pcp = default_pcp


class AclRule(object):
    """First-match ingress ACL rule.

    A field set to ``None`` is a wildcard. MAC masks use six-byte values.
    """

    __slots__ = (
        "priority",
        "action",
        "src_port",
        "vid",
        "smac",
        "smac_mask",
        "dmac",
        "dmac_mask",
        "ethertype",
        "queue",
        "mirror_port",
    )

    def __init__(
        self,
        priority,
        action,
        src_port=None,
        vid=None,
        smac=None,
        smac_mask=None,
        dmac=None,
        dmac_mask=None,
        ethertype=None,
        queue=None,
        mirror_port=None,
    ):
        self.priority = int(priority)
        self.action = action
        self.src_port = src_port
        self.vid = vid
        self.smac = smac
        self.smac_mask = smac_mask
        self.dmac = dmac
        self.dmac_mask = dmac_mask
        self.ethertype = ethertype
        self.queue = queue
        self.mirror_port = mirror_port

    @staticmethod
    def _masked_mac_match(actual, expected, mask):
        if expected is None:
            return True
        if mask is None:
            mask = b"\xff" * 6
        if len(expected) != 6 or len(mask) != 6:
            raise ValueError("ACL MAC and mask must contain six bytes")
        actual_i = int.from_bytes(actual, "big")
        expected_i = int.from_bytes(expected, "big")
        mask_i = int.from_bytes(mask, "big")
        return (actual_i & mask_i) == (expected_i & mask_i)

    def matches(self, frame, src_port, vid):
        return (
            (self.src_port is None or self.src_port == src_port)
            and (self.vid is None or self.vid == vid)
            and (self.ethertype is None or self.ethertype == frame.ethertype)
            and self._masked_mac_match(frame.smac, self.smac, self.smac_mask)
            and self._masked_mac_match(frame.dmac, self.dmac, self.dmac_mask)
        )


class EgressAction(object):
    __slots__ = ("port", "queue", "vlan_action", "vid", "mirror")

    def __init__(self, port, queue, vlan_action, vid, mirror=False):
        self.port = port
        self.queue = queue
        self.vlan_action = vlan_action
        self.vid = vid
        self.mirror = bool(mirror)

    def __repr__(self):
        return (
            "EgressAction(port=%r, queue=%r, vlan_action=%r, vid=%r, mirror=%r)"
            % (self.port, self.queue, self.vlan_action, self.vid, self.mirror)
        )


class ForwardDecision(object):
    __slots__ = (
        "actions",
        "drop_reason",
        "trapped_to_cpu",
        "flooded",
        "learned",
        "vid",
    )

    def __init__(
        self,
        actions=(),
        drop_reason=None,
        trapped_to_cpu=False,
        flooded=False,
        learned=False,
        vid=None,
    ):
        self.actions = tuple(actions)
        self.drop_reason = drop_reason
        self.trapped_to_cpu = bool(trapped_to_cpu)
        self.flooded = bool(flooded)
        self.learned = bool(learned)
        self.vid = vid

    @property
    def dropped(self):
        return bool(self.drop_reason)


class FunctionalSwitchModel(object):
    """Deterministic L2 forwarding reference model.

    Control protocols are intentionally not implemented here. Link-local
    control frames are trapped to a CPU port; software is expected to program
    VLAN, FDB, multicast, LAG and port-state tables.
    """

    def __init__(self, config=None):
        self.config = config or SwitchConfig()
        self.config.validate()
        self.ports = [PortConfig() for _ in range(self.config.num_ports)]
        self.vlan_members = {}
        self.vlan_untagged = {}
        self.fdb = {}
        self.multicast_groups = {}
        self.lags = {}
        self.acl_rules = []

    def _check_port(self, port):
        if not 0 <= port < self.config.num_ports:
            raise ValueError("port is out of range")

    def configure_vlan(self, vid, members, untagged=()):
        if not 1 <= vid <= 4094:
            raise ValueError("VID must be in the range 1..4094")
        members = set(int(port) for port in members)
        untagged = set(int(port) for port in untagged)
        for port in members | untagged:
            self._check_port(port)
        if not untagged.issubset(members):
            raise ValueError("untagged ports must also be VLAN members")
        self.vlan_members[vid] = members
        self.vlan_untagged[vid] = untagged

    def add_fdb_entry(self, mac, vid, destination):
        if is_multicast(mac):
            raise ValueError("FDB source/destination entry must be unicast")
        if destination.kind == "port":
            self._check_port(destination.identifier)
        self.fdb[(mac, vid)] = destination

    def configure_multicast(self, mac, vid, ports):
        if not is_multicast(mac) or is_broadcast(mac):
            raise ValueError("multicast group requires a non-broadcast multicast MAC")
        ports = set(int(port) for port in ports)
        for port in ports:
            self._check_port(port)
        self.multicast_groups[(mac, vid)] = ports

    def configure_lag(self, lag_id, members):
        members = tuple(sorted(set(int(port) for port in members)))
        if not members:
            raise ValueError("LAG requires at least one member")
        for port in members:
            self._check_port(port)
        self.lags[int(lag_id)] = members

    def add_acl_rule(self, rule):
        self.acl_rules.append(rule)
        self.acl_rules.sort(key=lambda item: item.priority)

    def _port_can_forward(self, port, vid):
        cfg = self.ports[port]
        return (
            cfg.enabled
            and cfg.link_up
            and cfg.state == PortState.FORWARDING
            and port in self.vlan_members.get(vid, set())
        )

    def _select_lag_member(self, lag_id, frame, vid):
        active = [
            port
            for port in self.lags.get(lag_id, ())
            if self._port_can_forward(port, vid)
        ]
        if not active:
            return None
        key = frame.smac + frame.dmac + vid.to_bytes(2, "big")
        return active[zlib.crc32(key) % len(active)]

    def _resolve_destination(self, destination, frame, vid):
        if destination.kind == "port":
            return destination.identifier
        return self._select_lag_member(destination.identifier, frame, vid)

    def _vlan_action(self, frame, vid, dst_port):
        egress_untagged = dst_port in self.vlan_untagged.get(vid, set())
        if frame.tagged and egress_untagged:
            return "pop"
        if not frame.tagged and not egress_untagged:
            return "push"
        return "none"

    def process(self, frame, src_port):
        self._check_port(src_port)
        ingress = self.ports[src_port]
        if not ingress.enabled or not ingress.link_up:
            return ForwardDecision(drop_reason="ingress_disabled")
        if ingress.state in (PortState.DISABLED, PortState.BLOCKING):
            return ForwardDecision(drop_reason="stp_blocking")

        vid = ingress.pvid if frame.vid is None or frame.vid == 0 else frame.vid
        if src_port not in self.vlan_members.get(vid, set()):
            return ForwardDecision(drop_reason="ingress_vlan_filter", vid=vid)

        learned = False
        if not is_multicast(frame.smac):
            self.fdb[(frame.smac, vid)] = Destination.port(src_port)
            learned = True

        if is_link_local_control(frame.dmac):
            return ForwardDecision(
                trapped_to_cpu=True,
                learned=learned,
                vid=vid,
            )

        if ingress.state == PortState.LEARNING:
            return ForwardDecision(
                drop_reason="stp_learning",
                learned=learned,
                vid=vid,
            )

        queue = frame.pcp if frame.tagged else ingress.default_pcp
        mirror_ports = []
        for rule in self.acl_rules:
            if not rule.matches(frame, src_port, vid):
                continue
            if rule.action == AclAction.DENY:
                return ForwardDecision(
                    drop_reason="acl_deny",
                    learned=learned,
                    vid=vid,
                )
            if rule.action == AclAction.SET_QUEUE:
                if rule.queue is None or not 0 <= rule.queue < self.config.queues_per_port:
                    raise ValueError("SET_QUEUE rule has an invalid queue")
                queue = rule.queue
            elif rule.action == AclAction.MIRROR:
                if rule.mirror_port is None:
                    raise ValueError("MIRROR rule requires mirror_port")
                self._check_port(rule.mirror_port)
                mirror_ports.append(rule.mirror_port)
            break

        flooded = False
        if is_broadcast(frame.dmac):
            dst_ports = set(self.vlan_members[vid])
            flooded = True
        elif is_multicast(frame.dmac):
            group = self.multicast_groups.get((frame.dmac, vid))
            dst_ports = set(group if group is not None else self.vlan_members[vid])
            flooded = group is None
        else:
            destination = self.fdb.get((frame.dmac, vid))
            if destination is None:
                dst_ports = set(self.vlan_members[vid])
                flooded = True
            else:
                resolved = self._resolve_destination(destination, frame, vid)
                dst_ports = set() if resolved is None else set([resolved])

        dst_ports.discard(src_port)
        dst_ports = set(
            port for port in dst_ports if self._port_can_forward(port, vid)
        )

        actions = []
        for port in sorted(dst_ports):
            actions.append(
                EgressAction(
                    port=port,
                    queue=queue,
                    vlan_action=self._vlan_action(frame, vid, port),
                    vid=vid,
                )
            )

        for port in mirror_ports:
            if port != src_port and self.ports[port].enabled and self.ports[port].link_up:
                if not any(action.port == port for action in actions):
                    actions.append(
                        EgressAction(
                            port=port,
                            queue=queue,
                            vlan_action="none",
                            vid=vid,
                            mirror=True,
                        )
                    )

        if not actions:
            return ForwardDecision(
                drop_reason="source_filtered_or_no_destination",
                flooded=flooded,
                learned=learned,
                vid=vid,
            )

        return ForwardDecision(
            actions=actions,
            flooded=flooded,
            learned=learned,
            vid=vid,
        )
