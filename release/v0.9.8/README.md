# v0.9.8

Prebuilt firmware for v0.9.8. See **MANIFEST.md** for provenance, the per-image
fuse bytes / flashing commands, **QUALIFICATION** for the machine-verified
release gate, and evidence/ for the retained logs. See the top-level
[release/README.md](../README.md) for the trust model and verification steps.

This release renamed its images and changed the PIC10F320 relay image for
idle coil-latch safety. **RENAME_IDENTITY.md** requires the other 17 images
to match their previous-release counterparts byte for byte.

Quick verify:
```
cd release/v0.9.8 && sha256sum -c SHA256SUMS
```

Verify the required checksum signature first:
```
gpg --verify SHA256SUMS.asc SHA256SUMS
```
