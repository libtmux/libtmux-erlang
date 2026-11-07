#!/usr/bin/env python3
"""Compare portable regex fixtures against PCRE2, JavaScript and Rust engines."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import tomllib


def main():
    started = time.monotonic()
    env = dict(os.environ)
    env.setdefault("ERL_FLAGS", "+S 4:4")
    native = json.loads(subprocess.check_output(
        ["escript", "tools/regex_fixture.escript"], env=env, text=True, timeout=20))
    patterns = native["patterns"]
    expected = [str(case["expected"]).lower() for p in patterns for case in p["cases"]]
    commands = {
        "javascript": ["node", "tools/regex-conformance/javascript.mjs"],
        "rust": ["_build/regex-conformance/debug/libtmux-regex-conformance"],
    }
    engines = {}
    for engine, command in commands.items():
        payload = "".join(p[engine] + "\t" + case["subject"].encode().hex() + "\n"
                          for p in patterns for case in p["cases"])
        run = subprocess.run(command, input=payload, capture_output=True, text=True,
                             check=True, timeout=20)
        actual = run.stdout.splitlines()
        if actual != expected:
            differences = [(n, a, b) for n, (a, b) in enumerate(zip(actual, expected)) if a != b]
            raise AssertionError((engine, len(actual), len(expected), differences[:10]))
        engines[engine] = {"result": "PASS", "cases": len(actual)}
    lock = tomllib.loads(Path("tools/regex-conformance/Cargo.lock").read_text())
    fixture = Path("test/fixtures/regex-v1.json")
    receipt = {
        "result": "PASS", "patterns": len(patterns), "cases_per_engine": len(expected),
        "engines": engines, "pcre2": "PASS: all expected fixture results",
        "native_versions": {key: native[key] for key in ("otp", "erts", "pcre2")},
        "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
        "regex_crate": next(p["version"] for p in lock["package"] if p["name"] == "regex"),
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "seconds": round(time.monotonic() - started, 6),
        "scope": "Shared grammar renderers and backend matching; not other ports' public filter APIs",
    }
    out = Path("_build/checks/regex.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
