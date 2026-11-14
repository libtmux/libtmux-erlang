#!/usr/bin/env python3
"""Install the public Hex release in a clean consumer and execute its examples."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import time

from check_package import exercise_consumer, run
from check_release import validate_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    args = parser.parse_args()
    version = validate_version(args.version, None)
    root = Path(__file__).resolve().parent.parent
    started = time.monotonic()
    output = root / "_build/checks/hex-install.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"result": "UNVERIFIED", "version": version,
                                  "reason": "public installation started"}) + "\n")
    env = dict(os.environ)
    for key in ("ERL_LIBS", "TMUX", "TMUX_PANE", "REBAR_CONFIG", "HEX_API_KEY",
                "HEX_CDN", "HEX_UNSAFE_REGISTRY", "HEX_NO_VERIFY_REPO_ORIGIN",
                "HEX_TRUSTED_MIRROR_URL", "HEX_MIRROR_URL"):
        env.pop(key, None)
    env.setdefault("ERL_FLAGS", "+S 4:4")
    with tempfile.TemporaryDirectory(prefix="erlang-hex-consumer-") as directory:
        temp = Path(directory)
        consumer = temp / "consumer"
        consumer.mkdir()
        env.update(REBAR_GLOBAL_CONFIG_DIR=str(temp / "config"),
                   REBAR_CACHE_DIR=str(temp / "cache"),
                   REBAR_GLOBAL_CACHE_DIR=str(temp / "cache"))
        (consumer / "rebar.config").write_text(
            '{deps, [{libtmux_erlang, ' + json.dumps(version) + '}]}.\n')
        compile_result = run(["rebar3", "compile"], consumer, env)
        installed = consumer / "_build/default/lib/libtmux_erlang"
        if not (installed / "priv/tmux_owned_io").is_file():
            raise RuntimeError("public source installation did not build the helper")
        results = exercise_consumer(root, consumer, installed / "ebin")
    receipt = {"result": "PASS", "version": version,
               "source": "public hexpm registry; empty consumer and build cache",
               "compile": compile_result, "consumers": results,
               "temporary_consumer_removed": not temp.exists(),
               "seconds": round(time.monotonic() - started, 6)}
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
