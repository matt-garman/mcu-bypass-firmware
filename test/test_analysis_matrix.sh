#!/usr/bin/env bash
# Exact fake-cppcheck contract for the complete declarative analysis matrix.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAKEFILE="$ROOT/Makefile"
work=$(mktemp -d "${TMPDIR:-${HOME:?HOME is required when TMPDIR is unset}}/test-analysis-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake_cppcheck="$work/cppcheck"
log="$work/argv.log"
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$work/avr-libc/avr" "$work/avr-gcc" \
	"$work/xt/include/avr" "$work/xc8" \
	"$work/dfp322/proc" "$work/dfp320/proc" "$work/dfp675/proc"
: > "$work/avr-libc/avr/io.h"
: > "$work/xt/include/avr/iotn202.h"
: > "$work/xc8/xc.h"
: > "$work/dfp322/proc/pic10f322.h"
: > "$work/dfp320/proc/pic10f320.h"
: > "$work/dfp675/proc/pic12f675.h"
: > "$log"

cat > "$fake_cppcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
	printf 'BEGIN\t%s\n' "${FAKE_ANALYSIS_CASE:?}"
	for arg in "$@"; do printf 'ARG\t%s\n' "$arg"; done
	printf 'END\t%s\n' "${FAKE_ANALYSIS_CASE:?}"
} >> "${FAKE_ANALYSIS_LOG:?}"
EOF
chmod 750 "$fake_cppcheck"

run_matrix() {
	local mode=$1 target=$2 output
	shift 2
	if ! output=$(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL VARIANTS
		FAKE_ANALYSIS_CASE="$mode:$target" FAKE_ANALYSIS_LOG="$log" \
			make --no-print-directory -C "$ROOT" "$target" \
			"CPPCHECK=$fake_cppcheck" \
			"AVR_LIBC_INCLUDE=$work/avr-libc" "AVR_GCC_INCLUDE=$work/avr-gcc" \
			macro_cd4053_simple=BROKEN_SIMPLE \
			macro_cd4053_with_mute=BROKEN_MUTE \
			macro_tq2_l2_5v_relay=BROKEN_RELAY \
			src_cd4053_simple=src/bypass_pure.c \
			src_cd4053_with_mute=src/bypass_pure.c \
			src_tq2_l2_5v_relay=src/bypass_pure.c \
			PIC10F320_SRC=src/bypass_pure.c \
			analysis_tuple=BROKEN_TUPLE analysis_tuple_source=src/bypass_pure.c \
			analysis_matrix_sources= run_cppcheck_matrix_sh=: run_misra_matrix_sh=: \
			ANALYSIS_SHARED_MODULAR_ROWS= ANALYSIS_CLASSIC_ROWS= \
			ANALYSIS_XT_ROWS= ANALYSIS_PIC10F322_ROWS= \
			ANALYSIS_PIC10F320_ROWS= ANALYSIS_PIC12F675_ROWS= "$@" 2>&1
	); then
		fail "$mode matrix target $target failed: $output"
	fi
	checks=$((checks + 1))
}

for mode in plain misra; do
	if [ "$mode" = plain ]; then suffix=cppcheck; else suffix=misra; fi
	run_matrix "$mode" "analyze-$suffix" "VARIANTS=cd4053_simple"
	run_matrix "$mode" "attiny202-analyze-$suffix" "XT_DFP=$work/xt"
	run_matrix "$mode" "pic10f322-analyze-$suffix" \
		"PIC_XC8_INCLUDE=$work/xc8" "PIC10F322_DFP_INCLUDE=$work/dfp322"
	run_matrix "$mode" "pic10f320-analyze-$suffix" \
		"PIC10F320_XC8_INCLUDE=$work/xc8" "PIC10F320_DFP_INCLUDE=$work/dfp320"
	run_matrix "$mode" "pic12f675-analyze-$suffix" \
		"PIC_XC8_INCLUDE=$work/xc8" "PIC12F675_DFP_INCLUDE=$work/dfp675"
done

per_variant_lanes=$(make -s --no-print-directory -C "$ROOT" \
	print-PIC10F320_PER_VARIANT_LANES 2>/dev/null) \
	|| fail "could not query PIC10F320 per-variant lanes"
[ "$per_variant_lanes" = pic10f320-test-gpsim ] \
	|| fail "PIC10F320 per-variant loop does not contain exactly gpsim: $per_variant_lanes"
checks=$((checks + 1))

supported_pic320=$(make -s --no-print-directory -C "$ROOT" \
	print-PIC10F320_VARIANTS_SUPPORTED 2>/dev/null) \
	|| fail "could not query PIC10F320 supported variants"
[ "$supported_pic320" = "cd4053_simple cd4053_with_mute tq2_l2_5v_relay" ] \
	|| fail "PIC10F320 supported analysis/gpsim matrix drifted: $supported_pic320"
checks=$((checks + 1))

routing_checks=$(python3 - "$MAKEFILE" <<'PY'
import pathlib
import re
import sys


text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
logical = re.sub(r"\\\n[ \t]*", " ", text)
matches = re.findall(r"^pic10f320-test:\s*([^\n]*)$", logical, re.MULTILINE)
if len(matches) != 1:
    raise SystemExit("expected one pic10f320-test rule, found {}".format(len(matches)))
prerequisites = matches[0].split()
if prerequisites.count("pic10f320-analyze") != 1:
    raise SystemExit("pic10f320-test must require pic10f320-analyze exactly once")
lines = text.splitlines()
start = next(
    (index for index, line in enumerate(lines) if line.startswith("pic10f320-test:")),
    None,
)
if start is None:
    raise SystemExit("pic10f320-test recipe not found")
body = []
for line in lines[start + 1:]:
    if line.startswith("\t"):
        body.append(line)
    elif body:
        break
recipe = "\n".join(body)
if recipe.count("for v in $(PIC10F320_VARIANTS_ALL); do") != 1:
    raise SystemExit("pic10f320-test does not iterate its guarded complete matrix")
dispatch = "PIC10F320_VARIANT=$$v $(PIC10F320_PER_VARIANT_LANES)"
if recipe.count(dispatch) != 1:
    raise SystemExit("pic10f320-test does not dispatch the per-variant gpsim lane")
print("3")
PY
) || fail "PIC10F320 aggregate analysis routing contract failed"
[ "$routing_checks" = 3 ] \
	|| fail "PIC10F320 aggregate routing returned $routing_checks checks instead of 3"
checks=$((checks + routing_checks))

matrix_checks=$(python3 - "$log" "$work" <<'PY'
import collections
import copy
import pathlib
import sys


log_path = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2])
shipping_sources = {
    "src/bypass_mcu_avr_classic.c",
    "src/bypass_mcu_avr_xt.c",
    "src/bypass_mcu_pic10f322.c",
    "src/bypass_mcu_pic10f320.c",
    "src/bypass_mcu_pic12f675.c",
    "src/bypass_pure.c",
    "src/bypass_output_cd4053_simple.c",
    "src/bypass_output_cd4053_with_mute.c",
    "src/bypass_output_tq2_l2_5v_relay.c",
}
modular_selectors = {
    "CD4053_SIMPLE",
    "CD4053_WITH_MUTE",
    "TQ2_L2_5V_RELAY",
}
pic320_selectors = {
    "OUTPUT_CD4053_SIMPLE",
    "OUTPUT_CD4053_WITH_MUTE",
    "OUTPUT_TQ2_RELAY",
}
all_selectors = modular_selectors | pic320_selectors

profile_markers = {
    "-D__AVR_ATtiny13A__": "classic_t13",
    "-D__AVR_ATtiny85__": "classic_x5",
    "-D__AVR_ATtiny202__": "avr_xt",
    "-D_10F322": "pic10f322",
    "-D_10F320": "pic10f320",
    "-D_12F675": "pic12f675",
}
profile_policy = {
    "classic_t13": ("avr8", "analyze-{}"),
    "classic_x5": ("avr8", "analyze-{}"),
    "avr_xt": ("avr8", "attiny202-analyze-{}"),
    "pic10f322": ("pic8-enhanced", "pic10f322-analyze-{}"),
    "pic10f320": ("pic8-enhanced", "pic10f320-analyze-{}"),
    "pic12f675": ("pic8", "pic12f675-analyze-{}"),
}
required_config = {
    "classic_t13": {
        "-D__AVR__", "-D__AVR_ATtiny13A__", "-DF_CPU=1200000UL",
        "-DBYPASS_MCU_AVR_CLASSIC", "-DBYPASS_CTX_CHECK",
        "-I" + str(work / "avr-libc"),
        "-I" + str(work / "avr-gcc"),
    },
    "classic_x5": {
        "-D__AVR__", "-D__AVR_ATtiny85__", "-DF_CPU=1000000UL",
        "-DBYPASS_MCU_AVR_CLASSIC", "-DBYPASS_CTX_CHECK",
        "-I" + str(work / "avr-libc"),
        "-I" + str(work / "avr-gcc"),
    },
    "avr_xt": {
        "-D__AVR__", "-D__AVR_XMEGA__", "-D__AVR_MEGA__",
        "-D__AVR_ATtiny202__", "-D__AVR_ARCH__=103",
        "-D__AVR_DEV_LIB_NAME__=tn202", "-DBYPASS_MCU_AVR_XT",
        "-DF_CPU=2000000UL", "-DBYPASS_CTX_CHECK",
        "-UBYPASS_MCU_PIC10F322", "-UBYPASS_MCU_AVR_CLASSIC", "-Isrc",
        "-I" + str(work / "avr-libc"), "-I" + str(work / "avr-gcc"),
        "-I" + str(work / "xt/include"),
    },
    "pic10f322": {
        "-D__XC8", "-D_10F322", "-D_XTAL_FREQ=2000000UL",
        "-DBYPASS_MCU_PIC10F322", "-U__AVR__", "-UBYPASS_MCU_AVR_CLASSIC",
        "-DBYPASS_CTX_CHECK", "-Isrc", "-I" + str(work / "dfp322"),
        "-I" + str(work / "dfp322/proc"), "-I" + str(work / "xc8"),
    },
    "pic10f320": {
        "-D__XC8", "-D_10F320", "-D_XTAL_FREQ=2000000UL",
        "-I" + str(work / "dfp320"), "-I" + str(work / "dfp320/proc"),
        "-I" + str(work / "xc8"),
    },
    "pic12f675": {
        "-D__XC8", "-D_12F675", "-D_XTAL_FREQ=4000000UL",
        "-DBYPASS_MCU_PIC12F675", "-U__AVR__", "-UBYPASS_MCU_AVR_CLASSIC",
        "-DBYPASS_CTX_CHECK", "-Isrc", "-I" + str(work / "dfp675"),
        "-I" + str(work / "dfp675/proc"), "-I" + str(work / "xc8"),
    },
}
language_markers = {"-D__AVR__", "-D__XC8"}
backend_markers = {
    "-DBYPASS_MCU_AVR_CLASSIC",
    "-DBYPASS_MCU_AVR_XT",
    "-DBYPASS_MCU_PIC10F322",
    "-DBYPASS_MCU_PIC12F675",
}
expected_backend = {
    "classic_t13": {"-DBYPASS_MCU_AVR_CLASSIC"},
    "classic_x5": {"-DBYPASS_MCU_AVR_CLASSIC"},
    "avr_xt": {"-DBYPASS_MCU_AVR_XT"},
    "pic10f322": {"-DBYPASS_MCU_PIC10F322"},
    "pic10f320": set(),
    "pic12f675": {"-DBYPASS_MCU_PIC12F675"},
}

shared_rows = [
    ("src/bypass_pure.c", "CD4053_SIMPLE"),
    ("src/bypass_output_cd4053_simple.c", "CD4053_SIMPLE"),
    ("src/bypass_output_cd4053_with_mute.c", "CD4053_WITH_MUTE"),
    ("src/bypass_output_tq2_l2_5v_relay.c", "TQ2_L2_5V_RELAY"),
]
profile_rows = {
    "classic_t13": [("src/bypass_mcu_avr_classic.c", "CD4053_SIMPLE")] + shared_rows,
    "classic_x5": [("src/bypass_mcu_avr_classic.c", "CD4053_SIMPLE")] + shared_rows,
    "avr_xt": [
        ("src/bypass_mcu_avr_xt.c", "CD4053_SIMPLE"),
        ("src/bypass_mcu_avr_xt.c", "TQ2_L2_5V_RELAY"),
    ] + shared_rows,
    "pic10f322": [("src/bypass_mcu_pic10f322.c", "CD4053_SIMPLE")] + shared_rows,
    "pic10f320": [
        ("src/bypass_mcu_pic10f320.c", "OUTPUT_CD4053_SIMPLE"),
        ("src/bypass_mcu_pic10f320.c", "OUTPUT_CD4053_WITH_MUTE"),
        ("src/bypass_mcu_pic10f320.c", "OUTPUT_TQ2_RELAY"),
    ],
    "pic12f675": [
        ("src/bypass_mcu_pic12f675.c", "CD4053_SIMPLE"),
        ("src/bypass_mcu_pic12f675.c", "TQ2_L2_5V_RELAY"),
    ] + shared_rows,
}


def parse_records():
    records = []
    current = None
    for raw in log_path.read_text(encoding="utf-8").splitlines():
        kind, separator, value = raw.partition("\t")
        if not separator:
            raise ValueError("malformed argv transcript line: {!r}".format(raw))
        if kind == "BEGIN":
            if current is not None:
                raise ValueError("nested argv record")
            current = {"case": value, "args": []}
        elif kind == "ARG":
            if current is None:
                raise ValueError("argument outside argv record")
            current["args"].append(value)
        elif kind == "END":
            if current is None or current["case"] != value:
                raise ValueError("mismatched argv record end")
            records.append(current)
            current = None
        else:
            raise ValueError("unknown argv transcript record: {}".format(kind))
    if current is not None:
        raise ValueError("unterminated argv record")
    return records


def exactly_one(values, what):
    if len(values) != 1:
        raise ValueError("expected exactly one {}, found {}".format(what, values))
    return values[0]


def validate(records):
    actual = collections.Counter()
    for record in records:
        mode, separator, target = record["case"].partition(":")
        if not separator or mode not in ("plain", "misra"):
            raise ValueError("bad analysis case {}".format(record["case"]))
        args = record["args"]
        profile = exactly_one(
            [profile_markers[arg] for arg in args if arg in profile_markers],
            "target profile",
        )
        source = exactly_one([arg for arg in args if arg in shipping_sources], "shipping source")
        selector_arg = exactly_one(
            [arg for arg in args if arg.startswith("-D") and arg[2:] in all_selectors],
            "output selector",
        )
        selector = selector_arg[2:]
        platform = exactly_one(
            [arg.removeprefix("--platform=") for arg in args if arg.startswith("--platform=")],
            "cppcheck platform",
        )
        standard = exactly_one(
            [arg.removeprefix("--std=") for arg in args if arg.startswith("--std=")],
            "analysis C standard",
        )
        expected_platform, target_pattern = profile_policy[profile]
        suffix = "cppcheck" if mode == "plain" else "misra"
        if target != target_pattern.format(suffix):
            raise ValueError("{} row ran through wrong target {}".format(profile, target))
        if platform != expected_platform:
            raise ValueError("{} used platform {}".format(profile, platform))
        if standard != "c11":
            raise ValueError("{} used analysis standard {}".format(profile, standard))
        missing_config = required_config[profile] - set(args)
        if missing_config:
            raise ValueError("{} lost target arguments {}".format(profile, missing_config))
        expected_language = {"-D__AVR__"} if profile.startswith(("classic", "avr_")) else {"-D__XC8"}
        if set(args) & language_markers != expected_language:
            raise ValueError("{} mixed target language markers".format(profile))
        if set(args) & backend_markers != expected_backend[profile]:
            raise ValueError("{} mixed backend selectors".format(profile))
        if profile == "pic10f320":
            if selector not in pic320_selectors or "-DBYPASS_CTX_CHECK" in args:
                raise ValueError("PIC10F320 row used modular selector/context policy")
        else:
            if selector not in modular_selectors or "-DBYPASS_CTX_CHECK" not in args:
                raise ValueError("modular row lost selector/context policy")
        templates = [arg for arg in args if arg.startswith("--template=")]
        suppression_lists = [arg for arg in args if arg.startswith("--suppressions-list=")]
        addons = [arg for arg in args if arg.startswith("--addon=")]
        if mode == "misra":
            exactly_one(templates, "MISRA diagnostic template")
            exactly_one(suppression_lists, "MISRA suppression list")
            exactly_one(addons, "MISRA addon")
        elif templates or suppression_lists or addons:
            raise ValueError("plain cppcheck row carried MISRA-only arguments")
        actual[(mode, profile, source, selector)] += 1

    expected = collections.Counter(
        (mode, profile, source, selector)
        for mode in ("plain", "misra")
        for profile, rows in profile_rows.items()
        for source, selector in rows
    )
    if actual != expected:
        missing = list((expected - actual).elements())
        extra = list((actual - expected).elements())
        raise ValueError("analysis matrix mismatch; missing={} extra={}".format(missing, extra))


records = parse_records()
validate(records)


def require_rejected(mutator, label):
    fixture = copy.deepcopy(records)
    mutator(fixture)
    try:
        validate(fixture)
    except ValueError:
        return
    raise ValueError("matrix validator accepted {}".format(label))


def replace_arg(rows, old, new):
    args = rows[0]["args"]
    args[args.index(old)] = new


require_rejected(lambda rows: rows.pop(), "a missing row")
require_rejected(lambda rows: rows.append(copy.deepcopy(rows[0])), "a duplicate row")
require_rejected(
    lambda rows: replace_arg(rows, "--platform=avr8", "--platform=pic8"),
    "a wrong platform",
)
require_rejected(
    lambda rows: replace_arg(rows, "--std=c11", "--std=c99"),
    "a wrong standard",
)
require_rejected(lambda rows: rows[0]["args"].append("-DOUTPUT_TQ2_RELAY"), "mixed selectors")
require_rejected(lambda rows: rows[0]["args"].append("src/bypass_pure.c"), "mixed sources")

if len(records) != 60:
    raise ValueError("expected 60 analyzer invocations, found {}".format(len(records)))
print("7")
PY
) || fail "analysis matrix argv contract failed"

[ "$matrix_checks" = 7 ] \
	|| fail "analysis matrix validator returned $matrix_checks checks instead of 7"
checks=$((checks + matrix_checks))

printf 'analysis matrix contract: %d checks, 0 failures (60 exact analyzer rows)\n' "$checks"
