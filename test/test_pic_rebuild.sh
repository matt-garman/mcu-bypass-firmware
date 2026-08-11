#!/usr/bin/env bash
set -euo pipefail

# Host-only rebuild-determinism regression for the PIC soak binaries -- the PIC
# counterpart of test-workload-rebuild / test-avr-build-rebuild, and the last
# open row of the merge plan's §6.12.
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
# Parameterized so ONE regression covers both chips (merge plan §4 FOLD).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-rebuild.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
log="$work/compile.log"
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
mkdir -p "$repo/build_pic10f322" "$repo/build_pic10f320"

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
# (merge plan §4 FOLD), so both chips' rules name test/pic/test_soak_pic.cc. A
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
chmod 755 "$tools/cxx" "$tools/pkg-config"

# build <target> <var=value...> -- one Make invocation against the scratch repo
build() {
	local target=$1; shift
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		PATH="$tools:$PATH" FAKE_CXX_LOG="$log" \
			"${MAKE_CMD[@]}" --no-print-directory -C "$repo" "$@" "$target" >/dev/null 2>&1
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
	local before after args

	: > "$log"
	build "$target" "$cxx_var=$tools/cxx" "$dur_var=60000" $extra \
		|| fail "$label: first build failed"
	[ "$(compiles)" -eq 1 ] || fail "$label: expected 1 compile, got $(compiles)"
	args=$(tail -1 "$log")
	[[ "$args" == *"-DSOAK_DURATION_MS=60000"* ]] \
		|| fail "$label: first build did not carry the requested duration: $args"
	checks=$((checks + 1))

	# (1) changed variable -> must recompile, with the NEW value
	build "$target" "$cxx_var=$tools/cxx" "$dur_var=120000" $extra \
		|| fail "$label: rebuild after a duration change failed"
	[ "$(compiles)" -eq 2 ] \
		|| fail "$label: a changed $dur_var did not recompile (stale binary kept); compiles=$(compiles)"
	args=$(tail -1 "$log")
	[[ "$args" == *"-DSOAK_DURATION_MS=120000"* ]] \
		|| fail "$label: rebuild did not carry the new duration: $args"
	checks=$((checks + 1))

	# (2) identical rerun -> must STILL recompile (proves FORCE, not timestamps)
	build "$target" "$cxx_var=$tools/cxx" "$dur_var=120000" $extra \
		|| fail "$label: identical rerun failed"
	[ "$(compiles)" -eq 3 ] \
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
	PIC_SOAK_CXX PIC12F675_SOAK_DURATION_MS ""

# --- the three chips must not share one binary -------------------------------
# The two 10F32x parts compile from the SAME source since the §4 FOLD, and all
# three now share the same core header, differing only in the -D flags and the
# output path -- which is exactly what makes a shared output path the live
# hazard here: it would leave one chip's soak silently running another's image.
[ -f "$repo/test/pic/test_soak_pic" ] && [ -f "$repo/build_pic10f320/test_soak_pic" ] \
	&& [ -f "$repo/test/pic/test_soak_pic12f675" ] \
	|| fail "expected a separate soak binary per chip"
checks=$((checks + 1))

printf 'PIC soak rebuild determinism: %d checks, 0 failures\n' "$checks"
