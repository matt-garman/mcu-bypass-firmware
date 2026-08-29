# v0.9.11

> **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran 1.0 h per combination instead of 24 h.

Prebuilt firmware for v0.9.11. See **MANIFEST.md** for provenance, the per-image
fuse bytes / flashing commands, **QUALIFICATION** for the machine-verified
release gate, and evidence/ for the retained logs. See the top-level
[release/README.md](../README.md) for the trust model and verification steps.

**PIC12F675 is not a raw write target.** Its per-device factory OSCCAL and
CONFIG BG trim live in memory a programmer erases, and a device that loses
either still appears to work. Pass its image to `flash-pic12f675.py` in this
directory -- covered by the same SHA256SUMS -- never straight to a programmer.

Quick verify:
```
cd release/v0.9.11 && sha256sum -c SHA256SUMS
```

Verify the required checksum signature first:
```
gpg --verify SHA256SUMS.asc SHA256SUMS
```
