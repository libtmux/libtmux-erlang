#!/usr/bin/env python3
"""Validate a clean release checkout and the exact public Hex source artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

APP = "libtmux_erlang"
ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
                    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def validate_version(version: str, tag: str | None) -> str:
    match = SEMVER.fullmatch(version)
    if not match or (match[4] and any(p.isdigit() and len(p) > 1 and p[0] == "0"
                                    for p in match[4].split("."))):
        raise ValueError("release version must be SemVer without build metadata")
    if tag is not None and tag != "v" + version:
        raise ValueError("tag must exactly match v" + version)
    return version


def validate_checkout(root: Path, tag: str | None) -> str:
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("release requires a clean checkout")
    head = git("rev-parse", "HEAD")
    if tag is not None and git("rev-parse", "refs/tags/" + tag + "^{commit}") != head:
        raise ValueError("release tag must point to HEAD")
    return head


def published_artifact(version: str, expected: bytes) -> bool:
    """Only HTTP 404 means absent; an existing different payload is an error."""
    url = f"https://repo.hex.pm/tarballs/{APP}-{version}.tar"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            actual = response.read(16 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    if actual != expected:
        raise ValueError("public Hex artifact differs from the qualified source package")
    return True


def validate_qualification(proof: dict, head: str, sha256: str) -> None:
    if (proof["result"] != "PASS" or proof["source"]["head"] != head
            or proof["source"]["status"]
            or proof["packages"][APP]["sha256"] != sha256):
        raise ValueError("artifact does not match clean native CI qualification")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="required exact vVERSION tag for publication")
    parser.add_argument("--artifact", type=Path, help="compare this tarball with public Hex")
    parser.add_argument("--qualified-receipt", type=Path, help="bind tarball to native CI")
    parser.add_argument("--require-published", action="store_true")
    args = parser.parse_args()
    metadata = (ROOT / f"apps/{APP}/src/{APP}.app.src").read_text()
    match = re.search(r'\{vsn,\s*"([^"\n]+)"\}', metadata)
    if not match:
        parser.error("missing literal application version")
    version = validate_version(match[1], args.tag)
    head = validate_checkout(ROOT, args.tag)
    result = {"version": version, "head": head}
    if args.qualified_receipt and not args.artifact:
        parser.error("--qualified-receipt requires --artifact")
    if args.artifact:
        expected = args.artifact.read_bytes()
        result["sha256"] = hashlib.sha256(expected).hexdigest()
        if args.qualified_receipt:
            proof = json.loads(args.qualified_receipt.read_text())
            validate_qualification(proof, head, result["sha256"])
        result["published"] = published_artifact(version, expected)
        if args.require_published and not result["published"]:
            raise ValueError("release not public on Hex; check staged approval before retrying")
    elif args.require_published:
        parser.error("--require-published requires --artifact")
    print(json.dumps(result, indent=2))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key, value in result.items():
                stream.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")


if __name__ == "__main__":
    main()
