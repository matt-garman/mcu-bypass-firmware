#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman

"""A published release is what its recipients already hold. This proves it.

THE DEFECT CLASS is a retroactive edit. Every release under `release/` has been
tagged, signed and handed out; the copies in this tree are not drafts of those
releases, they are the same objects. Editing one here does not update anything
a recipient has -- it makes this tree disagree with what was published, and
says nothing about which of the two is the release. The prospective work on
release layout (a canonical index, an evidence archive, artifact-only tagged
commits, moving payloads to hosted assets) all operates on this directory, and
every step of it is one bad path expansion away from rewriting history it is
supposed to be preserving.

Nothing caught that. A release signs SHA256SUMS over its images and programming
helpers, so those stay verifiable from the release directory alone -- but that
list covers 215 of the 576 published files. The other 361 are the evidence
logs, QUALIFICATION, MANIFEST.md, README.md and SHA256SUMS.asc itself: the
account of what was actually run, not reproducible from source, and until this
gate existed, editable in silence.

WHAT IT ASSERTS. Each release's own SHA256SUMS still verifies, so offline
integrity holds today rather than being assumed from the fact it held once.
Every remaining file matches test/published_release_digests.txt. The two lists
partition the directory exactly, so a file added to a published release is
covered by one or the other and never by neither, and no image can be dropped
from the signed list into the merely-recorded one. Where tags are present the
tag tree is compared directly, an independent opinion on the same claim that
owes nothing to either list.

AMENDMENTS ARE POSSIBLE AND ARE NOT SILENT. Three published releases do differ
from their tags: v0.9.0-v0.9.2 carry a safety errata added after the TMUX4053
polarity defect was found. That was the right call -- someone who fetches only
release/v0.9.1/ must see it -- and it is recorded below with its reason, the
markers that must survive in it, and the check that it touched no file any
verifier reads. It is the reason this gate pins content rather than forbidding
change: the question is never whether a published file may be amended, it is
whether the amendment is on the record.

WHAT THIS FILE DOES NOT DO. It does not verify signatures; SHA256SUMS.asc is
pinned as bytes, and checking it against the signing key needs GnuPG and a
trust decision that scripts/verify-release-signature.sh owns. It cannot speak
for a release whose tag is absent from this clone -- CI checks out shallow and
untagged, so the tag cross-check reports how many releases it could reach
rather than passing quietly over the ones it could not.
"""

from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys


# Overridable ONLY so this file's own failure modes can be exercised against a
# doctored copy of the tree -- an edited evidence log, an image moved out of
# the signed list, an unrecorded amendment -- without editing a published
# release to test the thing that guards published releases. The Make target
# never sets it.
ROOT = Path(os.environ.get("PUBLISHED_RELEASE_ROOT")
            or Path(__file__).resolve().parent.parent)
RELEASE = ROOT / "release"
RECORD = ROOT / "test" / "published_release_digests.txt"
HEADING = re.compile(r"^#\s*(v[0-9.]+)\s*--\s*(\d+) files signed by its own "
                     r"SHA256SUMS, (\d+) recorded here\s*$")

# Files a release signs for itself, and therefore the four this gate requires
# before it will believe a directory is a published release at all.
REQUIRED = ("SHA256SUMS", "SHA256SUMS.asc", "MANIFEST.md", "README.md")

# The one amendment ever made to a published release, and what makes it legible
# rather than a quiet edit: the files it touched, the text that must survive in
# them, and the anchor it sends the reader to.
AMENDMENTS = {
    "v0.9.0": ("MANIFEST.md", "README.md"),
    "v0.9.1": ("MANIFEST.md", "README.md"),
    "v0.9.2": ("MANIFEST.md", "README.md"),
}
AMENDMENT_REASON = (
    "the TMUX4053 direct-drive polarity errata. The `_tmux` images in these "
    "three releases select ENGAGED from the board's undriven pull-down state "
    "instead of fail-safe BYPASS. The images stay exactly as published, for "
    "reproducibility; the warning was added so that a reader who fetches one "
    "of these directories and nothing else cannot flash them unwarned")
AMENDMENT_MARKERS = (
    "[!WARNING]",
    "incorrect direct-drive polarity",
    "../README.md#safety-warning-v090-v092-tmux-images",
)
AMENDMENT_ANCHOR = "## Safety warning: v0.9.0-v0.9.2 TMUX images"

REGISTER = []
FAILURES = []
checks = 0
tags_compared = []
tags_absent = []


def row(identifier, claim):
    """Register one property of the published set and the claim it holds up."""
    def wrap(function):
        REGISTER.append((identifier, claim, function))
        return function
    return wrap


def note(identifier, witness):
    FAILURES.append((identifier, witness))


def counted(condition, identifier, witness):
    global checks
    checks += 1
    if not condition:
        note(identifier, witness)
    return condition


def digest_of(path):
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 16), b""):
            hasher.update(block)
    return hasher.hexdigest()


def versions():
    """Release directories on disk, oldest first."""
    if not RELEASE.is_dir():
        return []
    found = [entry.name for entry in RELEASE.iterdir()
             if entry.is_dir() and entry.name.startswith("v")]
    def order(name):
        try:
            return [int(part) for part in name.lstrip("v").split(".")]
        except ValueError:
            return [1 << 30]
    return sorted(found, key=order)


def payload_of(version):
    """The files a release signs for itself, name -> digest, from its own list."""
    listing = RELEASE / version / "SHA256SUMS"
    if not listing.is_file():
        return None
    signed = {}
    for line in listing.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            signed[parts[1].strip()] = parts[0].strip()
    return signed


def record():
    """The recorded digests, repository-relative path -> digest, in file order."""
    if not RECORD.is_file():
        return None
    recorded = {}
    for line in RECORD.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split(None, 1)
        if len(parts) == 2:
            recorded[parts[1].strip()] = parts[0].strip()
    return recorded


def record_headings():
    """Per-release counts the record states about itself, version -> (signed, recorded)."""
    if not RECORD.is_file():
        return {}
    stated = {}
    for line in RECORD.read_text(encoding="utf-8").splitlines():
        match = HEADING.match(line)
        if match:
            stated[match.group(1)] = (int(match.group(2)), int(match.group(3)))
    return stated


def ignorable():
    """Names release/.gitignore allows to appear without being published."""
    rules = RELEASE / ".gitignore"
    if not rules.is_file():
        return set()
    return set(line.strip() for line in rules.read_text(encoding="utf-8").splitlines()
               if line.strip() and not line.strip().startswith("#"))


def present(version):
    """Files on disk under a release, relative to it, minus ignorable names."""
    skip = ignorable()
    base = RELEASE / version
    return set("/".join(path.relative_to(base).parts)
               for path in base.rglob("*")
               if path.is_file() and path.name not in skip)


@row("payload-still-verifies",
     "a release directory is verifiable on its own, offline, by a recipient "
     "who has only it and sha256sum. That is the promise its SHA256SUMS makes, "
     "and it is checked here rather than assumed from having been true once")
def every_signed_file_still_hashes_to_its_listed_value():
    identifier = "payload-still-verifies"
    for version in versions():
        signed = payload_of(version)
        if signed is None:
            continue
        for name in sorted(signed):
            path = RELEASE / version / name
            if not counted(path.is_file(), identifier,
                           "release/%s/SHA256SUMS lists %s, which is gone; the "
                           "release no longer verifies from its own directory"
                           % (version, name)):
                continue
            counted(digest_of(path) == signed[name], identifier,
                    "release/%s/%s no longer hashes to the value its own signed "
                    "SHA256SUMS records" % (version, name))


@row("record-still-matches",
     "the evidence logs, QUALIFICATION, the manifests and the detached "
     "signatures are the account of what was run. They are not rebuildable "
     "from source, so if they change there is nothing to compare them against "
     "afterwards -- the record has to be kept ahead of the edit")
def every_recorded_file_still_matches():
    identifier = "record-still-matches"
    recorded = record()
    if not counted(recorded is not None, identifier,
                   "test/published_release_digests.txt is gone; nothing covers "
                   "the published files that no SHA256SUMS signs"):
        return
    for path in sorted(recorded):
        full = ROOT / path
        if not counted(full.is_file(), identifier,
                       "%s is recorded as published and is gone" % path):
            continue
        actual = digest_of(full)
        counted(actual == recorded[path], identifier,
                "%s differs from what was published (recorded %s, found %s)"
                % (path, recorded[path][:12], actual[:12]))


@row("every-published-file-is-covered-once",
     "a file protected by neither list is a published file that can be "
     "rewritten silently, and one protected by both invites the two to "
     "disagree. The two lists have to partition the directory, or the coverage "
     "claim is about whatever they happen to contain")
def the_two_lists_partition_each_release():
    identifier = "every-published-file-is-covered-once"
    recorded = record() or {}
    headings = record_headings()
    for version in versions():
        signed = payload_of(version)
        if not counted(signed is not None, identifier,
                       "release/%s has no SHA256SUMS, so nothing states which "
                       "of its files it signs for itself" % version):
            continue
        prefix = "release/%s/" % version
        mine = set(path[len(prefix):] for path in recorded if path.startswith(prefix))
        on_disk = present(version)

        for complaint, names in (
                ("appear in both the signed list and the record; two "
                 "authorities over one file can disagree", mine & set(signed)),
                ("are published and covered by neither that release's "
                 "SHA256SUMS nor the record", on_disk - mine - set(signed)),
                ("are covered but absent from the directory",
                 (mine | set(signed)) - on_disk)):
            counted(not names, identifier,
                    "release/%s: %s %s" % (version, ", ".join(sorted(names)),
                                           complaint))

        # The record states, per release, how many files that release signs for
        # itself. Without it, moving a payload file out of SHA256SUMS and into
        # the record leaves both lists internally consistent.
        stated = headings.get(version)
        if counted(stated is not None, identifier,
                   "the record has no header line for release/%s stating how "
                   "many files it signs" % version):
            counted(stated == (len(signed), len(mine)), identifier,
                    "release/%s signs %d files and has %d recorded; the record "
                    "says %d and %d"
                    % (version, len(signed), len(mine), stated[0], stated[1]))


@row("no-image-escapes-the-signed-list",
     "an image or programming helper covered only by this repository's record "
     "is not verifiable by the person holding the release. Payload belongs in "
     "the list the release ships and signs, whatever else is added to it")
def every_image_is_in_the_release_signed_list():
    identifier = "no-image-escapes-the-signed-list"
    for version in versions():
        signed = payload_of(version)
        if signed is None:
            continue
        for name in sorted(present(version)):
            if not name.endswith(".hex"):
                continue
            counted(name in signed, identifier,
                    "release/%s/%s is an image the release does not sign; a "
                    "recipient with only this directory cannot verify it"
                    % (version, name))


@row("amendments-are-on-the-record",
     "a published release may be amended -- a safety errata reaches a reader "
     "who fetched one directory and nothing else, and no other channel does. "
     "What must never happen is an amendment nobody can find later, so each "
     "one is named here with its reason and confined to files no verifier reads")
def the_recorded_amendments_are_intact_and_contained():
    identifier = "amendments-are-on-the-record"
    top = RELEASE / "README.md"
    if counted(top.is_file(), identifier, "release/README.md is gone"):
        counted(AMENDMENT_ANCHOR in top.read_text(encoding="utf-8"), identifier,
                "release/README.md no longer carries the %r heading the "
                "amendments link to; the errata still says to go there"
                % AMENDMENT_ANCHOR)

    carriers = set()
    for version, names in sorted(AMENDMENTS.items()):
        signed = payload_of(version) or {}
        for name in names:
            path = RELEASE / version / name
            if not counted(path.is_file(), identifier,
                           "release/%s/%s carried an amendment and is gone"
                           % (version, name)):
                continue
            carriers.add("%s/%s" % (version, name))
            text = path.read_text(encoding="utf-8")
            for marker in AMENDMENT_MARKERS:
                counted(marker in text, identifier,
                        "release/%s/%s no longer contains %r; the amendment was "
                        "reverted or reworded away" % (version, name, marker))
            counted(name not in signed, identifier,
                    "release/%s/%s is now signed by that release's SHA256SUMS. "
                    "The amendment was safe because it touched nothing a "
                    "verifier reads; this makes that false" % (version, name))

    # Confined: the errata describes three releases, so finding it in a fourth
    # means a published directory was amended without anyone recording it.
    for version in versions():
        for name in sorted(present(version)):
            if "%s/%s" % (version, name) in carriers:
                continue
            path = RELEASE / version / name
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            counted(AMENDMENT_MARKERS[1] not in text, identifier,
                    "release/%s/%s carries the TMUX errata and is not one of "
                    "the recorded amendments" % (version, name))


@row("the-tag-still-agrees",
     "the tag is the publication. Both lists in this tree are lists this tree "
     "keeps, and a rewrite thorough enough to update one could update the "
     "other; the signed tag is the one witness that a rewrite here cannot "
     "reach")
def each_release_matches_its_tag_except_where_recorded():
    identifier = "the-tag-still-agrees"
    global tags_compared, tags_absent
    for version in versions():
        expected = set(AMENDMENTS.get(version, ()))
        try:
            resolved = subprocess.run(
                ["git", "-C", str(ROOT), "rev-parse", "-q", "--verify",
                 "refs/tags/%s^{commit}" % version],
                capture_output=True, text=True)
        except (OSError, subprocess.SubprocessError):
            tags_absent.append(version)
            continue
        if resolved.returncode != 0:
            tags_absent.append(version)
            continue
        changed = subprocess.run(
            ["git", "-C", str(ROOT), "diff", "--name-only", "refs/tags/%s" % version,
             "--", "release/%s" % version],
            capture_output=True, text=True)
        if changed.returncode != 0:
            tags_absent.append(version)
            continue
        tags_compared.append(version)
        prefix = "release/%s/" % version
        differing = set(line[len(prefix):] for line in changed.stdout.split("\n")
                        if line.startswith(prefix))
        counted(not (differing - expected), identifier,
                "release/%s: %s differ from tag %s and are not recorded "
                "amendments"
                % (version, ", ".join(sorted(differing - expected)), version))
        counted(not (expected - differing), identifier,
                "release/%s: %s are recorded as amended but are identical to "
                "tag %s; the register describes an edit that is not there"
                % (version, ", ".join(sorted(expected - differing)), version))


@row("every-release-is-registered",
     "a release directory the record has never seen is one this gate cannot "
     "speak for, and silence about it would read exactly like coverage")
def the_directories_and_the_record_name_the_same_releases():
    identifier = "every-release-is-registered"
    recorded = record() or {}
    named = set(path.split("/")[1] for path in recorded
                if path.startswith("release/v") and path.count("/") >= 2)
    on_disk = set(versions())

    for version in sorted(on_disk - named):
        counted(False, identifier,
                "release/%s is published and appears nowhere in "
                "test/published_release_digests.txt; add its block with "
                "--print-record %s" % (version, version))
    for version in sorted(named - on_disk):
        counted(False, identifier,
                "the record covers release/%s, which is not in the tree; a "
                "published release was deleted" % version)
    for version in sorted(on_disk):
        for name in REQUIRED:
            counted((RELEASE / version / name).is_file(), identifier,
                    "release/%s has no %s" % (version, name))


def print_record(version):
    """Print the block to append for a release, computed from the tree."""
    signed = payload_of(version)
    if signed is None:
        print("no release/%s/SHA256SUMS: not a published release directory"
              % version, file=sys.stderr)
        return 1
    members = sorted(present(version))
    unsigned = [name for name in members if name not in signed]
    print("")
    print("# %s -- %d files signed by its own SHA256SUMS, %d recorded here"
          % (version, len(signed), len(unsigned)))
    for name in unsigned:
        print("%s  release/%s/%s"
              % (digest_of(RELEASE / version / name), version, name))
    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--print-record":
        raise SystemExit(print_record(sys.argv[2]))
    if len(sys.argv) != 1:
        print("usage: %s [--print-record vX.Y.Z]" % sys.argv[0], file=sys.stderr)
        raise SystemExit(2)

    for _, _, check in REGISTER:
        check()

    if FAILURES:
        claims = dict((identifier, claim) for identifier, claim, _ in REGISTER)
        print("FAIL: the published releases in this tree are not the ones that "
              "were published.", file=sys.stderr)
        for identifier in sorted(set(name for name, _ in FAILURES)):
            print("\n  %s" % identifier, file=sys.stderr)
            print("    what this holds up: %s" % claims[identifier], file=sys.stderr)
            for name, witness in FAILURES:
                if name == identifier and witness:
                    print("    - %s" % witness, file=sys.stderr)
        print("\nA published release is what its recipients already hold. If an "
              "amendment\nis genuinely intended, say what it is and why in this "
              "register first, then\nrecord it -- do not edit a digest until "
              "the run goes green.", file=sys.stderr)
        raise SystemExit(1)

    recorded = record() or {}
    signed = sum(len(payload_of(version) or {}) for version in versions())
    reach = ("tag cross-check ran for %d of %d"
             % (len(tags_compared), len(tags_compared) + len(tags_absent)))
    if tags_absent and not tags_compared:
        # The ordinary case in CI, which checks out shallow and without tags.
        # Said plainly rather than as a list of every release, so that a clone
        # which reaches SOME tags reads differently from one that reaches none.
        reach += " (no release tags in this clone)"
    elif tags_absent:
        reach += " (untagged here: %s)" % ", ".join(tags_absent)
    print("published release immutability: %d checks, 0 failures "
          "(%d releases, %d files signed by their own SHA256SUMS, %d recorded, "
          "%d recorded amendments, %s)"
          % (checks, len(versions()), signed, len(recorded),
             sum(len(names) for names in AMENDMENTS.values()), reach))


if __name__ == "__main__":
    main()
