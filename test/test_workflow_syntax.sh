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
# WHAT IT HOLDS
#   - both workflows load, with no duplicate or merge keys, and every run body
#     passes `bash -n`;
#   - supply chain and credentials: actions pinned to full commit SHAs,
#     GH_TOKEN reachable from the one publication step, no persisted checkout
#     credentials, an unconditional XC8/DFP cache verify, and cache keys bound
#     to the inputs they cache;
#   - release.yml verifies the committed release before exposing it, and its
#     publication-kind branches agree with make-release.sh's version grammar;
#   - nothing reaches a gate except through a declared Make goal, with no Make
#     flags and exactly the pins that goal declares, and no gate step can
#     continue after failure or be switched off by any condition but the
#     reviewed pull-request exclusion;
#   - every declared goal has a local counterpart, each goal keeps its
#     fail-closed policy, and the resource-policy pins agree on every surface
#     that carries one.
#
# WHAT IT DELIBERATELY DOES NOT CHECK
#   The exact shape of a job, step or recipe: which packages a job installs,
#   how many cache steps there are, which pins a recipe forwards to which
#   sub-make, what the reviewed goal lists contain. Each of those either fails
#   loudly on the next CI run or was a literal copy of the file it read, which
#   fires on every correct edit and on nothing else. The publication step's
#   commands are executed, with failures injected, by test-release-provenance
#   rather than restated here.
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

for name, job_id, idx, key in pic_cache_steps:
    check(
        "hashFiles('scripts/install_pic_toolchain.sh')" in key,
        f"{name}: job '{job_id}' PIC cache step {idx} is not keyed by the installer pin",
    )

for name, job_id, idx, key in attiny_cache_steps:
    check(
        "hashFiles('scripts/fetch_attiny_dfp.sh')" in key,
        f"{name}: job '{job_id}' ATtiny_DFP cache step {idx} is not keyed by its pins",
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

    # --- publication kind -----------------------------------------------------
    # A suffixed tag (v1.0.0-rc.1) must publish as a GitHub prerelease so a
    # candidate cannot take latest-release selection away from the newest
    # stable version; a bare vX.Y.Z must not. The workflow decides that with two
    # regex branches over $tag, which makes this ANOTHER copy of the project's
    # version grammar -- so extract both branch patterns and require that
    # together they accept exactly what scripts/make-release.sh accepts, and
    # that they split that grammar stable-vs-suffixed. What the step then does
    # with each kind is executed by test-release-provenance.
    publish_run = publish_steps[0].get("run") if len(publish_steps) == 1 else None
    if isinstance(publish_run, str):
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
# graph. Only the file itself is needed here; the handler, strict-export and
# resource-pin checks below read these lines.
ci_local = os.path.join(root, "scripts", "ci-local.sh")
ci_local_present = check(os.path.isfile(ci_local), "scripts/ci-local.sh: missing")
if ci_local_present:
    with open(ci_local, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

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

# A goal the release PATH runs and no workflow does: the artifact commit exists
# only after an operator has committed by hand, which is a tree no workflow can
# produce. It is declared so that its composition and its strictness are read
# from a recipe like every other one, and it stays out of RELEASE_GOALS so that
# list can keep meaning "what release.yml runs" and be checked against the file.
RELEASE_PATH_GOALS = makefile_goal_list("RELEASE_PATH_GOALS")
DECLARED_GOALS = WORKFLOW_GOALS + RELEASE_PATH_GOALS


ci_doc = docs.get("ci.yml")
ci_jobs = ci_doc.get("jobs") if isinstance(ci_doc, dict) else None


def normalized_condition(value):
    return re.sub(r"\s+", " ", value).strip() if isinstance(value, str) else value


NORMAL_NON_PR_CONDITION = (
    "github.event_name == 'push' || "
    "github.event_name == 'schedule' || "
    "github.event_name == 'workflow_dispatch'"
)

# Every Make invocation ci.yml makes, parsed once; the mutation-path check
# below asks which of them reach test-mutation.
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


# A CI goal INVOKES its gates rather than depending on them -- deliberately, so
# each aggregate gets its own Make process -- and recipe commands are invisible
# to the prerequisite database above. Without these edges every reachability
# question asked through a wrapper would answer "no" and the routing checks
# below would pass vacuously on a job that still runs the gate.
for ci_goal in DECLARED_GOALS:
    for goals, _, _ in ci_goal_commands(ci_goal):
        make_edges.setdefault(ci_goal, set()).update(goals)
        # A recipe may dispatch a LIST rather than a name: release-rebuild runs
        # $(CI_CLASSIC_PARTS), release-artifact-gates runs
        # $(RELEASE_ARTIFACT_GATES). Left unexpanded, such a goal reaches one
        # node spelled "$(...)" and nothing past it, so every coverage question
        # asked through it is answered by the empty set -- vacuously, and in the
        # fail-open direction. Expanding needs make_variable, which is why the
        # seeding sits below it rather than beside the database it extends.
        for word in goals:
            listed = re.fullmatch(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)", word)
            if listed and word not in make_edges:
                make_edges[word] = set(make_variable(listed.group(1)))


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


# The list dispatches above must really have been expanded. Nothing else would
# say so: an unexpanded $(VAR) is a node with no edges, so every coverage
# question asked through it is answered by the empty set and passes.
for listing_goal, listing_variable in (
    ("release-rebuild", "CI_CLASSIC_PARTS"),
    ("release-artifact-gates", "RELEASE_ARTIFACT_GATES"),
):
    listed_targets = make_variable(listing_variable)
    unreached = sorted(set(listed_targets) - reachable_set(listing_goal))
    check(
        bool(listed_targets) and not unreached,
        f"Makefile: $({listing_variable}) is {listed_targets!r}, and "
        f"{unreached!r} of it is not reachable from {listing_goal}: an "
        "unexpanded list dispatch is a node with no edges, so every coverage "
        "question asked through it is answered by the empty set",
    )


# --- nothing reaches a gate except through a declared goal --------------------
# The checks after this one ask whether the RIGHT goals run, under the right
# policy. This section asks the prior question, of both
# files at once: is there anything ELSE? A gate reached any other way -- a bare
# `make test`, a suite under test/ run directly, a `-k` that turns a red gate
# into a green job, a variable no goal declares -- has no local counterpart,
# and every ordering assertion further down would still pass while it ran.
#
# That needs a stricter reader than the canonical checks use. shell_tokens()
# reports a logical line whose FIRST word is `make`, which is every invocation
# either file contains today; it cannot see `cd x && make ...`,
# `out=$(make ...)` or `... | make ...` -- three shapes a step takes when it
# grows a gate call without anyone deciding to. So find command POSITIONS
# instead: the start of a line, and whatever follows an operator.
#
# Heredoc bodies are read as commands too. That is the safe direction -- a line
# of prose starting with the word "make" fails loudly, where skipping bodies
# would hide a real dispatch -- and the one heredoc either file has holds
# Python.
SHELL_SEPARATORS = {
    "&&", "||", ";", "|", "&", "(", ")", "{", "}", "!",
    "then", "do", "else", "elif",
}
# Wrappers that run whatever follows them. `command` is deliberately not one:
# `command -v make` is a probe for the tool, not a use of it.
COMMAND_PREFIXES = {"sudo", "env", "time", "exec", "nohup"}
# A consumed prefix brings its own options, and these take their value as a
# separate word rather than glued on with '='.
PREFIX_VALUE_FLAGS = {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}
SCRIPT_INTERPRETERS = {"bash", "sh", "python3", "python"}
# A variable read is not a dispatch, and these two flags are what silences one.
READ_MAKE_FLAGS = {"-s", "--no-print-directory"}


def command_argvs(text):
    """Yield the argv of every command position in a shell fragment."""
    for line in logical_shell_commands(text):
        # shlex keeps `$(` and a backtick glued to the word before them, so a
        # substituted command is invisible unless the opener separates first.
        line = re.sub(r"\$\(|`", " ; ", line)
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError:
            continue
        argvs = []
        argv = []
        for token in tokens:
            if token in SHELL_SEPARATORS:
                if argv:
                    argvs.append(argv)
                argv = []
                continue
            # `make ci-stress; fi` tokenises as one word plus one: a separator
            # only has to be spaced on one side to be a separator.
            terminated = token.endswith(";")
            token = token[:-1] if terminated else token
            if token:
                argv.append(token.rstrip(")"))
            if terminated and argv:
                argvs.append(argv)
                argv = []
        if argv:
            argvs.append(argv)
        for argv in argvs:
            index = 0
            prefixed = False
            while index < len(argv):
                word = argv[index]
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", word):
                    index += 1
                elif word in COMMAND_PREFIXES:
                    prefixed = True
                    index += 1
                elif prefixed and word.startswith("-"):
                    # Without this the scan stops ON the option and reports no
                    # command at all -- so a prefix listed here as understood
                    # would exempt what it wraps from every rule that reads a
                    # command position, which is all of them.
                    index += 1
                    if word in PREFIX_VALUE_FLAGS:
                        index += 1
                else:
                    break
            if index < len(argv):
                yield argv[index:]


def make_invocations(text):
    """Yield (flags, goals, pins) for every `make` command in a fragment."""
    for argv in command_argvs(text):
        if argv[0] != "make":
            continue
        flags = []
        goals = []
        pins = {}
        for word in argv[1:]:
            assignment = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", word)
            if word.startswith("-"):
                flags.append(word)
            elif assignment:
                pins[assignment.group(1)] = assignment.group(2)
            else:
                goals.append(word)
        yield flags, goals, pins


def direct_test_program(argv):
    """The program under test/ this command runs, if it runs one.

    `test -f test/misra.json` is the shell builtin reading a data file and must
    not match. `bash test/test_x.sh` is the bypass that must: run that way a
    gate carries whatever policy the step happened to set, which is the
    hand-maintained inventory this whole item exists to remove.
    """
    if re.search(r"(?:^|/)test/", argv[0]):
        return argv[0]
    if (argv[0] in SCRIPT_INTERPRETERS and len(argv) > 1
            and re.search(r"(?:^|/)test/", argv[1])):
        return argv[1]
    return None


# --- the scanner must see through a prefix it claims to understand -----------
# Every rule below reads command positions through command_argvs, so a form it
# cannot parse is not a rule that fails: it is a rule that reports nothing.
# `env` is in COMMAND_PREFIXES exactly so the command it wraps is still scanned,
# and its options are what a naive skip stops on. Both directions matter -- the
# dispatch that must still be seen, and the bypass that must still be caught.
for fragment, expected in (
    ("env -u MAKEFLAGS make ci-verify", ["make", "ci-verify"]),
    ("env -u MAKEFLAGS -i bash test/test_x.sh", ["bash", "test/test_x.sh"]),
    ("make ci-verify", ["make", "ci-verify"]),
):
    parsed = list(command_argvs(fragment))
    check(
        parsed == [expected],
        f"command_argvs({fragment!r}) reports {parsed!r}, not [{expected!r}]: a "
        "command position the scanner cannot parse silently exempts the step "
        "from every rule below",
    )


workflow_job_goals = {}
for workflow_name in ("ci.yml", "release.yml"):
    workflow_doc = docs.get(workflow_name)
    workflow_jobs = workflow_doc.get("jobs") if isinstance(workflow_doc, dict) else None
    bypasses = []
    for job_id, job in sorted((workflow_jobs or {}).items()):
        steps = job.get("steps") if isinstance(job, dict) else None
        for idx, step in enumerate(steps or [], 1):
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            where = f"{workflow_name}: job '{job_id}' step {idx}"
            for argv in command_argvs(step["run"]):
                program = direct_test_program(argv)
                if program is not None:
                    bypasses.append(f"job '{job_id}' step {idx} runs {program}")
            for flags, goals, pins in make_invocations(step["run"]):
                if len(goals) == 1 and goals[0].startswith("print-"):
                    check(
                        set(flags) <= READ_MAKE_FLAGS,
                        f"{where} reads {goals[0]} with "
                        f"{sorted(set(flags) - READ_MAKE_FLAGS)!r}: a variable "
                        "read takes -s and --no-print-directory, nothing else",
                    )
                    continue
                if not check(
                    len(goals) == 1,
                    f"{where} invokes make with {goals!r}; a step runs exactly "
                    "one declared goal, so that one name carries the gate, its "
                    "policy and its pins",
                ):
                    continue
                goal = goals[0]
                if not check(
                    goal in DECLARED_GOALS,
                    f"{where} invokes '{goal}', which no declared goal names: a "
                    "gate reached outside a goal runs under whatever policy the "
                    "step sets and has no local counterpart",
                ):
                    continue
                workflow_job_goals.setdefault((workflow_name, job_id), set()).add(goal)
                check(
                    not flags,
                    f"{where} passes Make {flags!r} to {goal}: -k and -i turn a "
                    "failing gate into a passing job, and -j changes the "
                    "serialisation these gates are written for",
                )
                required = set(ci_goal_pins(goal))
                supplied = set(pins)
                check(
                    supplied == required,
                    f"{where} invokes {goal} with {sorted(supplied)!r} but the "
                    f"goal declares {sorted(required)!r}: missing "
                    f"{sorted(required - supplied)!r} is refused at run time, "
                    f"an hour in, and extra {sorted(supplied - required)!r} "
                    "reaches every nested Make as unreviewed command-line input",
                )
    check(
        not bypasses,
        f"{workflow_name}: a step reaches a suite under test/ directly rather "
        "than through a declared goal: " + ", ".join(bypasses),
    )


# --- a gate cannot pass while failing, or be switched off --------------------
# continue-on-error turns a red gate into a green run, and nothing in either
# workflow needs it. A condition is how a gate is switched off without anyone
# reading a failure: the one reviewed condition keeps the FULL and mutation runs
# off pull requests, which they are too slow for, and no other condition may
# sit on a job or step that runs a declared goal.
for workflow_name, doc in sorted(docs.items()):
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    for job_id, job in sorted((jobs or {}).items()):
        if not isinstance(job, dict):
            continue
        check(
            job.get("continue-on-error", False) is False,
            f"{workflow_name}: job '{job_id}' may continue after failure",
        )
        for idx, step in enumerate(job.get("steps") or [], 1):
            if not isinstance(step, dict):
                continue
            check(
                step.get("continue-on-error", False) is False,
                f"{workflow_name}: job '{job_id}' step {idx} may continue after failure",
            )
            # An upload that finds nothing must fail: a job whose build quietly
            # produced no image would otherwise upload nothing and pass.
            if str(step.get("uses", "")).startswith("actions/upload-artifact@"):
                options = step.get("with")
                check(
                    isinstance(options, dict)
                    and options.get("if-no-files-found") == "error",
                    f"{workflow_name}: job '{job_id}' step {idx} uploads without "
                    "if-no-files-found: error",
                )
            run = step.get("run")
            if not (isinstance(run, str) and any(
                    goal in DECLARED_GOALS
                    for _, goals, _ in make_invocations(run) for goal in goals)):
                continue
            for owner, label in ((job, f"job '{job_id}'"), (step, f"step {idx}")):
                condition = owner.get("if")
                check(
                    condition is None
                    or normalized_condition(condition) == NORMAL_NON_PR_CONDITION,
                    f"{workflow_name}: {label} runs a declared goal under "
                    f"{condition!r}; the only reviewed condition is the "
                    "pull-request exclusion",
                )


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

# WHICH declared goals belong in which file. The section above already proved
# that these are all of them -- found at every command position, each one
# declared, unflagged and pinned as its recipe requires -- so what is left is
# the two directions of the inventory. Either failing is a hole: a job that
# invokes no goal is running gates the local mirror never hears about, and a
# declared goal no job invokes is an hour of local work CI does not do.
if isinstance(ci_jobs, dict):
    ci_yml_goals = set()
    for job_id in sorted(ci_jobs):
        job_goals = workflow_job_goals.get(("ci.yml", job_id), set())
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

# The same closing direction for release.yml. Not CI_GOALS: that workflow runs
# different work -- it rebuilds from the tag and deliberately does not soak --
# plus the one PIC gate both share, which is what makes "release re-runs the
# identical PIC gate" true by construction. The bypass scan above holds each
# step to its goal's declared pins; this says there is nothing else.
release_yml_goals = set()
for (workflow_name, job_id), goals in workflow_job_goals.items():
    if workflow_name == "release.yml":
        release_yml_goals |= goals
expected_release_yml_goals = set(RELEASE_GOALS) | {"ci-pic"}
check(
    release_yml_goals == expected_release_yml_goals,
    f"release.yml invokes {sorted(release_yml_goals)!r}, expected "
    f"{sorted(expected_release_yml_goals)!r}",
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


# --- the fail-closed assertions the ATtiny202 goals carry ---------------------
# Every attiny202-* target exits 0 when the device pack or the simulator venv is
# absent, so two assertions that used to be loose shell in the workflow are what
# keep that job from passing on nothing: the build goal checks that every
# declared image was actually built, and the target goal counts one soak PASS
# per supported variant.
build_lines = ci_goal_recipe("ci-attiny202-build")
check(
    any("XT_RELEASE_IMAGES" in line for line in build_lines)
    and any("$(XT_BUILD_DIR)/$$hex" in line for line in build_lines),
    "Makefile: ci-attiny202-build no longer asserts every declared image "
    "was actually built",
)
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


# ci-local.sh stands in for every job, so it runs them strict as well.
ci_local_text = "\n".join(lines) if ci_local_present else ""
if ci_local_present:
    strict_exports = sum(
        tokens == ["export", "STRICT_TOOLS=1"] for tokens in shell_tokens(ci_local_text)
    )
    check(
        strict_exports == 1,
        f"scripts/ci-local.sh: export STRICT_TOOLS=1 occurs {strict_exports} "
        "time(s), expected 1",
    )

release_script_text = ""

release_script_path = os.path.join(root, "scripts", "make-release.sh")
if check(os.path.isfile(release_script_path), "scripts/make-release.sh: missing"):
    with open(release_script_path, encoding="utf-8") as fh:
        release_script_text = fh.read()

    # The local release pipeline must COVER the public attestation. Every gate
    # release.yml runs on the tag has to have run here first, or a release
    # qualifies over hours locally and then fails in a workflow that cannot be
    # re-run without cutting another tag -- the exact cost this whole item
    # exists to remove. It is the release half of what CI_LOCAL_SEQUENCE says
    # for a push, and it has to be asked as COVERAGE for the same reason the
    # CI_LOCAL_FOLDED claim is: the two callers reach the same gates by
    # different routes. The workflow names goals; this script names each
    # consumer directly and deliberately -- it resolves a toolchain path per
    # command and tees each gate to its own evidence log -- so the goal NAMES
    # are excluded from the question. What must match is everything under them.
    script_targets = set()
    for _, goals, _ in make_invocations(release_script_text):
        for goal in goals:
            if (re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", goal)
                    and not goal.startswith("print-")):
                script_targets.add(goal)
    check(
        bool(script_targets),
        "scripts/make-release.sh invokes no Make target at all; the coverage "
        "check below would pass on an empty pipeline",
    )
    local_release_covers = set()
    for target in script_targets:
        local_release_covers |= reachable_set(target)
    for goal in sorted(release_yml_goals):
        reached = {
            target for target in reachable_set(goal)
            if not target.startswith("$(")
        }
        uncovered = sorted(reached - local_release_covers - set(DECLARED_GOALS))
        # Name a handful: dropping one aggregate from the script uncovers
        # dozens at once, and the fact that matters is which gate went dark.
        shown = ", ".join(uncovered[:5])
        if len(uncovered) > 5:
            shown += f", and {len(uncovered) - 5} more"
        check(
            not uncovered,
            f"release.yml reaches {shown} through {goal}, and "
            "scripts/make-release.sh reaches none of them: a release would "
            "qualify locally over hours and then fail its public attestation, "
            "on a tag that cannot be re-cut",
        )


# --- the resource-policy pins agree wherever they are carried -----------------
# The static-RAM, stack-frame and PIC12F675 data ceilings are pinned outside the
# Makefile on purpose: each caller states its own value, so a Makefile default
# that moves fails the gate instead of agreeing with itself. That works only
# while every caller states the SAME value. Four surfaces carry them -- ci.yml
# and release.yml as workflow env, ci-local.sh and make-release.sh as readonly
# constants -- and the pin names are read from ci.yml rather than listed here,
# so adding a pin needs no edit to this file.
def workflow_pins(workflow_name, prefix):
    doc = docs.get(workflow_name)
    env = doc.get("env") if isinstance(doc, dict) else None
    if not isinstance(env, dict):
        return {}
    return {
        name[len(prefix):]: str(value)
        for name, value in env.items() if name.startswith(prefix)
    }


def readonly_pins(text, prefix):
    return {
        match.group(1): match.group(2)
        for match in re.finditer(
            rf"(?m)^readonly {prefix}([A-Z][A-Z0-9_]*)=([^\s#]+)\s*$", text)
    }


ci_pins = workflow_pins("ci.yml", "CI_")
release_pins = workflow_pins("release.yml", "RELEASE_")
check(bool(ci_pins), "ci.yml: the workflow env carries no CI_* resource-policy pins")
check(
    set(release_pins) == set(ci_pins),
    f"release.yml pins {sorted(release_pins)!r} but ci.yml pins {sorted(ci_pins)!r}",
)
for surface, pins in (
    ("release.yml", release_pins),
    ("scripts/ci-local.sh", readonly_pins(ci_local_text, "CI_")),
    ("scripts/make-release.sh", readonly_pins(release_script_text, "RELEASE_")),
):
    for name, value in sorted(ci_pins.items()):
        check(
            pins.get(name) == value,
            f"{surface}: {name} is {pins.get(name)!r}, but ci.yml pins {value!r}",
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

# The whole reason release-test-long is not ci-verify or a bare test-long.
check(
    any("PIC12F675_FLASH_IMAGES=build" in line
        for line in ci_goal_recipe("release-test-long")),
    "Makefile: release-test-long no longer points the flashing-helper gate "
    "at the images rebuilt from the tagged source",
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

# --- the policy each declared goal owns ---------------------------------------
# A job's fail-closed policy used to sit in its workflow step; it now sits in
# the recipe of the goal the step invokes, so it is asserted there. Every
# sub-make that runs gates runs them under STRICT_TOOLS=1, so a missing tool
# fails the job instead of skipping, and a sub-make that reaches the mutation
# run cannot let a mutant skip. A sub-make that only builds -- clean, an image,
# the soak smoke -- runs no gate and is not held to it. A list dispatch is
# judged by what it expands to.
def dispatched_names(word):
    listed = re.fullmatch(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)", word)
    return make_variable(listed.group(1)) if listed else [word]


def runs_gates(word):
    return any(
        name == "stress" or "test" in name.split("-")
        for name in dispatched_names(word)
    )


gate_dispatches = 0
for goal in DECLARED_GOALS:
    commands = ci_goal_commands(goal)
    check(
        bool(commands),
        f"Makefile: {goal} dispatches no sub-make; the recipe parse has stopped matching",
    )
    for goals, assignments, duplicate in commands:
        label = f"Makefile: {goal} runs {' '.join(goals)}"
        check(not duplicate, f"{label} with one variable assigned twice")
        if any(runs_gates(word) for word in goals):
            gate_dispatches += 1
            check(
                assignments.get("STRICT_TOOLS") == "1",
                f"{label} without STRICT_TOOLS=1: a missing tool would skip "
                "instead of failing the job",
            )
        if any(target_reaches(word, "test-mutation") for word in goals):
            check(
                assignments.get("MUTATION_ALLOW_SKIP", "0") == "0",
                f"{label} with MUTATION_ALLOW_SKIP="
                f"{assignments.get('MUTATION_ALLOW_SKIP')!r}: a mutant that "
                "cannot run must fail the run",
            )
check(
    gate_dispatches > 0,
    "no declared goal dispatches a gate; the STRICT_TOOLS check has stopped matching",
)


for msg in failures:
    print(f"FAIL: {msg}", file=sys.stderr)

print(f"workflow syntax/structure validation: {checks} checks, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
