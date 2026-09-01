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
from the signed list into the merely-recorded one. Nothing under release/ is a
symbolic link, because every check above reads content through the path and a
link to identical bytes elsewhere would satisfy all of them. Where tags are present the
tag tree is compared directly, an independent opinion on the same claim that
owes nothing to either list.

CONTINUITY IS DECLARED TOO. Every release republishes the whole canonical image
set, unchanged bytes included, so that nobody needs an older release to assemble
a complete one. That makes repeated bytes ordinary here -- five releases
republished every image they inherited -- and ordinary is what makes them
invisible: a build that restaged its predecessor's images instead of producing
its own would publish, verify and reproduce perfectly. So what each release did
to the images it inherited is declared below and recomputed from the two signed
lists. The newest release is the one exception, and it is a timing exception
rather than a hole: its counts cannot exist in any commit that publishes it, so
its declaration is due before the NEXT release is cut, and that release cannot
pass this gate without it.

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
VERSION_TEXT = (r"v[0-9]+\.[0-9]+\.[0-9]+"
                r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")
VERSION = re.compile(r"^%s$" % VERSION_TEXT)
HEADING = re.compile(r"^#\s*(%s)\s*--\s*(\d+) files signed by its own "
                     r"SHA256SUMS, (\d+) recorded here\s*$" % VERSION_TEXT)

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

# What each release did to the images the one before it published: how many of
# the shared names it republished byte for byte, how many it rebuilt, and why.
# Recomputed on every run from the two signed lists, so a release that restaged
# bytes it did not build has to say so here before this gate will pass.
# <version>: (republished unchanged, rebuilt, why)
IMAGE_CONTINUITY = {
    "v0.9.1": (0, 20, "every image was rebuilt"),
    "v0.9.2": (15, 5, "only the five PIC10F322 images changed, by that part's "
                      "16 MHz to 2 MHz core clock drop"),
    "v0.9.3": (12, 0, "the TMUX4053 polarity errata withdrew the eight _tmux "
                      "variants rather than rebuilding them, and the twelve "
                      "that remained were republished untouched"),
    "v0.9.4": (6, 6, "the three PIC10F322 images and the three Classic AVR "
                     "mute images changed"),
    "v0.9.5": (0, 12, "every image was rebuilt"),
    "v0.9.6": (12, 0, "ATtiny202 and PIC10F320 joined the release set; the "
                      "twelve images already in it were republished untouched"),
    "v0.9.7": (18, 0, "a test and release-tooling release: no firmware image "
                      "changed"),
    "v0.9.8": (0, 0, "every image was renamed, so this release shares no image "
                     "name with the one before it. That the contents survived "
                     "the rename was proved at the time by a one-shot verifier, "
                     "and its signed report is published in this release"),
    "v0.9.9": (18, 0, "PIC12F675 joined the release set; the eighteen images "
                      "already in it were republished untouched"),
    "v0.9.10": (2, 19, "nineteen images changed; the two PIC10F320 cd4053 "
                       "images did not"),
    "v0.9.11": (21, 0, "v0.9.10 was tagged and never published -- its own gate "
                       "refused the environment CI ran it in, after tag CI had "
                       "already rebuilt all 21 images from the tagged source "
                       "and confirmed they reproduced bit for bit. Identical "
                       "bytes under a release that could be published is the "
                       "whole purpose of this one"),
}


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


def release_directory_names():
    """Directory names that claim to be releases, before syntax validation."""
    if not RELEASE.is_dir():
        return []
    return [entry.name for entry in RELEASE.iterdir()
            if entry.is_dir() and entry.name.startswith("v")]


def version_order(name):
    """Deterministic release precedence, including prerelease identifiers."""
    if not VERSION.fullmatch(name):
        raise ValueError("invalid release version: %s" % name)
    core, separator, prerelease = name[1:].partition("-")
    major, minor, patch = (int(part) for part in core.split("."))
    if not separator:
        # A final release follows every prerelease with the same numeric core.
        return major, minor, patch, 1, (), name

    identifiers = []
    for identifier in re.split(r"[.-]", prerelease):
        if identifier.isdigit():
            # Numeric identifiers precede textual ones. Length and spelling
            # break ties admitted by this project's version grammar (01/1).
            identifiers.append((0, int(identifier), len(identifier), identifier))
        else:
            identifiers.append((1, identifier))
    # VERSION accepts both dot and hyphen separators inside the prerelease.
    # The original name is therefore the final tiebreak for equivalent token
    # sequences such as rc.1 and rc-1.
    return major, minor, patch, 0, tuple(identifiers), name


def versions():
    """Valid release directories on disk, oldest first."""
    found = [name for name in release_directory_names()
             if VERSION.fullmatch(name)]
    return sorted(found, key=version_order)


@row("release-directory-names-are-valid",
     "a directory whose name claims to be a release must have deterministic "
     "release precedence. Silently sorting malformed names last can give one "
     "the newest-release continuity exemption")
def release_directory_names_are_valid():
    identifier = "release-directory-names-are-valid"
    for name in sorted(release_directory_names()):
        counted(VERSION.fullmatch(name), identifier,
                "release/%s is not a valid release directory name" % name)


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


def entries(base):
    """Every path under a directory -- links included, and never followed.

    os.walk with followlinks=False reports a symlinked directory once, in its
    parent's listing, and does not descend through it, so a link substituted
    for a whole evidence tree is one entry here rather than a walk into
    somewhere else. A dangling link is reported too, which rglob's is_file()
    would drop silently.
    """
    found = []
    for parent, directories, files in os.walk(base, followlinks=False):
        for name in sorted(directories) + sorted(files):
            found.append(Path(parent) / name)
    return found


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


@row("no-published-file-is-a-link",
     "the two rows above read content through the path, so an image replaced "
     "by a link to identical bytes elsewhere satisfies both of them and the "
     "record as well. What was published was a file; a link is a different "
     "object, resolved when someone reads it, against a tree that can change "
     "after this gate has gone green. Publication already refuses symlinked "
     "assets, inventories and signatures -- this holds the published tree to "
     "the same rule afterwards, which is where it was not being held")
def nothing_under_release_is_a_link():
    identifier = "no-published-file-is-a-link"
    for path in sorted(entries(RELEASE)):
        target = os.readlink(path) if path.is_symlink() else None
        counted(target is None, identifier,
                "release/%s is a symbolic link to %s, not the file that was "
                "published" % ("/".join(path.relative_to(RELEASE).parts),
                               target))


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


def record_block(version):
    """Return the canonical block appended for one release."""
    if not VERSION.fullmatch(version):
        raise ValueError("invalid release version: %s" % version)
    signed = payload_of(version)
    if signed is None:
        raise ValueError(
            "no release/%s/SHA256SUMS: not a published release directory"
            % version)
    members = sorted(present(version))
    unsigned = [name for name in members if name not in signed]
    lines = ["", "# %s -- %d files signed by its own SHA256SUMS, %d recorded here"
             % (version, len(signed), len(unsigned))]
    for name in unsigned:
        lines.append("%s  release/%s/%s"
                     % (digest_of(RELEASE / version / name), version, name))
    return "\n".join(lines) + "\n"


def print_record(version):
    """Print the block to append for a release, computed from the tree."""
    try:
        block = record_block(version)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    if version in record_headings():
        print("release/%s is already registered" % version, file=sys.stderr)
        return 1
    sys.stdout.write(block)
    return 0


def verify_record_append(version):
    """Verify RECORD is the parent bytes plus one canonical release block."""
    try:
        block = record_block(version).encode("utf-8")
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    parent = sys.stdin.buffer.read()
    try:
        parent_text = parent.decode("utf-8")
    except UnicodeDecodeError:
        print("parent publication registry is not UTF-8", file=sys.stderr)
        return 1
    if any(match and match.group(1) == version
           for match in (HEADING.match(line)
                         for line in parent_text.splitlines())):
        print("parent publication registry already names release/%s" % version,
              file=sys.stderr)
        return 1
    if not RECORD.is_file() or RECORD.is_symlink():
        print("publication registry is missing or not a regular file",
              file=sys.stderr)
        return 1
    if RECORD.read_bytes() != parent + block:
        print("publication registry is not the parent bytes plus the exact "
              "canonical block for release/%s" % version, file=sys.stderr)
        return 1
    print("publication registration: exact append for release/%s" % version)
    return 0


@row("image-continuity-is-declared",
     "a release republishes every canonical image, the unchanged ones "
     "included, so that no recipient needs an older release to hold a complete "
     "one. That policy makes repeated bytes ordinary, which is precisely what "
     "makes them invisible: a build that restaged its predecessor's images "
     "instead of producing its own would publish, verify and reproduce "
     "perfectly, and every gate in this file would pass. Declaring the "
     "relation is what separates a deliberate republication from an accident")
def image_continuity_is_declared():
    identifier = "image-continuity-is-declared"
    published = versions()
    for previous, version in zip(published, published[1:]):
        declared = IMAGE_CONTINUITY.get(version)
        # The newest release must not be REQUIRED to carry a declaration, and
        # is still checked against one when it has it. Its counts are not known
        # until its images are built, and the commit that publishes them may
        # change only release/<version>/ plus the one canonical append to the
        # publication registry -- so no commit exists in which its declaration
        # could land, and a release under construction would fail this gate
        # with nothing its author could do about it. That is the same defect as
        # a gate no prospective release can pass, which is what makes it worth
        # spelling out rather than special-casing quietly. The declaration is
        # owed by the time the next release is cut: at that point this release
        # is no longer the newest, and the next release's own source commit
        # cannot go green without it.
        if declared is None and version == published[-1]:
            continue
        if not counted(declared is not None, identifier,
                       "%s inherits images from %s and declares nothing about "
                       "them. Say how many it republished byte for byte, how "
                       "many it rebuilt, and why" % (version, previous)):
            continue
        before, after = payload_of(previous), payload_of(version)
        if not counted(before is not None and after is not None, identifier,
                       "%s or %s has no signed list, so the images they share "
                       "cannot be compared" % (previous, version)):
            continue
        # The comparison is between the two SIGNED lists rather than the files
        # on disk: those digests are what each release published about itself,
        # and the rows above already hold the directories to them.
        shared = [name for name in sorted(after)
                  if name.endswith(".hex") and name in before]
        identical = sum(1 for name in shared if after[name] == before[name])
        counted((identical, len(shared) - identical) == declared[:2], identifier,
                "%s republished %d of %s's images unchanged and rebuilt %d; the "
                "declaration here says %d and %d. Reconcile it: an unexpected "
                "republication is a build that staged bytes it did not produce"
                % (version, identical, previous, len(shared) - identical,
                   declared[0], declared[1]))
        counted(bool(declared[2].strip()), identifier,
                "%s declares its continuity counts with no reason, which "
                "records the arithmetic and not the decision" % version)

    orphans = sorted(set(IMAGE_CONTINUITY) - set(published[1:]))
    counted(not orphans, identifier,
            "%s is declared here but is not a published release with a "
            "predecessor" % ", ".join(orphans))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--print-record":
        raise SystemExit(print_record(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-record-append":
        raise SystemExit(verify_record_append(sys.argv[2]))
    if len(sys.argv) != 1:
        print("usage: %s [--print-record vX.Y.Z | "
              "--verify-record-append vX.Y.Z]" % sys.argv[0], file=sys.stderr)
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
    continuity = "%d declared image continuities" % len(IMAGE_CONTINUITY)
    published = versions()
    if len(published) > 1 and published[-1] not in IMAGE_CONTINUITY:
        # Exempting the newest release defers the declaration; it does not
        # cancel it, and this is the one moment the debt is invisible -- the
        # run is green and the release just published has said nothing about
        # the images it inherited. Name it here, so the operator who published
        # it is told rather than whoever cuts the next release finding out.
        continuity += " (%s owes one)" % published[-1]
    print("published release immutability: %d checks, 0 failures "
          "(%d releases, %d files signed by their own SHA256SUMS, %d recorded, "
          "%d recorded amendments, %s, %s)"
          % (checks, len(published), signed, len(recorded),
             sum(len(names) for names in AMENDMENTS.values()),
             continuity, reach))


if __name__ == "__main__":
    main()
