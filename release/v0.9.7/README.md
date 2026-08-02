# v0.9.7

Prebuilt firmware for v0.9.7. See **MANIFEST.md** for provenance, the per-image
fuse bytes / flashing commands, **QUALIFICATION** for the machine-verified
release gate, and evidence/ for the retained logs. See the top-level
[release/README.md](../README.md) for the trust model and verification steps.

Quick verify:
```
cd release/v0.9.7 && sha256sum -c SHA256SUMS
```

Verify the required checksum signature first:
```
gpg --verify SHA256SUMS.asc SHA256SUMS
```
