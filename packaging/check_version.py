#!/usr/bin/env python3
"""Check that every native client version source agrees.

Usage: check_version.py [TAG]

Without TAG, the Tauri configuration, Cargo manifest, Cargo lockfile, and
Flatpak metainfo (newest release entry) must name the same version. With TAG
(for example v0.2.0), that version must also equal TAG without its leading v.

Uses only the standard library so it runs on any runner's python3.
"""

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAURI = ROOT / "app/src-tauri/tauri.conf.json"
CARGO = ROOT / "app/src-tauri/Cargo.toml"
LOCK = ROOT / "app/src-tauri/Cargo.lock"
METAINFO = ROOT / "packaging/flatpak/io.github.adsouza.FeudHall.metainfo.xml"
PACKAGE = "feud-hall"
TAG = re.compile(r"v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)")


def tauri_version():
    return json.loads(TAURI.read_text())["version"]


def cargo_version():
    # The [package] table runs until the next table header.
    match = re.search(r"^\[package\]\n(.*?)(?=^\[|\Z)", CARGO.read_text(), re.M | re.S)
    version = match and re.search(r'^version\s*=\s*"([^"]+)"', match.group(1), re.M)
    return version.group(1) if version else None


def lock_version():
    for block in LOCK.read_text().split("[[package]]"):
        if re.search(rf'^name = "{re.escape(PACKAGE)}"$', block, re.M):
            version = re.search(r'^version = "([^"]+)"$', block, re.M)
            return version.group(1) if version else None
    return None


def metainfo_version():
    # AppStream lists releases newest first.
    release = ET.parse(METAINFO).getroot().find("releases/release")
    return release.get("version") if release is not None else None


def main(argv):
    if len(argv) > 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    sources = {
        str(TAURI.relative_to(ROOT)): tauri_version(),
        str(CARGO.relative_to(ROOT)): cargo_version(),
        f"{LOCK.relative_to(ROOT)} ({PACKAGE})": lock_version(),
        f"{METAINFO.relative_to(ROOT)} (newest release)": metainfo_version(),
    }
    problems = [f"{path}: no version found" for path, v in sources.items() if not v]
    versions = {v for v in sources.values() if v}
    if len(versions) > 1:
        problems.append("version sources disagree")

    if len(argv) == 2:
        tag = TAG.fullmatch(argv[1])
        if not tag:
            problems.append(f"tag {argv[1]!r} is not v<major>.<minor>.<patch>[-pre]")
        elif versions != {tag.group(1)}:
            problems.append(f"tag {argv[1]} does not match the client version")

    for path, version in sources.items():
        print(f"{version or '-':>12}  {path}")
    sys.stdout.flush()
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
