#!/usr/bin/env python3
"""Run bounded development checks and retain command-level evidence."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tier", choices=["inner", "mid", "outer"])
    parser.add_argument("--module", help="EUnit module for the inner loop")
    args = parser.parse_args()
    if args.tier == "inner" and not args.module:
        parser.error("inner requires --module; use mid for the full unit suite")
    root = Path(__file__).resolve().parent.parent
    output = root / "_build/checks"
    output.mkdir(parents=True, exist_ok=True)
    budgets = {"inner": 5, "mid": 30, "outer": 300}
    commands = {
        "inner": [["rebar3", "eunit", "--module", args.module]],
        "mid": [
            ["escript", "tools/generate_schema.escript", "--check"],
            ["rebar3", "eunit"],
            ["git", "diff", "--check"],
        ],
        "outer": [
            ["rebar3", "compile"],
            ["python3", "test/helper_protocol.py"],
            ["python3", "test/ci_cache_tests.py"],
            ["rebar3", "dialyzer"],
            ["rebar3", "ct"],
            ["python3", "tools/check_package.py", "--dialyzer"],
        ],
    }[args.tier]
    started = time.monotonic()
    check_env = dict(os.environ)
    check_env.setdefault("ERL_FLAGS", "+S 4:4")
    results = []
    failed = False
    for index, command in enumerate(commands, start=1):
        remaining = budgets[args.tier] - (time.monotonic() - started)
        if remaining <= 0:
            failed = True
            results.append({"result": "FAIL", "reason": "loop_budget_exceeded"})
            break
        invocation = command if os.environ.get("GITHUB_ACTIONS") == "true" else ["mise", "exec", "--", *command]
        command_start = time.monotonic()
        process = subprocess.Popen(
            invocation, cwd=root, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, start_new_session=True, env=check_env
        )
        timed_out = False
        try:
            stdout, _ = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            stdout, _ = process.communicate()
        elapsed = time.monotonic() - command_start
        log = output / f"{args.tier}-{index}.log"
        log.write_bytes(stdout)
        passed = process.returncode == 0 and not timed_out
        result = {
            "command": invocation,
            "exit_status": process.returncode,
            "seconds": round(elapsed, 6),
            "result": "PASS" if passed else "FAIL",
            "timed_out": timed_out,
            "log": log.relative_to(root).as_posix(),
        }
        results.append(result)
        print(f"{result['result']} {elapsed:.3f}s {' '.join(invocation)}", flush=True)
        if not passed:
            print(stdout.decode(errors="replace"), flush=True)
            failed = True
            break
    elapsed = time.monotonic() - started
    failed = failed or elapsed >= budgets[args.tier]
    receipt = {
        "tier": args.tier,
        "result": "FAIL" if failed else "PASS",
        "budget_seconds": budgets[args.tier],
        "dispatch_seconds": round(elapsed, 6),
        "runtime_flags": check_env["ERL_FLAGS"],
        "commands": results,
        "scope": "Currently implemented checks; not the complete epic matrix",
    }
    (output / f"{args.tier}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
