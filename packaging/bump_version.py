#!/usr/bin/env python3
"""Release a new native client version: bump every version source, commit,
tag, and push.

Usage: bump_version.py VERSION [--date YYYY-MM-DD] [--files-only]

VERSION is <major>.<minor>.<patch>[-pre], with or without a leading v, and
must be newer than the current version. The four sources must agree before
the bump (see check_version.py). The script updates:

  app/src-tauri/tauri.conf.json   "version"
  app/src-tauri/Cargo.toml        [package] version
  app/src-tauri/Cargo.lock        the feud-hall package entry
  packaging/flatpak/...metainfo   a new newest <release> entry, dated --date
                                  (default: today); a pre-release is marked
                                  type="development"

Edits are textual so each file keeps its formatting. Nothing is written
unless every edit applies, and check_version.py runs afterwards.

By default it then commits the bump on main, creates the annotated tag
v<VERSION>, and pushes main and the tag to origin in one atomic push, which
starts the native workflow's draft release. Before editing anything it
requires: the main branch checked out, a clean working tree, local main not
behind or diverged from origin/main, and no existing v<VERSION> tag locally
or on origin. Any unpushed commits already on main are pushed too.

--files-only edits the files and stops, for a bump that goes through a pull
request; tag the merged commit on main afterwards.
"""

import argparse
import datetime
import re
import subprocess
import sys

import check_version as cv

VERSION = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")
BRANCH = "main"
REMOTE = "origin"


def precedence(version):
    """A sort key following SemVer 2.0 precedence (build metadata unsupported)."""
    major, minor, patch, pre = VERSION.fullmatch(version).groups()
    if pre is None:
        # A release ranks above any of its pre-releases.
        return (int(major), int(minor), int(patch), 1, ())
    # Numeric identifiers compare numerically and rank below alphanumeric ones.
    ids = tuple((0, int(i), "") if i.isdigit() else (1, 0, i) for i in pre.split("."))
    return (int(major), int(minor), int(patch), 0, ids)


def replace_once(text, pattern, replacement, what, flags=0):
    new, count = re.subn(pattern, replacement, text, flags=flags)
    if count != 1:
        raise SystemExit(f"error: expected one {what}, found {count}")
    return new


def edits(old, new, date):
    q_old = re.escape(old)
    tauri = replace_once(
        cv.TAURI.read_text(),
        rf'^(  "version":\s*)"{q_old}"',
        rf'\g<1>"{new}"',
        "top-level version in tauri.conf.json",
        re.M,
    )
    cargo = replace_once(
        cv.CARGO.read_text(),
        rf'(^\[package\]\n(?:(?!^\[).*\n)*?^version\s*=\s*)"{q_old}"',
        rf'\g<1>"{new}"',
        "[package] version in Cargo.toml",
        re.M,
    )
    lock = replace_once(
        cv.LOCK.read_text(),
        rf'(^name = "{re.escape(cv.PACKAGE)}"\nversion = )"{q_old}"',
        rf'\g<1>"{new}"',
        f"{cv.PACKAGE} entry in Cargo.lock",
        re.M,
    )
    kind = ' type="development"' if "-" in new else ""
    metainfo = replace_once(
        cv.METAINFO.read_text(),
        r"^(?P<indent>[ \t]*)<releases>\n",
        rf'\g<0>\g<indent>  <release version="{new}" date="{date}"{kind}/>\n',
        "<releases> element in the metainfo",
        re.M,
    )
    return {cv.TAURI: tauri, cv.CARGO: cargo, cv.LOCK: lock, cv.METAINFO: metainfo}


def git(*args, capture=True):
    result = subprocess.run(
        ["git", *args], cwd=cv.ROOT, text=True, capture_output=capture
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        raise SystemExit(f"error: git {' '.join(args)} failed" + (f":\n{detail}" if detail else ""))
    return result.stdout.strip() if capture else ""


def check_git_ready(tag):
    """Refuse before any edit unless the commit, tag, and push can all proceed."""
    branch = git("branch", "--show-current")
    if branch != BRANCH:
        raise SystemExit(f"error: check out {BRANCH} first (on {branch or 'a detached HEAD'}), or use --files-only")
    if git("status", "--porcelain"):
        raise SystemExit("error: the working tree has uncommitted changes; commit or stash them first")
    git("fetch", "--quiet", REMOTE, BRANCH)
    upstream = f"{REMOTE}/{BRANCH}"
    behind = git("rev-list", "--count", f"HEAD..{upstream}")
    if behind != "0":
        raise SystemExit(f"error: {BRANCH} is {behind} commit(s) behind {upstream}; pull first")
    ahead = git("rev-list", "--count", f"{upstream}..HEAD")
    if git("tag", "--list", tag):
        raise SystemExit(f"error: tag {tag} already exists locally")
    if git("ls-remote", "--tags", REMOTE, f"refs/tags/{tag}"):
        raise SystemExit(f"error: tag {tag} already exists on {REMOTE}")
    return int(ahead)


def commit_tag_push(old, new, tag):
    paths = [str(p.relative_to(cv.ROOT)) for p in (cv.TAURI, cv.CARGO, cv.LOCK, cv.METAINFO)]
    git("add", "--", *paths)
    git("commit", "--quiet", "-m", f"Release {tag}", "-m", f"Bump the native client version from {old} to {new}.")
    git("tag", "--annotate", tag, "-m", f"Feud Hall {tag}")
    print(f"\nCommitted and tagged {tag}; pushing {BRANCH} and {tag} to {REMOTE}...", flush=True)
    result = subprocess.run(
        ["git", "push", "--atomic", REMOTE, f"refs/heads/{BRANCH}", f"refs/tags/{tag}"], cwd=cv.ROOT
    )
    if result.returncode != 0:
        print(
            f"\nerror: the push failed, so nothing reached {REMOTE}. The commit and tag are local.\n"
            f"  retry:  git push --atomic {REMOTE} refs/heads/{BRANCH} refs/tags/{tag}\n"
            f"  undo:   git tag -d {tag} && git reset --hard HEAD~1",
            file=sys.stderr,
        )
        return 1
    print(f"\nPushed. The native packages run for {tag} drafts the GitHub Release.")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("version", help="new version, for example 0.2.0 or v0.2.0-rc.1")
    parser.add_argument("--date", help="metainfo release date (default: today)")
    parser.add_argument("--files-only", action="store_true", help="edit the files only: no commit, tag, or push")
    args = parser.parse_args(argv[1:])

    if not VERSION.fullmatch(args.version):
        raise SystemExit(f"error: {args.version!r} is not <major>.<minor>.<patch>[-pre]")
    new = args.version.removeprefix("v")
    tag = f"v{new}"
    try:
        date = datetime.date.fromisoformat(args.date) if args.date else datetime.date.today()
    except ValueError:
        raise SystemExit(f"error: --date {args.date!r} is not YYYY-MM-DD")

    current = {cv.tauri_version(), cv.cargo_version(), cv.lock_version(), cv.metainfo_version()}
    if len(current) != 1 or None in current:
        cv.main([argv[0]])
        raise SystemExit("error: version sources disagree; fix them before bumping")
    (old,) = current
    if not VERSION.fullmatch(old):
        raise SystemExit(f"error: current version {old!r} is not <major>.<minor>.<patch>[-pre]")
    if precedence(new) <= precedence(old):
        raise SystemExit(f"error: {new} is not newer than the current version {old}")

    ahead = 0 if args.files_only else check_git_ready(tag)

    # Build every edit before writing any file.
    for path, text in edits(old, new, date.isoformat()).items():
        path.write_text(text)

    print(f"Bumped {old} -> {new}")
    if cv.main([argv[0], tag]) != 0:
        return 1
    if args.files_only:
        print(f"\nNext: merge this bump, then tag the merge commit as {tag}.")
        return 0
    if ahead:
        print(f"\nNote: {BRANCH} already has {ahead} unpushed commit(s); they are pushed with the release.")
    return commit_tag_push(old, new, tag)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
