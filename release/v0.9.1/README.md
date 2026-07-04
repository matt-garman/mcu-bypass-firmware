# v0.9.1

Prebuilt firmware for v0.9.1. See **MANIFEST.md** for provenance, the per-image
fuse bytes / flashing commands, and the soak evidence. See the top-level
[release/README.md](../README.md) for the trust model and verification steps.

Quick verify:
```
cd release/v0.9.1 && sha256sum -c SHA256SUMS
```

If SHA256SUMS.asc is present, verify the signature first:
```
gpg --verify SHA256SUMS.asc SHA256SUMS
```
