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
            metadata_command = [
                "expected_assets+=(SHA256SUMS", "SHA256SUMS.asc", "MANIFEST.md",
                "QUALIFICATION)",
            ]
            snapshot_command = [
                "cp", "-p", "--", "$dir/*.hex", "$dir/SHA256SUMS",
                "$dir/SHA256SUMS.asc", "$dir/MANIFEST.md", "$dir/QUALIFICATION",
                "$publish_stage/",
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
                and len(metadata_indices) == 1 and len(snapshot_indices) == 1
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
    ("verify", "test"),
    ("stress", "stress"),
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
    "pic12f675-test": {
        "PIC12F675_DATA_LIMIT": CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    },
    "test-mutation": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "PIC12F675_DATA_LIMIT": CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    },
    "attiny202-test": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "XT_STACK_MAX_FRAME": CI_RESOURCE_REFS["XT_STACK_MAX_FRAME"],
    },
    "attiny202-test-target": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
    },
    "attiny202-soak": {
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
    },
}
RELEASE_RESOURCE_ROUTES = release_resource_routes(RELEASE_RESOURCE_REFS)

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

check_resource_routes(
    [invocation[4] for invocation in ci_make_invocations],
    "ci.yml",
    CI_RESOURCE_ROUTES,
)

# Hosted CI must consume the same fail-closed ATtiny202 target aggregate as
# release qualification. test-target-matrix independently executes the aggregate
# with a fake Make and proves sim, fault, and lock-step remain required members;
# this check owns only workflow routing and does not restate that orchestration.
attiny_job = ci_jobs.get("attiny202") if isinstance(ci_jobs, dict) else None
if check(isinstance(attiny_job, dict), "ci.yml: required job 'attiny202' is missing"):
    target_invocations = [
        invocation for invocation in ci_make_invocations
        if invocation[0] == "attiny202"
        and "attiny202-test-target" in invocation[4][0]
    ]
    check(
        len(target_invocations) == 1,
        "ci.yml: attiny202 job must invoke attiny202-test-target exactly once",
    )
    if len(target_invocations) == 1:
        _, idx, step, command_count, parsed, tokens = target_invocations[0]
        check(
            not parsed[2] and parsed[:2] == (
                ("attiny202-test-target",),
                {
                    "STRICT_TOOLS": "1",
                    "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
                },
            ),
            "ci.yml: ATtiny202 target aggregate invocation is not canonical: "
            f"{' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"ci.yml: ATtiny202 target aggregate step {idx} must contain only "
            "its Make command",
        )
        check("if" not in step, "ci.yml: ATtiny202 target aggregate is conditional")
        check(
            step.get("continue-on-error", False) is False,
            "ci.yml: ATtiny202 target aggregate may continue after failure",
        )

    component_goals = {"attiny202-sim", "attiny202-fault", "attiny202-lockstep"}
    direct_components = [
        goal
        for invocation in ci_make_invocations if invocation[0] == "attiny202"
        for goal in invocation[4][0] if goal in component_goals
    ]
    check(
        not direct_components,
        "ci.yml: attiny202 job bypasses its target aggregate with direct "
        f"component calls: {direct_components}",
    )
    soak_invocations = [
        invocation for invocation in ci_make_invocations
        if invocation[0] == "attiny202" and "attiny202-soak" in invocation[4][0]
    ]
    check(
        len(soak_invocations) == 1,
        "ci.yml: attiny202 job must retain one separately routed soak",
    )

mutation_invocations = [
    invocation for invocation in ci_make_invocations
    if "test-mutation" in invocation[4][0]
]
check(
    len(mutation_invocations) == 1,
    f"ci.yml: direct test-mutation invocation count is "
    f"{len(mutation_invocations)}, expected 1",
)
if len(mutation_invocations) == 1:
    job_id, idx, step, command_count, parsed, tokens = mutation_invocations[0]
    expected_assignments = {
        "STRICT_TOOLS": "1",
        "MUTATION_ALLOW_SKIP": "0",
        "PIC_CC": "${XC8_DIR}/bin/xc8-cc",
        "PIC_DFP": "${XC8_DFP_ROOT}/xc8",
        "PIC10F320_CC": "${XC8_DIR}/bin/xc8-cc",
        "PIC10F320_DFP": "${XC8_DFP_ROOT}/xc8",
        "XT_STATIC_RAM_LIMIT": CI_RESOURCE_REFS["XT_STATIC_RAM_LIMIT"],
        "PIC12F675_DATA_LIMIT": CI_RESOURCE_REFS["PIC12F675_DATA_LIMIT"],
    }
    check(
        job_id == "pic" and not parsed[2]
        and parsed[:2] == (("test-mutation",), expected_assignments),
        "ci.yml: the one mutation command is not the canonical fail-closed "
        f"pic invocation: {' '.join(tokens)}",
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

mutation_bearing_invocations = [
    invocation for invocation in ci_make_invocations
    if any(goal in {"test-mutation", "test-long"} for goal in invocation[4][0])
]
check(
    mutation_bearing_invocations == mutation_invocations,
    "ci.yml: a normal-CI job invokes mutation-bearing test-long in addition "
    "to the one direct mutation gate",
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
            not parsed[2] and parsed[:2] == (("stress",), {"STRICT_TOOLS": "1"}),
            "ci.yml: stress job does not invoke the canonical mutation-free "
            f"FULL aggregate: {' '.join(tokens)}",
        )
        check(
            command_count == 1,
            f"ci.yml: stress suite step {idx} must contain only its Make command",
        )
        check(
            "MUTATION_ALLOW_SKIP" not in parsed[1],
            "ci.yml: mutation-free stress still configures mutation skip policy",
        )
        check(
            step.get("continue-on-error", False) is False,
            "ci.yml: stress suite may continue after failure",
        )
    all_stress_invocations = [
        invocation for invocation in ci_make_invocations
        if "stress" in invocation[4][0]
    ]
    check(
        all_stress_invocations == stress_invocations,
        "ci.yml: another normal-CI job invokes the FULL stress aggregate",
    )

# Matrix-selected goals are expressions in the run command, so literal command
# parsing cannot see their concrete values. Pin the small reviewed matrix here;
# otherwise a row could route test-long/mutation without changing the command.
build_matrix_job = ci_jobs.get("build-matrix") if isinstance(ci_jobs, dict) else None
if check(
        isinstance(build_matrix_job, dict),
        "ci.yml: required job 'build-matrix' is missing"):
    strategy = build_matrix_job.get("strategy")
    matrix = strategy.get("matrix") if isinstance(strategy, dict) else None
    include = matrix.get("include") if isinstance(matrix, dict) else None
    expected_build_matrix = [
        {"mcu": "attiny13a", "build": "attiny13a", "size": "attiny13a-size"},
        {"mcu": "attiny85", "build": "attiny85", "size": "attiny85-size"},
        {"mcu": "attiny45", "build": "attiny45", "size": "attiny45-size"},
    ]
    check(
        include == expected_build_matrix,
        "ci.yml: build-matrix goals no longer match the reviewed Classic AVR set",
    )

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
            not duplicate_assignment
            and (goals, non_resource_assignments(assignments)) in PIC_COMMANDS,
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
            not parsed[2] and parsed[0] == goals
            and non_resource_assignments(parsed[1]) == assignments
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
        (goals, {})
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
            not duplicate_assignment
            and (goals, non_resource_assignments(assignments)) in local_commands,
            "scripts/ci-local.sh: noncanonical PIC job command: make "
            f"{' '.join(goals)}"
            + "".join(f" {key}={value}" for key, value in assignments.items()),
        )
    for goals, assignments in local_commands:
        occurrences = sum(
            not parsed[2] and parsed[0] == goals
            and non_resource_assignments(parsed[1]) == assignments
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
        RELEASE_RESOURCE_ROUTES,
    )


# The public release attestation must use the same five-process PIC boundary as
# normal CI. In particular, PIC12F675's two goals must occupy one command so GNU
# Make executes their shared matrix qualifier once.
if check(isinstance(release_job, dict), "release.yml: required job 'release' is missing"):
    release_pic_invocations = []
    release_make_commands = []
    for idx, step in enumerate(release_job.get("steps") or [], 1):
        run = step.get("run") if isinstance(step, dict) else None
        commands = shell_tokens(run) if isinstance(run, str) else []
        for tokens in commands:
            parsed = make_command(tokens)
            if parsed is not None:
                release_make_commands.append(parsed)
            if parsed is not None and any(goal in PIC_GOALS for goal in parsed[0]):
                release_pic_invocations.append((idx, step, len(commands), parsed, tokens))

    check_resource_routes(
        release_make_commands,
        "release.yml",
        RELEASE_RESOURCE_ROUTES,
    )

    for idx, step, command_count, parsed, tokens in release_pic_invocations:
        goals, assignments, duplicate_assignment = parsed
        check(
            not duplicate_assignment
            and (goals, non_resource_assignments(assignments)) in PIC_COMMANDS,
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
            not parsed[2] and parsed[0] == goals
            and non_resource_assignments(parsed[1]) == assignments
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
    first_pic_gate = [
        idx for idx, candidate in enumerate(pic_steps)
        if isinstance(candidate, dict)
        and str(candidate.get("name", "")).startswith("PIC10F322 pre-hardware gate")
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
