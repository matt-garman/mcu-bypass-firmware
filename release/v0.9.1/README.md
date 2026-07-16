# v0.9.1

> [!WARNING]
> The `bypass_cd4053_tmux*.hex` and `bypass_mute_tmux*.hex` images in this
> release use an incorrect direct-drive polarity: the TMUX4053 board's
> absent/undriven-MCU pull-down state selects ENGAGED instead of fail-safe
> BYPASS. They are retained only for historical reproducibility. **Do not flash
> them for new TMUX4053 hardware.** Use `v0.9.3` or later and select the
> corresponding image without `_tmux` in its filename. See the
> [top-level safety warning](../README.md#safety-warning-v090-v092-tmux-images).

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
