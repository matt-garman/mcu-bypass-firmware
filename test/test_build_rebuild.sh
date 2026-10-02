#!/usr/bin/env bash
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
# This only reports; `set -e` still does the exiting, so control flow is unchanged.
# The `case $-` guard is required, not defensive: bash runs an ERR trap even
# inside a deliberate `set +e` block, and several suites use one around a
# command whose non-zero status IS the expected result (`make -q` returns 1).
# Without the guard those print a spurious FAIL that lands in retained
# release evidence, because test-long.summary.txt is built by grepping ^FAIL.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

# Every file this Makefile builds is rebuilt from current inputs on every
# request, and a failed build publishes nothing.
#
# THE PROPERTY
# ------------
# FORCE's definition in the Makefile states it: an "always-out-of-date
# prerequisite used for artifacts whose effective build command includes
# command-line variables that timestamps cannot represent." Every compile here
# is one. The variant, clock, fuse bytes, workload sizing, soak duration and the
# compiler itself all reach a recipe as Make variables, and a timestamp records
# none of them. Both PIC10F32x soak rules once omitted FORCE. Measured:
#
#   make build_pic10f320/test_soak_pic PIC10F320_SOAK_DURATION_MS=60000
#   make build_pic10f320/test_soak_pic PIC10F320_SOAK_DURATION_MS=120000
#     -> "'build_pic10f320/test_soak_pic' is up to date."  (60000 binary kept)
#
# 1. STRUCTURE, read from Make's own database. Nothing is listed here, so a rule
#    is covered the day it is written: every file rule with a recipe must name
#    FORCE among its NORMAL prerequisites. Three near-misses do not count,
#    because none of them rebuilds in every graph:
#      - FORCE after the `|`. An order-only prerequisite never makes a target
#        out of date.
#      - Another phony prerequisite. A caller can mark it --old-file, as the
#        release soak does with _pic12f675-build-soak.
#      - A forced prerequisite. A recipe-less file target does not pass its
#        phony prerequisite on, and a forced one can be switched off: the AVR
#        soak binary was forced only through its ELF, and AVR_REBUILD_PREREQ=,
#        which reuses a validated ELF, left the binary as it was.
#    The classic AVR images name FORCE through $(AVR_REBUILD_PREREQ). It is FORCE
#    in the database read here, and empty only in the reviewed consumer phases
#    section 2 exercises. A rule whose whole recipe is `mkdir -p $@` makes a
#    directory and is exempt. A command target missing from .PHONY fails too,
#    which is right: a file of that name would satisfy it silently. Fixture
#    rules prove each of these decisions, so the reader cannot pass by finding
#    nothing.
#
#    The same database holds the aggregates: `stress` and `test-long` run the
#    `test` inventory at FULL sizing, and only `test-long` reaches mutation.
#
# 2. BEHAVIOUR, with fake tools, for what a database cannot show.
#      - Classic AVR images publish atomically. A failed, empty, malformed or
#        wrong-architecture compile, or a failed, empty or malformed objcopy,
#        leaves no ELF/HEX and no temporaries. So does a failed fuse-checker
#        compile, which would otherwise validate the previous fuse values.
#      - A validated ELF is reused only where that is reviewed. HEX regenerates
#        from it without recompiling, and in one graph the flash-budget and
#        simulator gates share one build.
#      - Recursive simulator phases keep the requested workload, and a request
#        mixing FAST and FULL aggregates is refused.
#      - PIC harnesses compile the selected variant's image, block time and
#        symbol-derived addresses, and rebuild derived inputs a direct request
#        finds missing. A missing XC8 neither keeps a stale soak binary nor
#        skips under STRICT_TOOLS=1.
#    One identical rerun must also recompile, as a direct witness that the
#    structural reading means what it says.
#
# NOT CHECKED, on purpose: which headers each rule lists, which files the soak
# rules read, and the fuse values. Those restate the tree. With FORCE on every
# rule a missing header prerequisite cannot keep a stale artifact, and the fuse
# values are held by test-fuse-injection-contract.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-${HOME:?HOME is required when TMPDIR is unset}}/test-build-rebuild.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
unset AVR_BUILD_DIR AVR_FW FW_BASE ATTINY13A_MCU ATTINY13A_F_CPU TINYX5_F_CPU \
      CFLAGS CFLAGS_COMMON AVR_REBUILD_PREREQ VARIANTS MCU HOST_DEFS SIM_DEFS SIZE
unset XT_FUSE_WDTCFG XT_FUSE_BODCFG XT_FUSE_OSCCFG XT_FUSE_SYSCFG0 \
      XT_FUSE_SYSCFG1 XT_FUSE_APPEND XT_FUSE_BOOTEND
unset FAKE_CC_MODE FAKE_OBJCOPY_MODE FAKE_READELF_MODE FAKE_COMPILER_MODE

# shellcheck source=test/scratch_tree.sh
. "$ROOT/test/scratch_tree.sh" || fail "could not load test/scratch_tree.sh"

# One full scratch tree, from the shared allowlist walk the mutation runner also
# uses. Section 1 reads its Makefile; section 2c builds PIC harnesses in it.
tree="$work/tree"
scratch_tree_copy "$ROOT" "$tree" \
	|| fail "could not populate the scratch tree (see test/scratch_tree.sh)"
tree_lock_id=$(stat -Lc '%d:%i' "$tree")

# ============================================================================
# 1. STRUCTURE
# ============================================================================

# make_database <output> [make args...] -- Make's rule database for the scratch
# tree. Question mode normally returns 1 for an out-of-date default goal; only a
# parse or database failure (status > 1) is an error here.
make_database() {
	local out=$1 rc=0
	shift
	make --no-print-directory -C "$tree" -pRrq \
		_MAKE_SERIAL_LOCK_HELD="$tree_lock_id" "$@" >"$out" 2>"$out.err" \
		|| rc=$?
	[ "$rc" -le 1 ] || fail "could not read Make's database: $(cat "$out.err")"
	grep -qx '# Files' "$out" || fail "Make's database has no file section"
}

# unforced_rules <database> -- each file rule with a recipe that does not name
# FORCE among its normal prerequisites, sorted, one per line. Special targets
# (.PHONY, .DELETE_ON_ERROR) and directory rules are skipped.
unforced_rules() {
	awk '
	function flush() {
		if (name != "" && !skip && name !~ /^\./ && !phony && recipe \
				&& !(lines == 1 && text ~ /^@?mkdir -p \$@$/) && !forced)
			print name
		name = ""; skip = 0; phony = 0; recipe = 0; forced = 0
		lines = 0; text = ""
	}
	$0 == "# Files" { in_files = 1; next }
	$0 == "# files hash-table stats:" { flush(); in_files = 0; next }
	!in_files { next }
	/^$/ { flush(); next }
	/^# Not a target:/ { skip = 1; next }
	skip { next }
	/^#  Phony target/ { phony = 1; next }
	/^#  recipe to execute/ { recipe = 1; next }
	/^\t/ { lines++; text = substr($0, 2); next }
	/^#/ { next }
	name == "" && $1 ~ /:$/ && index($0, "=") == 0 {
		name = $1
		sub(/:$/, "", name)
		for (i = 2; i <= NF && $i != "|"; i++)
			if ($i == "FORCE") forced = 1
	}' "$1" | LC_ALL=C sort
}

# force_definition <database> -- "phony=<0|1> prereqs=<n> recipe=<0|1>" for FORCE.
# FORCE works only while it is phony, has no prerequisites and has no recipe.
force_definition() {
	awk '
	$0 == "# Files" { in_files = 1; next }
	$0 == "# files hash-table stats:" { in_files = 0 }
	!in_files { next }
	/^$/ { if (found) exit; next }
	!found && $1 == "FORCE:" && index($0, "=") == 0 {
		found = 1
		for (i = 2; i <= NF; i++) if ($i != "|") prereqs++
		next
	}
	found && /^#  Phony target/ { phony = 1 }
	found && /^#  recipe to execute/ { recipe = 1 }
	END {
		if (found) printf "phony=%d prereqs=%d recipe=%d\n", phony, prereqs, recipe
	}' "$1"
}

db="$work/make.db"
make_database "$db"
[ "$(force_definition "$db")" = 'phony=1 prereqs=0 recipe=0' ] \
	|| fail "FORCE is not a phony target with no prerequisites and no recipe:" \
		"$(force_definition "$db")"
checks=$((checks + 1))
unforced=$(unforced_rules "$db")
[ -z "$unforced" ] \
	|| fail "these file rules can be skipped as up to date; name FORCE among" \
		"their normal prerequisites, or declare a command target .PHONY:" \
		"$(printf '%s ' $unforced)"
checks=$((checks + 1))

# The reader must see every way a rule can miss. The fixture Makefile is the
# real one with FORCE made an ordinary file target that has a prerequisite and a
# recipe, plus one rule per decision above.
fixture_makefile="$tree/Makefile.fixture"
sed '/^\.PHONY: FORCE$/d' "$tree/Makefile" > "$fixture_makefile"
[ "$(($(wc -l < "$tree/Makefile") - $(wc -l < "$fixture_makefile")))" -eq 1 ] \
	|| fail "could not remove exactly one '.PHONY: FORCE' line for the fixture"
cat >> "$fixture_makefile" <<'EOF'
FORCE: fixture-phony
	@:
.PHONY: fixture-phony fixture-gate
fixture-phony:
fixture-gate:
	@:
fixture-undeclared-gate:
	@:
fixture/forced: FORCE
	@:
fixture/directory:
	@mkdir -p $@
fixture/unforced:
	@:
fixture/order-only: | FORCE
	@:
fixture/other-phony: fixture-phony
	@:
fixture/through-forced: fixture/forced
	@:
EOF
fixture_db="$work/fixture.db"
make_database "$fixture_db" -f Makefile.fixture
[ "$(force_definition "$fixture_db")" = 'phony=0 prereqs=1 recipe=1' ] \
	|| fail "the FORCE reader missed a non-phony FORCE with a prerequisite and" \
		"a recipe: $(force_definition "$fixture_db")"
checks=$((checks + 1))
expected_unforced='FORCE
fixture-undeclared-gate
fixture/order-only
fixture/other-phony
fixture/through-forced
fixture/unforced'
actual_unforced=$(unforced_rules "$fixture_db")
[ "$actual_unforced" = "$expected_unforced" ] \
	|| fail "the rule reader judged the fixture rules wrongly; expected:" \
		"$(printf '%s ' $expected_unforced) got: $(printf '%s ' $actual_unforced)"
checks=$((checks + 1))
rm -f "$fixture_makefile"

# --- aggregates ---------------------------------------------------------------
aggregate_prereqs() {
	awk -v target="$1:" '
		$1 == target && index($0, "=") == 0 {
			for (i = 2; i <= NF; i++) print $i
		}' "$db"
}

aggregate_profile() {
	awk -v target="$1:" -v variable="$2" '
		$1 == target && $2 == variable && $3 == "=" { print $4 }
		' "$db"
}

fast_gates=$(aggregate_prereqs test | grep -v '^$' | sort)
stress_gates=$(aggregate_prereqs stress | grep -v '^$' | sort)
long_gates=$(aggregate_prereqs test-long | grep -v '^$' | sort)
for aggregate in test stress test-long; do
	gates=$(aggregate_prereqs "$aggregate")
	[ -n "$gates" ] || fail "could not read $aggregate prerequisites from Make"
	if printf '%s\n' "$gates" | grep -Fxq clean-tests; then
		fail "$aggregate reintroduced the parallel clean-tests race"
	fi
done
checks=$((checks + 3))

# Both FULL aggregates must select the empty in-source-default profiles. Pin the
# target-specific assignments as well as gate membership so `stress` cannot
# accidentally become a fast non-mutation alias.
for aggregate in stress test-long; do
	[ "$(aggregate_profile "$aggregate" HOST_DEFS)" = '$(FULL_HOST_DEFS)' ] \
		|| fail "$aggregate does not select FULL_HOST_DEFS"
	[ "$(aggregate_profile "$aggregate" SIM_DEFS)" = '$(FULL_SIM_DEFS)' ] \
		|| fail "$aggregate does not select FULL_SIM_DEFS"
done
checks=$((checks + 4))

# Stress is exactly the shared non-mutation inventory. test-long is that same
# inventory plus one full mutation gate, preserving release qualification while
# normal hosted stress avoids the duplicate run.
if ! diff_out=$(diff <(printf '%s\n' "$fast_gates") \
		<(printf '%s\n' "$stress_gates")); then
	fail "test and stress do not run the same base gates: $diff_out"
fi
long_without_mutation=$(printf '%s\n' "$long_gates" | grep -Fxv test-mutation)
if ! diff_out=$(diff <(printf '%s\n' "$fast_gates") \
		<(printf '%s\n' "$long_without_mutation")); then
	fail "test-long is not the base inventory plus mutation: $diff_out"
fi
[ "$(printf '%s\n' "$stress_gates" | grep -Fxc test-mutation || true)" -eq 0 ] \
	|| fail "stress includes the full mutation gate"
[ "$(printf '%s\n' "$long_gates" | grep -Fxc test-mutation || true)" -eq 1 ] \
	|| fail "test-long does not include exactly one full mutation gate"
[ "$(printf '%s\n' "$stress_gates" | grep -Fxc test-mutation-sandbox || true)" -eq 1 ] \
	|| fail "stress lost the mutation-driver sandbox regression"
# Compute the reverse transitive closure as a separate assertion: no other Make
# target may acquire mutation indirectly and become a second CI route. Ignore
# Make's dot-prefixed special targets such as .PHONY, which list names rather
# than execution prerequisites.
mutation_ancestors=$(awk '
	$0 == "# Files" { in_files = 1; next }
	$0 == "# files hash-table stats:" { in_files = 0 }
	in_files && $0 !~ /^[[:space:]#]/ && $1 ~ /:$/ && $1 !~ /^\./ \
			&& index($0, "=") == 0 {
		target = $1
		sub(/:$/, "", target)
		for (i = 2; i <= NF; i++) {
			if ($i != "|") edge[target SUBSEP $i] = 1
		}
	}
	END {
		reaches["test-mutation"] = 1
		changed = 1
		while (changed) {
			changed = 0
			for (pair in edge) {
				split(pair, nodes, SUBSEP)
				if (reaches[nodes[2]] && !reaches[nodes[1]]) {
					reaches[nodes[1]] = 1
					changed = 1
				}
			}
		}
		for (target in reaches) {
			if (target != "test-mutation" && reaches[target]) print target
		}
	}' "$db" | sort)
[ "$mutation_ancestors" = test-long ] \
	|| fail "Make targets other than test-long reach full mutation: $mutation_ancestors"
checks=$((checks + 6))

# No gate may appear twice in any aggregate. Make would still run a phony
# prerequisite once, so a duplicate is not double execution; it is the
# fingerprint of a hand edit that can later remove only one copy.
for aggregate in test stress test-long; do
	dupes=$(aggregate_prereqs "$aggregate" | grep -v '^$' | sort | uniq -d || true)
	[ -z "$dupes" ] \
		|| fail "$aggregate lists a gate more than once: $(printf '%s' "$dupes" | tr '\n' ' ')"
done
checks=$((checks + 3))

# The two PIC shipping-source coverage gates are named explicitly because they
# are the ones that were reachable ONLY through standalone full-tool aggregates,
# and because they are the reason `make test` can catch a PIC host-oracle
# regression at all. Both need nothing beyond the host compiler, gcov and Bash
# that `test` already requires, so neither has an excuse to leave the inventory.
for gate in pic10f322-coverage-check-fw pic12f675-coverage-check-fw; do
	found=$(printf '%s\n' "$fast_gates" | grep -Fxc "$gate" || true)
	[ "$found" = 1 ] \
		|| fail "$gate appears $found times in the shared gate inventory, expected exactly 1"
done
checks=$((checks + 2))

# ============================================================================
# 2a. CLASSIC AVR IMAGES -- atomic publication and the validated-ELF consumer
# ============================================================================
avr="$work/avr"
avr_tools="$work/avr-tools"
cc_log="$work/avr-cc.log"
objcopy_log="$work/avr-objcopy.log"
mkdir -p "$avr/src" "$avr/test" "$avr/scripts" "$avr/build_avr_classic" "$avr_tools"
cp "$ROOT/Makefile" "$avr/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$avr/scripts/validate-ihex.sh"

cat > "$avr_tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
out=
args=$*
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 0
printf '%s => %s\n' "$args" "$out" >> "$FAKE_CC_LOG"
case "${FAKE_CC_MODE:-pass}" in
	fail) printf 'partial ELF\n' > "$out"; exit 1 ;;
	empty) : > "$out" ;;
	malformed) printf 'not an ELF\n' > "$out" ;;
	*) printf 'fresh ELF\n' > "$out" ;;
esac
EOF

cat > "$avr_tools/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do elf=$arg; done
grep -q -x 'fresh ELF' "$elf"
printf '  Machine:                           Atmel AVR 8-bit microcontroller\n'
if [ "${FAKE_READELF_MODE:-pass}" = wrong ]; then
	printf '  Flags:                             0x5, avr:5\n'
else
	printf '  Flags:                             0x19, avr:25, link-relax\n'
fi
EOF

cat > "$avr_tools/objcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do out=$arg; done
printf '%s %s\n' "$0" "$*" >> "$FAKE_OBJCOPY_LOG"
case "${FAKE_OBJCOPY_MODE:-pass}" in
	fail) printf 'partial HEX\n' > "$out"; exit 1 ;;
	empty) : > "$out" ;;
	malformed) printf ':0100000001FF\n:00000001FF\n' > "$out" ;;
	*) printf ':0100000001FE\n:00000001FF\n' > "$out" ;;
esac
EOF
chmod 750 "$avr_tools/cc" "$avr_tools/readelf" "$avr_tools/objcopy" \
	"$avr/scripts/validate-ihex.sh"

avr_sources=(
	src/bypass_mcu_avr_classic.c src/bypass_pure.c src/bypass_pure.h
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_avr_classic.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.c
	src/bypass_output_cd4053_with_mute.c
	src/bypass_output_cd4053_with_mute.h src/bypass_output_tq2_l2_5v_relay.c
	src/bypass_output_tq2_l2_5v_relay.h
)
for file in "${avr_sources[@]}"; do : > "$avr/$file"; done
: > "$cc_log"
: > "$objcopy_log"

run_avr_make() {
	FAKE_CC_LOG="$cc_log" FAKE_OBJCOPY_LOG="$objcopy_log" \
	make --no-print-directory -C "$avr" "$@" \
		CC="$avr_tools/cc" HOSTCC="$avr_tools/cc" \
		OBJCOPY="$avr_tools/objcopy" \
		READELF="$avr_tools/readelf" \
		AVR_BUILD_DIR=build_avr_classic \
		AVR_FW=build_avr_classic/bypass FW_BASE=bypass ATTINY13A_MCU=attiny13a \
		VARIANTS="cd4053_simple cd4053_with_mute tq2_l2_5v_relay"
}

cc_count() { grep -c -F "$1.tmp" "$cc_log" || true; }
objcopy_count() { grep -c -F "$1.tmp" "$objcopy_log" || true; }

t13=build_avr_classic/bypass-attiny13a-cd4053_simple
x5=build_avr_classic/bypass-attiny85-cd4053_simple

run_avr_make "$t13.hex" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 1 && "$(objcopy_count "$t13.hex")" -eq 1 ]] \
	&& grep -F "$t13.elf.tmp" "$cc_log" | grep -q -- '-DBYPASS_MCU_AVR_CLASSIC' \
	|| fail "initial ATtiny13a build did not reach the fake compiler with its backend selector"
checks=$((checks + 1))
# The direct witness for section 1: nothing changed, and both still rebuild.
run_avr_make "$t13.hex" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 2 && "$(objcopy_count "$t13.hex")" -eq 2 ]] \
	|| fail "an identical request reused the ATtiny13a ELF/HEX"
checks=$((checks + 1))

run_avr_make "$t13.hex" "CFLAGS=-DNAME='quoted value'" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 3 ]] && grep -q -- "-DNAME=quoted value" "$cc_log" \
	|| fail "apostrophe-bearing flags did not reach the compiler"
checks=$((checks + 1))

# A forced ELF rebuild must invalidate its paired HEX. A subsequent consumer
# phase can then regenerate HEX from that exact ELF without compiling again.
run_avr_make "$t13.elf" >/dev/null
[[ -s "$avr/$t13.elf" && ! -e "$avr/$t13.hex" ]] \
	|| fail "ELF rebuild did not invalidate its paired HEX"
checks=$((checks + 1))
validated_hash=$(sha256sum "$avr/$t13.elf")
validated_cc_count=$(cc_count "$t13.elf")
validated_objcopy_count=$(objcopy_count "$t13.hex")
# GNU Make deliberately omits --old-file from recursive MAKEFLAGS. This private
# sandbox call therefore identifies itself as an already-held graph so the
# wrapper does not consume and lose the option before the real build rules see
# it. The enclosing regression is the sandbox's sole owner.
avr_lock_id=$(stat -Lc '%d:%i' "$avr")
(
	export MAKEFLAGS=-B _MAKE_SERIAL_LOCK_HELD="$avr_lock_id"
	run_avr_make --old-file="$t13.elf" "$t13.hex" AVR_REBUILD_PREREQ=
) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq "$validated_cc_count" \
	&& "$(objcopy_count "$t13.hex")" -eq $((validated_objcopy_count + 1)) \
	&& "$(sha256sum "$avr/$t13.elf")" == "$validated_hash" \
	&& -s "$avr/$t13.hex" ]] \
	|| fail "HEX regeneration recompiled or changed the validated ELF"
checks=$((checks + 1))
run_avr_make "$t13.elf" AVR_REBUILD_PREREQ= >/dev/null
[[ "$(cc_count "$t13.elf")" -eq "$validated_cc_count" \
	&& "$(sha256sum "$avr/$t13.elf")" == "$validated_hash" \
	&& -s "$avr/$t13.hex" ]] \
	|| fail "consumer-only ELF access invalidated publishable artifacts"
checks=$((checks + 1))

# Each way the compiler or objcopy can fail must publish nothing: no HEX, no
# temporary, and no ELF unless the failure came after a valid one. A failed
# fuse-checker compile is held to the same rule in 2b.
for spec in \
		'compiler failure:FAKE_CC_MODE=fail:0' \
		'empty compiler output:FAKE_CC_MODE=empty:0' \
		'malformed compiler output:FAKE_CC_MODE=malformed:0' \
		'wrong-architecture compiler output:FAKE_READELF_MODE=wrong:0' \
		'objcopy failure:FAKE_OBJCOPY_MODE=fail:1' \
		'empty objcopy output:FAKE_OBJCOPY_MODE=empty:1' \
		'malformed objcopy output:FAKE_OBJCOPY_MODE=malformed:1'; do
	IFS=: read -r what setting elf_kept <<<"$spec"
	if (export "$setting"; run_avr_make "$t13.hex") >/dev/null 2>&1; then
		fail "$what was accepted"
	fi
	shopt -s nullglob
	temps=("$avr/$t13.elf".tmp.* "$avr/$t13.hex".tmp.*)
	shopt -u nullglob
	[[ ! -e "$avr/$t13.hex" && "${#temps[@]}" -eq 0 ]] \
		|| fail "$what left a HEX or a temporary file"
	if [ "$elf_kept" = 1 ]; then
		[ -s "$avr/$t13.elf" ] || fail "$what removed the valid ELF it came after"
	else
		[ ! -e "$avr/$t13.elf" ] || fail "$what left an ELF"
	fi
	checks=$((checks + 1))
	run_avr_make "$t13.hex" >/dev/null
done

rm -rf "$avr/build_avr_classic"
mkdir -p "$avr/build_avr_classic"
: > "$cc_log"; : > "$objcopy_log"
(run_avr_make "$t13.hex") >/dev/null & pid1=$!
(run_avr_make "$x5.hex") >/dev/null & pid2=$!
wait "$pid1" && wait "$pid2" || fail "concurrent classic builds interfered"
[[ -s "$avr/$t13.hex" && -s "$avr/$x5.hex" ]] \
	|| fail "concurrent classic builds lost an artifact"
checks=$((checks + 1))

rm -f "$avr/$t13.hex"
mkdir "$avr/$t13.hex"
if run_avr_make "$t13.elf" ATTINY13A_F_CPU=3300000UL >/dev/null 2>&1; then
	fail "unremovable stale HEX path was accepted"
fi
[[ -d "$avr/$t13.hex" && ! -e "$avr/$t13.elf" ]] \
	|| fail "cleanup failure published an invalid artifact"
checks=$((checks + 1))

# ============================================================================
# 2b. WORKLOAD -- the fuse checker, recursive phases and one build per graph
# ============================================================================
wl="$work/workload"
wl_tools="$work/workload-tools"
wl_log="$work/workload-compiler.log"
mkdir -p "$wl/test/host" "$wl/test/avr" "$wl/src" "$wl/build_avr_classic" \
	"$wl_tools"
cp "$ROOT/Makefile" "$wl/Makefile"
cp "$ROOT/test/check_flash_budget.sh" "$wl/test/check_flash_budget.sh"

# Every output is an executable that passes, so the fuse checker and simulator
# binaries run; FAKE_COMPILER_MODE breaks one compile at a time.
cat > "$wl_tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake compiler 1\n'; exit 0; fi
out=
for arg in "$@"; do
	if [ "$arg" = -o ]; then want_out=1; continue; fi
	if [ "${want_out:-0}" = 1 ]; then out=$arg; want_out=0; fi
done
[ -n "$out" ] || exit 0
printf '%s\n' "$*" >> "$FAKE_COMPILER_LOG"
mkdir -p "$(dirname "$out")"
case "${FAKE_COMPILER_MODE:-pass}" in
	fail) printf 'partial compiler output\n' > "$out"; exit 1 ;;
	empty) : > "$out"; exit 0 ;;
esac
printf '#!/bin/sh\nexit 0\n' > "$out"
chmod 750 "$out"
EOF

cat > "$wl_tools/size" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'Program: 512 bytes (50.0%% Full)\n'
EOF

cat > "$wl_tools/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '  Machine: Atmel AVR 8-bit microcontroller\n'
printf '  Flags: 0x19, avr:25, link-relax\n'
EOF
chmod 750 "$wl_tools/cc" "$wl_tools/size" "$wl_tools/readelf" \
	"$wl/test/check_flash_budget.sh"

for file in "${avr_sources[@]}" \
		test/host/test_logic_host.c test/avr/test_sim.c test/avr/test_fuses.c \
		test/model_step.h test/bypass_config_host.h test/bypass_output_host.h; do
	mkdir -p "$wl/${file%/*}"
	: > "$wl/$file"
done
cp "$ROOT/test/avr/attiny202_fuses.py" "$ROOT/test/avr/test_attiny202_fuses.py" \
	"$wl/test/avr/"
: > "$wl_log"

run_make() {
	FAKE_COMPILER_LOG="$wl_log" make --no-print-directory -C "$wl" "$@" \
		CC="$wl_tools/cc" HOSTCC="$wl_tools/cc" SANITIZE= \
		SIZE="$wl_tools/size" READELF="$wl_tools/readelf" SIM_LIBS= AVR_BUILD_DIR=build_avr_classic \
		AVR_FW=build_avr_classic/bypass FW_BASE=bypass ATTINY13A_MCU=attiny13a \
		VARIANTS="cd4053_simple cd4053_with_mute tq2_l2_5v_relay"
}

compile_count() {
	local output=$1
	grep -c -- "-o $output" "$wl_log" || true
}

# A failed or empty fuse-checker compile must leave no checker: one left behind
# would validate the previous fuse values.
for mode in fail empty; do
	run_make test-fuses >/dev/null
	[[ -x "$wl/test/avr/test_fuses" ]] || fail "could not build the fuse checker"
	if (export FAKE_COMPILER_MODE=$mode; run_make test-fuses) >/dev/null 2>&1; then
		fail "fuse-checker compile ($mode) was accepted"
	fi
	shopt -s nullglob
	fuse_temps=("$wl/test/avr/test_fuses".tmp.*)
	shopt -u nullglob
	[[ ! -e "$wl/test/avr/test_fuses" && "${#fuse_temps[@]}" -eq 0 ]] \
		|| fail "fuse-checker compile ($mode) left a stale checker or temporary output"
	checks=$((checks + 1))
done

: > "$wl_log"
run_make test-sim-attiny13a SIM_DEFS=-DRECURSIVE_SIM=1 >/dev/null
[[ "$(grep -c -- '-DRECURSIVE_SIM=1' "$wl_log")" -eq 3 ]] \
	|| fail "recursive simulator phase lost effective SIM_DEFS"
checks=$((checks + 1))
: > "$wl_log"
run_make test-sim-attiny13a SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny13a)" -eq 1 ]] \
	|| fail "recursive FULL simulator phase did not rebuild"
if grep -q -- '-DSIM_RANDOM_NOISE_DURATION_MS=' "$wl_log"; then
	fail "recursive FULL simulator phase fell back to FAST definitions"
fi
checks=$((checks + 1))

: > "$wl_log"
(
	export MAKEFLAGS=-B
	run_make test-sim-attiny13a SIM_DEFS=-DFORCED_SIM=1
) >/dev/null
[[ "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_simple.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_with_mute.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-tq2_l2_5v_relay.elf)" -eq 1 ]] \
	|| fail "inherited -B rebuilt ELFs after flash-budget validation"
checks=$((checks + 1))

: > "$wl_log"
run_make -j2 test-sim-attiny13a test-flash-budget SIM_DEFS=-DCOALESCED_SIM=1 >/dev/null
[[ "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_simple.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_with_mute.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-tq2_l2_5v_relay.elf)" -eq 1 ]] \
	|| fail "parallel simulator and flash gates rebuilt shared ELFs more than once"
checks=$((checks + 1))

# Shared prerequisites inherit a target-specific workload profile from their
# parent. Mixing FAST and FULL parents in one graph is ambiguous and must fail
# before either aggregate can print a misleading success banner.
for request in "test stress" "test-fast test-long"; do
	if output=$(run_make $request 2>&1); then
		fail "mixed workload profiles were accepted: $request"
	fi
	case "$output" in
		*"request either a FAST test/test-fast profile or a FULL stress/test-long profile, not both"*) ;;
		*) fail "mixed workload profile produced the wrong diagnostic: $output" ;;
	esac
done
checks=$((checks + 2))

outside="$work/external-build"
run_make test-sim-cd4053_simple-attiny13a AVR_BUILD_DIR="$outside" SIM_DEFS=-DISOLATED=1 >/dev/null
[ ! -e "$outside/bypass-attiny13a-cd4053_simple.elf" ] \
	|| fail "regression escaped its isolated mini-tree build path"
checks=$((checks + 1))

# ============================================================================
# 2c. PIC HARNESSES -- selected image, derived inputs, missing XC8
# ============================================================================
# The scratch tree from section 1, with fake c++, pkg-config, XC8 and the
# PIC12F675 timing/calibration helpers, so this needs neither gpsim nor glib.
repo="$tree"
tools="$work/pic-tools"
log="$work/pic-compile.log"
argv_log="$work/pic-compile-argv.log"
mklog="$work/pic-make.log"
mkdir -p "$tools" "$repo/build_pic10f322" "$repo/build_pic10f320" \
	"$repo/build_pic12f675/simcal"

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"

# Records the full argv, then writes the -o target so Make sees a fresh artifact.
cat > "$tools/cxx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=; want=0
for a in "$@"; do
	if [ "$a" = -o ]; then want=1; continue; fi
	if [ "$want" = 1 ]; then out=$a; want=0; fi
done
printf '%s\n' "$*" >> "${FAKE_CXX_LOG:?}"
if [ -n "${FAKE_CXX_ARGV_LOG:-}" ]; then
	printf '%s\n' __COMMAND_BEGIN__ >> "$FAKE_CXX_ARGV_LOG"
	printf '%s\n' "$@" >> "$FAKE_CXX_ARGV_LOG"
	printf '%s\n' __COMMAND_END__ >> "$FAKE_CXX_ARGV_LOG"
fi
[ -n "$out" ] || exit 0
printf 'fake soak binary\n' > "$out"
chmod 755 "$out"
EOF
# PIC*_SOAK_COMPILE shells out to pkg-config for glib flags; neither glib nor
# pkg-config may exist on the runner.
cat > "$tools/pkg-config" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
	--cflags) printf -- '-I/fake/glib\n' ;;
	--exists) exit 0 ;;
esac
exit 0
EOF
cat > "$tools/timing-python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script=${1:?}
shift
case "$script $*" in
	*'pic12f675_soak_timing.py '*'--format defines'*)
		case " $* " in
			*' --variant cd4053_with_mute '*) block=5 ;;
			*' --variant tq2_l2_5v_relay '*) block=12 ;;
			*) block=0 ;;
		esac
		printf '%s\n' "-DSOAK_TICK_US=1024u -DSOAK_ACTUATION_BLOCK_MS=${block}u"
		;;
	*'inject_calibration_word.py '*)
		argc=$#
		eval "input=\${$((argc - 1))}"
		eval "output=\${$argc}"
		cp "$input" "$output"
		;;
	*) exit 2 ;;
esac
EOF
cat > "$tools/xc8" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf '%s\n' ':020000000028D6' ':02400E009E38DA' ':00000001FF' > "$out"
printf '_ctx_:\n ds 3\n' > "${out%.hex}.s"
printf '%s\n' '_ctx_ 0021 0023 BANK0 0' '_gpio_shadow_ 0020 0020 BANK0 0' \
       '%segments' > "${out%.hex}.sym"
printf 'Program space used 2Ah (42) of 400h words (4.1%%)\n'
printf 'Data space used 20h (32) of 40h bytes (50.0%%)\n'
EOF
chmod 755 "$tools/cxx" "$tools/pkg-config" "$tools/timing-python" "$tools/xc8"

# build <target> <var=value...> -- one Make invocation against the scratch tree.
# Combined output lands in $mklog so the skip/strict checks below can read the
# recipe's own diagnostic instead of inferring it from an exit status.
build() {
	local target=$1; shift
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		PATH="$tools:$PATH" FAKE_CXX_LOG="$log" FAKE_CXX_ARGV_LOG="$argv_log" \
		_MAKE_SERIAL_LOCK_HELD="$tree_lock_id" \
			"${MAKE_CMD[@]}" --no-print-directory -C "$repo" "$@" "$target" >"$mklog" 2>&1
	)
}

compiles() { [ -f "$log" ] && grep -c . "$log" || printf '0\n'; }

# The PIC12F675 soak compiles from build-derived inputs: the symbol file supplies
# the shadow address and the timing helper the tick and block time, and the
# direct file target must produce them itself, from nothing.
: > "$log"
build test/pic/test_soak_pic12f675 PIC_SOAK_CXX="$tools/cxx" \
	PIC12F675_SOAK_DURATION_MS=60000 PIC_CC="$tools/xc8" \
	PIC12F675_PYTHON="$tools/timing-python" \
	|| fail "PIC12F675: direct soak build failed: $(cat "$mklog")"
[ "$(compiles)" -eq 1 ] || fail "PIC12F675: expected 1 compile, got $(compiles)"
for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
	[[ -s "$repo/build_pic12f675/bypass-pic12f675-${variant}.sym" \
		&& -s "$repo/build_pic12f675/simcal/bypass-pic12f675-${variant}_simcal.hex" ]] \
		|| fail "PIC12F675: clean direct build did not produce complete symbol/simulator inputs for $variant"
done
args=$(tail -1 "$log")
[[ "$args" == *"-DPIC_SHADOW_ADDR=0x0020"* \
	&& "$args" == *"-DSOAK_TICK_US=1024u"* \
	&& "$args" == *"-DSOAK_ACTUATION_BLOCK_MS=0u"* ]] \
	|| fail "PIC12F675: compile did not carry the symbol-derived address and timing definitions: $args"
checks=$((checks + 1))
rm -rf "$repo/build_pic12f675"
build test/pic/test_soak_pic12f675 PIC_SOAK_CXX="$tools/cxx" \
	PIC12F675_SOAK_DURATION_MS=60000 PIC_CC="$tools/xc8" \
	PIC12F675_PYTHON="$tools/timing-python" \
	|| fail "PIC12F675: direct clean-tree rebuild failed: $(cat "$mklog")"
[ "$(compiles)" -eq 2 ] || fail "PIC12F675: clean-tree request did not reach the soak compiler"
args=$(tail -1 "$log")
[[ "$args" == *"-DPIC_SHADOW_ADDR=0x0020"* ]] \
	|| fail "PIC12F675: clean-tree rebuild lost PIC_SHADOW_ADDR: $args"
checks=$((checks + 1))

# Each 10F32x implementation keeps its own timing map. Exercise every entry at
# the producer boundary so a correct source constant paired with the wrong Make
# lookup cannot pass the value-level timing contract alone.
check_10f32x_variant() {
	local label=$1 target=$2 cxx_var=$3 duration_var=$4 variant_var=$5
	local image_prefix=$6 variant=$7 block=$8 args arg
	local begin=0 end=0 block_args=0 fw_args=0
	local expected_block="-DSOAK_ACTUATION_BLOCK_MS=${block}u"
	local expected_fw="-DFW_PATH=\"$repo/${image_prefix}${variant}.hex\""
	: > "$log"
	: > "$argv_log"
	build "$target" "$cxx_var=$tools/cxx" "$duration_var=60000" \
		"$variant_var=$variant" \
		|| fail "$label: direct $variant build failed"
	[ "$(compiles)" -eq 1 ] \
		|| fail "$label: $variant issued $(compiles) compiler commands instead of 1"
	args=$(tail -1 "$log")
	while IFS= read -r arg; do
		case "$arg" in
			__COMMAND_BEGIN__) begin=$((begin + 1)) ;;
			__COMMAND_END__) end=$((end + 1)) ;;
			-DFW_PATH=*)
				fw_args=$((fw_args + 1))
				[ "$arg" = "$expected_fw" ] \
					|| fail "$label: $variant used the wrong firmware path: $arg"
				;;
			-DSOAK_ACTUATION_BLOCK_MS=*)
				block_args=$((block_args + 1))
				[ "$arg" = "$expected_block" ] \
					|| fail "$label: $variant used the wrong actuation-block value: $arg"
				;;
		esac
	done < "$argv_log"
	[ "$begin" -eq 1 ] && [ "$end" -eq 1 ] \
		|| fail "$label: $variant compiler argv transcript was incomplete"
	[ "$fw_args" -eq 1 ] \
		|| fail "$label: $variant compile carried $fw_args FW_PATH arguments: $args"
	[ "$block_args" -eq 1 ] \
		|| fail "$label: $variant compile carried $block_args actuation-block arguments: $args"
	checks=$((checks + 1))
}

for spec in cd4053_simple:0 cd4053_with_mute:5 tq2_l2_5v_relay:12; do
	variant=${spec%%:*}; block=${spec#*:}
	check_10f32x_variant "PIC10F322" "test/pic/test_soak_pic" \
		PIC_SOAK_CXX PIC10F322_SOAK_DURATION_MS PIC10F322_SOAK_VARIANT \
		build_pic10f322/bypass-pic10f322- "$variant" "$block"
	check_10f32x_variant "PIC10F320" "build_pic10f320/test_soak_pic" \
		PIC10F320_SOAK_CXX PIC10F320_SOAK_DURATION_MS PIC10F320_SOAK_VARIANT \
		build_pic10f320/bypass-pic10f320- "$variant" "$block"
done

# The selected variant must reach both the image path and timing derivation.
for spec in cd4053_with_mute:5 tq2_l2_5v_relay:12; do
	variant=${spec%%:*}; block=${spec#*:}
	: > "$log"
	build test/pic/test_soak_pic12f675 PIC_SOAK_CXX="$tools/cxx" \
		PIC12F675_SOAK_DURATION_MS=60000 PIC_CC="$tools/xc8" \
		PIC12F675_PYTHON="$tools/timing-python" PIC12F675_SOAK_VARIANT="$variant" \
		|| fail "PIC12F675: direct $variant build failed"
	args=$(tail -1 "$log")
	[[ "$args" == *"bypass-pic12f675-${variant}_simcal.hex"* \
		&& "$args" == *"-DSOAK_ACTUATION_BLOCK_MS=${block}u"* ]] \
		|| fail "PIC12F675: $variant did not reach image/timing compile arguments: $args"
	checks=$((checks + 1))
done

# Each fault and lock-step binary consumes an XC8 image, the matching
# assembly/symbol sidecars and the context-layout checker. Build once, delete
# those generated inputs beneath the binary, and require the direct target to
# restore them and recompile. The phony run lanes mask a stale direct-file use
# by deleting their binaries inline.
check_direct_harness() {
	local label=$1 target=$2 image=$3 asm=$4 sym=$5
	local before after args

	rm -f "$repo/$target" "$repo/$image" "$repo/$asm" "$repo/$sym"
	: > "$log"
	build "$target" PIC_CC="$tools/xc8" PIC_SOAK_CXX="$tools/cxx" \
		HOSTCC="$tools/cxx" PIC12F675_PYTHON="$tools/timing-python" \
		|| fail "$label: clean direct build failed: $(cat "$mklog")"
	for artifact in "$target" "$image" "$asm" "$sym"; do
		[ -s "$repo/$artifact" ] \
			|| fail "$label: clean direct build did not produce $artifact"
	done
	args=$(tail -1 "$log")
	[[ "$args" == *"-DCTX_ADDR=0x0021"* ]] \
		|| fail "$label: compile did not carry the validated context address: $args"
	case "$label" in
		PIC12F675-fault)
			[[ "$args" == *"-DPIC_SHADOW_ADDR=0x0020"* ]] \
				|| fail "$label: compile did not carry the symbol-derived shadow address: $args"
			;;
	esac
	checks=$((checks + 1))

	before=$(compiles)
	rm -f "$repo/$image" "$repo/$asm" "$repo/$sym"
	build "$target" PIC_CC="$tools/xc8" PIC_SOAK_CXX="$tools/cxx" \
		HOSTCC="$tools/cxx" PIC12F675_PYTHON="$tools/timing-python" \
		|| fail "$label: generated-input rebuild failed: $(cat "$mklog")"
	after=$(compiles)
	[ "$after" -gt "$before" ] \
		|| fail "$label: deleting generated inputs did not rebuild the harness"
	for artifact in "$image" "$asm" "$sym"; do
		[ -s "$repo/$artifact" ] \
			|| fail "$label: generated-input rebuild did not restore $artifact"
	done
	checks=$((checks + 1))
}

check_direct_harness PIC10F322-fault test/pic/test_fault_pic \
	build_pic10f322/bypass-pic10f322-cd4053_simple.hex \
	build_pic10f322/bypass-pic10f322-cd4053_simple.s \
	build_pic10f322/bypass-pic10f322-cd4053_simple.sym
check_direct_harness PIC10F322-lockstep test/pic/test_lockstep_pic \
	build_pic10f322/bypass-pic10f322-cd4053_simple.hex \
	build_pic10f322/bypass-pic10f322-cd4053_simple.s \
	build_pic10f322/bypass-pic10f322-cd4053_simple.sym
check_direct_harness PIC12F675-fault test/pic/test_fault_pic12f675 \
	build_pic12f675/simcal/bypass-pic12f675-cd4053_simple_simcal.hex \
	build_pic12f675/bypass-pic12f675-cd4053_simple.s \
	build_pic12f675/bypass-pic12f675-cd4053_simple.sym
check_direct_harness PIC12F675-lockstep test/pic/test_lockstep_pic12f675 \
	build_pic12f675/simcal/bypass-pic12f675-cd4053_simple_simcal.hex \
	build_pic12f675/bypass-pic12f675-cd4053_simple.s \
	build_pic12f675/bypass-pic12f675-cd4053_simple.sym

# A zero-XC8 skip must not leave a stale binary that no longer reflects the
# requested duration/variant.
#
# STRICT_TOOLS is PINNED on the command line for every check from here down,
# rather than inherited. It is exported by scripts/ci-local.sh and by the
# release gates, and it is precisely what decides whether a missing-tool
# condition skips or fails -- so an unpinned invocation measures the runner's
# environment instead of the rule. Both settings are asserted, in that order.
printf 'stale soak binary\n' > "$repo/test/pic/test_soak_pic12f675"
rm -rf "$repo/build_pic12f675"
build test/pic/test_soak_pic12f675 STRICT_TOOLS= PIC_SOAK_CXX="$tools/cxx" \
	PIC_CC="$tools/missing-xc8" PIC12F675_PYTHON="$tools/missing-python" \
	PIC12F675_SOAK_DURATION_MS=70000 \
	|| fail "PIC12F675: zero-XC8 direct target did not skip cleanly: $(cat "$mklog")"
grep -q 'skipping PIC12F675 soak build' "$mklog" \
	|| fail "PIC12F675: zero-XC8 direct target exited 0 without taking the" \
		"documented skip: $(cat "$mklog")"
[ ! -e "$repo/test/pic/test_soak_pic12f675" ] \
	|| fail "PIC12F675: zero-XC8 direct target retained a stale soak binary"
checks=$((checks + 1))

# The same condition under STRICT_TOOLS=1 -- what CI and the release gates run --
# must fail closed instead, and must not compile a binary on the way out.
#
# Nothing is asserted here about the stale file. Under STRICT_TOOLS=1 the
# failure lands in the PREREQUISITE ($(PIC12F675_SOAK_BIN) requires
# _pic12f675-build-soak, which requires the XC8 build), so the soak rule's own
# recipe -- the one carrying the `rm -f` scrub the skip path above relies on --
# never runs at all. Make leaving existing artifacts alone when a prerequisite
# fails is correct, and the caller is told the build is RED; the hazard this
# fixture guards is a stale binary surviving a build that reported SUCCESS.
printf 'stale soak binary\n' > "$repo/test/pic/test_soak_pic12f675"
rm -rf "$repo/build_pic12f675"
before=$(compiles)
if build test/pic/test_soak_pic12f675 STRICT_TOOLS=1 PIC_SOAK_CXX="$tools/cxx" \
		PIC_CC="$tools/missing-xc8" PIC12F675_PYTHON="$tools/missing-python" \
		PIC12F675_SOAK_DURATION_MS=70000; then
	fail "PIC12F675: zero-XC8 direct target skipped under STRICT_TOOLS=1"
fi
grep -q 'STRICT_TOOLS=1:' "$mklog" \
	|| fail "PIC12F675: strict zero-XC8 failure reported the wrong result:" \
		"$(cat "$mklog")"
[ "$(compiles)" -eq "$before" ] \
	|| fail "PIC12F675: strict zero-XC8 failure still reached the soak compiler"
rm -f "$repo/test/pic/test_soak_pic12f675"
checks=$((checks + 1))

# Selector validation dominates both the producer and skip paths. Pinned to the
# skipping setting: under STRICT_TOOLS=1 the missing compiler alone fails the
# build, and this check would pass without the selector ever being consulted.
if build test/pic/test_soak_pic12f675 STRICT_TOOLS= PIC_SOAK_CXX="$tools/cxx" \
		PIC_CC="$tools/missing-xc8" PIC12F675_PYTHON="$tools/missing-python" \
		PIC12F675_SOAK_VARIANT=unknown; then
	fail "PIC12F675: direct binary target accepted an invalid variant"
fi
grep -q 'PIC12F675_SOAK_VARIANT=unknown is not supported' "$mklog" \
	|| fail "PIC12F675: invalid variant was rejected for the wrong reason:" \
		"$(cat "$mklog")"
checks=$((checks + 1))

printf 'build rebuild validation: %d checks, 0 failures\n' "$checks"
