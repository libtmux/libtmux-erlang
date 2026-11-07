#!/usr/bin/env python3
"""Build or validate an exact, owned CI tmux installation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def output(args: list[str]) -> str:
    return subprocess.check_output(args, text=True).strip()


def identity(version: str) -> dict:
    pins = json.loads(Path(__file__).with_name("tmux-sources.json").read_text())["versions"]
    if version not in pins:
        raise ValueError("tmux version has no reviewed source pin")
    image = [os.environ.get(key, "local") for key in ["ImageOS", "ImageVersion"]]
    return {
        "version": version, "source": pins[version], "image": image,
        "architecture": platform.machine(), "compiler": output(["cc", "--version"]),
        "packages": output(["dpkg-query", "-W", "-f=${Package}=${Version}\n",
            "gcc", "libc6", "libevent-dev", "libncurses-dev", "bison", "pkg-config"]),
        "recipe": digest(Path(__file__)),
        "flags": {"CFLAGS": "-O2", "CPPFLAGS": "", "LDFLAGS": "", "MAKEFLAGS": ""},
    }


def valid(prefix: Path, expected: dict) -> bool:
    binary = prefix / "bin/tmux"
    if prefix.is_symlink() or binary.parent.is_symlink() or binary.is_symlink():
        return False
    try:
        record = json.loads((prefix / "build.json").read_text())
        if record != {"identity": expected, "binary_sha256": digest(binary)}:
            return False
        result = subprocess.run([str(binary), "-V"], check=True, capture_output=True,
                                text=True, timeout=1)
        return result.stdout.strip() == "tmux " + expected["version"]
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def build(prefix: Path, expected: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="tmux-source-", dir=prefix.parent) as directory:
        work = Path(directory)
        archive = work / "source.tar.gz"
        pin = expected["source"]
        with urllib.request.urlopen(pin["url"], timeout=60) as response:
            with archive.open("wb") as destination:
                shutil.copyfileobj(response, destination)
        if digest(archive) != pin["archive_sha256"]:
            raise ValueError("tmux archive differs from its pinned SHA256")
        with tarfile.open(archive) as bundle:
            bundle.extractall(work, filter="data")
        source = work / ("tmux-" + expected["version"])
        env = dict(os.environ, **expected["flags"], CC="cc")
        subprocess.run(["./configure", f"--prefix={prefix}"], cwd=source, env=env, check=True)
        subprocess.run(["make", "-j2"], cwd=source, env=env, check=True)
        subprocess.run(["make", "install"], cwd=source, env=env, check=True)


def prepare(prefix: Path, expected: dict) -> bool:
    if valid(prefix, expected):
        print("Validated exact tmux cache", flush=True)
        return False
    if prefix.is_symlink():
        prefix.unlink()
    elif prefix.exists():
        shutil.rmtree(prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    build(prefix, expected)
    binary = prefix / "bin/tmux"
    record = {"identity": expected, "binary_sha256": digest(binary)}
    (prefix / "build.json").write_text(json.dumps(record, sort_keys=True) + "\n")
    if not valid(prefix, expected):
        (prefix / "build.json").unlink()
        raise RuntimeError("new tmux installation failed version/runtime validation")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["plan", "prepare"])
    parser.add_argument("version")
    args = parser.parse_args()
    expected = identity(args.version)
    key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()
    root = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())).resolve() / "libtmux-erlang-tmux"
    prefix = root / ("tmux-" + args.version)
    if args.phase == "plan":
        print(json.dumps(expected, indent=2))
        if destination := os.environ.get("GITHUB_OUTPUT"):
            with Path(destination).open("a") as stream:
                stream.write(f"prefix={prefix}\nkey=tmux-v1-{key}\n")
        return
    rebuilt = prepare(prefix, expected)
    if rebuilt and os.environ.get("CACHE_HIT") == "true":
        print("::warning::Rejected exact cache rebuilt; change the recipe to replace the immutable cache entry")
    if destination := os.environ.get("GITHUB_ENV"):
        with Path(destination).open("a") as stream:
            stream.write(f"LIBTMUX_TEST_TMUX={prefix}/bin/tmux\n")


if __name__ == "__main__":
    main()
