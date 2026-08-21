"""Golden functional model and capacity model for the RTL2 data plane."""

from .capacity import analyze_capacity, simulate_line_rate
from .config import SwitchConfig
from .frame import EthernetFrame
from .functional import (
    AclAction,
    AclRule,
    Destination,
    FunctionalSwitchModel,
    PortState,
)
from .resources import OwnershipError, ResourceExhausted, SwitchResourceModel

__all__ = [
    "AclAction",
    "AclRule",
    "Destination",
    "EthernetFrame",
    "FunctionalSwitchModel",
    "PortState",
    "OwnershipError",
    "ResourceExhausted",
    "SwitchConfig",
    "SwitchResourceModel",
    "analyze_capacity",
    "simulate_line_rate",
]
