#!/usr/bin/env bash

# Pure validation helpers shared by the mutation driver and its host self-test.

mutation_parse_record() {
    local label=$1 expected_fields=$2 entry=$3 rest field
    MUTATION_RECORD_FIELDS=()
    rest=$entry
    while [[ $rest == *$'\t'* ]]; do
        field=${rest%%$'\t'*}
        MUTATION_RECORD_FIELDS+=("$field")
        rest=${rest#*$'\t'}
    done
    MUTATION_RECORD_FIELDS+=("$rest")

    if [ "${#MUTATION_RECORD_FIELDS[@]}" -ne "$expected_fields" ]; then
        printf 'ERROR: mutation inventory %s has %d fields; expected %d\n' \
            "$label" "${#MUTATION_RECORD_FIELDS[@]}" "$expected_fields" >&2
        return 1
    fi
    for field in "${MUTATION_RECORD_FIELDS[@]}"; do
        if [ -z "$field" ]; then
            printf 'ERROR: mutation inventory %s has an empty field\n' "$label" >&2
            return 1
        fi
        if [[ $field == *$'\n'* || $field == *$'\r'* || $field == *$'\x1f'* ]]; then
            printf 'ERROR: mutation inventory %s contains a reserved control delimiter\n' \
                "$label" >&2
            return 1
        fi
    done
}

mutation_require_count() {
    local label=$1 expected=$2 actual=$3
    if ! [[ $expected =~ ^(0|[1-9][0-9]*)$ && $actual =~ ^(0|[1-9][0-9]*)$ ]]; then
        printf 'ERROR: mutation inventory %s count is not canonical decimal (%s/%s)\n' \
            "$label" "$actual" "$expected" >&2
        return 1
    fi
    if [ "$actual" -ne "$expected" ]; then
        printf 'ERROR: mutation inventory %s has %s entries; expected %s\n' \
            "$label" "$actual" "$expected" >&2
        return 1
    fi
}

mutation_validate_totals() {
    local expected=$1 dispatched=$2 skipped=$3 killed=$4 survived=$5 errored=$6
    local worker_failures=$7 artifact_errors=$8 label value
    for label in expected dispatched skipped killed survived errored worker_failures artifact_errors; do
        value=${!label}
        if ! [[ $value =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#value}" -gt 9 ]; then
            printf 'ERROR: mutation accounting %s is not a bounded canonical decimal: %s\n' \
                "$label" "$value" >&2
            return 1
        fi
    done
    if [ $((dispatched + skipped)) -ne "$expected" ]; then
        printf 'ERROR: mutation accounting planned %d dispatched + %d skipped; expected %d total\n' \
            "$dispatched" "$skipped" "$expected" >&2
        return 1
    fi
    if [ $((killed + survived + errored)) -ne "$dispatched" ]; then
        printf 'ERROR: mutation accounting recorded %d results for %d dispatched mutants\n' \
            "$((killed + survived + errored))" "$dispatched" >&2
        return 1
    fi
    if [ "$worker_failures" -ne 0 ] || [ "$artifact_errors" -ne 0 ]; then
        printf 'ERROR: mutation accounting saw %d worker failure(s) and %d artifact error(s)\n' \
            "$worker_failures" "$artifact_errors" >&2
        return 1
    fi
}

# Statuses that mean "the checker did not run", as opposed to "the checker ran
# and the mutant failed it". The distinction is load-bearing: a mutant is KILLED
# on any nonzero exit, so anything misfiled here becomes a silent false green.
#
# 124 is timeout(1)'s expiry status and is the reason this comment exists. Every
# mutant checker is wrapped in `timeout` (see mutation_bounded in
# run_mutation_tests.sh), and without 124 in this set a mutant that HANGS would
# exit nonzero and be recorded as killed -- the suite would report a clean run
# while the thing it was measuring never finished. 125/126/127 are timeout's own
# failure-to-run statuses and the shell's not-executable / not-found; >=128 is
# death by signal.
#
# A checker that genuinely exits 124 for a non-timeout reason is now reported as
# ERROR rather than killed. That is the safe direction: a loud, investigable
# result instead of a quiet wrong one.
mutation_checker_status_is_infrastructure_error() {
    local status=$1
    [[ $status =~ ^(0|[1-9][0-9]*)$ ]] || return 0
    [ "$status" -eq 124 ] || [ "$status" -eq 125 ] || [ "$status" -eq 126 ] \
        || [ "$status" -eq 127 ] \
        || { [ "$status" -ge 128 ] && [ "$status" -le 255 ]; }
}

mutation_read_status() {
    local label=$1 path=$2
    local -a lines=()
    MUTATION_STATUS=
    MUTATION_SURVIVOR=
    if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -s "$path" ]; then
        printf 'ERROR: mutation result %s status is missing, empty, or not regular\n' \
            "$label" >&2
        return 1
    fi
    mapfile -t lines < "$path" || return 1
    case "${lines[0]-}" in
        killed|errored)
            [ "${#lines[@]}" -eq 1 ] || {
                printf 'ERROR: mutation result %s status has trailing data\n' "$label" >&2
                return 1
            }
            MUTATION_STATUS=${lines[0]}
            cmp -s "$path" <(printf '%s\n' "$MUTATION_STATUS") || {
                printf 'ERROR: mutation result %s status is not byte-canonical\n' \
                    "$label" >&2
                return 1
            }
            ;;
        survived)
            [ "${#lines[@]}" -eq 2 ] && [ -n "${lines[1]}" ] || {
                printf 'ERROR: mutation result %s survivor payload is malformed\n' "$label" >&2
                return 1
            }
            MUTATION_STATUS=survived
            MUTATION_SURVIVOR=${lines[1]}
            cmp -s "$path" <(printf 'survived\n%s\n' "$MUTATION_SURVIVOR") || {
                printf 'ERROR: mutation result %s status is not byte-canonical\n' \
                    "$label" >&2
                return 1
            }
            ;;
        *)
            printf 'ERROR: mutation result %s has an unrecognized status\n' "$label" >&2
            return 1
            ;;
    esac
}

mutation_validate_output() {
    local label=$1 path=$2 status=$3
    local -a lines=()
    if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -s "$path" ]; then
        printf 'ERROR: mutation result %s output is missing, empty, or not regular\n' \
            "$label" >&2
        return 1
    fi
    mapfile -t lines < "$path" || return 1
    if [ "${#lines[@]}" -ne 1 ] || [ -z "${lines[0]}" ] \
            || ! cmp -s "$path" <(printf '%s\n' "${lines[0]}"); then
        printf 'ERROR: mutation result %s output is not one canonical text line\n' \
            "$label" >&2
        return 1
    fi
    case "$status" in
        killed)   [[ ${lines[0]} == "[$label] killed   ("* ]] ;;
        survived) [[ ${lines[0]} == "[$label] SURVIVED ("* ]] ;;
        errored)  [[ ${lines[0]} == "[$label] ERROR  "* ]] ;;
        *) return 1 ;;
    esac || {
        printf 'ERROR: mutation result %s output disagrees with status %s\n' \
            "$label" "$status" >&2
        return 1
    }
}
