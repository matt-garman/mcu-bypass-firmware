"""Fail-closed ATtiny202 production-fuse configuration for yasimavr."""

import re


class FuseConfigError(ValueError):
    """The simulator did not receive a complete valid production fuse set."""


# Fuse-memory offsets from the ATtiny202 fuse map. Offsets 3 and 4 are not part
# of this target's production programming command and must remain untouched.
FUSE_SPECS = (
    ("WDTCFG", 0),
    ("BODCFG", 1),
    ("OSCCFG", 2),
    ("SYSCFG0", 5),
    ("SYSCFG1", 6),
    ("APPEND", 7),
    ("BOOTEND", 8),
)

_BYTE_PATTERN = re.compile(r"(?:0[xX][0-9a-fA-F]{1,2}|[0-9]{1,3})")


def read_fuses(environ):
    """Read every required fuse byte from the Makefile-provided environment."""
    values = {}
    for name, _index in FUSE_SPECS:
        env_name = "ATTINY202_FUSE_" + name
        raw = environ.get(env_name)
        if raw is None:
            raise FuseConfigError("required fuse variable %s is missing" % env_name)
        if not _BYTE_PATTERN.fullmatch(raw):
            raise FuseConfigError("%s is not an unsigned byte: %r" % (env_name, raw))
        value = int(raw[2:], 16) if raw[:2].lower() == "0x" else int(raw, 10)
        if value > 0xFF:
            raise FuseConfigError("%s is outside [0x00, 0xFF]: %r" % (env_name, raw))
        values[name] = value
    return values


def apply_factory_values(factory_values, values):
    """Return a copy of factory_values with every production fuse applied."""
    try:
        patched = list(factory_values)
    except TypeError as exc:
        raise FuseConfigError("yasimavr factory fuse values are not iterable") from exc
    for name, index in FUSE_SPECS:
        if name not in values:
            raise FuseConfigError("required fuse value %s is missing" % name)
        value = values[name]
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFF:
            raise FuseConfigError("fuse %s is not an unsigned byte: %r" % (name, value))
        if index >= len(patched):
            raise FuseConfigError(
                "yasimavr factory fuse array has %d byte(s); %s needs index %d"
                % (len(patched), name, index)
            )
        patched[index] = value
    return patched
