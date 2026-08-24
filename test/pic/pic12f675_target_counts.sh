#!/usr/bin/env bash

# Independent, reviewed oracle for the PIC12F675 target aggregate's canonical
# machine-result counts. Consumers deliberately share this table so each
# Makefile count-map branch is checked against one test-side source of truth.
pic12f675_target_count_table() {
	printf '%s\n' \
		'cd4053_simple 40 3005 25' \
		'cd4053_with_mute 40 3005 26' \
		'tq2_l2_5v_relay 46 3005 36'
}

pic12f675_target_counts() {
	local wanted=$1 variant fault lockstep io found=0 values=
	while read -r variant fault lockstep io; do
		if [ "$variant" = "$wanted" ]; then
			found=$((found + 1))
			values="$fault $lockstep $io"
		fi
	done < <(pic12f675_target_count_table)
	[ "$found" -eq 1 ] || return 1
	printf '%s\n' "$values"
}
