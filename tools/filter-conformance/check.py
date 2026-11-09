#!/usr/bin/env python3
"""Compare unchanged fixtures through pinned filter and selection APIs."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

ELIXIR_REVISION = "a740a1308e51e5e975d4239e0e017efacf4cb169"
ROOT = Path(__file__).resolve().parents[2]


def prepare_owner():
    children = Path(f"/proc/self/task/{os.getpid()}/children")
    children.read_text()
    if not hasattr(os, "pidfd_open"):
        raise RuntimeError("command retirement requires Linux pidfd support")
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, *([ctypes.c_ulong] * 4)]
    libc.prctl.restype = ctypes.c_int
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)

    def terminate(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    return children


def retire(process, children):
    deadline = time.monotonic() + 1
    if process.returncode is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=max(0, deadline - time.monotonic()))
    # Reaped command leaders can leave adopted children, including new sessions.
    while pending := children.read_text().split():
        descriptors = {}
        poller = select.poll()
        try:
            for value in pending:
                pid = int(value)
                descriptor = os.pidfd_open(pid)
                descriptors[descriptor] = pid
                poller.register(descriptor, select.POLLIN)
                os.kill(pid, signal.SIGKILL)
            while descriptors:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("owned command cleanup did not complete")
                for descriptor, _ in poller.poll(max(1, int(remaining * 1000))):
                    pid = descriptors[descriptor]
                    os.waitpid(pid, 0)
                    poller.unregister(descriptor)
                    os.close(descriptor)
                    del descriptors[descriptor]
        finally:
            for descriptor in descriptors:
                os.close(descriptor)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def owned(command, children, **options):
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    process = None
    # Restore child cancellation signals without a Python preexec_fn after fork.
    launcher = "\n".join((
        "import os, signal, sys",
        "signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM})",
        "os.execvp(sys.argv[1], sys.argv[1:])",
    ))
    try:
        process = subprocess.Popen(
            [sys.executable, "-c", launcher, *command],
            start_new_session=True, **options,
        )
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        stdout, stderr = process.communicate(timeout=120)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            if process is not None:
                retire(process, children)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def git(repo, children, environment, *args):
    result = owned(
        ["git", "-C", str(repo), *args], children, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    result.check_returncode()
    return result.stdout.strip()


def archive(repo, revision, members, destination, scratch, children, environment):
    package = scratch / (destination.name + ".tar")
    with package.open("wb") as stream:
        result = owned(
            ["git", "-C", str(repo), "archive", "--format=tar", revision, *members],
            children, env=environment, stdout=stream, stderr=subprocess.PIPE,
        )
        result.check_returncode()
    destination.mkdir()
    with tarfile.open(package) as source:
        source.extractall(destination, filter="data")
    return digest(package)


def comparison(observations, fixture):
    for port in ("erlang", "elixir"):
        for key in ("valid", "invalid"):
            inputs = fixture["cases" if key == "valid" else "invalid"]
            expected = [case["name"] for case in inputs]
            if len(set(expected)) != len(expected):
                raise ValueError(f"duplicate {key} fixture case names")
            actual = [case["name"] for case in observations[port][key]]
            if actual != expected:
                raise ValueError(f"{port} {key} observations do not cover the input cases")
    native = observations["erlang"]
    companion = observations["elixir"]

    def valid(value):
        return bool(value["valid"]) and all(
            case.get("semantic_match") is True for case in value["valid"]
        )

    def invalid(value):
        return bool(value["invalid"]) and all(
            case.get("rejected") is True
            and case.get("matches_erlang_diagnostic") is True
            for case in value["invalid"]
        )

    native_ok = valid(native) and invalid(native)
    companion_ok = (
        companion["full_graph"]["accepted"] and valid(companion) and invalid(companion)
    )
    return {
        "native": "PASS" if native_ok else "FAIL",
        "interoperability": "PASS" if native_ok and companion_ok else "FAIL",
        "native_valid_cases": len(native["valid"]),
        "native_invalid_cases": len(native["invalid"]),
        "companion_admitted": sum(case["admitted"] for case in companion["valid"]),
        "companion_semantic_matches": sum(
            case.get("semantic_match", False) for case in companion["valid"]
        ),
        "companion_matching_diagnostics": sum(
            case.get("matches_erlang_diagnostic", False)
            for case in companion["invalid"]
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elixir-repo", required=True, type=Path)
    parser.add_argument("--elixir-revision", default=ELIXIR_REVISION)
    parser.add_argument("--fixture", type=Path, default=ROOT / "test/fixtures/filters-v1.json")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as failure:
        print(json.dumps({"status": "ERROR", "error": str(failure)}), file=sys.stderr)
        return 2
    receipt = {"status": "RUNNING", "commands": []}

    def save():
        (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")

    save()
    environment = dict(os.environ)
    for name in list(environment):
        if name.startswith("REBAR_"):
            environment.pop(name)
    for name in (
        "ERL_LIBS", "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ELIXIR_ERL_OPTIONS",
        "ELIXIR_CLI_OPTIONS", "TMUX", "TMUX_PANE",
    ):
        environment.pop(name, None)
    environment["ERL_FLAGS"] = "+S 4:4"

    def run(name, command, cwd):
        started = time.monotonic()
        with (output / (name + ".log")).open("w") as log:
            interrupted = False
            try:
                process = owned(
                    command, children, cwd=cwd, env=environment, stdout=log,
                    stderr=subprocess.STDOUT,
                )
                code = process.returncode
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as failure:
                interrupted = isinstance(failure, KeyboardInterrupt)
                code = 130 if interrupted else 124
        receipt["commands"].append({
            "name": name, "argv": command, "seconds": time.monotonic() - started,
            "exit_status": code,
        })
        save()
        if interrupted:
            raise KeyboardInterrupt
        if code:
            raise RuntimeError(f"{name} exited {code}; see {name}.log")

    try:
        children = prepare_owner()
        companion_repo = args.elixir_repo.resolve()
        native_revision = git(ROOT, children, environment, "rev-parse", "HEAD^{commit}")
        companion_revision = git(
            companion_repo, children, environment, "rev-parse", "--verify", "--end-of-options",
            args.elixir_revision + "^{commit}",
        )
        fixture = args.fixture.read_bytes()
        consumer = Path(__file__).with_name("consumer.exs").read_bytes()
        receipt.update({
            "native_revision": native_revision,
            "companion_repository": "libtmux/libtmux-elixir",
            "companion_revision": companion_revision,
            "fixture_sha256": hashlib.sha256(fixture).hexdigest(),
            "consumer_sha256": hashlib.sha256(consumer).hexdigest(),
            "driver_sha256": digest(Path(__file__)),
            "wire_translation": False,
        })
        (output / "filters-v1.json").write_bytes(fixture)
        (output / "consumer.exs").write_bytes(consumer)
        with tempfile.TemporaryDirectory(prefix="libtmux-filter-conformance-") as temporary:
            scratch = Path(temporary)
            native = scratch / "erlang"
            companion = scratch / "elixir"
            configuration = scratch / "rebar-config"
            configuration.mkdir()
            environment.update({
                "REBAR_GLOBAL_CONFIG_DIR": str(configuration),
                "REBAR_CACHE_DIR": str(scratch / "rebar-cache"),
                "REBAR_GLOBAL_CACHE_DIR": str(scratch / "rebar-cache"),
                "REBAR_OFFLINE": "1",
                "ERL_CRASH_DUMP": str(output / "erl_crash.dump"),
            })
            receipt["native_archive_sha256"] = archive(
                ROOT, native_revision, [".tool-versions", "rebar.config", "apps"],
                native, scratch, children, environment,
            )
            receipt["companion_archive_sha256"] = archive(
                companion_repo, companion_revision, ["lib", "priv/tmux"],
                companion, scratch, children, environment,
            )
            expected_otp = dict(
                line.split() for line in (native / ".tool-versions").read_text().splitlines()
            )["erlang"]
            run("erlang-compile", ["rebar3", "compile"], native)
            ebin = companion / "ebin"
            ebin.mkdir()
            run("elixir-compile", [
                "elixirc", "-o", str(ebin),
                *[str(path) for path in sorted((companion / "lib").rglob("*.ex"))],
            ], companion)
            run("public-consumers", [
                "elixir", "-pa", str(native / "_build/default/lib/libtmux_erlang/ebin"),
                "-pa", str(ebin), str(output / "consumer.exs"),
                str(output / "filters-v1.json"), str(output / "observations.json"),
            ], scratch)
            observations = json.loads((output / "observations.json").read_text())
            if observations["runtime"]["otp"] != expected_otp:
                raise RuntimeError("consumer runtime does not match the native OTP pin")
            for key, beam in (
                ("erlang_filter_beam", native / "_build/default/lib/libtmux_erlang/ebin/tmux_filter.beam"),
                ("elixir_filter_beam", ebin / "Elixir.LibTmux.Filter.beam"),
            ):
                runtime = observations["runtime"]
                if Path(runtime[key]).resolve() != beam.resolve() or runtime[key + "_sha256"] != digest(beam):
                    raise RuntimeError(f"{key} did not load the private build")
            receipt["runtime"] = observations["runtime"]
            receipt.update(comparison(observations, json.loads(fixture)))
            receipt["status"] = receipt["interoperability"]
        save()
        print(json.dumps({
            key: receipt[key] for key in (
                "status", "native", "interoperability", "companion_admitted",
                "companion_semantic_matches",
            )
        }))
        return 0 if receipt["status"] == "PASS" else 1
    except (Exception, KeyboardInterrupt) as failure:
        receipt.update({
            "status": "ERROR", "error_type": type(failure).__name__,
            "error": str(failure),
        })
        save()
        print(json.dumps({"status": "ERROR", "error": str(failure)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
