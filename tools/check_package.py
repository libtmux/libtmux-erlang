#!/usr/bin/env python3
"""Check native imports from a compiled OTP archive outside the checkout."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time


def run(command: list[str], cwd: Path, env: dict[str, str], *, json_output: bool = False) -> dict:
    started = time.monotonic()
    result = subprocess.run(
        command, cwd=cwd, env=env, capture_output=True, text=True, timeout=30
    )
    receipt = {
        "program": Path(command[0]).name,
        "command": [
            item.replace(str(cwd), "<consumer>").replace(
                str(Path(__file__).resolve().parent.parent), "<repo>"
            )
            for item in command
        ],
        "exit_status": result.returncode,
        "seconds": round(time.monotonic() - started, 6),
    }
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    if json_output:
        receipt["output"] = json.loads(result.stdout)
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dialyzer", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    root = Path(__file__).resolve().parent.parent
    artifact_dir = root / "_build/package-check"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    (artifact_dir / "receipt.json").unlink(missing_ok=True)
    app = root / "_build/default/lib/libtmux_erlang"
    beams = sorted((app / "ebin").glob("*"))
    if not beams or not (app / "ebin/libtmux_erlang.app").is_file():
        raise RuntimeError("Run mise exec -- rebar3 compile first")

    archive = artifact_dir / "libtmux_erlang-otp.tar.gz"
    prefix = "libtmux_erlang-0.0.0+development"
    members = [("ebin/" + path.name, path) for path in beams if path.is_file()]
    members.append(("LICENSE", root / "apps/libtmux_erlang/LICENSE"))
    if (app / "priv").is_dir():
        members.extend(
            (path.relative_to(app).as_posix(), path)
            for path in sorted((app / "priv").rglob("*"))
            if path.is_file()
        )
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as packed:
            with tarfile.open(fileobj=packed, mode="w|") as bundle:
                for name, path in members:
                    data = path.read_bytes()
                    entry = tarfile.TarInfo(f"{prefix}/{name}")
                    entry.size = len(data)
                    entry.mode = 0o755 if os.access(path, os.X_OK) else 0o644
                    bundle.addfile(entry, io.BytesIO(data))

    commands = []
    with tempfile.TemporaryDirectory(prefix="tmux-erlang-consumer-") as directory:
        temp = Path(directory)
        with tarfile.open(archive, "r:gz") as bundle:
            bundle.extractall(temp, filter="data")
        installed_ebin = temp / prefix / "ebin"
        consumer_ebin = temp / "consumer-ebin"
        consumer_ebin.mkdir()
        shutil.copyfile(root / "examples/native_consumer.erl", temp / "native_consumer.erl")
        shutil.copyfile(root / "test/tmux_test_fixture.erl", temp / "tmux_test_fixture.erl")
        shutil.copyfile(root / "test/tmux_fixture_watch.py", consumer_ebin / "tmux_fixture_watch.py")
        for directory in (temp / "tools", temp / "test", temp / "examples"):
            directory.mkdir()
        shutil.copyfile(root / "tools/run_examples.escript", temp / "tools/run_examples.escript")
        for name in ("tmux_test_fixture.erl", "tmux_fixture_watch.py"):
            shutil.copyfile(root / "test" / name, temp / "test" / name)
        for name in ("filter_demo", "inspect_demo", "readme_demo", "linked_graph", "job_demo", "options_demo", "buffer_demo", "pane_demo", "config_demo", "pipe_demo"):
            shutil.copyfile(root / "examples" / (name + ".erl"), temp / "examples" / (name + ".erl"))
        shutil.copyfile(root / "examples/terminal_job.py", temp / "examples/terminal_job.py")
        env = dict(os.environ)
        env.pop("ERL_LIBS", None)
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        tmux = env.get("LIBTMUX_TEST_TMUX") or shutil.which("tmux")
        if not tmux or not Path(tmux).is_absolute():
            raise RuntimeError("The installed endpoint check requires an absolute tmux executable")
        env["LIBTMUX_TEST_TMUX"] = tmux
        env["ERL_CRASH_DUMP"] = str(temp / "erl_crash.dump")
        commands.append(run([
            "escript", "tools/run_examples.escript", "--ebin", str(installed_ebin)
        ], temp, env, json_output=True))
        commands.append(run([
            "erlc", "-Werror", "+debug_info", "-pa", str(installed_ebin),
            "-o", str(consumer_ebin), "native_consumer.erl", "tmux_test_fixture.erl"
        ], temp, env))
        commands.append(run([
            "erl", "-noshell", "-noinput", "-pa", str(installed_ebin),
            "-pa", str(consumer_ebin), "-eval",
            "ok = native_consumer:run(), halt(0)."
        ], temp, env))
        installed_helper = temp / prefix / "priv/tmux_owned_io"
        commands.append(run(
            [str(installed_helper), "--exec-one", "/bin/true"], temp, env
        ))
        commands.append(run([
            "erl", "-noshell", "-noinput", "-pa", str(installed_ebin), "-eval",
            '{ok, #{stdout := <<0,255,10>>, stderr := <<>>, exit_status := 0, '
            'cleanup := complete}} = tmux_transport:run(<<"/bin/cat">>, [], '
            '#{stdin => <<0,255,10>>}), '
            'ok = application:stop(libtmux_erlang), halt(0).'
        ], temp, env))
        commands.append(run([
            # OTP makes a bare top-level app path absolute; ./ retains the
            # relative priv path needed to exercise child-cwd independence.
            "erl", "-noshell", "-noinput", "-pa", "./" + str(installed_ebin.relative_to(temp)),
            "-pa", str(consumer_ebin), "-eval",
            'Executable = unicode:characters_to_binary(os:getenv("LIBTMUX_TEST_TMUX")), '
            '{ok, _} = application:ensure_all_started(libtmux_erlang), '
            '{ok, Fixture} = tmux_test_fixture:start(Executable), '
            'try #{socket := Socket} = tmux_test_fixture:info(Fixture), '
            'ok = native_consumer:run_endpoint(Socket, Executable) '
            'after ok = tmux_test_fixture:close(Fixture) end, '
            'ok = application:stop(libtmux_erlang), halt(0).'
        ], temp, env))
        if args.dialyzer:
            plts = list((root / "_build/default").glob("*_plt"))
            if len(plts) != 1:
                raise RuntimeError("Run mise exec -- rebar3 dialyzer first")
            commands.append(run([
                "dialyzer", "--plt", str(plts[0]),
                str(consumer_ebin / "native_consumer.beam"),
                str(consumer_ebin / "tmux_test_fixture.beam"),
                "-r", str(installed_ebin)
            ], temp, env))
    assert not temp.exists()
    receipt = {
        "result": "PASS",
        "scope": "Compiled OTP archive, native records, doctest, helper adapter and public borrowed endpoint",
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "commands": commands,
        "temporary_consumer_removed": True,
        "seconds": round(time.monotonic() - started, 6),
        "hex_source_package": "UNVERIFIED",
        "installed_helper_adapter": "PASS",
        "public_borrowed_endpoint": "PASS",
        "relative_code_path_child_cwd": "PASS",
        "public_domain_consumer": "PASS: create, split, bind, capture, rename, read and session cleanup",
        "public_snapshot_consumer": "PASS: captured graph, native pane lists, relationships and coverage",
        "public_filter_consumer": "PASS: local selection, graph filter, wire round trip, cardinality and prepared context",
        "public_option_consumer": "PASS: local ownership, sparse arrays and inherited restoration",
        "documentation_examples": "PASS: first program, graph, jobs, options, buffers, pane topology, configuration and pipe consumer from the installed archive",
        "public_tmux_command_api": "PARTIAL: command values, operations and initial domain facades",
        "publication": "UNVERIFIED",
    }
    (artifact_dir / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
