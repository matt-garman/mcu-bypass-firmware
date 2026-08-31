#!/usr/bin/env bash
set -euo pipefail

# Host-only rebuild-determinism regression for the PIC soak binaries -- the PIC
# counterpart of test-workload-rebuild / test-avr-build-rebuild.
#
# THE PROPERTY
# ------------
# The Makefile states the contract at FORCE's definition: "always-out-of-date
# prerequisite used for artifacts whose effective build command includes
# command-line variables that timestamps cannot represent." Both soak binaries
# are exactly that -- PIC{,320}_SOAK_{DURATION,LIVENESS_INTERVAL,PROGRESS_
# INTERVAL}_MS and the variant are compiled in as -D flags -- and both rules
# omitted FORCE until 2026-07-27. Measured before the fix, on both chips:
#
#   make build_pic10f320/test_soak_pic PIC10F320_SOAK_DURATION_MS=60000
#   make build_pic10f320/test_soak_pic PIC10F320_SOAK_DURATION_MS=120000
#     -> "'build_pic10f320/test_soak_pic' is up to date."  (60000 binary kept)
#
# It stayed invisible because the normal lane never uses the file rule:
# pic10f32{2,0}-test-soak deletes and recompiles the binary inline. So the hazard is
# reachable only by naming the artifact directly -- which is what a release
# rehearsal or a hand-run soak at a shortened duration does.
#
# WHY IT DOES NOT NEED A TOOLCHAIN
# --------------------------------
# A fake c++ and a fake pkg-config stand in for the real ones, so this runs
# inside `make test` on any host. The recipe under test is the file rule itself,
# which carries no tool guards -- only the surrounding lane does.
#
# Parameterized so ONE regression covers both chips.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-${HOME:?HOME is required when TMPDIR is unset}}/test-pic-rebuild.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
log="$work/compile.log"
argv_log="$work/compile-argv.log"
mklog="$work/make.log"
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"

# shellcheck source=test/scratch_tree.sh
. "$ROOT/test/scratch_tree.sh" || fail "could not load test/scratch_tree.sh"

# Populate the scratch repo with the SHARED allowlist walk -- the same one the
# mutation runner uses (test/scratch_tree.sh). This fixture used to enumerate the
# file rules' prerequisites by hand, which meant a target that gained one broke
# both sandbox builders in turn, this one first. The walk takes every source
# under test/ at any depth, so a new prerequisite arrives without an edit here.
mkdir -p "$tools"
scratch_tree_copy "$ROOT" "$repo" \
	|| fail "could not populate the scratch repo (see test/scratch_tree.sh)"
repo_lock_id=$(stat -Lc '%d:%i' "$repo")
mkdir -p "$repo/build_pic10f322" "$repo/build_pic10f320" \
	"$repo/build_pic12f675/simcal"

# Blank the prerequisites of the rules under test, which is this fixture's whole
# point: the property is Make's staleness decision, not compilation, and the fake
# compiler below never opens them. Emptying them makes that impossible to depend
# on by accident.
#
# The list is no longer how these files GET here -- the walk above brings them --
# so it can no longer omit one and stop Make short of the property. What it still
# does is assert that these specific files are prerequisites of the soak rules:
# if one is renamed or dropped, this fixture says so in one line instead of
# quietly measuring something smaller.
blank_prereq() {
	[ -f "$repo/$1" ] \
		|| fail "scratch repo is missing $1 -- either the allowlist walk in" \
			"test/scratch_tree.sh no longer reaches it, or the soak rules'" \
			"prerequisites have moved"
	: > "$repo/$1" || fail "could not blank $1"
	checks=$((checks + 1))
}

# ONE soak source for the two 10F32x parts: PIC10F320_SOAK_SRC = $(PIC_SOAK_SRC)
# so both chips' rules name test/pic/test_soak_pic.cc. A
# test/pic10f320/ counterpart would fabricate a prerequisite no rule has. The
# PIC12F675 has its own adapter, and all three share the core header below.
blank_prereq test/soak_timing_config.h
blank_prereq test/pic/test_soak_pic.cc
blank_prereq test/pic/test_soak_pic12f675.cc
# $(PIC_TARGET_SOAK_CORE_HDR) -- the shared soak mechanism, a prerequisite of
# every chip's soak rule since the adapter split.
blank_prereq test/pic/test_soak_pic_core.h
# $(PIC_PIN_LOOKUP_HDR) -- the exact-pin lookup helper is a prerequisite of BOTH
# chips' soak rules. Its absence is what broke this fixture, and then the
# mutation sandbox, before the two builders were converged.
blank_prereq test/pic/find_pin_exact.h
# $(PIC_GPSIM_BOOTSTRAP_HDR) -- likewise: the shared libgpsim bring-up is a
# prerequisite of both chips' soak rules (and of the io/lock-step/fault rules).
blank_prereq test/pic/gpsim_bootstrap.h
# $(PIC_SOAK_SAMPLING_HDR) keeps multi-ms LED observation at one sample per ms.
# Both chip-specific soak rules consume it through their shared source.
blank_prereq test/pic/soak_sampling.h
blank_prereq test/pic/soak_hold_timing.h

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
printf 'fake assembly\n' > "${out%.hex}.s"
printf '_gpio_shadow_ 0020\n' > "${out%.hex}.sym"
printf 'Program space used 2Ah (42) of 400h words (4.1%%)\n'
printf 'Data space used 20h (32) of 40h bytes (50.0%%)\n'
EOF
chmod 755 "$tools/cxx" "$tools/pkg-config" "$tools/timing-python" "$tools/xc8"

# build <target> <var=value...> -- one Make invocation against the scratch repo.
# Combined output lands in $mklog so the skip/strict checks below can read the
# recipe's own diagnostic instead of inferring it from an exit status.
build() {
	local target=$1; shift
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		PATH="$tools:$PATH" FAKE_CXX_LOG="$log" FAKE_CXX_ARGV_LOG="$argv_log" \
		_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" \
			"${MAKE_CMD[@]}" --no-print-directory -C "$repo" "$@" "$target" >"$mklog" 2>&1
	)
}

compiles() { [ -f "$log" ] && grep -c . "$log" || printf '0\n'; }

# --- the contract, once per chip ---------------------------------------------
# 1. a changed workload variable must recompile (the measured hazard)
# 2. an UNCHANGED rerun must recompile too -- that is the signature of an
#    always-out-of-date prerequisite, and it is what distinguishes a real FORCE
#    from a rebuild that merely happened because a timestamp moved
check_chip() {
	local label=$1 target=$2 cxx_var=$3 dur_var=$4 extra=$5
	local before after args after_change after_identical

	: > "$log"
	build "$target" "$cxx_var=$tools/cxx" "$dur_var=60000" $extra \
		|| fail "$label: first build failed"
	[ "$(compiles)" -eq 1 ] || fail "$label: expected 1 compile, got $(compiles)"
	args=$(tail -1 "$log")
	[[ "$args" == *"-DSOAK_DURATION_MS=60000"* ]] \
		|| fail "$label: first build did not carry the requested duration: $args"
	if [ "$label" = PIC12F675 ]; then
		for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
			[[ -s "$repo/build_pic12f675/bypass-pic12f675-${variant}.sym" \
				&& -s "$repo/build_pic12f675/simcal/bypass-pic12f675-${variant}_simcal.hex" ]] \
				|| fail "$label: clean direct build did not produce complete symbol/simulator inputs for $variant"
		done
		[[ "$args" == *"-DPIC_SHADOW_ADDR=0x0020"* \
			&& "$args" == *"-DSOAK_TICK_US=1024u"* \
			&& "$args" == *"-DSOAK_ACTUATION_BLOCK_MS=0u"* ]] \
			|| fail "$label: compile did not carry the symbol-derived address and timing definitions: $args"
		checks=$((checks + 1))
		# Re-run from no image/symbol tree without suppressing prerequisites. The
		# direct file target itself must recreate every build-derived input.
		rm -rf "$repo/build_pic12f675"
		build "$target" "$cxx_var=$tools/cxx" "$dur_var=60000" $extra \
			|| fail "$label: direct clean-tree rebuild failed"
		[ "$(compiles)" -eq 2 ] \
			|| fail "$label: clean-tree request did not reach the soak compiler"
		args=$(tail -1 "$log")
		[[ "$args" == *"-DPIC_SHADOW_ADDR=0x0020"* ]] \
			|| fail "$label: clean-tree rebuild lost PIC_SHADOW_ADDR: $args"
		checks=$((checks + 1))
	fi
	checks=$((checks + 1))

	# (1) changed variable -> must recompile, with the NEW value
	build "$target" "$cxx_var=$tools/cxx" "$dur_var=120000" $extra \
		|| fail "$label: rebuild after a duration change failed"
	if [ "$label" = PIC12F675 ]; then after_change=3; else after_change=2; fi
	[ "$(compiles)" -eq "$after_change" ] \
		|| fail "$label: a changed $dur_var did not recompile (stale binary kept); compiles=$(compiles)"
	args=$(tail -1 "$log")
	[[ "$args" == *"-DSOAK_DURATION_MS=120000"* ]] \
		|| fail "$label: rebuild did not carry the new duration: $args"
	checks=$((checks + 1))

	# (2) identical rerun -> must STILL recompile (proves FORCE, not timestamps)
	build "$target" "$cxx_var=$tools/cxx" "$dur_var=120000" $extra \
		|| fail "$label: identical rerun failed"
	if [ "$label" = PIC12F675 ]; then after_identical=4; else after_identical=3; fi
	[ "$(compiles)" -eq "$after_identical" ] \
		|| fail "$label: an identical rerun did not recompile, so the rule is not unconditionally out of date; compiles=$(compiles)"
	checks=$((checks + 1))

	# the recorded command must be this chip's, not the other's
	args=$(tail -1 "$log")
	[[ "$args" == *"$target"* ]] \
		|| fail "$label: compile did not target $target: $args"
	checks=$((checks + 1))
}

check_chip "PIC10F322" "test/pic/test_soak_pic" \
	PIC_SOAK_CXX PIC10F322_SOAK_DURATION_MS ""
check_chip "PIC10F320" "build_pic10f320/test_soak_pic" \
	PIC10F320_SOAK_CXX PIC10F320_SOAK_DURATION_MS ""
# The PIC12F675 shares $(PIC_SOAK_CXX) with the 322 and, since the adapter
# split, the core header too -- so its own -D flags are the only thing keeping
# its binary distinct.
check_chip "PIC12F675" "test/pic/test_soak_pic12f675" \
	PIC_SOAK_CXX PIC12F675_SOAK_DURATION_MS \
	"PIC_CC=$tools/xc8 PIC12F675_PYTHON=$tools/timing-python"

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

# --- the three chips must not share one binary -------------------------------
# The two 10F32x parts compile from the SAME source, and all
# three now share the same core header, differing only in the -D flags and the
# output path -- which is exactly what makes a shared output path the live
# hazard here: it would leave one chip's soak silently running another's image.
[ -f "$repo/test/pic/test_soak_pic" ] && [ -f "$repo/build_pic10f320/test_soak_pic" ] \
	|| fail "expected a separate soak binary per chip"
checks=$((checks + 1))

printf 'PIC soak rebuild determinism: %d checks, 0 failures\n' "$checks"
