#!/usr/bin/env python3
"""Outer check: instrumented helper lifecycle tests and bounded parser fuzzing."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import time


def frame(body: bytes) -> bytes:
    return struct.pack(">H", len(body)) + body


def seeds() -> list[bytes]:
    def string(value):
        return struct.pack(">H", len(value)) + value

    opening = (b"O\x04\x01" + struct.pack(">I", 900) + string(b"/tmp")
               + struct.pack(">H", 1) + string(b"/bin/true") + b"\x00\x00")
    bodies = [opening, b"Q", b"C", b"T", b"R\x01\x20\x00",
              b"R\x02\x20\x01", b"W\x00\x00\x00\x01hello"]
    wires = [frame(body) for body in bodies]
    wires += [frame(opening[:cut]) for cut in (0, 1, 6, 8, 12, len(opening) - 1)]
    wires += [b"\x00", b"\x00\x00", b"\x80\x01", b"\xff\xff",
              frame(b"W\x00\x00\x00\x01" + b"x" * 8192),
              frame(b"W\x00\x00\x00\x01" + b"x" * 8193),
              frame(b"R\x01\x20\x00") * 2, frame(b"C") * 2,
              frame(b"x" * 32768)]
    return [bytes([mode, fragment]) + wire
            for mode in range(4) for fragment in (0, 255) for wire in wires]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang-18")
    parser.add_argument("--runs", type=int, default=10000)
    args = parser.parse_args()
    if not 1000 <= args.runs <= 100000:
        parser.error("runs must be between 1000 and 100000")
    root = Path(__file__).resolve().parent.parent
    output = root / "_build/checks/helper-native"
    output.mkdir(parents=True, exist_ok=True)
    attempt = output / f"run-{time.time_ns()}"
    attempt.mkdir()
    receipt_path = output / "receipt.json"
    receipt_path.unlink(missing_ok=True)
    started = time.monotonic()
    flags = ["-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
             "-fno-sanitize-recover=all", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic"]
    env = dict(os.environ,
               ASAN_OPTIONS=f"detect_leaks=1:abort_on_error=1:log_path={attempt}/asan",
               UBSAN_OPTIONS=f"halt_on_error=1:print_stacktrace=1:log_path={attempt}/ubsan")
    for key in ("TMUX", "TMUX_PANE"):
        env.pop(key, None)
    receipt = {"result": "FAIL", "scope": "Helper ASan/UBSan lifecycle and parser fuzzing",
               "attempt": attempt.relative_to(root).as_posix(),
               "platform": platform.platform(), "machine": platform.machine(),
               "runs_requested": args.runs, "seed": 20261108, "commands": [],
               "source_sha256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                   for name in ("apps/libtmux_erlang/c_src/owned_io.c", "test/helper_fuzz.c",
                                "test/helper_protocol.py", "tools/check_helper_native.py")}}

    def run(command, limit=30):
        before = time.monotonic()
        timed_out = False
        try:
            result = subprocess.run(command, cwd=root, env=env, capture_output=True,
                                    text=True, timeout=limit)
            code, text = result.returncode, result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            timed_out = True
            code = 124
            text = (error.stdout or b"").decode(errors="replace")
            text += (error.stderr or b"").decode(errors="replace")
        log = attempt / f"command-{len(receipt['commands']) + 1}.log"
        log.write_text(text)
        elapsed = time.monotonic() - before
        receipt["commands"].append({"command": command, "seconds": elapsed,
                                    "exit_status": code, "timed_out": timed_out,
                                    "log": log.relative_to(root).as_posix()})
        if code:
            if timed_out:
                receipt["owned_cleanup"] = "UNVERIFIED after forced check-runner timeout"
            raise RuntimeError(text[-6000:] or f"command failed: {command}")
        return text

    try:
        receipt["compiler"] = run([args.cc, "--version"]).splitlines()[0]
        with tempfile.TemporaryDirectory(prefix="tmux-erlang-native-") as directory:
            temporary = Path(directory)
            helper, fuzzer = temporary / "helper", temporary / "fuzz"
            run([args.cc, *flags, "apps/libtmux_erlang/c_src/owned_io.c", "-o", str(helper)])
            env.update(LIBTMUX_TEST_HELPER=str(helper), LIBTMUX_TEST_CC=args.cc,
                       LIBTMUX_TEST_CFLAGS=" ".join(flags))
            run([sys.executable, "test/helper_protocol.py"])
            run([args.cc, *flags, "-fsanitize=fuzzer", "test/helper_fuzz.c", "-o", str(fuzzer)])
            corpus = temporary / "corpus"
            corpus.mkdir()
            initial = seeds()
            for value in initial:
                (corpus / hashlib.sha256(value).hexdigest()).write_bytes(value)
            receipt["seed_corpus_sha256"] = hashlib.sha256(b"".join(sorted(initial))).hexdigest()
            receipt["generated_seed_cases"] = len(initial)
            receipt["initial_corpus_files"] = sum(1 for _ in corpus.iterdir())
            log = run([str(fuzzer), str(corpus), f"-runs={args.runs}", "-seed=20261108",
                       "-max_len=65540", "-timeout=1", "-rss_limit_mb=256",
                       f"-artifact_prefix={attempt}/"])
            if f"Done {args.runs} runs" not in log:
                raise RuntimeError("fuzzer did not complete the requested run count")
            receipt["corpus_cases_after"] = sum(1 for _ in corpus.iterdir())
            receipt["fuzz_scope"] = ("Real read_parent/launch/input_packet with fragmented reads and EOF; "
                                     "fork returns EAGAIN, so fuzz input never executes a child. "
                                     "Separate instrumented protocol tests exercise actual owned children.")
        receipt["temporary_files_removed"] = not temporary.exists()
        receipt["result"] = "PASS"
    except (OSError, RuntimeError) as error:
        receipt["error"] = str(error)
    finally:
        receipt["seconds"] = time.monotonic() - started
        document = json.dumps(receipt, indent=2) + "\n"
        (attempt / "receipt.json").write_text(document)
        receipt_path.write_text(document)
    print(json.dumps(receipt, indent=2))
    raise SystemExit(0 if receipt["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
