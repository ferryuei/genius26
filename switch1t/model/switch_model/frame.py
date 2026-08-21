"""Ethernet frame representation used by the golden model."""

import struct


def mac_from_text(value):
    parts = value.split(":")
    if len(parts) != 6:
        raise ValueError("MAC address must contain six octets")
    result = bytes(bytearray(int(part, 16) for part in parts))
    if len(result) != 6:
        raise ValueError("invalid MAC address")
    return result


def mac_to_text(value):
    _check_mac(value)
    return ":".join("%02x" % octet for octet in bytearray(value))


def _check_mac(value):
    if not isinstance(value, bytes) or len(value) != 6:
        raise ValueError("MAC address must be exactly six bytes")


def is_multicast(value):
    _check_mac(value)
    return bool(bytearray(value)[0] & 0x01)


def is_broadcast(value):
    _check_mac(value)
    return value == b"\xff" * 6


def is_link_local_control(value):
    _check_mac(value)
    octets = bytearray(value)
    return octets[:5] == bytearray(b"\x01\x80\xc2\x00\x00") and octets[5] <= 0x0F


class EthernetFrame(object):
    """Frame bytes excluding preamble, IFG and FCS.

    ``vid=None`` represents an untagged frame. VLAN 0 remains representable as
    a priority-tagged frame.
    """

    __slots__ = ("dmac", "smac", "ethertype", "payload", "vid", "pcp", "dei")

    def __init__(
        self,
        dmac,
        smac,
        ethertype=0x0800,
        payload=b"",
        vid=None,
        pcp=0,
        dei=False,
    ):
        _check_mac(dmac)
        _check_mac(smac)
        if not 0 <= ethertype <= 0xFFFF:
            raise ValueError("ethertype is out of range")
        if vid is not None and not 0 <= vid <= 4095:
            raise ValueError("VID is out of range")
        if not 0 <= pcp <= 7:
            raise ValueError("PCP is out of range")
        if not isinstance(payload, bytes):
            raise ValueError("payload must be bytes")
        self.dmac = dmac
        self.smac = smac
        self.ethertype = ethertype
        self.payload = payload
        self.vid = vid
        self.pcp = pcp
        self.dei = bool(dei)

    @property
    def tagged(self):
        return self.vid is not None

    def serialize(self):
        data = self.dmac + self.smac
        if self.tagged:
            tci = (self.pcp << 13) | (int(self.dei) << 12) | self.vid
            data += struct.pack(">HH", 0x8100, tci)
        data += struct.pack(">H", self.ethertype)
        return data + self.payload

    @classmethod
    def parse(cls, data):
        if not isinstance(data, bytes) or len(data) < 14:
            raise ValueError("Ethernet frame is shorter than 14 bytes")
        dmac = data[0:6]
        smac = data[6:12]
        first_type = struct.unpack(">H", data[12:14])[0]
        if first_type == 0x8100:
            if len(data) < 18:
                raise ValueError("tagged Ethernet frame is shorter than 18 bytes")
            tci, ethertype = struct.unpack(">HH", data[14:18])
            return cls(
                dmac=dmac,
                smac=smac,
                ethertype=ethertype,
                payload=data[18:],
                vid=tci & 0x0FFF,
                pcp=(tci >> 13) & 0x7,
                dei=bool((tci >> 12) & 0x1),
            )
        return cls(
            dmac=dmac,
            smac=smac,
            ethertype=first_type,
            payload=data[14:],
        )

    @property
    def wire_bytes(self):
        # FCS is not stored in the object. A MAC frame occupies at least 64 B.
        mac_frame_bytes = max(64, len(self.serialize()) + 4)
        return mac_frame_bytes + 8 + 12
