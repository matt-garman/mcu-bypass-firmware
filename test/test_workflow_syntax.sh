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

# Validate the GitHub Actions workflow files locally.
#
# WHY THIS EXISTS
#   Nothing else in the repo ever PARSES .github/workflows/*.yml. The release
#   regressions grep release.yml for fixed strings, which succeeds happily on a
#   file GitHub cannot load at all, and ci-local.sh reproduces the jobs in bash
#   without ever reading ci.yml. So a workflow could be syntactically invalid --
#   the whole matrix refusing to start with "Invalid workflow file" -- while
#   every local gate reported green. That is
#   exactly what happened: an unquoted job `name:` containing ": " parsed as a
#   nested mapping and took the entire CI run down, after a full clean
#   ci-local.sh pass.
#
#   These checks are deliberately cheap and structural. They do not emulate the
#   Actions runner; they assert the file is loadable and internally consistent,
#   which is the class of failure a local run can otherwise never see.
#
# TOOL POLICY
#   Needs PyYAML. Absent, this SKIPS cleanly by default (so a bare checkout can
#   still run `make test`) but FAILS under STRICT_TOOLS=1 -- which is what
#   ci-local.sh sets, so the gate that exists to mirror CI can never quietly
#   validate nothing.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! command -v python3 >/dev/null 2>&1 \
   || ! python3 -c 'import yaml' >/dev/null 2>&1; then
	if [ -n "${STRICT_TOOLS:-}" ]; then
		printf 'ERROR: PyYAML absent and STRICT_TOOLS=1 (apt: python3-yaml)\n' >&2
		exit 1
	fi
	printf 'workflow syntax validation: SKIPPED (PyYAML absent; apt: python3-yaml)\n'
	exit 0
fi

ROOT="$ROOT" python3 - <<'PY'
import os
import re
import shlex
import subprocess
import sys

import yaml

root = os.environ["ROOT"]
wf_dir = os.path.join(root, ".github", "workflows")

# The workflows this repo is required to have. Listed explicitly rather than
# globbed: a glob turns a renamed or deleted workflow into "zero files, all
# valid", which is the same fail-open shape this test exists to close.
REQUIRED = ("ci.yml", "release.yml")

checks = 0
failures = []


def check(ok, msg):
    global checks
    checks += 1
    if not ok:
        failures.append(msg)
    return ok


class UniqueKeyLoader(yaml.SafeLoader):
    pass


# GitHub's workflow parser follows YAML 1.2 for booleans; PyYAML's SafeLoader
# follows YAML 1.1 and otherwise constructs an unquoted `on` as True. Normalize
# the resolver so quoted and unquoted spellings become the same mapping key and
# duplicate detection cannot be bypassed by alternating them.
UniqueKeyLoader.yaml_implicit_resolvers = {
    first: list(resolvers)
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
for first, resolvers in UniqueKeyLoader.yaml_implicit_resolvers.items():
    UniqueKeyLoader.yaml_implicit_resolvers[first] = [
        resolver for resolver in resolvers
        if resolver[0] != "tag:yaml.org,2002:bool"
    ]
UniqueKeyLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool",
    re.compile(r"^(?:true|false)$", re.IGNORECASE),
    list("tTfF"),
)


def construct_unique_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping", node.start_mark,
                "workflow merge keys are not supported", key_node.start_mark,
            )
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping", node.start_mark,
                "found an unhashable key", key_node.start_mark,
            ) from exc
        if duplicate:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping", node.start_mark,
                f"found duplicate key ({key!r})", key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_unique_mapping,
)


def bash_syntax_error(run):
    result = subprocess.run(
        ["bash", "-n"], input=run, capture_output=True, text=True, check=False,
    )
    if result.returncode == 0:
        return None
    return result.stderr.strip() or f"bash -n exited {result.returncode}"


def job_execution_shape_valid(job):
    return (
        isinstance(job, dict)
        and (("uses" in job) != ("steps" in job))
        and (("runs-on" in job) == ("steps" in job))
    )


def step_execution_shape_valid(step):
    return isinstance(step, dict) and (("uses" in step) != ("run" in step))


# Prove parser failure modes against in-memory inputs before trusting them with
# the real workflows. SafeLoader's default last-key-wins behavior and the old
# shell-token exception suppression both made malformed workflows green.
for duplicate_label, duplicate_yaml in (
    ("top-level", "name: first\nname: second\n"),
    ("nested", "jobs:\n  verify:\n    run: first\n    run: second\n"),
    ("quoted-on", "on: first\n\"on\": second\n"),
):
    try:
        yaml.load(duplicate_yaml, Loader=UniqueKeyLoader)
    except yaml.constructor.ConstructorError as exc:
        check(
            "found duplicate key" in str(exc),
            f"duplicate-{duplicate_label} YAML fixture failed for the wrong reason: {exc}",
        )
    else:
        check(False, f"duplicate-{duplicate_label} YAML fixture parsed clean")

try:
    yaml.load("base: &base {run: first}\njob:\n  <<: *base\n", Loader=UniqueKeyLoader)
except yaml.constructor.ConstructorError as exc:
    check(
        "merge keys are not supported" in str(exc),
        f"YAML merge-key fixture failed for the wrong reason: {exc}",
    )
else:
    check(False, "YAML merge-key fixture parsed clean")

check(
    bash_syntax_error('echo "unterminated') is not None,
    "unmatched-quote shell fixture passed the Bash syntax validator",
)
check(
    bash_syntax_error("if true; then\n  echo ok\n") is not None,
    "unterminated-if fixture passed the Bash syntax validator",
)
for invalid_job in (
    {"uses": "./reusable.yml", "steps": []},
    {"uses": "./reusable.yml", "runs-on": "ubuntu-24.04"},
):
    check(
        not job_execution_shape_valid(invalid_job),
        "malformed reusable-workflow job passed the execution-shape validator",
    )
check(
    not step_execution_shape_valid({"uses": "./action", "run": "true"}),
    "step with both uses and run passed the execution-shape validator",
)


docs = {}
checkout_steps = []
token_steps = []
pic_installer_steps = []
pic_verify_steps = []
pic_cache_steps = []
attiny_cache_steps = []
yasimavr_cache_steps = []
for name in REQUIRED:
    path = os.path.join(wf_dir, name)
    if not check(os.path.isfile(path), f"{name}: missing from .github/workflows"):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            docs[name] = yaml.load(fh, Loader=UniqueKeyLoader)
        check(True, "")
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        where = f" (line {mark.line + 1}, column {mark.column + 1})" if mark else ""
        check(False, f"{name}: does not parse as YAML{where}: {getattr(exc, 'problem', exc)}")

for name, doc in docs.items():
    if not check(isinstance(doc, dict), f"{name}: top level is not a mapping"):
        continue

    check("on" in doc, f"{name}: no trigger (`on:`) block")
    check("defaults" not in doc, f"{name}: workflow-level run defaults are unsupported")

    jobs = doc.get("jobs")
    if not check(isinstance(jobs, dict) and jobs, f"{name}: no jobs defined"):
        continue

    workflow_env = doc.get("env")
    check(
        not isinstance(workflow_env, dict) or "GH_TOKEN" not in workflow_env,
        f"{name}: GH_TOKEN is exposed at workflow scope",
    )

    for job_id, job in jobs.items():
        if not check(isinstance(job, dict), f"{name}: job '{job_id}' is not a mapping"):
            continue
        check(
            "runs-on" in job or "uses" in job,
            f"{name}: job '{job_id}' has neither runs-on nor uses",
        )

        job_env = job.get("env")
        check(
            not isinstance(job_env, dict) or "GH_TOKEN" not in job_env,
            f"{name}: job '{job_id}' exposes GH_TOKEN to every step",
        )
        check("defaults" not in job, f"{name}: job '{job_id}' run defaults are unsupported")

        job_action = job.get("uses")
        if "uses" in job:
            check(
                isinstance(job_action, str),
                f"{name}: job '{job_id}' has a non-string reusable-workflow reference",
            )
            if isinstance(job_action, str) and not job_action.startswith("."):
                check(
                    re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", job_action) is not None,
                    f"{name}: job '{job_id}' reusable workflow is not pinned "
                    f"to a full lowercase commit SHA: '{job_action}'",
                )

        has_steps = "steps" in job
        check(
            job_execution_shape_valid(job),
            f"{name}: job '{job_id}' has an invalid uses/steps/runs-on shape",
        )
        if has_steps:
            check(
                isinstance(job.get("runs-on"), str)
                and job["runs-on"].startswith("ubuntu-"),
                f"{name}: job '{job_id}' does not use the validator's Ubuntu/Bash substrate",
            )
            steps = job.get("steps")
            check(
                isinstance(steps, list) and steps,
                f"{name}: job '{job_id}' has no steps",
            )
            for idx, step in enumerate(steps or [], 1):
                if not isinstance(step, dict):
                    check(False, f"{name}: job '{job_id}' step {idx} is not a mapping")
                    continue
                check(
                    step_execution_shape_valid(step),
                    f"{name}: job '{job_id}' step {idx} must define exactly one of run or uses",
                )
                action = step.get("uses")
                if "uses" in step:
                    check(
                        isinstance(action, str),
                        f"{name}: job '{job_id}' step {idx} has a non-string action reference",
                    )
                if isinstance(action, str) and not action.startswith("."):
                    check(
                        re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action) is not None,
                        f"{name}: job '{job_id}' step {idx} action is not pinned "
                        "to a full lowercase commit SHA: "
                        f"'{action}'",
                    )
                    if action.startswith("actions/checkout@"):
                        checkout_steps.append((name, job_id, idx, step))
                    if action.startswith("actions/cache/"):
                        with_args = step.get("with")
                        key = with_args.get("key") if isinstance(with_args, dict) else None
                        check(
                            isinstance(key, str),
                            f"{name}: job '{job_id}' cache step {idx} has no string key",
                        )
                        if isinstance(key, str) and key.startswith("microchip-xc8-"):
                            pic_cache_steps.append((name, job_id, idx, key))
                        if isinstance(key, str) and key.startswith("attiny-dfp-"):
                            attiny_cache_steps.append((name, job_id, idx, key))
                        if isinstance(key, str) and key.startswith("yasimavr-venv-"):
                            yasimavr_cache_steps.append((name, job_id, idx, key))

                run = step.get("run")
                if "run" in step:
                    check(
                        isinstance(run, str),
                        f"{name}: job '{job_id}' step {idx} has a non-string run body",
                    )
                    if isinstance(run, str):
                        shell = step.get("shell")
                        shell_is_bash = shell is None or (
                            isinstance(shell, str) and shell.split()[:1] == ["bash"]
                        )
                        check(
                            shell_is_bash,
                            f"{name}: job '{job_id}' step {idx} uses an unsupported shell",
                        )
                        if shell_is_bash:
                            syntax_error = bash_syntax_error(run)
                            check(
                                syntax_error is None,
                                f"{name}: job '{job_id}' step {idx} run body is not valid Bash: "
                                f"{syntax_error}",
                            )
                if run == "scripts/install_pic_toolchain.sh":
                    pic_installer_steps.append((name, job_id, idx))
                if run == "scripts/verify_pic_toolchain_cache.sh":
                    pic_verify_steps.append((name, job_id, idx, "if" in step))

                env = step.get("env")
                if isinstance(env, dict) and "GH_TOKEN" in env:
                    token_steps.append((name, job_id, idx, step))

        # A `needs:` naming a job that does not exist is accepted by the YAML
        # parser and rejected by GitHub at dispatch time -- the same class of
        # late failure as a syntax error, and the exact drift a job rename
        # causes.
        needs = job.get("needs", [])
        if isinstance(needs, str):
            needs = [needs]
        for dep in needs:
            check(dep in jobs, f"{name}: job '{job_id}' needs undeclared job '{dep}'")
            check(dep != job_id, f"{name}: job '{job_id}' needs itself")

check(bool(checkout_steps), "workflows contain no actions/checkout steps")
for name, job_id, idx, step in checkout_steps:
    with_args = step.get("with")
    check(
        isinstance(with_args, dict) and with_args.get("persist-credentials") is False,
        f"{name}: job '{job_id}' checkout step {idx} persists Git credentials",
    )

for workflow_name in REQUIRED:
    count = sum(name == workflow_name for name, _, _ in pic_installer_steps)
    check(
        count == 1,
        f"{workflow_name}: shared PIC installer appears in {count} active steps, expected 1",
    )

# The XC8/DFP cache-integrity verify must run once per workflow and be
# UNCONDITIONAL: a restored cache bypasses the SHA-verified installer, so a
# verify gated on a cache miss (the exact case it exists to catch) would never
# check a restored tree.
for workflow_name in REQUIRED:
    matches = [s for s in pic_verify_steps if s[0] == workflow_name]
    check(
        len(matches) == 1,
        f"{workflow_name}: XC8 cache-integrity verify appears in "
        f"{len(matches)} active steps, expected 1",
    )
    for _, job_id, idx, has_if in matches:
        check(
            not has_if,
            f"{workflow_name}: job '{job_id}' verify step {idx} is conditional; "
            "it must run on every restore (hit or miss)",
        )

check(len(pic_cache_steps) == 4, f"found {len(pic_cache_steps)} PIC cache steps, expected 4")
for name, job_id, idx, key in pic_cache_steps:
    check(
        "hashFiles('scripts/install_pic_toolchain.sh')" in key,
        f"{name}: job '{job_id}' PIC cache step {idx} is not keyed by the installer pin",
    )

check(
    len(attiny_cache_steps) == 6,
    f"found {len(attiny_cache_steps)} ATtiny_DFP cache steps, expected 6",
)
for name, job_id, idx, key in attiny_cache_steps:
    check(
        "hashFiles('scripts/fetch_attiny_dfp.sh')" in key,
        f"{name}: job '{job_id}' ATtiny_DFP cache step {idx} is not keyed by its pins",
    )

check(
    len(yasimavr_cache_steps) == 6,
    f"found {len(yasimavr_cache_steps)} yasimavr cache steps, expected 6",
)
for name, job_id, idx, key in yasimavr_cache_steps:
    check(
        "'scripts/fetch_yasimavr.sh'" in key
        and "'scripts/yasimavr-build-requirements.txt'" in key
        and "'third_party/yasimavr/patches/**'" in key,
        f"{name}: job '{job_id}' yasimavr cache step {idx} omits a pinned input",
    )

check(len(token_steps) == 1, f"GH_TOKEN is exposed to {len(token_steps)} steps, expected 1")
if len(token_steps) == 1:
    name, job_id, idx, step = token_steps[0]
    token_env = step.get("env", {})
    check(
        name == "release.yml" and job_id == "release"
        and step.get("id") == "publish"
        and token_env.get("GH_TOKEN") == "${{ github.token }}",
        f"GH_TOKEN is exposed outside the release publication step: "
        f"{name} job '{job_id}' step {idx}",
    )

release_source = os.path.join(wf_dir, "release.yml")
if check(os.path.isfile(release_source), "release.yml: missing for token-scope check"):
    with open(release_source, encoding="utf-8") as fh:
        release_text = fh.read()
    check(
        release_text.count("${{ github.token }}") == 1,
        "release.yml must reference github.token exactly once",
    )


def logical_shell_commands(run):
    commands = []
    pending = ""
    for raw in run.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        pending = f"{pending} {line}".strip()
        if pending.endswith("\\"):
            pending = pending[:-1].rstrip()
            continue
        commands.append(pending)
        pending = ""
    if pending:
        commands.append(pending)
    return commands


def shell_tokens(run):
    parsed = []
    for command in logical_shell_commands(run):
        try:
            parsed.append(shlex.split(command, comments=True, posix=True))
        except ValueError:
            continue
    return parsed


release_doc = docs.get("release.yml")
release_jobs = release_doc.get("jobs") if isinstance(release_doc, dict) else None
release_job = release_jobs.get("release") if isinstance(release_jobs, dict) else None
release_steps = release_job.get("steps") if isinstance(release_job, dict) else None
if check(isinstance(release_steps, list), "release.yml: release job has no step list"):
    release_checkout_steps = [
        step for step in release_steps
        if isinstance(step, dict)
        and isinstance(step.get("uses"), str)
        and step["uses"].startswith("actions/checkout@")
    ]
    check(
        len(release_checkout_steps) == 1,
        "release.yml: release checkout step is not unique",
    )
    if len(release_checkout_steps) == 1:
        checkout_with = release_checkout_steps[0].get("with")
        check(
            isinstance(checkout_with, dict) and checkout_with.get("fetch-depth") == 2,
            "release.yml: release checkout does not fetch the qualified source parent",
        )

    locate_steps = [
        step for step in release_steps
        if isinstance(step, dict) and step.get("id") == "rel"
    ]
    repro_steps = [
        step for step in release_steps
        if isinstance(step, dict)
        and step.get("id") == "repro"
    ]
    publish_steps = [
        step for step in release_steps
        if isinstance(step, dict) and step.get("id") == "publish"
    ]
    check(len(locate_steps) == 1, "release.yml: committed-release locator is not unique")
    check(len(repro_steps) == 1, "release.yml: frozen-bundle producer step is not unique")
    check(len(publish_steps) == 1, "release.yml: publication step is not unique")
    if len(release_checkout_steps) == 1 and len(locate_steps) == 1 \
            and len(repro_steps) == 1 and len(publish_steps) == 1:
        check(
            release_steps.index(release_checkout_steps[0])
            < release_steps.index(locate_steps[0])
            < release_steps.index(repro_steps[0])
            < release_steps.index(publish_steps[0]),
            "release.yml: checkout/verification/freeze/publication step order is invalid",
        )

    if len(locate_steps) == 1:
        locate = locate_steps[0]
        locate_env = locate.get("env")
        locate_run = locate.get("run")
        check(
            isinstance(locate_env, dict)
            and locate_env.get("RELEASE_TAG") == "${{ github.ref_name }}"
            and locate_env.get("RELEASE_OBJECT") == "${{ github.sha }}",
            "release.yml: release tag/object are not routed through the locator environment",
        )
        check(isinstance(locate_run, str), "release.yml: committed-release locator has no shell body")
        if isinstance(locate_run, str):
            commands = shell_tokens(locate_run)
            signature_command = [
                "scripts/verify-release-signature.sh", "detached",
                "$dir/SHA256SUMS.asc", "$dir/SHA256SUMS",
            ]
            qualification_command = [
                "scripts/verify-release-qualification.sh", "$dir", "$tag",
            ]
            history_command = [
                "scripts/verify-release-history.sh", "$dir", "$tag", "$RELEASE_OBJECT",
            ]
            signature_indices = [
                i for i, command in enumerate(commands) if command == signature_command
            ]
            qualification_indices = [
                i for i, command in enumerate(commands) if command == qualification_command
            ]
            history_indices = [
                i for i, command in enumerate(commands) if command == history_command
            ]
            output_indices = [
                i for i, command in enumerate(commands) if "$GITHUB_OUTPUT" in command
            ]
            check(
                len(signature_indices) == 1 and len(qualification_indices) == 1
                and len(history_indices) == 1 and bool(output_indices),
                "release.yml: committed release verification command inventory is not exact",
            )
            if signature_indices and qualification_indices and history_indices and output_indices:
                check(
                    signature_indices[0] < qualification_indices[0]
                    < history_indices[0] < output_indices[0],
                    "release.yml: committed release is exposed before all verification completes",
                )
            check(
                commands[:1] == [["set", "-euo", "pipefail"]]
                and "${{" not in locate_run and "|| true" not in locate_run
                and "if" not in locate
                and locate.get("continue-on-error", False) is False,
                "release.yml: committed-release verification is not fail-closed",
            )

    if len(repro_steps) == 1:
        repro = repro_steps[0]
        repro_run = repro.get("run")
        check(isinstance(repro_run, str), "release.yml: frozen-bundle producer has no shell body")
        if isinstance(repro_run, str):
            commands = shell_tokens(repro_run)
            private_dir_command = [
                "sudo", "install", "-d", "-o", "root", "-g", "root", "-m",
                "0700", "--", "$frozen_root", "$publish",
            ]
            asset_install_command = [
                "sudo", "install", "-o", "root", "-g", "root", "-m", "0444",
                "--", "$publish_stage/$asset", "$publish/$asset",
            ]
            # The provenance files are no longer named here: they come from
            # Makefile RELEASE_PROVENANCE_FILES, so the checksum list and the
            # published set cannot drift apart. What stays pinned is that the
            # checksum list and its detached signature are added exactly once.
            metadata_command = [
                "expected_assets+=(SHA256SUMS", "SHA256SUMS.asc)",
            ]
            provenance_command = [
                "expected_assets+=(${release_provenance_names[@]})",
            ]
            snapshot_command = [
                "cp", "-p", "--", "$dir/*.hex", "$dir/SHA256SUMS",
                "$dir/SHA256SUMS.asc", "$publish_stage/",
            ]
            inventory_mode_command = [
                "sudo", "chmod", "0444", "--", "$inventory",
            ]
            harden_command = [
                "sudo", "chmod", "0555", "--", "$publish", "$frozen_root",
            ]
            initial_verify_command = [
                "python3", "scripts/verify_release_publication.py", "verify",
                "$publish", "$inventory", "$inventory_sha256",
            ]
            private_dir_indices = [
                i for i, command in enumerate(commands) if command == private_dir_command
            ]
            asset_install_indices = [
                i for i, command in enumerate(commands) if command == asset_install_command
            ]
            metadata_indices = [
                i for i, command in enumerate(commands) if command == metadata_command
            ]
            provenance_indices = [
                i for i, command in enumerate(commands) if command == provenance_command
            ]
            snapshot_indices = [
                i for i, command in enumerate(commands) if command == snapshot_command
            ]
            record_indices = [
                i for i, command in enumerate(commands)
                if command == [
                    "inventory_sha256=$(sudo", "python3",
                    "scripts/verify_release_publication.py", "record", "$publish",
                    "$inventory", "${expected_assets[@]})",
                ]
            ]
            inventory_mode_indices = [
                i for i, command in enumerate(commands) if command == inventory_mode_command
            ]
            harden_indices = [
                i for i, command in enumerate(commands) if command == harden_command
            ]
            initial_verify_indices = [
                i for i, command in enumerate(commands) if command == initial_verify_command
            ]
            output_indices = [
                i for i, command in enumerate(commands) if command == ["echo", "inventory=$inventory"]
            ]
            check(
                commands[:1] == [["set", "-euo", "pipefail"]]
                and not any(command[:2] in (["set", "+e"], ["set", "+u"])
                            or command == ["set", "+o", "pipefail"] for command in commands),
                "release.yml: frozen-bundle producer does not retain strict shell mode",
            )
            check(
                len(private_dir_indices) == 1 and len(asset_install_indices) == 1
                and len(metadata_indices) == 1 and len(provenance_indices) == 1
                and len(snapshot_indices) == 1
                and len(record_indices) == 1 and len(inventory_mode_indices) == 1
                and len(harden_indices) == 1
                and len(initial_verify_indices) == 1 and len(output_indices) == 1,
                "release.yml: active root-owned freeze commands are not exact",
            )
            if metadata_indices and snapshot_indices and private_dir_indices \
                    and asset_install_indices and record_indices \
                    and inventory_mode_indices and harden_indices \
                    and initial_verify_indices and output_indices:
                check(
                    metadata_indices[0] < snapshot_indices[0] < private_dir_indices[0]
                    < asset_install_indices[0] < record_indices[0]
                    < inventory_mode_indices[0] < harden_indices[0]
                    < initial_verify_indices[0] < output_indices[0],
                    "release.yml: root-owned publication inventory is not hardened and verified before outputs",
                )
            check(
                ["frozen_root=/opt/mcu-bypass-publication"] in commands
                and ["echo", "inventory_sha256=$inventory_sha256"] in commands,
                "release.yml: frozen-bundle producer omits the inventory digest output",
            )
            check(
                "if" not in repro
                and repro.get("continue-on-error", False) is False
                and "|| true" not in repro_run,
                "release.yml: frozen-bundle producer can be skipped or ignored",
            )

    if len(publish_steps) == 1:
        publish = publish_steps[0]
        publish_env = publish.get("env")
        publish_run = publish.get("run")
        check(isinstance(publish_env, dict), "release.yml: publication step has no environment")
        if isinstance(publish_env, dict):
            check(
                publish_env.get("RELEASE_INVENTORY") == "${{ steps.repro.outputs.inventory }}",
                "release.yml: publication inventory path is not routed through step output/env",
            )
            check(
                publish_env.get("RELEASE_INVENTORY_SHA256")
                == "${{ steps.repro.outputs.inventory_sha256 }}",
                "release.yml: publication inventory digest is not routed through step output/env",
            )
            check(
                publish_env.get("RELEASE_HELPER_ASSETS")
                == "${{ steps.repro.outputs.helper_assets }}",
                "release.yml: helper assets are not routed through frozen-bundle step output/env",
            )
        check(isinstance(publish_run, str), "release.yml: publication step has no shell body")
        if isinstance(publish_run, str):
            commands = shell_tokens(publish_run)
            tag_command = [
                "scripts/verify-release-tag-target.sh", "origin", "$tag",
                "$VERIFIED_RELEASE_COMMIT",
            ]
            inventory_command = [
                "python3", "scripts/verify_release_publication.py", "verify", "$dir",
                "$RELEASE_INVENTORY", "$RELEASE_INVENTORY_SHA256",
            ]
            signature_command = [
                "scripts/verify-release-signature.sh", "detached",
                "$dir/SHA256SUMS.asc", "$dir/SHA256SUMS",
            ]
            # The strict checksum command carries its own ::error:: handler: the
            # tool is third-party and its failure wording is not stable (coreutils
            # 9.x dropped the "SHA256" token), so the workflow emits a
            # project-owned annotation that the provenance test can assert on.
            # shlex glues the trailing ";" onto the preceding quoted token.
            checksum_command = [
                "(cd", "$dir", "&&", "sha256sum", "--check", "--strict", "--",
                "SHA256SUMS)", "||", "{", "echo",
                "::error::strict image checksum verification failed;",
                "exit", "1;", "}",
            ]
            tag_indices = [i for i, command in enumerate(commands) if command == tag_command]
            inventory_indices = [
                i for i, command in enumerate(commands) if command == inventory_command
            ]
            signature_indices = [
                i for i, command in enumerate(commands) if command == signature_command
            ]
            checksum_indices = [
                i for i, command in enumerate(commands) if command == checksum_command
            ]
            publish_indices = [
                i for i, command in enumerate(commands)
                if command == [
                    "gh", "release", "create", "$tag", "--title", "Firmware $tag",
                    "--notes-file", "$notes", "--verify-tag",
                    "${prerelease_flag[@]}", "${assets[@]}",
                ]
            ]
            check(
                len(tag_indices) == 1 and len(inventory_indices) == 2
                and len(signature_indices) == 1
                and len(checksum_indices) == 1 and len(publish_indices) == 1,
                "release.yml: active final publication command inventory is not exact",
            )
            if tag_indices and len(inventory_indices) == 2 \
                    and signature_indices and checksum_indices and publish_indices:
                check(
                    tag_indices[0] < inventory_indices[0]
                    < signature_indices[0] < checksum_indices[0] < inventory_indices[1]
                    and publish_indices[0] == inventory_indices[1] + 1,
                    "release.yml: active final checks do not dominate immediate gh publication",
                )
            check(
                commands[:1] == [["set", "-euo", "pipefail"]]
                and not any(command[:2] in (["set", "+e"], ["set", "+u"])
                            or command == ["set", "+o", "pipefail"] for command in commands)
                and "|| true" not in publish_run,
                "release.yml: publication shell does not retain strict fail-closed mode",
            )
            check(
                "if" not in publish
                and publish.get("continue-on-error", False) is False,
                "release.yml: publication step may be skipped or continue after verification failure",
            )

            # --- publication kind -------------------------------------------
            # A suffixed tag (v1.0.0-rc.1) must publish as a GitHub prerelease
            # so a candidate cannot take latest-release selection away from the
            # newest stable version; a bare vX.Y.Z must not. The workflow
            # decides that with two regex branches over $tag, which makes this
            # ANOTHER copy of the project's version grammar -- so do not just
            # look for the flag: extract both branch patterns and require that
            # together they accept exactly what scripts/make-release.sh accepts,
            # and that they split that grammar stable-vs-suffixed.
            flag_init = ["prerelease_flag=()"]
            flag_set = ["prerelease_flag=(", "--prerelease", ")"]
            init_indices = [i for i, command in enumerate(commands) if command == flag_init]
            set_indices = [i for i, command in enumerate(commands) if command == flag_set]
            check(
                len(init_indices) == 1 and len(set_indices) == 1
                and init_indices[0] < set_indices[0]
                and bool(publish_indices) and set_indices[0] < publish_indices[0],
                "release.yml: publication does not build one prerelease flag before publishing",
            )

            # The suffixed branch must set the flag, and the fall-through must
            # abort -- not silently publish an unrecognized shape as either kind.
            publish_lines = [line.strip() for line in publish_run.split("\n")]
            elif_lines = [
                i for i, line in enumerate(publish_lines)
                if line.startswith('elif [[ "$tag" =~ ')
            ]
            fail_closed_tail = [
                "prerelease_flag=( --prerelease )",
                "else",
                "echo \"::error::tag '$tag' is not vX.Y.Z (optionally -suffix)\"",
                "exit 1",
                "fi",
            ]
            check(
                len(elif_lines) == 1
                and publish_lines[elif_lines[0] + 1:elif_lines[0] + 6] == fail_closed_tail,
                "release.yml: unrecognized tag shapes do not fail closed before publication",
            )

            branch_patterns = re.findall(
                r'^\s*(?:if|elif) \[\[ "\$tag" =~ (\S+) \]\]; then$',
                publish_run,
                re.M,
            )
            NEVER = r"(?!)"
            stable_pattern, suffixed_pattern = (
                branch_patterns if len(branch_patterns) == 2 else (NEVER, NEVER)
            )
            canonical_pattern = NEVER
            try:
                with open(os.path.join(root, "scripts", "make-release.sh"), encoding="utf-8") as fh:
                    canonical_match = re.search(r'\[\[ "\$VERSION" =~ (\S+) \]\]', fh.read())
                if canonical_match:
                    canonical_pattern = canonical_match.group(1)
            except OSError:
                pass
            check(
                canonical_pattern != NEVER and len(branch_patterns) == 2,
                "release.yml: publication-kind branches or the producer's version "
                "grammar could not be extracted for comparison",
            )

            # Stable, prerelease, and malformed shapes, including the ones the
            # `on:` tag globs admit but the grammar does not (`v1.0.0-`).
            TAG_CASES = (
                ("v0.9.10", "stable"),
                ("v1.0.0", "stable"),
                ("v10.20.30", "stable"),
                ("v1.0.0-rc.1", "prerelease"),
                ("v1.0.0-rc1", "prerelease"),
                ("v1.0.0-rc-1", "prerelease"),
                ("v1.0.0-alpha.1.2", "prerelease"),
                ("v1.0.0-", "rejected"),
                ("v1.0.0-rc.", "rejected"),
                ("v1.0.0-rc..1", "rejected"),
                ("v1.0.0--rc", "rejected"),
                ("v1.0.0+build", "rejected"),
                ("v1.0.0.rc1", "rejected"),
                ("v1.0", "rejected"),
                ("v1.0.0.0", "rejected"),
                ("1.0.0", "rejected"),
                ("v1.0.0 rc1", "rejected"),
                ("", "rejected"),
            )
            overlapping = []
            disagreeing = []
            misclassified = []
            for tag_case, kind in TAG_CASES:
                stable_ok = re.fullmatch(stable_pattern, tag_case) is not None
                suffixed_ok = re.fullmatch(suffixed_pattern, tag_case) is not None
                canonical_ok = re.fullmatch(canonical_pattern, tag_case) is not None
                if stable_ok and suffixed_ok:
                    overlapping.append(tag_case)
                if (stable_ok or suffixed_ok) != canonical_ok:
                    disagreeing.append(tag_case)
                expected = {"stable": (True, False), "prerelease": (False, True)}.get(
                    kind, (False, False))
                if (stable_ok, suffixed_ok) != expected:
                    misclassified.append(f"{tag_case or '(empty)'} != {kind}")
            check(
                not overlapping,
                "release.yml: a tag matches both publication-kind branches: "
                + ", ".join(overlapping),
            )
            check(
                not disagreeing,
                "release.yml: publication-kind branches disagree with the "
                "scripts/make-release.sh version grammar on: " + ", ".join(disagreeing),
            )
            check(
                not misclassified,
                "release.yml: publication kind is wrong for: " + ", ".join(misclassified),
            )
def apt_packages(step):
    run = step.get("run") if isinstance(step, dict) else None
    packages = set()
    if not isinstance(run, str):
        return packages
    for tokens in shell_tokens(run):
        if tokens[:1] == ["sudo"]:
            tokens = tokens[1:]
        if tokens[:2] != ["apt-get", "install"]:
            continue
        try:
            yes = tokens.index("-y", 2)
        except ValueError:
            continue
        for token in tokens[yes + 1:]:
            if token in {"&&", "||", ";"}:
                break
            if not token.startswith("-"):
                packages.add(token)
    return packages


def run_step_asserts(step, requirement):
    run = step.get("run") if isinstance(step, dict) else None
    if not isinstance(run, str):
        return False
    for tokens in shell_tokens(run):
        if requirement == "PyYAML":
            if tokens[:3] == ["python3", "-c", "import yaml"]:
                return True
        elif tokens[:3] == ["command", "-v", requirement]:
            return True
    return False


def ci_goal_recipe(goal):
    """Return the recipe lines of a Makefile goal, without their leading tabs.

    The fixed policy a CI job runs under -- STRICT_TOOLS, MUTATION_ALLOW_SKIP --
    used to sit in the workflow step, where this file could read it directly.
    It now sits in the goal the step invokes, which is the entire point of the
    move: policy is a decision about how the project is verified, so it belongs
    with the project. Asserting it therefore means reading the recipe rather
    than the workflow, and asserting NOTHING would silently retire every policy
    check the workflow used to carry.
    """
    with open(os.path.join(root, "Makefile"), encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    recipe = []
    collecting = False
    for line in lines:
        if line.startswith(goal + ":"):
            collecting = True
            continue
        if collecting:
            if line.startswith("\t"):
                recipe.append(line[1:])
                continue
            if not line.strip():
                continue
            break
    return recipe


def prior_steps(workflow_name, job_id, first_use, description):
    doc = docs.get(workflow_name)
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    job = jobs.get(job_id) if isinstance(jobs, dict) else None
    steps = job.get("steps") if isinstance(job, dict) else None
    if not check(isinstance(steps, list), f"{workflow_name}: job '{job_id}' has no step list"):
        return []
    matches = []
    for idx, step in enumerate(steps):
        run = step.get("run") if isinstance(step, dict) else None
        if isinstance(run, str) and any(first_use(tokens) for tokens in shell_tokens(run)):
            matches.append(idx)
    if not check(
        bool(matches),
        f"{workflow_name}: job '{job_id}' has no {description} invocation",
    ):
        return []
    return steps[:min(matches)]


# Strict host suites consume Git history, GnuPG fixtures, and PyYAML. Hosted
# runners happen to carry some of them, but the workflow contract must install
# and assert them before the first make test/stress invocation.
for job_id, gate_name in (
    ("verify", "ci-verify"),
    ("stress", "ci-stress"),
):
    before = prior_steps(
        "ci.yml",
        job_id,
        lambda tokens, target=gate_name: tokens[:2] == ["make", target],
        "strict suite",
    )
    for package in ("git", "gnupg", "python3-yaml"):
        check(
            any(package in apt_packages(step) for step in before),
            f"ci.yml: job '{job_id}' does not install {package} before its strict suite",
        )
    for command in ("git", "gpg", "PyYAML"):
        check(
            any(run_step_asserts(step, command) for step in before),
            f"ci.yml: job '{job_id}' does not assert {command} before its strict suite",
        )

# Release signature/history/qualification verification occurs near the top of
# the job. Its small prerequisite install must precede that first use rather
# than relying on the larger compiler installation later in the workflow.
before_release_verify = prior_steps(
    "release.yml",
    "release",
    lambda tokens: bool(tokens) and re.fullmatch(
        r"scripts/verify-release-(?:signature|qualification|history)\.sh", tokens[0]
    ) is not None,
    "release signature/history/qualification verifier",
)
for package in ("make", "git", "gnupg", "python3", "python3-yaml"):
    check(
        any(package in apt_packages(step) for step in before_release_verify),
        f"release.yml: release verification does not install {package} before first use",
    )
for command in ("make", "git", "gpg", "PyYAML"):
    check(
        any(run_step_asserts(step, command) for step in before_release_verify),
        f"release.yml: release verification does not assert {command} before first use",
    )

# --- the local mirror EXECUTES the inventory ---------------------------------
# ci-local.sh used to carry a prose CI-JOB MAPPING header, and this gate checked
# that its entries named the same jobs ci.yml declares. That proved someone had
# typed each job's name into a comment; it never proved anything ran. The
# Makefile now declares CI_LOCAL_SEQUENCE (the goals the script invokes, in
# order) and CI_LOCAL_FOLDED (the goals one local `make test-long` covers),
# refuses to PARSE unless those two partition CI_GOALS, and the script refuses
# to start unless every sequenced goal has a handler. The checks further down
# close the two links that structure cannot carry on its own: that CI_GOALS is
# exactly the set ci.yml invokes, and that the folded claim is true of Make's
# graph. Only the file itself is needed here; the later PIC-routing and
# resource-pin checks read these lines.
ci_local = os.path.join(root, "scripts", "ci-local.sh")
ci_local_present = check(os.path.isfile(ci_local), "scripts/ci-local.sh: missing")
if ci_local_present:
    with open(ci_local, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

# --- pin the complete PIC CI contract independently of ci-local.sh ------------
# Set equality is not enough here: both files could lose one part together, and
# sets erase duplicates. These are five Make processes containing six required
# aggregates; PIC12F675's two goals deliberately share one retained matrix.
RESOURCE_POLICY = {
    "XT_STATIC_RAM_LIMIT": "16",
    "XT_STACK_MAX_FRAME": "32",
    "PIC12F675_DATA_LIMIT": "48",
}
CI_RESOURCE_ENV = {
    f"CI_{name}": value for name, value in RESOURCE_POLICY.items()
}
RELEASE_RESOURCE_ENV = {
    f"RELEASE_{name}": value for name, value in RESOURCE_POLICY.items()
}
CI_RESOURCE_REFS = {
    name: f"$CI_{name}" for name in RESOURCE_POLICY
}
RELEASE_RESOURCE_REFS = {
    name: f"$RELEASE_{name}" for name in RESOURCE_POLICY
}


def release_resource_routes(refs):
    """Which release.yml commands carry which resource-policy pins.

    Keyed on the GOALS the workflow now invokes. The consumers those goals
    reach -- attiny202, pic12f675, test-long, attiny202-test and the rest -- are
    checked inside each recipe by RELEASE_GOAL_RESOURCE_ROUTES below, so the
    routing is asserted end to end rather than only at whichever end happens to
    be visible.
    """
    static = refs["XT_STATIC_RAM_LIMIT"]
    stack = refs["XT_STACK_MAX_FRAME"]
    data = refs["PIC12F675_DATA_LIMIT"]
    return {
        "release-rebuild": {
            "XT_STATIC_RAM_LIMIT": static,
            "PIC12F675_DATA_LIMIT": data,
        },
        "release-test-long": {
            "XT_STATIC_RAM_LIMIT": static,
            "PIC12F675_DATA_LIMIT": data,
        },
        "release-attiny202": {
            "XT_STATIC_RAM_LIMIT": static,
            "XT_STACK_MAX_FRAME": stack,
        },
        "ci-pic": {"PIC12F675_DATA_LIMIT": data},
    }


def make_release_resource_routes(refs):
    """Which scripts/make-release.sh commands carry which resource-policy pins.

    This is the map release.yml used before its steps invoked goals: the local
    pipeline still names each consumer directly, so the expectation stays
    consumer-keyed. Keeping the two apart is the point -- they are different
    callers, and folding them back together would make one of the two vacuous.
    """
    static = refs["XT_STATIC_RAM_LIMIT"]
    stack = refs["XT_STACK_MAX_FRAME"]
    data = refs["PIC12F675_DATA_LIMIT"]
    return {
        "attiny202": {"XT_STATIC_RAM_LIMIT": static},
        "pic12f675": {"PIC12F675_DATA_LIMIT": data},
        "test-long": {
            "XT_STATIC_RAM_LIMIT": static,
            "PIC12F675_DATA_LIMIT": data,
        },
        "attiny202-test": {
            "XT_STATIC_RAM_LIMIT": static,
            "XT_STACK_MAX_FRAME": stack,
        },
        "attiny202-test-target": {"XT_STATIC_RAM_LIMIT": static},
        "pic12f675-test": {"PIC12F675_DATA_LIMIT": data},
    }


CI_RESOURCE_ROUTES = {
    # The workflow hands the data limit to the goal; ci-pic's own recipe is
    # separately checked (CI_GOAL_RESOURCE_ROUTES) to route it to the one
    # PIC12F675 command and nowhere else.
    "ci-pic": {
        "PIC12F675_DATA_LIMIT": CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    },
    "ci-mutation": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "PIC12F675_DATA_LIMIT": CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    },
    "ci-attiny202-build": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "XT_STACK_MAX_FRAME": CI_RESOURCE_REFS["XT_STACK_MAX_FRAME"],
    },
    "ci-attiny202-target": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
    },
}
RELEASE_RESOURCE_ROUTES = release_resource_routes(RELEASE_RESOURCE_REFS)
# scripts/make-release.sh is NOT a workflow: it drives the local release
# pipeline and invokes the gate goals directly, so its routing is checked
# against the consumers themselves rather than against workflow goals.
MAKE_RELEASE_RESOURCE_ROUTES = make_release_resource_routes(RELEASE_RESOURCE_REFS)
# Inside a CI goal's recipe the same routing question is asked of $(VAR)
# forwards rather than of shell references.
# Keyed by CI goal, because each recipe is its own surface: asking ci-pic's
# recipe to route the mutation limits, or the reverse, would fail on a goal
# that correctly does not run that consumer.
CI_GOAL_RESOURCE_ROUTES = {
    "ci-pic": {
        "pic12f675-test": {"PIC12F675_DATA_LIMIT": "$(PIC12F675_DATA_LIMIT)"},
    },
    "ci-mutation": {
        "test-mutation": {
            "XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)",
            "PIC12F675_DATA_LIMIT": "$(PIC12F675_DATA_LIMIT)",
        },
    },
    "ci-attiny202-build": {
        "attiny202-test": {
            "XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)",
            "XT_STACK_MAX_FRAME": "$(XT_STACK_MAX_FRAME)",
        },
    },
    "ci-attiny202-target": {
        "attiny202-test-target": {"XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)"},
        "attiny202-soak": {"XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)"},
    },
    "release-rebuild": {
        "attiny202": {"XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)"},
        "pic12f675": {"PIC12F675_DATA_LIMIT": "$(PIC12F675_DATA_LIMIT)"},
    },
    "release-test-long": {
        "test-long": {
            "XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)",
            "PIC12F675_DATA_LIMIT": "$(PIC12F675_DATA_LIMIT)",
        },
    },
    "release-attiny202": {
        "attiny202-test": {
            "XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)",
            "XT_STACK_MAX_FRAME": "$(XT_STACK_MAX_FRAME)",
        },
        "attiny202-test-target": {"XT_STATIC_RAM_LIMIT": "$(XT_STATIC_RAM_LIMIT)"},
    },
}

for workflow_name, expected in (
        ("ci.yml", CI_RESOURCE_ENV),
        ("release.yml", RELEASE_RESOURCE_ENV)):
    doc = docs.get(workflow_name)
    env = doc.get("env") if isinstance(doc, dict) else None
    actual = {
        name: str(env.get(name)) if isinstance(env, dict) and name in env else None
        for name in expected
    }
    check(
        actual == expected,
        f"{workflow_name}: resource-policy pins are {actual!r}, expected {expected!r}",
    )

# The five-process PIC boundary, stated once. Only the VALUES differ by
# surface: a hosted workflow pins the installer's real paths, ci-pic's recipe
# forwards whatever its caller pinned, and release.yml pins the same paths CI
# does. Parameterising keeps one description of the boundary rather than three
# that could drift apart while each still passed its own check.
def pic_commands(refs):
    cc, dfp = refs["PIC_CC"], refs["PIC_DFP"]
    cc320, dfp320 = refs["PIC10F320_CC"], refs["PIC10F320_DFP"]
    return (
        (("pic10f322-test",),
         {"STRICT_TOOLS": "1", "PIC_CC": cc, "PIC_DFP": dfp}),
        (("pic10f322-test-target-variants",),
         {"STRICT_TOOLS": "1", "PIC_CC": cc, "PIC_DFP": dfp}),
        (("pic10f320-test",),
         {"STRICT_TOOLS": "1", "PIC10F320_CC": cc320, "PIC10F320_DFP": dfp320}),
        (("pic10f320-test-target-variants",),
         {"STRICT_TOOLS": "1", "PIC10F320_CC": cc320, "PIC10F320_DFP": dfp320}),
        (("pic12f675-test", "pic12f675-test-target-variants"),
         {"STRICT_TOOLS": "1", "PIC_CC": cc, "PIC_DFP": dfp}),
    )


XC8_PIC_REFS = {
    "PIC_CC": "${XC8_DIR}/bin/xc8-cc",
    "PIC_DFP": "${XC8_DFP_ROOT}/xc8",
    "PIC10F320_CC": "${XC8_DIR}/bin/xc8-cc",
    "PIC10F320_DFP": "${XC8_DFP_ROOT}/xc8",
}
# Inside the recipe the pins are forwarded, not spelled: $(call ci_pin,...)
# has already refused anything the caller did not supply.
MAKE_PIC_REFS = {name: f"$({name})" for name in XC8_PIC_REFS}
# scripts/ci-local.sh resolves each path once in its preflight -- from the
# environment, else the Makefile default -- and hands that same value to the
# goal it asserted the toolchain for.
CI_LOCAL_PIC_REFS = {name: f"$PIN_{name}" for name in XC8_PIC_REFS}

# The goal NAMES are the same whichever refs are substituted, so take them from
# the Make-level form -- the one ci-pic's recipe is checked against. There is no
# longer a workflow-level PIC command list: both workflows invoke ci-pic, and
# the boundary is asserted once, against its recipe.
PIC_GOALS = tuple(goal for goals, _ in pic_commands(MAKE_PIC_REFS) for goal in goals)


def make_command(tokens):
    if tokens[:1] != ["make"]:
        return None
    goals = []
    assignments = {}
    duplicate_assignment = False
    for token in tokens[1:]:
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", token)
        if match:
            if match.group(1) in assignments:
                duplicate_assignment = True
            assignments[match.group(1)] = match.group(2)
        else:
            goals.append(token)
    return tuple(goals), assignments, duplicate_assignment


def ci_goal_commands(goal):
    """Parse the $(MAKE) invocations inside a CI goal's recipe.

    Each recipe line's sub-make prefix is rewritten to a literal command word,
    so the same parser that reads workflow steps reads the recipe. That
    equivalence is the point: once a job invokes a goal, the recipe is what
    runs, and it must be held to the same canonical shape the workflow step
    used to be held to.
    """
    text = "\n".join(ci_goal_recipe(goal)).replace("$(MAKE)", "make")
    parsed_commands = []
    for line in logical_shell_commands(text):
        # A recipe line is a shell command LIST, not a single command: a
        # sub-make may follow a `;` (a guard computed first) and may end at a
        # `|` (its output teed so PASS lines can be counted). Reading the line
        # whole would miss the first and swallow the pipeline into the second's
        # goal list, so split on the operators before parsing.
        for segment in re.split(r"[;&|]+|\d*>[>&]?\S*", line):
            try:
                tokens = shlex.split(segment, comments=True, posix=True)
            except ValueError:
                continue
            parsed = make_command(tokens)
            if parsed is not None:
                parsed_commands.append(parsed)
    return parsed_commands


def ci_goal_pins(goal):
    """Return the variables a CI goal refuses to run without.

    $(call ci_pin,NAME) is how a goal states that NAME must arrive from the
    caller's command line rather than from this Makefile's own default. It is
    the goal-side half of every pin a workflow step supplies, so a step that
    passes a pin the goal does not require would be unenforced.
    """
    return [
        name
        for line in ci_goal_recipe(goal)
        for name in re.findall(r"\$\(call ci_pin,([A-Za-z_][A-Za-z0-9_]*)\)", line)
    ]


def makefile_goal_list(name):
    with open(os.path.join(root, "Makefile"), encoding="utf-8") as handle:
        for line in handle:
            if line.startswith(f"{name} ="):
                return tuple(line.split("=", 1)[1].split())
    return ()


CI_GOALS = makefile_goal_list("CI_GOALS")
RELEASE_GOALS = makefile_goal_list("RELEASE_GOALS")
# Every goal a workflow may invoke. Recipe edges are seeded from this, so a
# release goal's sub-makes are as visible to the routing checks as a CI goal's.
WORKFLOW_GOALS = CI_GOALS + RELEASE_GOALS
check(
    CI_GOALS == (
        "ci-verify", "ci-stress", "ci-pic", "ci-mutation",
        "ci-attiny202-build", "ci-attiny202-target", "ci-build-classic",
    ),
    f"Makefile: CI_GOALS is {CI_GOALS!r}, expected the reviewed seven",
)
check(
    RELEASE_GOALS == ("release-rebuild", "release-test-long", "release-attiny202"),
    f"Makefile: RELEASE_GOALS is {RELEASE_GOALS!r}, expected the reviewed three",
)

# A goal the release PATH runs and no workflow does: the artifact commit exists
# only after an operator has committed by hand, which is a tree no workflow can
# produce. It is declared so that its composition and its strictness are read
# from a recipe like every other one, and it stays out of RELEASE_GOALS so that
# list can keep meaning "what release.yml runs" and be checked against the file.
RELEASE_PATH_GOALS = makefile_goal_list("RELEASE_PATH_GOALS")
check(
    RELEASE_PATH_GOALS == ("release-artifact-gates",),
    f"Makefile: RELEASE_PATH_GOALS is {RELEASE_PATH_GOALS!r}, expected the "
    "reviewed one",
)
DECLARED_GOALS = WORKFLOW_GOALS + RELEASE_PATH_GOALS


def check_resource_routes(commands, surface, routes):
    for goal, expected in routes.items():
        matches = [parsed for parsed in commands if goal in parsed[0]]
        check(
            len(matches) == 1,
            f"{surface}: resource consumer '{goal}' occurs {len(matches)} "
            "time(s), expected 1",
        )
        if len(matches) != 1:
            continue
        goals, assignments, duplicate_assignment = matches[0]
        actual = {
            name: value for name, value in assignments.items()
            if name in RESOURCE_POLICY
        }
        check(
            not duplicate_assignment and actual == expected,
            f"{surface}: resource consumer '{goal}' receives {actual!r}, "
            f"expected {expected!r}",
        )


def non_resource_assignments(assignments):
    return {
        name: value for name, value in assignments.items()
        if name not in RESOURCE_POLICY
    }


ci_doc = docs.get("ci.yml")
ci_jobs = ci_doc.get("jobs") if isinstance(ci_doc, dict) else None


def normalized_condition(value):
    return re.sub(r"\s+", " ", value).strip() if isinstance(value, str) else value


NORMAL_NON_PR_CONDITION = (
    "github.event_name == 'push' || "
    "github.event_name == 'schedule' || "
    "github.event_name == 'workflow_dispatch'"
)

# Normal CI owns one fully provisioned mutation run. The hosted stress job must
# retain the FULL workload without reaching mutation directly or through
# test-long; test/test_workload_rebuild.sh independently proves what `stress`
# expands to in Make.
ci_make_invocations = []
if isinstance(ci_jobs, dict):
    for job_id, job in ci_jobs.items():
        steps = (job.get("steps") or []) if isinstance(job, dict) else []
        for idx, step in enumerate(steps, 1):
            run = step.get("run") if isinstance(step, dict) else None
            commands = shell_tokens(run) if isinstance(run, str) else []
            for tokens in commands:
                parsed = make_command(tokens)
                if parsed is not None:
                    ci_make_invocations.append(
                        (job_id, idx, step, len(commands), parsed, tokens)
                    )

# Compare workflow provisioning with Make's real transitive prerequisite graph.
# A `needs: pic` edge orders jobs but does not copy the PIC runner's filesystem,
# so checking only visible workflow commands misses a target-only prerequisite
# concealed inside `make test` or `make stress`.
worktree = os.stat(root)
worktree_id = f"{worktree.st_dev}:{worktree.st_ino}"
make_db = subprocess.run(
    ["make", "-pRrq", f"_MAKE_SERIAL_LOCK_HELD={worktree_id}"],
    cwd=root,
    capture_output=True,
    text=True,
    check=False,
)
make_edges = {}
if check(
        make_db.returncode <= 1,
        f"Make prerequisite database failed with status {make_db.returncode}"):
    in_files = False
    for line in make_db.stdout.splitlines():
        if line == "# Files":
            in_files = True
            continue
        if line == "# files hash-table stats:":
            in_files = False
        if not in_files or not line or line[0].isspace() or line.startswith("#"):
            continue
        fields = line.split()
        if not fields or not fields[0].endswith(":") or "=" in line:
            continue
        target = fields[0][:-1]
        if target.startswith("."):
            continue
        prereqs = fields[1:fields.index("|")] if "|" in fields else fields[1:]
        make_edges.setdefault(target, set()).update(prereqs)

# A CI goal INVOKES its gates rather than depending on them -- deliberately, so
# each aggregate gets its own Make process -- and recipe commands are invisible
# to the prerequisite database above. Without these edges every reachability
# question asked through a wrapper would answer "no" and the routing checks
# below would pass vacuously on a job that still runs the gate.
for ci_goal in DECLARED_GOALS:
    for goals, _, _ in ci_goal_commands(ci_goal):
        make_edges.setdefault(ci_goal, set()).update(goals)


def make_variable(name):
    """Expand one Make variable, so a workflow can be checked against Make.

    Reading it from the -pRrq dump above would give the unexpanded definition;
    a `print-<VAR>` query gives the value a build actually sees. The lock token
    is the same one the dump uses: a complete Make invocation holds the worktree
    lock, and this gate can run inside one.
    """
    result = subprocess.run(
        ["make", "-s", "--no-print-directory", f"print-{name}",
         f"_MAKE_SERIAL_LOCK_HELD={worktree_id}"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.split() if result.returncode == 0 else []


def reachable_set(target):
    """Every target reachable from `target`, itself included.

    Set inclusion is how the CI_LOCAL_FOLDED claim is checked: `test-long` does
    not depend on `test`, it re-aggregates the same gates with the exhaustive
    domains, so the question is whether it covers them, not whether it reaches
    them.
    """
    pending, seen = [target], set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        pending.extend(make_edges.get(current, ()))
    return seen


def target_reaches(target, wanted):
    pending = [target]
    seen = set()
    while pending:
        current = pending.pop()
        if current == wanted:
            return True
        if current in seen:
            continue
        seen.add(current)
        pending.extend(make_edges.get(current, ()))
    return False


# --- the local mirror runs what ci.yml runs, by construction ------------------
# Three links, none of which a comment can carry:
#
#   ci.yml -> CI_GOALS       every gate step invokes a declared goal, and every
#                            declared goal is invoked by some job (below);
#   CI_GOALS -> local        CI_LOCAL_SEQUENCE + CI_LOCAL_FOLDED partition it,
#                            refused at Make PARSE time (proved below, by
#                            breaking it);
#   local -> executed        every sequenced goal has a handler in ci-local.sh
#                            (below, and again at run time in the script).
#
# Chained, those make "a clean local pass means CI will be green" a property of
# the files rather than a claim in a header.
CI_LOCAL_SEQUENCE = makefile_goal_list("CI_LOCAL_SEQUENCE")
CI_LOCAL_FOLDED = makefile_goal_list("CI_LOCAL_FOLDED")
check(
    CI_LOCAL_SEQUENCE == (
        "ci-pic", "ci-build-classic",
        "ci-attiny202-build", "ci-attiny202-target",
    ),
    f"Makefile: CI_LOCAL_SEQUENCE is {CI_LOCAL_SEQUENCE!r}, expected the "
    "reviewed four, in the order a serial run needs them",
)
check(
    CI_LOCAL_FOLDED == ("ci-verify", "ci-stress", "ci-mutation"),
    f"Makefile: CI_LOCAL_FOLDED is {CI_LOCAL_FOLDED!r}, expected the reviewed three",
)

# The partition is enforced by a parse-time $(error), so it cannot be checked by
# reading a value -- a broken partition produces no value at all. Break it on
# the command line and require the refusal. Grepping the Makefile for the guard
# would pass on a guard someone had commented out.
def make_refuses(override):
    result = subprocess.run(
        ["make", "-s", "--no-print-directory", "print-CI_GOALS", override,
         f"_MAKE_SERIAL_LOCK_HELD={worktree_id}"],
        cwd=root, capture_output=True, text=True, check=False,
    )
    return result.returncode != 0, result.stderr


for override, wanted in (
    # a CI goal in neither list: the local mirror would not run it
    ("CI_LOCAL_SEQUENCE=ci-pic", "no local counterpart"),
    # a name in neither direction's CI_GOALS: a typo leaves a gate unrun
    ("CI_LOCAL_FOLDED=ci-verify ci-stress ci-mutation ci-nonexistent",
     "CI_GOALS does not declare"),
    # both invoked and folded: the goal would run twice, or not at all
    ("CI_LOCAL_FOLDED=ci-verify ci-stress ci-mutation ci-pic",
     "both locally invoked and folded"),
):
    refused, stderr = make_refuses(override)
    check(
        refused and wanted in stderr,
        f"Makefile: `make {override}` was not refused at parse time "
        f"(expected {wanted!r}); the CI_GOALS partition is not enforced",
    )

# Every gate step in ci.yml invokes a declared CI goal, and between them the
# jobs invoke ALL of them. Either direction failing is a hole: a job running a
# gate directly bypasses the local mirror entirely, and a declared goal no job
# invokes is a local run spending time on work CI does not do.
if isinstance(ci_jobs, dict):
    ci_yml_goals = set()
    for job_id, job in sorted(ci_jobs.items()):
        job_goals = set()
        for step in (job.get("steps") or []) if isinstance(job, dict) else []:
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            for tokens in shell_tokens(step["run"]):
                parsed = make_command(tokens)
                if parsed is not None:
                    job_goals.update(parsed[0])
        check(
            job_goals and job_goals <= set(CI_GOALS),
            f"ci.yml job '{job_id}' invokes {sorted(job_goals)!r}, which is not "
            "a non-empty subset of CI_GOALS: a gate reached outside a declared "
            "goal has no local counterpart",
        )
        ci_yml_goals |= job_goals
    check(
        ci_yml_goals == set(CI_GOALS),
        f"ci.yml invokes {sorted(ci_yml_goals)!r} but CI_GOALS declares "
        f"{sorted(CI_GOALS)!r}",
    )

# "One `make test-long` covers these" is a claim about Make's graph. Ask it.
# Not `test-long reaches ci-verify's target` -- it does not, and must not: `test`
# and `test-long` are sibling aggregates over overlapping gate sets, not one
# built on the other. The claim that matters is COVERAGE: everything a folded
# goal's target pulls in is also pulled in by test-long. A gate that `test`
# runs and `test-long` does not would be a gate CI runs and a local push
# silently never does.
test_long_covers = reachable_set("test-long")
for goal in CI_LOCAL_FOLDED:
    for goals, _, _ in ci_goal_commands(goal):
        for invoked in goals:
            uncovered = sorted(reachable_set(invoked) - test_long_covers - {invoked})
            # Name a handful, not all of them: dropping one shared list from
            # test-long uncovers dozens at once, and a 70-item line buries the
            # one fact that matters -- which goal stopped being covered.
            shown = ", ".join(uncovered[:5])
            if len(uncovered) > 5:
                shown += f", and {len(uncovered) - 5} more"
            check(
                not uncovered,
                f"Makefile: {goal} runs '{invoked}', which pulls in {shown} "
                "that test-long does not; CI_LOCAL_FOLDED claims one local "
                "test-long covers it",
            )

# ci-local.sh defines exactly one handler per sequenced goal, and no others. The
# script checks this too, at run time; here it fails in `make test`, before
# anyone waits an hour to discover a gate was quietly absent.
if ci_local_present:
    handlers = set(re.findall(r"(?m)^goal_([A-Za-z0-9_]+)\(\) \{$", "\n".join(lines)))
    expected_handlers = {goal.replace("-", "_") for goal in CI_LOCAL_SEQUENCE}
    check(
        handlers == expected_handlers,
        f"scripts/ci-local.sh defines handlers {sorted(handlers)!r}, expected "
        f"{sorted(expected_handlers)!r} -- one per goal in CI_LOCAL_SEQUENCE",
    )
    # The dispatcher must READ the sequence rather than restate it; a literal
    # loop over the goal names would pass every check above while drifting.
    check(
        "print-CI_LOCAL_SEQUENCE" in "\n".join(lines),
        "scripts/ci-local.sh does not read CI_LOCAL_SEQUENCE from the Makefile",
    )


def prior_job_steps(job_id, step_index):
    job = ci_jobs.get(job_id) if isinstance(ci_jobs, dict) else None
    steps = job.get("steps", []) if isinstance(job, dict) else []
    return [step for step in steps[:step_index - 1] if isinstance(step, dict)]


def provisions_pic(job_id, step_index):
    return any(
        "scripts/assert_pic_toolchain.sh --github-actions" in str(step.get("run", ""))
        for step in prior_job_steps(job_id, step_index)
    )


def provisions_attiny202(job_id, step_index):
    required = (
        "command -v cppcheck",
        "third_party/attiny_dfp/gcc/dev/attiny202/device-specs/specs-attiny202",
        "third_party/attiny_dfp/include/avr/iotn202.h",
    )
    return any(
        step.get("name") == "Assert ATtiny202 build + analysis inputs present"
        and all(fragment in str(step.get("run", "")) for fragment in required)
        for step in prior_job_steps(job_id, step_index)
    )


target_gate_routes = {
    "test-pic-guard-mutations": ("pic", provisions_pic),
    "test-attiny202-guard-mutations": ("attiny202", provisions_attiny202),
}
for gate, (expected_job, provisioned) in target_gate_routes.items():
    routes = [
        invocation for invocation in ci_make_invocations
        if any(target_reaches(goal, gate) for goal in invocation[4][0])
    ]
    check(
        len(routes) == 1,
        f"ci.yml: target-toolchain gate '{gate}' is reached by {len(routes)} "
        "Make invocations, expected 1",
    )
    if len(routes) == 1:
        job_id, idx, _, _, _, _ = routes[0]
        check(
            job_id == expected_job,
            f"ci.yml: target-toolchain gate '{gate}' is owned by job "
            f"'{job_id}', expected '{expected_job}'",
        )
        check(
            provisioned(job_id, idx),
            f"ci.yml: job '{job_id}' does not provision {gate}'s inputs before use",
        )

check_resource_routes(
    [invocation[4] for invocation in ci_make_invocations],
    "ci.yml",
    CI_RESOURCE_ROUTES,
)

# Hosted CI must consume the same fail-closed ATtiny202 target aggregate as
# release qualification. test-target-matrix independently executes the aggregate
# with a fake Make and proves sim, fault, and lock-step remain required members;
# this check owns only workflow routing and does not restate that orchestration.
#
# The job runs TWO goals, in order, and the split is load-bearing: the first
# needs only the vendored ATtiny_DFP (compile the images and prove they exist),
# the second needs the patched yasimavr venv (run them). The workflow
# provisions the venv and caches the DFP between them, so a single folded goal
# would spend a simulator build before knowing the image compiled.
ATTINY_CI_GOALS = (
    ("ci-attiny202-build", {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "XT_STACK_MAX_FRAME": CI_RESOURCE_REFS["XT_STACK_MAX_FRAME"],
    }),
    ("ci-attiny202-target", {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
    }),
)

attiny_job = ci_jobs.get("attiny202") if isinstance(ci_jobs, dict) else None
if check(isinstance(attiny_job, dict), "ci.yml: required job 'attiny202' is missing"):
    attiny_step_index = {}
    for goal, expected_pins in ATTINY_CI_GOALS:
        invocations = [
            invocation for invocation in ci_make_invocations
            if goal in invocation[4][0]
        ]
        check(
            len(invocations) == 1,
            f"ci.yml: {goal} is invoked {len(invocations)} time(s), expected 1",
        )
        if len(invocations) != 1:
            continue
        job_id, idx, step, command_count, parsed, tokens = invocations[0]
        attiny_step_index[goal] = idx
        check(
            job_id == "attiny202" and not parsed[2]
            and parsed[:2] == ((goal,), expected_pins),
            f"ci.yml: the {goal} invocation is not canonical: {' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"ci.yml: {goal} step {idx} must contain only its Make command",
        )
        check("if" not in step, f"ci.yml: {goal} step {idx} is conditional")
        check(
            step.get("continue-on-error", False) is False,
            f"ci.yml: {goal} step {idx} may continue after failure",
        )
    check(
        attiny_step_index.get("ci-attiny202-build") is not None
        and attiny_step_index.get("ci-attiny202-target") is not None
        and attiny_step_index["ci-attiny202-build"]
        < attiny_step_index["ci-attiny202-target"],
        "ci.yml: the ATtiny202 build gate must run before the target/soak gate, "
        "so a broken image is found before a simulator is built",
    )

    # Every ATtiny202 gate must be reached THROUGH those goals. A step naming
    # one directly would run it under a second, unpinned policy -- and the two
    # component checks below (that the aggregate is not bypassed, and that the
    # soak stays a separately counted lane) are why the aggregate is trusted.
    direct_goals = {
        "attiny202-test", "attiny202-test-target", "attiny202-soak",
        "attiny202-sim", "attiny202-fault", "attiny202-lockstep",
    }
    direct_attiny = [
        f"{invocation[0]} step {invocation[1]}: {goal}"
        for invocation in ci_make_invocations
        for goal in invocation[4][0] if goal in direct_goals
    ]
    check(
        not direct_attiny,
        "ci.yml: a job bypasses the ATtiny202 CI goals with direct calls: "
        + ", ".join(direct_attiny),
    )

    build_recipe = ci_goal_commands("ci-attiny202-build")
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in build_recipe
        ) == ((("attiny202-test",), {"STRICT_TOOLS": "1"}),)
        and not any(duplicate for _, _, duplicate in build_recipe),
        "Makefile: ci-attiny202-build no longer runs the pre-hardware gate "
        "under STRICT_TOOLS=1: "
        + " | ".join(" ".join(goals) for goals, _, _ in build_recipe),
    )
    check(
        sorted(ci_goal_pins("ci-attiny202-build"))
        == ["XT_STACK_MAX_FRAME", "XT_STATIC_RAM_LIMIT"],
        "Makefile: ci-attiny202-build does not refuse every pin its callers "
        f"supply: {ci_goal_pins('ci-attiny202-build')}",
    )
    check_resource_routes(
        build_recipe, "Makefile ci-attiny202-build",
        CI_GOAL_RESOURCE_ROUTES["ci-attiny202-build"],
    )
    # The assertion that used to be loose shell in the workflow. Without it a
    # failed DFP fetch is a green run that produced no images, because every
    # attiny202-* target exits 0 when the DFP is absent.
    build_lines = ci_goal_recipe("ci-attiny202-build")
    check(
        any("XT_RELEASE_IMAGES" in line for line in build_lines)
        and any("$(XT_BUILD_DIR)/$$hex" in line for line in build_lines),
        "Makefile: ci-attiny202-build no longer asserts every declared image "
        "was actually built",
    )

    target_recipe = ci_goal_commands("ci-attiny202-target")
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in target_recipe
        ) == (
            (("attiny202-test-target",), {"STRICT_TOOLS": "1"}),
            (("attiny202-soak",), {
                "XT_SOAK_DURATION_MS": "$(CI_XT_SOAK_DURATION_MS)",
                "XT_SOAK_PROGRESS_INTERVAL_MS": "$(CI_XT_SOAK_DURATION_MS)",
            }),
        )
        and not any(duplicate for _, _, duplicate in target_recipe),
        "Makefile: ci-attiny202-target no longer runs the fail-closed aggregate "
        "and one separately routed soak: "
        + " | ".join(" ".join(goals) for goals, _, _ in target_recipe),
    )
    check(
        ci_goal_pins("ci-attiny202-target") == ["XT_STATIC_RAM_LIMIT"],
        "Makefile: ci-attiny202-target does not refuse every pin its callers "
        f"supply: {ci_goal_pins('ci-attiny202-target')}",
    )
    check_resource_routes(
        target_recipe, "Makefile ci-attiny202-target",
        CI_GOAL_RESOURCE_ROUTES["ci-attiny202-target"],
    )
    # The other assertion the workflow carried as loose shell: a soak that skips
    # a variant still exits 0, so the PASS count is the only thing that proves
    # the matrix was covered. XT_VARIANTS_SUPPORTED is the immutable expectation.
    target_lines = ci_goal_recipe("ci-attiny202-target")
    check(
        any("SOAK PASS" in line for line in target_lines)
        and any("XT_VARIANTS_SUPPORTED" in line for line in target_lines),
        "Makefile: ci-attiny202-target no longer counts one soak PASS per "
        "supported variant",
    )
# Exactly one normal-CI path may run mutants, and it must be the fully
# provisioned one. The question is asked by REACHABILITY, not by goal name: a
# wrapper hides the inner goal, and `test-long` carries mutation too, so
# matching literals would miss both a second wrapper and a folded-in aggregate.
mutation_invocations = [
    invocation for invocation in ci_make_invocations
    if any(target_reaches(goal, "test-mutation") for goal in invocation[4][0])
]
check(
    len(mutation_invocations) == 1,
    f"ci.yml: {len(mutation_invocations)} Make invocations reach test-mutation, "
    "expected 1",
)
if len(mutation_invocations) == 1:
    job_id, idx, step, command_count, parsed, tokens = mutation_invocations[0]
    expected_mutation_pins = dict(XC8_PIC_REFS)
    expected_mutation_pins["XT_STATIC_RAM_LIMIT"] = \
        CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"]
    expected_mutation_pins["PIC12F675_DATA_LIMIT"] = \
        CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"]
    check(
        job_id == "pic" and not parsed[2]
        and parsed[:2] == (("ci-mutation",), expected_mutation_pins),
        "ci.yml: the one mutation command is not the canonical pinned "
        f"ci-mutation invocation: {' '.join(tokens)}",
    )
    check(
        command_count == 1,
        f"ci.yml: pic mutation step {idx} must contain only its Make command",
    )
    check(
        normalized_condition(step.get("if")) == NORMAL_NON_PR_CONDITION,
        "ci.yml: pic mutation gate does not use the exact "
        "push/schedule/workflow_dispatch condition",
    )
    check(
        step.get("continue-on-error", False) is False,
        "ci.yml: pic mutation gate may continue after failure",
    )

    # The fail-closed policy the step used to carry now lives in the recipe.
    # Asserting nothing here would retire the one check that makes this a gate
    # rather than a report: a skipped mutant must fail, on every substrate.
    mutation_recipe = ci_goal_commands("ci-mutation")
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in mutation_recipe
        ) == ((
            ("test-mutation",),
            dict(MAKE_PIC_REFS, STRICT_TOOLS="1", MUTATION_ALLOW_SKIP="0"),
        ),)
        and not any(duplicate for _, _, duplicate in mutation_recipe),
        "Makefile: ci-mutation is not the canonical fail-closed mutation run: "
        + " | ".join(" ".join(goals) for goals, _, _ in mutation_recipe),
    )
    check(
        sorted(ci_goal_pins("ci-mutation")) == sorted(
            list(XC8_PIC_REFS) + ["XT_STATIC_RAM_LIMIT", "PIC12F675_DATA_LIMIT"]
        ),
        "Makefile: ci-mutation does not refuse every pin its callers supply: "
        f"{ci_goal_pins('ci-mutation')}",
    )
    check_resource_routes(
        mutation_recipe, "Makefile ci-mutation", CI_GOAL_RESOURCE_ROUTES["ci-mutation"]
    )

stress_job = ci_jobs.get("stress") if isinstance(ci_jobs, dict) else None
if check(isinstance(stress_job, dict), "ci.yml: required job 'stress' is missing"):
    check(
        normalized_condition(stress_job.get("if")) == NORMAL_NON_PR_CONDITION,
        "ci.yml: stress job does not use the exact "
        "push/schedule/workflow_dispatch condition",
    )
    check(
        stress_job.get("continue-on-error", False) is False,
        "ci.yml: stress job may continue after failure",
    )
    stress_invocations = [
        invocation for invocation in ci_make_invocations
        if invocation[0] == "stress"
    ]
    check(
        len(stress_invocations) == 1,
        f"ci.yml: stress job has {len(stress_invocations)} Make invocations, expected 1",
    )
    if len(stress_invocations) == 1:
        _, idx, step, command_count, parsed, tokens = stress_invocations[0]
        check(
            not parsed[2] and parsed[:2] == (("ci-stress",), {}),
            "ci.yml: stress job does not invoke exactly the ci-stress goal "
            f"with no overrides: {' '.join(tokens)}",
        )
        verify_recipe = ci_goal_recipe("ci-verify")
        check(
            any(line.split()[1:] == ["test", "STRICT_TOOLS=1"]
                for line in verify_recipe if line.startswith("$(MAKE) ")),
            "Makefile: ci-verify does not invoke the default suite under "
            f"STRICT_TOOLS=1: {verify_recipe}",
        )
        stress_recipe = ci_goal_recipe("ci-stress")
        check(
            any(line.split()[1:] == ["stress", "STRICT_TOOLS=1"]
                for line in stress_recipe if line.startswith("$(MAKE) ")),
            "Makefile: ci-stress does not invoke the canonical mutation-free "
            f"FULL aggregate under STRICT_TOOLS=1: {stress_recipe}",
        )
        check(
            not any("MUTATION_ALLOW_SKIP" in line for line in stress_recipe),
            "Makefile: mutation-free ci-stress still configures mutation skip policy",
        )
        check(
            command_count == 1,
            f"ci.yml: stress suite step {idx} must contain only its Make command",
        )
        check(
            step.get("continue-on-error", False) is False,
            "ci.yml: stress suite may continue after failure",
        )
    # Membership in the parsed goal tuple, not a substring: the FULL aggregate
    # is now reached through ci-stress, and only that goal may reach it.
    all_stress_invocations = [
        invocation for invocation in ci_make_invocations
        if "ci-stress" in invocation[4][0] or "stress" in invocation[4][0]
    ]
    check(
        all_stress_invocations == stress_invocations,
        "ci.yml: another normal-CI job invokes the FULL stress aggregate",
    )

# A matrix row selects its work through an expression, which literal command
# parsing cannot resolve. It used to be pinned here as a reviewed list of
# {mcu, build, size} triples -- a second hand-kept copy of what the Makefile
# already knows, checked against a third copy in this file. The row now carries
# only the part name and the goal derives the rest, so the question becomes
# whether the workflow covers the parts MAKE declares. Adding a classic AVR
# part to the Makefile fails this check until the matrix covers it.
build_matrix_job = ci_jobs.get("build-matrix") if isinstance(ci_jobs, dict) else None
if check(
        isinstance(build_matrix_job, dict),
        "ci.yml: required job 'build-matrix' is missing"):
    strategy = build_matrix_job.get("strategy")
    matrix = strategy.get("matrix") if isinstance(strategy, dict) else None
    rows = matrix.get("mcu") if isinstance(matrix, dict) else None
    declared_parts = make_variable("CI_CLASSIC_PARTS")
    check(
        bool(declared_parts),
        "Makefile: CI_CLASSIC_PARTS is empty; the build matrix would be unchecked",
    )
    check(
        rows == declared_parts,
        f"ci.yml: build-matrix covers {rows!r}, but the Makefile declares "
        f"CI_CLASSIC_PARTS={declared_parts!r}",
    )
    check(
        isinstance(matrix, dict) and "include" not in matrix,
        "ci.yml: build-matrix reintroduced per-row goal fields; the goal owns "
        "which targets a part builds",
    )

    build_invocations = [
        invocation for invocation in ci_make_invocations
        if "ci-build-classic" in invocation[4][0]
    ]
    check(
        len(build_invocations) == 1,
        f"ci.yml: ci-build-classic is invoked {len(build_invocations)} time(s), "
        "expected 1",
    )
    if len(build_invocations) == 1:
        job_id, idx, step, command_count, parsed, tokens = build_invocations[0]
        check(
            job_id == "build-matrix" and not parsed[2]
            and parsed[:2] == (
                ("ci-build-classic",), {"CI_CLASSIC_PART": "${{ matrix.mcu }}"}
            ),
            "ci.yml: the build-matrix invocation is not the canonical pinned "
            f"ci-build-classic command: {' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"ci.yml: build-matrix step {idx} must contain only its Make command",
        )
        check("if" not in step, f"ci.yml: build-matrix step {idx} is conditional")
        check(
            step.get("continue-on-error", False) is False,
            f"ci.yml: build-matrix step {idx} may continue after failure",
        )

    # No job may name a classic part target directly: the pin is what makes an
    # unsupported part fail loudly instead of expanding to some other goal.
    direct_classic = [
        f"{invocation[0]} step {invocation[1]}: {goal}"
        for invocation in ci_make_invocations
        for goal in invocation[4][0]
        if goal in declared_parts or goal in {f"{p}-size" for p in declared_parts}
    ]
    check(
        not direct_classic,
        "ci.yml: a job bypasses ci-build-classic with a direct part target: "
        + ", ".join(direct_classic),
    )

    build_recipe = ci_goal_commands("ci-build-classic")
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in build_recipe
        ) == (
            (("$(CI_CLASSIC_PART)",), {}),
            (("$(CI_CLASSIC_PART)-size",), {"AVR_REBUILD_PREREQ": ""}),
        )
        and not any(duplicate for _, _, duplicate in build_recipe),
        "Makefile: ci-build-classic no longer builds the part and re-reports "
        "its size without rebuilding: "
        + " | ".join(" ".join(goals) for goals, _, _ in build_recipe),
    )
    check(
        ci_goal_pins("ci-build-classic") == ["CI_CLASSIC_PART"],
        "Makefile: ci-build-classic does not refuse the pin its callers supply: "
        f"{ci_goal_pins('ci-build-classic')}",
    )
    # The pin reaches a sub-make as a goal name, so it must be checked against
    # the declared set FIRST. Without this the recipe would run whatever it was
    # handed.
    check(
        any("CI_CLASSIC_PARTS" in line for line in ci_goal_recipe("ci-build-classic")),
        "Makefile: ci-build-classic does not validate CI_CLASSIC_PART against "
        "CI_CLASSIC_PARTS before using it as a goal",
    )
pic_job = ci_jobs.get("pic") if isinstance(ci_jobs, dict) else None
if check(isinstance(pic_job, dict), "ci.yml: required job 'pic' is missing"):
    check("if" not in pic_job, "ci.yml: job 'pic' must be unconditional")
    check(
        pic_job.get("continue-on-error", False) is False,
        "ci.yml: job 'pic' may continue after failure",
    )
    # The job invokes ONE goal. What that goal runs is asserted against the
    # recipe below, so the boundary is described once and both the hosted job
    # and scripts/ci-local.sh are held to the same description.
    ci_pic_invocations = [
        invocation for invocation in ci_make_invocations
        if "ci-pic" in invocation[4][0]
    ]
    check(
        len(ci_pic_invocations) == 1,
        f"ci.yml: ci-pic is invoked {len(ci_pic_invocations)} time(s), expected 1",
    )
    if len(ci_pic_invocations) == 1:
        job_id, idx, step, command_count, parsed, tokens = ci_pic_invocations[0]
        expected_pic_pins = dict(XC8_PIC_REFS)
        expected_pic_pins["PIC12F675_DATA_LIMIT"] = \
            CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"]
        check(
            job_id == "pic" and not parsed[2]
            and parsed[:2] == (("ci-pic",), expected_pic_pins),
            "ci.yml: the PIC gate invocation is not the canonical pinned "
            f"ci-pic command: {' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"ci.yml: pic gate step {idx} must contain only its Make command",
        )
        check("if" not in step, f"ci.yml: pic gate step {idx} is conditional")
        check(
            step.get("continue-on-error", False) is False,
            f"ci.yml: pic gate step {idx} may continue after failure",
        )

    # Every PIC aggregate must be reached THROUGH the goal. A step that named
    # one directly would run the same gate under a second, unpinned policy.
    direct_pic_invocations = [
        invocation for invocation in ci_make_invocations
        if any(goal in PIC_GOALS for goal in invocation[4][0])
    ]
    check(
        not direct_pic_invocations,
        "ci.yml: a job bypasses ci-pic with direct PIC aggregate calls: "
        + ", ".join(
            f"{invocation[0]} step {invocation[1]}"
            for invocation in direct_pic_invocations
        ),
    )

    # ...and the goal itself must still be the reviewed five-process boundary,
    # forwarding the caller's pins and refusing to run without them.
    recipe_commands = ci_goal_commands("ci-pic")
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in recipe_commands
        ) == pic_commands(MAKE_PIC_REFS)
        and not any(duplicate for _, _, duplicate in recipe_commands),
        "Makefile: ci-pic no longer runs the reviewed five PIC commands: "
        + " | ".join(" ".join(goals) for goals, _, _ in recipe_commands),
    )
    check(
        sorted(ci_goal_pins("ci-pic")) == sorted(
            list(XC8_PIC_REFS) + ["PIC12F675_DATA_LIMIT"]
        ),
        "Makefile: ci-pic does not refuse every pin its callers supply: "
        f"{ci_goal_pins('ci-pic')}",
    )
    check_resource_routes(
        recipe_commands, "Makefile ci-pic", CI_GOAL_RESOURCE_ROUTES["ci-pic"]
    )

    expected_uploads = {
        "firmware-pic10f322": "build_pic10f322/*.hex",
        "firmware-pic10f320": "build_pic10f320/*.hex",
        "firmware-pic12f675": "build_pic12f675/*.hex",
    }
    actual_uploads = []
    for step in pic_job.get("steps") or []:
        if not isinstance(step, dict) \
                or not str(step.get("uses", "")).startswith("actions/upload-artifact@"):
            continue
        options = step.get("with") or {}
        actual_uploads.append((
            options.get("name"), options.get("path"),
            options.get("if-no-files-found"),
        ))
    check(
        len(actual_uploads) == len(expected_uploads),
        f"ci.yml: PIC job has {len(actual_uploads)} firmware uploads, "
        f"expected {len(expected_uploads)}",
    )
    for artifact, path in expected_uploads.items():
        matches = [upload for upload in actual_uploads if upload[0] == artifact]
        check(
            matches == [(artifact, path, "error")],
            f"ci.yml: PIC artifact {artifact} must upload {path} exactly once "
            "with if-no-files-found: error",
        )

    for job_id in ("verify", "attiny202", "build-matrix", "stress"):
        job = ci_jobs.get(job_id)
        needs = job.get("needs", []) if isinstance(job, dict) else []
        if isinstance(needs, str):
            needs = [needs]
        check(
            isinstance(needs, list) and "pic" in needs,
            f"ci.yml: job '{job_id}' must declare needs: pic",
        )

    # Local CI now invokes the SAME goal the hosted job does, so the
    # five-process boundary is asserted once, above, against ci-pic's recipe.
    # What remains local is which installation to point it at: the paths this
    # script resolved in its own preflight, plus the production data limit.
    local_shell = shell_tokens("\n".join(lines))
    local_invocations = []
    for tokens in local_shell:
        if len(tokens) >= 4 and tokens[0] == "run_step" \
                and tokens[1].startswith("pic job:") and tokens[2] == "make":
            parsed = make_command(tokens[2:])
            if parsed is not None:
                local_invocations.append(parsed)
    check(
        len(local_invocations) == 1,
        f"scripts/ci-local.sh: the PIC job runs {len(local_invocations)} Make "
        "commands, expected 1",
    )
    if len(local_invocations) == 1:
        goals, assignments, duplicate_assignment = local_invocations[0]
        expected_local_pins = dict(CI_LOCAL_PIC_REFS)
        expected_local_pins["PIC12F675_DATA_LIMIT"] = "$CI_PIC12F675_DATA_LIMIT"
        check(
            not duplicate_assignment
            and (goals, assignments) == (("ci-pic",), expected_local_pins),
            "scripts/ci-local.sh: noncanonical PIC job command: make "
            f"{' '.join(goals)}"
            + "".join(f" {key}={value}" for key, value in assignments.items()),
        )
    strict_exports = sum(tokens == ["export", "STRICT_TOOLS=1"] for tokens in local_shell)
    check(
        strict_exports == 1,
        f"scripts/ci-local.sh: export STRICT_TOOLS=1 occurs {strict_exports} "
        "time(s), expected 1",
    )


def check_shell_resource_constants(text, surface, prefix):
    expected = {f"{prefix}_{name}": value for name, value in RESOURCE_POLICY.items()}
    actual = {}
    for name in expected:
        matches = re.findall(
            rf"(?m)^readonly {re.escape(name)}=([^\s#]+)\s*$", text
        )
        actual[name] = matches[0] if len(matches) == 1 else matches
    check(
        actual == expected,
        f"{surface}: resource-policy pins are {actual!r}, expected {expected!r}",
    )


ci_local_text = "\n".join(lines)
check_shell_resource_constants(ci_local_text, "scripts/ci-local.sh", "CI")

release_script_path = os.path.join(root, "scripts", "make-release.sh")
if check(os.path.isfile(release_script_path), "scripts/make-release.sh: missing"):
    with open(release_script_path, encoding="utf-8") as fh:
        release_script_text = fh.read()
    check_shell_resource_constants(
        release_script_text, "scripts/make-release.sh", "RELEASE"
    )
    release_script_commands = []
    for tokens in shell_tokens(release_script_text):
        parsed = make_command(tokens)
        if parsed is not None:
            release_script_commands.append(parsed)
    check_resource_routes(
        release_script_commands,
        "scripts/make-release.sh",
        MAKE_RELEASE_RESOURCE_ROUTES,
    )


# The public release attestation runs three goals. Two are release-specific
# because release runs DIFFERENT work from CI -- it rebuilds from the tag, and
# it does not soak. The third is ci-pic itself: normal CI and the attestation
# re-run the identical PIC gate, which is the strongest form of the parity this
# whole item exists for, and it is now true by construction rather than by two
# command lists happening to match.
RELEASE_WORKFLOW_GOALS = (
    ("release-rebuild", {
        **XC8_PIC_REFS,
        "XT_STATIC_RAM_LIMIT": RELEASE_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "PIC12F675_DATA_LIMIT": RELEASE_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    }),
    ("release-test-long", {
        "XT_STATIC_RAM_LIMIT": RELEASE_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "PIC12F675_DATA_LIMIT": RELEASE_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    }),
    ("release-attiny202", {
        "XT_STATIC_RAM_LIMIT": RELEASE_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "XT_STACK_MAX_FRAME": RELEASE_RESOURCE_REFS["XT_STACK_MAX_FRAME"],
    }),
    ("ci-pic", {
        **XC8_PIC_REFS,
        "PIC12F675_DATA_LIMIT": RELEASE_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    }),
)

if check(isinstance(release_job, dict), "release.yml: required job 'release' is missing"):
    release_make_commands = []
    release_goal_steps = {}
    for idx, step in enumerate(release_job.get("steps") or [], 1):
        run = step.get("run") if isinstance(step, dict) else None
        commands = shell_tokens(run) if isinstance(run, str) else []
        for tokens in commands:
            parsed = make_command(tokens)
            if parsed is None:
                continue
            release_make_commands.append(parsed)
            for goal in parsed[0]:
                if goal in WORKFLOW_GOALS:
                    release_goal_steps.setdefault(goal, []).append(
                        (idx, step, len(commands), parsed, tokens)
                    )

    check_resource_routes(
        release_make_commands,
        "release.yml",
        RELEASE_RESOURCE_ROUTES,
    )

    for goal, expected_pins in RELEASE_WORKFLOW_GOALS:
        invocations = release_goal_steps.get(goal, [])
        check(
            len(invocations) == 1,
            f"release.yml: {goal} is invoked {len(invocations)} time(s), expected 1",
        )
        if len(invocations) != 1:
            continue
        idx, step, command_count, parsed, tokens = invocations[0]
        check(
            not parsed[2] and parsed[:2] == ((goal,), expected_pins),
            f"release.yml: the {goal} invocation is not canonical: {' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"release.yml: {goal} step {idx} must contain only its Make command",
        )
        check("if" not in step, f"release.yml: {goal} step {idx} is conditional")
        check(
            step.get("continue-on-error", False) is False,
            f"release.yml: {goal} step {idx} may continue after failure",
        )

    # The rebuild must reproduce from NOTHING, and must cover the same parts the
    # Makefile declares. "The committed images reproduce bit-for-bit" is a claim
    # about a clean build; a rebuild that skipped the clean would compare the
    # committed images against whatever happened to be on disk.
    rebuild_recipe = ci_goal_commands("release-rebuild")
    check(
        rebuild_recipe and rebuild_recipe[0][0] == ("clean",),
        "Makefile: release-rebuild does not start from a clean tree: "
        + " | ".join(" ".join(goals) for goals, _, _ in rebuild_recipe),
    )
    check(
        any("$(CI_CLASSIC_PARTS)" in line for line in ci_goal_recipe("release-rebuild")),
        "Makefile: release-rebuild names its own classic-AVR set instead of "
        "the declared CI_CLASSIC_PARTS",
    )
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in rebuild_recipe
        ) == (
            (("clean",), {}),
            (("$(CI_CLASSIC_PARTS)",), {}),
            (("attiny202",), {"STRICT_TOOLS": "1"}),
            (("pic10f322",), dict(PIC_CC=MAKE_PIC_REFS["PIC_CC"],
                                  PIC_DFP=MAKE_PIC_REFS["PIC_DFP"])),
            (("pic10f320-variants",),
             dict(PIC10F320_CC=MAKE_PIC_REFS["PIC10F320_CC"],
                  PIC10F320_DFP=MAKE_PIC_REFS["PIC10F320_DFP"])),
            (("pic12f675",), dict(PIC_CC=MAKE_PIC_REFS["PIC_CC"],
                                  PIC_DFP=MAKE_PIC_REFS["PIC_DFP"])),
        )
        and not any(duplicate for _, _, duplicate in rebuild_recipe),
        "Makefile: release-rebuild no longer rebuilds the reviewed release image "
        "set: " + " | ".join(" ".join(goals) for goals, _, _ in rebuild_recipe),
    )

    # The whole reason release-test-long is not ci-verify or a bare test-long.
    check(
        any("PIC12F675_FLASH_IMAGES=build" in line
            for line in ci_goal_recipe("release-test-long")),
        "Makefile: release-test-long no longer points the flashing-helper gate "
        "at the images rebuilt from the tagged source",
    )

    # Release does NOT soak: qualification soaks belong to make-release.sh and
    # run for the full duration before the tag exists. A 5-minute smoke here
    # would attest to something weaker than the release already claims.
    attiny_release_recipe = ci_goal_commands("release-attiny202")
    check(
        tuple(
            (goals, non_resource_assignments(assignments))
            for goals, assignments, _ in attiny_release_recipe
        ) == (
            (("attiny202-test",), {"STRICT_TOOLS": "1"}),
            (("attiny202-test-target",), {"STRICT_TOOLS": "1"}),
        )
        and not any(duplicate for _, _, duplicate in attiny_release_recipe),
        "Makefile: release-attiny202 no longer runs exactly the pre-hardware "
        "gate and the fail-closed target aggregate: "
        + " | ".join(" ".join(goals) for goals, _, _ in attiny_release_recipe),
    )

    for goal in RELEASE_GOALS:
        check_resource_routes(
            ci_goal_commands(goal), f"Makefile {goal}",
            CI_GOAL_RESOURCE_ROUTES[goal],
        )

    # --- the artifact-commit verifier's composition -------------------------
    # The last gate composition in the release path that lived in a shell
    # script: `make $gates STRICT_TOOLS=1 <pins>`, assembled by
    # verify-release-artifact-commit.sh and therefore readable by nothing.
    # It is now a goal, and these are the three properties that made it worth
    # moving: WHICH gates (the declared list, by name, so the two cannot
    # diverge), WHAT policy (strictness, the whole of what the goal owns), and
    # WHAT ELSE (nothing).
    artifact_recipe = ci_goal_commands("release-artifact-gates")
    check(
        artifact_recipe == [
            (("$(RELEASE_ARTIFACT_GATES)",), {"STRICT_TOOLS": "1"}, False),
        ],
        "Makefile: release-artifact-gates no longer runs exactly "
        "$(RELEASE_ARTIFACT_GATES) under STRICT_TOOLS=1: "
        + " | ".join(
            " ".join(goals) + "".join(f" {k}={v}" for k, v in a.items())
            for goals, a, _ in artifact_recipe
        ),
    )
    # No pins, and that is an assertion. The script used to hand these gates
    # release.yml's three independent pins; not one of the eight reads any of
    # them, in its recipe or in the script it runs, and what they did do was
    # reach the gates' own nested Makes as ENVIRONMENT origin -- unreviewed
    # build input by the release guard's own definition, which is why
    # test-release-preflight (a member of this list) scrubs inherited
    # build-input names before its first case. A gate added here that genuinely
    # reads a pin must be given it deliberately, and fail this check first.
    artifact_pins = ci_goal_pins("release-artifact-gates")
    check(
        artifact_pins == [],
        f"Makefile: release-artifact-gates requires pin(s) {artifact_pins!r}; "
        "no gate it runs reads one",
    )
    # An empty inventory must refuse, not run zero gates and report the commit
    # publishable. The script checks this too, earlier and with a friendlier
    # diagnostic; the goal is what any other caller gets.
    check(
        any("RELEASE_ARTIFACT_GATES" in line and "$(error" in line
            for line in ci_goal_recipe("release-artifact-gates")),
        "Makefile: release-artifact-gates does not refuse an empty "
        "RELEASE_ARTIFACT_GATES, so it would prove a release publishable by "
        "running nothing",
    )

    # The script must reach the gates through that goal and no other way -- the
    # same rule every workflow step is held to. The workflow step parser is not
    # reusable here: it joins continuations into one logical line, and this
    # script's `make ... || die "<multi-line message>"` leaves an unbalanced
    # quote that shlex refuses, so every command would silently drop out and the
    # check would pass on an empty list. Scan lines instead, skipping comments
    # and requiring `make` in command position -- at the start of a line or
    # right after `$(`. Prose is full of the word: the header says
    # "make-release.sh", and the printed handoff explains that no workflow can
    # "make two separate GitHub API operations atomic", which a looser scan
    # reported as a Make goal named "two". print- is a variable read, not
    # dispatch, and is excluded by name.
    verifier_path = os.path.join(root, "scripts", "verify-release-artifact-commit.sh")
    if check(os.path.isfile(verifier_path),
             "scripts/verify-release-artifact-commit.sh: missing"):
        with open(verifier_path, encoding="utf-8") as fh:
            verifier_text = fh.read()
        verifier_goals = []
        for raw in verifier_text.splitlines():
            if raw.lstrip().startswith("#"):
                continue
            for match in re.finditer(r"(?:^|\$\()\s*make\s+(.*)$", raw):
                words = [
                    word.strip("()\"'")
                    for word in match.group(1).split()
                    if word != "\\" and not word.startswith("-")
                    and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", word)
                ]
                if words:
                    verifier_goals.append(words[0])
        dispatched = [g for g in verifier_goals if not g.startswith("print-")]
        check(
            dispatched == ["release-artifact-gates"],
            "scripts/verify-release-artifact-commit.sh must dispatch the gates "
            "through release-artifact-gates and nothing else; it runs: "
            + ", ".join(dispatched or ["(nothing -- did the scan break?)"]),
        )
        # The pins are gone from the script, not merely unused by the goal:
        # re-adding the release.yml parse would restore an environment-origin
        # leak into every nested Make these gates run. Scoped to the dispatch
        # section, because the handoff below it legitimately names
        # RELEASE_SIGNING_FINGERPRINT.
        dispatch_section = verifier_text.split("# 3. The gates")[-1].split("# 4. Hand off")[0]
        leaked = sorted(set(re.findall(r"\bRELEASE_[A-Z0-9_]+\b", dispatch_section))
                        - {"RELEASE_ARTIFACT_GATES"})
        check(
            not leaked,
            "scripts/verify-release-artifact-commit.sh hands the gates "
            f"{leaked!r} again; no gate it runs consumes one",
        )

    # Nothing in release.yml may reach a gate except through a declared goal.
    release_direct = [
        f"step {idx}: {goal}"
        for idx, step in enumerate(release_job.get("steps") or [], 1)
        for tokens in (shell_tokens(step.get("run"))
                       if isinstance(step, dict) and isinstance(step.get("run"), str)
                       else [])
        for parsed in (make_command(tokens),) if parsed is not None
        for goal in parsed[0]
        if goal in PIC_GOALS
        or goal in {"test-long", "attiny202-test", "attiny202-test-target"}
    ]
    check(
        not release_direct,
        "release.yml: a step bypasses the declared goals with a direct gate "
        "call: " + ", ".join(release_direct),
    )

# Normal CI must invoke the same strict PIC capability helper as ci-local, with
# every independently selectable tool/header surface explicit. The helper's own
# behavioral regression proves the three-header and malformed-input contracts;
# this check owns only unconditional workflow routing and complete argv.
ci_doc = docs.get("ci.yml")
ci_jobs = ci_doc.get("jobs") if isinstance(ci_doc, dict) else None
pic_job = ci_jobs.get("pic") if isinstance(ci_jobs, dict) else None
pic_steps = pic_job.get("steps", []) if isinstance(pic_job, dict) else []
pic_assert_steps = [
    (idx, step) for idx, step in enumerate(pic_steps)
    if isinstance(step, dict)
    and step.get("name") == "Assert PIC toolchain present (fail loud, do NOT skip)"
]
check(
    len(pic_assert_steps) == 1,
    f"ci.yml: found {len(pic_assert_steps)} canonical PIC assertion steps, expected 1",
)
if len(pic_assert_steps) == 1:
    assert_idx, step = pic_assert_steps[0]
    run = step.get("run")
    required_fragments = (
        "scripts/assert_pic_toolchain.sh --github-actions",
        '--pic-cc "${XC8_DIR}/bin/xc8-cc"',
        '--pic-dfp "${XC8_DFP_ROOT}/xc8"',
        '--pic10f320-cc "${XC8_DIR}/bin/xc8-cc"',
        '--pic10f320-dfp "${XC8_DFP_ROOT}/xc8"',
        "--gpsim gpsim",
        "--cppcheck cppcheck",
        "--pic-cxx c++",
        "--pic-gpsim-inc /usr/include/gpsim",
        "--pic10f320-cxx c++",
        "--pic10f320-gpsim-inc /usr/include/gpsim",
    )
    check(isinstance(run, str), "ci.yml: PIC assertion step has no run body")
    if isinstance(run, str):
        for fragment in required_fragments:
            check(
                run.count(fragment) == 1,
                f"ci.yml: PIC assertion must contain {fragment!r} exactly once",
            )
    check("if" not in step, "ci.yml: PIC toolchain assertion is conditional")
    check(
        step.get("continue-on-error", False) is False,
        "ci.yml: PIC toolchain assertion may continue after failure",
    )
    verify_indices = [
        idx for idx, candidate in enumerate(pic_steps)
        if isinstance(candidate, dict)
        and candidate.get("run") == "scripts/verify_pic_toolchain_cache.sh"
    ]
    save_indices = [
        idx for idx, candidate in enumerate(pic_steps)
        if isinstance(candidate, dict)
        and candidate.get("name") == "Save XC8 + DFP cache"
    ]
    # Found by what the step RUNS, not by its name: the gate steps were folded
    # into one goal invocation once already, and a name-matched search would
    # have gone quietly vacuous rather than failing.
    first_pic_gate = [
        idx for idx, candidate in enumerate(pic_steps)
        if isinstance(candidate, dict)
        and any(
            make_command(tokens) is not None and "ci-pic" in make_command(tokens)[0]
            for tokens in shell_tokens(str(candidate.get("run", "")))
        )
    ]
    check(
        len(verify_indices) == 1 and verify_indices[0] < assert_idx,
        "ci.yml: PIC assertion must run after unconditional cache verification",
    )
    check(
        len(save_indices) == 1 and assert_idx < save_indices[0],
        "ci.yml: PIC assertion must run before saving the XC8/DFP cache",
    )
    check(
        len(first_pic_gate) == 1 and assert_idx < first_pic_gate[0],
        "ci.yml: PIC assertion must run before the first PIC aggregate",
    )

for msg in failures:
    print(f"FAIL: {msg}", file=sys.stderr)

print(f"workflow syntax/structure validation: {checks} checks, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
