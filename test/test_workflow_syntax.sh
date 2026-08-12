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

# --- the pic job's PART LANES must match ci-local.sh's, both ways -------------
# The job-list check above is at JOB granularity, and the pic job is one job for
# three parts (ci.yml decision D3). So a part can be dropped from either side --
# or added to only one -- with every other gate green, and the failure mode is
# the quiet one: a clean local run that no longer implies a green CI run, or a
# CI lane nobody can reproduce locally. Compare the SETS of per-part Make
# targets, not their order: the two files are free to sequence them differently.
    ci_doc = docs.get("ci.yml")
    if isinstance(ci_doc, dict) and isinstance(ci_doc.get("jobs"), dict) \
            and isinstance(ci_doc["jobs"].get("pic"), dict):
        pat = re.compile(r"\b(pic[0-9a-z]+-test(?:-target-variants)?)\b")
        yml_lanes = set()
        pic12_lines = []
        for step in ci_doc["jobs"]["pic"].get("steps") or []:
            if isinstance(step, dict) and isinstance(step.get("run"), str):
                yml_lanes.update(pat.findall(step["run"]))
                pic12_lines.extend(
                    line.strip() for line in step["run"].splitlines()
                    if "pic12f675-test" in line
                )
        local_lanes = set()
        for line in lines:
            if "run_step" in line and "pic job:" in line:
                local_lanes.update(pat.findall(line))
        check(bool(yml_lanes), "ci.yml pic job: no per-part Make lanes found")
        check(
            len(pic12_lines) == 1 and re.match(
                r"^make\s+pic12f675-test\s+"
                r"pic12f675-test-target-variants(?:\s|$)",
                pic12_lines[0],
            ) is not None,
            "ci.yml pic job: PIC12F675 aggregates must share one Make command",
        )
        for lane in sorted(yml_lanes - local_lanes):
            check(False, f"ci.yml pic job runs '{lane}', which ci-local.sh's pic job does not")
        for lane in sorted(local_lanes - yml_lanes):
            check(False, f"ci-local.sh's pic job runs '{lane}', which ci.yml's pic job does not")
        for lane in sorted(yml_lanes & local_lanes):
            check(True, f"pic lane '{lane}' runs in both")

for msg in failures:
    print(f"FAIL: {msg}", file=sys.stderr)

print(f"workflow syntax/structure validation: {checks} checks, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
