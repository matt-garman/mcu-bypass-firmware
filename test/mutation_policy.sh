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
		0|1) printf '%s\n' "$value" ;;
		*) printf "ERROR: MUTATION_ALLOW_SKIP must be 0 or 1 (got '%s')\n" \
			"$value" >&2; return 2 ;;
	esac
}
