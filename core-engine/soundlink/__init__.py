"""SoundLink core engine: send small, secure data packets through sound."""

from .crypto import Identity, key_from_pin, random_key
from .link import Receiver, SoundLink
from .modem import PROFILES, Modem, Profile
from .packet import Packet, PacketError, PacketType, ReplayGuard

__all__ = [
    "Identity",
    "key_from_pin",
    "random_key",
    "Receiver",
    "SoundLink",
    "PROFILES",
    "Modem",
    "Profile",
    "Packet",
    "PacketError",
    "PacketType",
    "ReplayGuard",
]

__version__ = "0.1.0"
