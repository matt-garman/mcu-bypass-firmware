# Resolve mutation skip policy without running probes or mutants. This is
# sourced by run_mutation_tests.sh and the host-only ci-local routing regression.
resolve_mutation_allow_skip() {
	local value
	if [ -n "${MUTATION_ALLOW_SKIP+x}" ]; then
		value=$MUTATION_ALLOW_SKIP
	elif [ -n "${STRICT_TOOLS:-}" ]; then
		value=0
	else
		value=1
	fi

	case "$value" in
		0|1|PIC|ATtiny202|PIC,ATtiny202) printf '%s\n' "$value" ;;
		*) printf "ERROR: MUTATION_ALLOW_SKIP must be 0, 1, PIC, ATtiny202, or PIC,ATtiny202 (got '%s')\n" \
			"$value" >&2; return 2 ;;
	esac
}

mutation_skip_is_allowed() {
	local substrate=$1 policy=$2
	case "$policy:$substrate" in
		1:PIC|1:ATtiny202|PIC:PIC|ATtiny202:ATtiny202|PIC,ATtiny202:PIC|PIC,ATtiny202:ATtiny202)
			return 0 ;;
		*) return 1 ;;
	esac
}
