#!/usr/bin/env bash
# Assert that every per-variant map in the Makefile is registered with the
# parse-time completeness guard (`require_variant_map`).
#
# WHY THIS EXISTS. The guard itself catches a registered map whose keys stop
# matching the supported variant set. It cannot catch a map that was never
# registered, and that is the case v0.9.8 hit: `pic_soak_block_*` kept its
# retired cd4053/mute/relay keys through the stage-vocabulary rename while
# PIC10F322_SOAK_VARIANT moved to the new names. Every lookup expanded empty,
# the soak compile line emitted `-DSOAK_ACTUATION_BLOCK_MS=u`, the driver failed
# to compile, and the PIC10F322 WDT mutant degraded to a SKIP. Three of the
# fifteen release soak binaries build through the same rule, so it would also
# have failed the release. The 10F320 copy of the same map had been renamed
# correctly -- the two lanes disagreed in silence for an entire release.
#
# A guard that needs a human to remember to extend it has the same failure mode
# as the thing it guards. This closes that loop.
#
# HARVEST BY DEREFERENCE, NOT BY DEFINITION. A definition-keyed harvest (find
# `<prefix><variant> =` lines) would NOT have caught the original defect:
# `pic_soak_block_cd4053` does not end in any current variant name, so it would
# have been invisible precisely when it was broken. A dereference site
# (`$(pic_soak_block_$(PIC10F322_SOAK_VARIANT))`) exists regardless of what the
# keys are called, so it is vocabulary-independent -- which is the property that
# matters for a check whose whole purpose is surviving renames.
#
# SCOPE, stated so the next reader does not over-trust it: this keys on
# dereferences indexed by a variant-bearing name (`$(v)`, `$(VARIANT)`,
# `$(*_VARIANT)`). It deliberately does NOT match `$(1)`/`$(2)` template
# parameters, which are ambiguous -- `$(mmcu_$(1))` and `$(part_$(1))` are
# per-CHIP maps indexed by $(TINYX5), not per-variant, and pulling them in would
# make this gate demand a variant contract for a chip table.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAKEFILE="$ROOT/Makefile"
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Per-variant map prefixes actually used by the Makefile.
harvest_prefixes() {
	grep -oE '\$\([a-z][a-z0-9_]*_\$\((v|VARIANT|[A-Z][A-Z0-9_]*VARIANT)\)' "$1" \
		| sed -E 's/^\$\(//; s/_\$\(.*//' \
		| sort -u
}

# Prefixes registered with the parse-time guard.
registered_prefixes() {
	grep -oE '\$\(call[[:space:]]+require_variant_map,[a-z][a-z0-9_]*_,' "$1" \
		| sed -E 's/^\$\(call[[:space:]]+require_variant_map,//; s/_,$//' \
		| sort -u
}

used=$(harvest_prefixes "$MAKEFILE")
registered=$(registered_prefixes "$MAKEFILE")

# The harvest must find something. A regex that quietly stops matching is the
# same class of defect this gate exists to catch, and it would otherwise pass by
# comparing two empty sets.
[ -n "$used" ] || fail "harvested no per-variant map prefixes -- the dereference regex has stopped matching"
checks=$((checks + 1))
[ -n "$registered" ] || fail "found no require_variant_map registrations -- the guard regex has stopped matching"
checks=$((checks + 1))

# Known floor. If a map is legitimately retired, lower this deliberately; it
# exists so a harvest that silently halves cannot pass.
used_count=$(printf '%s\n' "$used" | wc -l)
[ "$used_count" -ge 4 ] \
	|| fail "expected at least 4 per-variant maps, harvested $used_count: $(printf '%s' "$used" | tr '\n' ' ')"
checks=$((checks + 1))

# The contract itself.
missing=$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$registered") || true)
[ -z "$missing" ] \
	|| fail "per-variant map(s) not registered with require_variant_map: $(printf '%s' "$missing" | tr '\n' ' ')"
checks=$((checks + 1))

# A registration naming a map nothing dereferences is dead weight and usually
# means a rename left the call behind.
stale=$(comm -13 <(printf '%s\n' "$used") <(printf '%s\n' "$registered") || true)
[ -z "$stale" ] \
	|| fail "require_variant_map registers map(s) nothing dereferences: $(printf '%s' "$stale" | tr '\n' ' ')"
checks=$((checks + 1))

# NEGATIVE CASE, per the house pattern: introduce a per-variant dereference that
# is not registered, and the contract check must reject it. Without this the
# gate could pass by harvesting nothing at all.
work=$(mktemp -d "${TMPDIR:-/tmp}/test-variant-map.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$MAKEFILE" "$work/Makefile"
printf '\nBOGUS_UNREGISTERED = $(bogus_map_$(PIC10F322_SOAK_VARIANT))\n' >> "$work/Makefile"
neg_used=$(harvest_prefixes "$work/Makefile")
neg_registered=$(registered_prefixes "$work/Makefile")
neg_missing=$(comm -23 <(printf '%s\n' "$neg_used") <(printf '%s\n' "$neg_registered") || true)
[ "$neg_missing" = "bogus_map" ] \
	|| fail "negative case: an unregistered per-variant map was not detected (got '$neg_missing')"
checks=$((checks + 1))

printf 'variant map contract: %d checks, 0 failures\n' "$checks"
