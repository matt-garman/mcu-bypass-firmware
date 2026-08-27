#!/usr/bin/env bash
set -euo pipefail

# Validate the GitHub Actions workflow files locally.
#
# WHY THIS EXISTS
#   Nothing else in the repo ever PARSES .github/workflows/*.yml. The release
#   regressions grep release.yml for fixed strings, which succeeds happily on a
#   file GitHub cannot load at all, and ci-local.sh re-implements the job order
#   in bash from a comment header rather than reading ci.yml. So a workflow
#   could be syntactically invalid -- the whole matrix refusing to start with
#   "Invalid workflow file" -- while every local gate reported green. That is
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
import sys

import yaml

root = os.environ["ROOT"]
wf_dir = os.path.join(root, ".github", "workflows")

# The workflows this repo is required to have. Listed explicitly rather than
# globbed: a glob turns a renamed or deleted workflow into "zero files, all
# valid", which is the same fail-open shape this test exists to close.
REQUIRED = ("ci.yml", "release.yml")

# ci-local.sh mirrors ci.yml's jobs, plus its own local-only steps. Anything
# here is allowed to appear in the mapping without a matching CI job; anything
# else in the mapping must name a real job.
CI_LOCAL_ONLY = {"preflight"}

checks = 0
failures = []


def check(ok, msg):
    global checks
    checks += 1
    if not ok:
        failures.append(msg)
    return ok


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
            docs[name] = yaml.safe_load(fh)
        check(True, "")
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        where = f" (line {mark.line + 1}, column {mark.column + 1})" if mark else ""
        check(False, f"{name}: does not parse as YAML{where}: {getattr(exc, 'problem', exc)}")

for name, doc in docs.items():
    if not check(isinstance(doc, dict), f"{name}: top level is not a mapping"):
        continue

    # PyYAML resolves an unquoted `on:` key to the boolean True (YAML 1.1), so
    # accept either spelling rather than reporting a missing trigger.
    check(("on" in doc) or (True in doc), f"{name}: no trigger (`on:`) block")

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

        if "uses" not in job:
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
                    ("run" in step) or ("uses" in step),
                    f"{name}: job '{job_id}' step {idx} has neither run nor uses",
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
        and step.get("name") == "Publish GitHub Release"
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
    repro_steps = [
        step for step in release_steps
        if isinstance(step, dict)
        and step.get("name") == "Verify committed images reproduce bit-for-bit"
    ]
    publish_steps = [
        step for step in release_steps
        if isinstance(step, dict) and step.get("name") == "Publish GitHub Release"
    ]
    check(len(repro_steps) == 1, "release.yml: frozen-bundle producer step is not unique")
    check(len(publish_steps) == 1, "release.yml: publication step is not unique")

    if len(repro_steps) == 1:
        repro_run = repro_steps[0].get("run")
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
                and len(record_indices) == 1 and len(inventory_mode_indices) == 1
                and len(harden_indices) == 1
                and len(initial_verify_indices) == 1 and len(output_indices) == 1,
                "release.yml: active root-owned freeze commands are not exact",
            )
            if private_dir_indices and asset_install_indices and record_indices \
                    and inventory_mode_indices and harden_indices \
                    and initial_verify_indices and output_indices:
                check(
                    private_dir_indices[0] < asset_install_indices[0] < record_indices[0]
                    < inventory_mode_indices[0] < harden_indices[0]
                    < initial_verify_indices[0] < output_indices[0],
                    "release.yml: root-owned publication inventory is not hardened and verified before outputs",
                )
            check(
                ["frozen_root=/opt/mcu-bypass-publication"] in commands
                and ["echo", "inventory_sha256=$inventory_sha256"] in commands,
                "release.yml: frozen-bundle producer omits the inventory digest output",
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
                publish.get("continue-on-error", False) is False,
                "release.yml: publication step may continue after verification failure",
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
# and assert them before the first make test/test-long invocation.
for job_id, gate_name in (
    ("verify", "test"),
    ("stress", "test-long"),
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

# --- ci-local.sh must stay in step with ci.yml's job list --------------------
# ci-local.sh reproduces CI by hand, so its CI-JOB MAPPING header is the only
# link between the two. A job added to ci.yml that nobody mirrors locally, or a
# mapping entry naming a job that no longer exists, both mean "a clean local run
# no longer implies a green CI run" -- the script's entire premise.
ci_local = os.path.join(root, "scripts", "ci-local.sh")
if check(os.path.isfile(ci_local), "scripts/ci-local.sh: missing"):
    with open(ci_local, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    mapped, in_block = set(), False
    for line in lines:
        if line.startswith("# CI-JOB MAPPING"):
            in_block = True
            continue
        if in_block:
            # The block ends at the next header comment or the first non-comment.
            if not line.startswith("#"):
                break
            if re.match(r"^# [A-Z]", line):
                break
            m = re.match(r"^#\s{2,}(\S+)\s+->", line)
            if m:
                mapped.add(m.group(1))

    check(bool(mapped), "scripts/ci-local.sh: CI-JOB MAPPING block parsed as empty")

    # Only meaningful once ci.yml actually loaded. Without this guard an
    # unparseable ci.yml yields an empty job set, and every mapping entry is
    # then reported as naming a job that does not exist -- burying the one real
    # failure under a pile that points at the wrong file.
    ci_doc = docs.get("ci.yml")
    if isinstance(ci_doc, dict) and isinstance(ci_doc.get("jobs"), dict):
        ci_jobs = set(ci_doc["jobs"])
        for job_id in sorted(ci_jobs):
            check(
                job_id in mapped,
                f"ci.yml job '{job_id}' is not in ci-local.sh's CI-JOB MAPPING",
            )
        for entry in sorted(mapped - CI_LOCAL_ONLY):
            check(
                entry in ci_jobs,
                f"ci-local.sh maps '{entry}', which is not a job in ci.yml",
            )

# --- pin the complete PIC CI contract independently of ci-local.sh ------------
# Set equality is not enough here: both files could lose one part together, and
# sets erase duplicates. These are five Make processes containing six required
# aggregates; PIC12F675's two goals deliberately share one retained matrix.
PIC_COMMANDS = (
    (
        ("pic10f322-test",),
        {
            "STRICT_TOOLS": "1",
            "PIC_CC": "${XC8_DIR}/bin/xc8-cc",
            "PIC_DFP": "${XC8_DFP_ROOT}/xc8",
        },
    ),
    (
        ("pic10f322-test-target-variants",),
        {
            "STRICT_TOOLS": "1",
            "PIC_CC": "${XC8_DIR}/bin/xc8-cc",
            "PIC_DFP": "${XC8_DFP_ROOT}/xc8",
        },
    ),
    (
        ("pic10f320-test",),
        {
            "STRICT_TOOLS": "1",
            "PIC10F320_CC": "${XC8_DIR}/bin/xc8-cc",
            "PIC10F320_DFP": "${XC8_DFP_ROOT}/xc8",
        },
    ),
    (
        ("pic10f320-test-target-variants",),
        {
            "STRICT_TOOLS": "1",
            "PIC10F320_CC": "${XC8_DIR}/bin/xc8-cc",
            "PIC10F320_DFP": "${XC8_DFP_ROOT}/xc8",
        },
    ),
    (
        ("pic12f675-test", "pic12f675-test-target-variants"),
        {
            "STRICT_TOOLS": "1",
            "PIC_CC": "${XC8_DIR}/bin/xc8-cc",
            "PIC_DFP": "${XC8_DFP_ROOT}/xc8",
            "PIC12F675_DATA_LIMIT": "48",
        },
    ),
)
PIC_GOALS = tuple(goal for goals, _ in PIC_COMMANDS for goal in goals)


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


ci_doc = docs.get("ci.yml")
ci_jobs = ci_doc.get("jobs") if isinstance(ci_doc, dict) else None
pic_job = ci_jobs.get("pic") if isinstance(ci_jobs, dict) else None
if check(isinstance(pic_job, dict), "ci.yml: required job 'pic' is missing"):
    check("if" not in pic_job, "ci.yml: job 'pic' must be unconditional")
    check(
        pic_job.get("continue-on-error", False) is False,
        "ci.yml: job 'pic' may continue after failure",
    )
    pic_invocations = []
    for idx, step in enumerate(pic_job.get("steps") or [], 1):
        run = step.get("run") if isinstance(step, dict) else None
        commands = shell_tokens(run) if isinstance(run, str) else []
        for tokens in commands:
            parsed = make_command(tokens)
            if parsed is not None and any(goal in PIC_GOALS for goal in parsed[0]):
                pic_invocations.append((idx, step, len(commands), parsed, tokens))

    for idx, step, command_count, parsed, tokens in pic_invocations:
        goals, assignments, duplicate_assignment = parsed
        check(
            not duplicate_assignment and (goals, assignments) in PIC_COMMANDS,
            f"ci.yml: pic step {idx} has a noncanonical aggregate command: "
            f"{' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"ci.yml: pic aggregate step {idx} must contain only its direct Make command",
        )
        check("if" not in step, f"ci.yml: pic aggregate step {idx} is conditional")
        check(
            step.get("continue-on-error", False) is False,
            f"ci.yml: pic aggregate step {idx} may continue after failure",
        )

    for goals, assignments in PIC_COMMANDS:
        matches = sum(
            not parsed[2] and parsed[:2] == (goals, assignments)
            for _, _, _, parsed, _ in pic_invocations
        )
        check(
            matches == 1,
            f"ci.yml: PIC command {' '.join(goals)} appears canonically "
            f"{matches} time(s), expected 1",
        )
    for goal in PIC_GOALS:
        occurrences = sum(
            parsed[0].count(goal) for _, _, _, parsed, _ in pic_invocations
        )
        check(
            occurrences == 1,
            f"ci.yml: PIC aggregate '{goal}' occurs {occurrences} time(s), expected 1",
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

    # Local CI has the same hard-coded five process boundary, but obtains tool
    # paths from Make/environment defaults and exports strictness once globally.
    # The production data limit remains pinned on the PIC12F675 invocation.
    local_commands = tuple(
        (
            goals,
            {"PIC12F675_DATA_LIMIT": "48"}
            if "pic12f675-test" in goals else {},
        )
        for goals, _ in PIC_COMMANDS
    )
    local_invocations = []
    local_shell = shell_tokens("\n".join(lines))
    for tokens in local_shell:
        if len(tokens) >= 4 and tokens[0] == "run_step" \
                and tokens[1].startswith("pic job:") and tokens[2] == "make":
            parsed = make_command(tokens[2:])
            if parsed is not None:
                local_invocations.append(parsed)
    for goals, assignments, duplicate_assignment in local_invocations:
        check(
            not duplicate_assignment and (goals, assignments) in local_commands,
            "scripts/ci-local.sh: noncanonical PIC job command: make "
            f"{' '.join(goals)}"
            + "".join(f" {key}={value}" for key, value in assignments.items()),
        )
    for goals, assignments in local_commands:
        occurrences = sum(
            not parsed[2] and parsed[:2] == (goals, assignments)
            for parsed in local_invocations
        )
        check(
            occurrences == 1,
            f"scripts/ci-local.sh: PIC command {' '.join(goals)} occurs "
            f"{occurrences} time(s), expected 1",
        )
    strict_exports = sum(tokens == ["export", "STRICT_TOOLS=1"] for tokens in local_shell)
    check(
        strict_exports == 1,
        f"scripts/ci-local.sh: export STRICT_TOOLS=1 occurs {strict_exports} "
        "time(s), expected 1",
    )


# The public release attestation must use the same five-process PIC boundary as
# normal CI. In particular, PIC12F675's two goals must occupy one command so GNU
# Make executes their shared matrix qualifier once.
if check(isinstance(release_job, dict), "release.yml: required job 'release' is missing"):
    release_pic_invocations = []
    for idx, step in enumerate(release_job.get("steps") or [], 1):
        run = step.get("run") if isinstance(step, dict) else None
        commands = shell_tokens(run) if isinstance(run, str) else []
        for tokens in commands:
            parsed = make_command(tokens)
            if parsed is not None and any(goal in PIC_GOALS for goal in parsed[0]):
                release_pic_invocations.append((idx, step, len(commands), parsed, tokens))

    for idx, step, command_count, parsed, tokens in release_pic_invocations:
        goals, assignments, duplicate_assignment = parsed
        check(
            not duplicate_assignment and (goals, assignments) in PIC_COMMANDS,
            f"release.yml: PIC step {idx} has a noncanonical aggregate command: "
            f"{' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"release.yml: PIC aggregate step {idx} must contain only its direct Make command",
        )
        check("if" not in step, f"release.yml: PIC aggregate step {idx} is conditional")
        check(
            step.get("continue-on-error", False) is False,
            f"release.yml: PIC aggregate step {idx} may continue after failure",
        )

    for goals, assignments in PIC_COMMANDS:
        matches = sum(
            not parsed[2] and parsed[:2] == (goals, assignments)
            for _, _, _, parsed, _ in release_pic_invocations
        )
        check(
            matches == 1,
            f"release.yml: PIC command {' '.join(goals)} appears canonically "
            f"{matches} time(s), expected 1",
        )
    for goal in PIC_GOALS:
        occurrences = sum(
            parsed[0].count(goal) for _, _, _, parsed, _ in release_pic_invocations
        )
        check(
            occurrences == 1,
            f"release.yml: PIC aggregate '{goal}' occurs {occurrences} time(s), expected 1",
        )


# Normal CI must reject a DFP missing any device header required by its shared
# three-part PIC job. The installer's cache key changes with the same three-header
# postcondition.
required_pic_headers = ("pic10f322", "pic10f320", "pic12f675")
for workflow_name, job_id in (("ci.yml", "pic"),):
    doc = docs.get(workflow_name)
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    job = jobs.get(job_id) if isinstance(jobs, dict) else None
    loops = []
    body_checks = []
    for step in job.get("steps", []) if isinstance(job, dict) else []:
        run = step.get("run") if isinstance(step, dict) else None
        if not isinstance(run, str):
            continue
        for tokens in shell_tokens(run):
            if tokens[:3] != ["for", "d", "in"]:
                continue
            devices = []
            for token in tokens[3:]:
                token = token.rstrip(";")
                if token == "do":
                    break
                devices.append(token)
            if any(device in required_pic_headers for device in devices):
                loops.append(tuple(devices))
                body_checks.append(re.search(
                    r'(?m)^\s*for d in pic10f322 pic10f320 pic12f675; do\s*$'
                    r'\n\s*dev="\$\{XC8_DFP_ROOT\}/xc8/pic/include/proc/'
                    r'\$\{d\}\.h"\s*$'
                    r'\n\s*test -f "\$\{dev\}" \|\| \{ echo '
                    r'"::error::DFP missing: \$\{dev\}"; exit 1; \}\s*$'
                    r'\n\s*done\s*$',
                    run,
                ) is not None)
    check(
        loops == [required_pic_headers],
        f"{workflow_name}: active PIC-header assertion loops are {loops!r}, "
        f"expected {[required_pic_headers]!r}",
    )
    check(
        body_checks == [True],
        f"{workflow_name}: PIC-header loop does not fail on a missing "
        "${XC8_DFP_ROOT}/xc8/pic/include/proc/${d}.h",
    )

for msg in failures:
    print(f"FAIL: {msg}", file=sys.stderr)

print(f"workflow syntax/structure validation: {checks} checks, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
