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


def assemble_archive(root: Path, app_name: str, artifact_dir: Path) -> tuple[Path, str]:
    app = root / "_build/default/lib" / app_name
    beams = sorted((app / "ebin").glob("*"))
    if not beams or not (app / "ebin" / (app_name + ".app")).is_file():
        raise RuntimeError("Run mise exec -- rebar3 compile first")
    archive = artifact_dir / (app_name + "-otp.tar.gz")
    prefix = app_name + "-0.0.0+development"
    members = [("ebin/" + path.name, path) for path in beams if path.is_file()]
    for name in ("LICENSE", "CHANGELOG.md"):
        members.append((name, root / "apps" / app_name / name))
    if (app / "priv").is_dir():
        members.extend((path.relative_to(app).as_posix(), path)
                       for path in sorted((app / "priv").rglob("*")) if path.is_file())
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as packed:
            with tarfile.open(fileobj=packed, mode="w|") as bundle:
                for name, path in members:
                    data = path.read_bytes()
                    entry = tarfile.TarInfo(f"{prefix}/{name}")
                    entry.size = len(data)
                    entry.mode = 0o755 if os.access(path, os.X_OK) else 0o644
                    bundle.addfile(entry, io.BytesIO(data))
    return archive, prefix


def exercise_consumer(root: Path, temp: Path, installed_ebin: Path,
                      *, dialyzer: bool = False) -> list[dict]:
    """Run the same installed public consumers for binary and source artifacts."""
    commands = []
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
    for name in ("filter_demo", "inspect_demo", "readme_demo", "linked_graph", "job_demo", "options_demo", "buffer_demo", "pane_demo", "config_demo", "pipe_demo", "hook_demo", "key_demo", "command_demo", "control_demo", "plan_demo", "batch_demo"):
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
    # A separate VM retains a native value whose captured definition lacks
    # the new field. Changing only model_version on a new row misses this.
    legacy = temp / "legacy"
    legacy.mkdir()
    (legacy / "tmux_model.erl").write_text(
        '-module(tmux_model).\n-export([old_pane/0]).\n'
        '-export_record([pane]).\n'
        '-record #pane{id, origin = none, snapshot_id = none, model_version = 1}.\n'
        'old_pane() -> #pane{id = <<"%1">>}.\n'
    )
    commands.append(run([
        "erl", "-noshell", "-noinput", "-pa", str(installed_ebin), "-eval",
        '{tmux_model, Current, Name} = code:get_object_code(tmux_model), '
        '{ok, tmux_model, Legacy} = compile:file("legacy/tmux_model.erl", [binary]), '
        '{module, tmux_model} = code:load_binary(tmux_model, "legacy", Legacy), '
        'Old = tmux_model:old_pane(), Table = ets:new(retained_rows, []), '
        'true = ets:insert(Table, {pane, Old}), '
        '{module, tmux_model} = code:load_binary(tmux_model, Name, Current), '
        '{error, #{code := invalid_row}} = tmux_model:validate(Old), '
        '[{pane, Retained}] = ets:lookup(Table, pane), '
        '{error, #{code := invalid_row}} = tmux_model:validate(Retained), '
        '{ok, Fresh} = tmux_model:pane(#{id => <<"%1">>}), '
        '2 = tmux_model:model_version(Fresh), '
        '{ok, Fresh} = tmux_model:validate(Fresh), '
        'true = ets:delete(Table), halt(0).'
    ], temp, env))
    installed_helper = installed_ebin.parent / "priv/tmux_owned_io"
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
    if dialyzer:
        plts = list((root / "_build/default").glob("*_plt"))
        if len(plts) != 1:
            raise RuntimeError("Run mise exec -- rebar3 dialyzer first")
        commands.append(run([
            "dialyzer", "--plt", str(plts[0]),
            str(consumer_ebin / "native_consumer.beam"),
            str(consumer_ebin / "tmux_test_fixture.beam"),
            "-r", str(installed_ebin)
        ], temp, env))
        type_sources = temp / "type-consumer"
        type_sources.mkdir()
        for name in ("model_types_ok.erl", "model_types_bad.erl"):
            shutil.copyfile(root / "test/consumers" / name, type_sources / name)
        shutil.copyfile(root / "tools/check_model_types.escript",
                        temp / "tools/check_model_types.escript")
        commands.append(run([
            "escript", "tools/check_model_types.escript", str(installed_ebin),
            str(plts[0]), str(type_sources)
        ], temp, env, json_output=True))
    return commands


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dialyzer", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    root = Path(__file__).resolve().parent.parent
    artifact_dir = root / "_build/package-check"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    (artifact_dir / "receipt.json").unlink(missing_ok=True)
    archive, prefix = assemble_archive(root, "libtmux_erlang", artifact_dir)

    commands = []
    with tempfile.TemporaryDirectory(prefix="tmux-erlang-consumer-") as directory:
        temp = Path(directory)
        with tarfile.open(archive, "r:gz") as bundle:
            bundle.extractall(temp, filter="data")
        installed_ebin = temp / prefix / "ebin"
        commands.extend(exercise_consumer(root, temp, installed_ebin,
                                          dialyzer=args.dialyzer))
    assert not temp.exists()
    receipt = {
        "result": "PASS",
        "scope": "Compiled OTP archive, native records, doctest, helper adapter, owned startup and borrowed endpoint",
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "commands": commands,
        "temporary_consumer_removed": True,
        "seconds": round(time.monotonic() - started, 6),
        "hex_source_package": "UNVERIFIED",
        "installed_helper_adapter": "PASS",
        "public_borrowed_endpoint": "PASS",
        "public_owned_endpoint": "PASS: installed README uses private startup, graph operations and token-based retirement",
        "public_command_builders": "PASS: installed commands example builds captured targets, rejects foreign origins and executes through one-shot operations",
        "public_control_attachment": "PASS: installed control example verifies same-connection identity, attachment counts, unchanged dimensions and native detachment",
        "relative_code_path_child_cwd": "PASS",
        "public_domain_consumer": "PASS: session lifecycle, pane topology, literal names, window/pane deletion and session cleanup",
        "retained_native_model": "PASS: old native shape in process and ETS is rejected after loading model version 2; fresh rows validate",
        "public_input_consumer": "PASS: text/native key delivery and normal job exit after EOF",
        "public_hook_consumer": "PASS: sparse registration, manual execution, empty override and local removal",
        "public_layout_consumer": "PASS: restore native serialized layouts after changing arrangement; require JSON v2 on tmux 3.8+",
        "public_snapshot_consumer": "PASS: captured graph, native pane lists, relationships and coverage",
        "public_filter_consumer": "PASS: local selection, graph filter, wire round trip, cardinality and prepared context",
        "public_option_consumer": "PASS: local ownership, sparse arrays and inherited restoration",
        "documentation_examples": "PASS: first program, graph, jobs, options, buffers, pane topology, configuration, pipe consumer, hooks, keys and command builders from the installed archive",
        "public_tmux_command_api": "PARTIAL: command values, operations and initial domain facades",
        "publication": "UNVERIFIED",
    }
    (artifact_dir / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
