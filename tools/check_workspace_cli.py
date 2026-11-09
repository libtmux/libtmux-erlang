#!/usr/bin/env python3
"""Exercise a standalone workspace escript against one owned foreground tmux."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def retire(daemon, watcher, stop) -> None:
    """Retire owned fixture processes even when the native stop attempt raises."""
    try:
        if daemon is not None and daemon.poll() is None:
            try:
                stop()
            except BaseException:
                if daemon.poll() is None:
                    daemon.kill()
                raise
            finally:
                try:
                    daemon.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=1)
    finally:
        if watcher.poll() is None:
            try:
                watcher.communicate(b"Q", timeout=1)
            finally:
                if watcher.poll() is None:
                    watcher.kill()
                    watcher.wait(timeout=1)


def exercise_cli(artifact: Path, tmux: str, directory: Path) -> dict:
    """Consume exactly this archive, with no checkout-relative runtime files."""
    started = time.monotonic()
    cli = directory / "libtmux-workspace"
    shutil.copyfile(artifact, cli)
    cli.chmod(0o700)
    with zipfile.ZipFile(cli) as archive:
        for member in ("ebin/libtmux_erlang.app", "priv/tmux_owned_io",
                       "priv/owned_io.LICENSE", "priv/owned_io.provenance.json"):
            if not archive.read("libtmux_erlang/" + member):
                raise RuntimeError("archive member is empty: " + member)
        if any(n.startswith("crypto/") for n in archive.namelist()):
            raise RuntimeError("archive must use the installed OTP crypto application")
    env = {k: v for k, v in os.environ.items()
           if k not in ("TMUX", "TMUX_PANE", "ERL_LIBS", "ERL_AFLAGS", "ERL_ZFLAGS")}
    env.update(ERL_FLAGS="+S 4:4", TMPDIR=str(directory),
               ERL_CRASH_DUMP=str(directory / "erl_crash.dump"))
    socket = directory / "s"
    watcher = subprocess.Popen(["/usr/bin/python3", str(ROOT / "test/tmux_fixture_watch.py"),
                                str(socket)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
    daemon = None
    pane_fds = []
    calls = []

    def event(expected: bytes) -> None:
        if not select.select([watcher.stdout], [], [], 1)[0]:
            raise RuntimeError("fixture readiness event timed out")
        if watcher.stdout.readline() != expected + b"\n":
            raise RuntimeError("unexpected fixture readiness event")

    def native(*args: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run([tmux, "-u", "-N", "-S", str(socket), *args],
                              env=env, capture_output=True, timeout=3, check=check)

    config = directory / "host.json"
    source = directory / "workspace.json"
    plan = directory / "plan.json"

    def invoke(*args: str, expected: int = 0) -> dict:
        before = time.monotonic()
        result = subprocess.run([str(cli), *args, "--config", str(config)],
                                cwd=directory, env=env, capture_output=True, timeout=15)
        if result.returncode != expected:
            raise RuntimeError(f"CLI exit {result.returncode}, expected {expected}: "
                               + result.stdout.decode(errors="replace")
                               + result.stderr.decode(errors="replace"))
        data = json.loads(result.stdout)
        if result.stdout.count(b"\n") != 1:
            raise RuntimeError("machine stdout must contain exactly one JSON line")
        if list(directory.glob("libtmux-workspace-*")):
            raise RuntimeError("CLI helper directory survived completion")
        calls.append({"command": args[0], "exit_status": result.returncode,
                      "seconds": time.monotonic() - before, "result": data})
        return data

    def write(document: dict) -> None:
        source.write_text(json.dumps(document))

    try:
        event(b"armed")
        daemon = subprocess.Popen([tmux, "-D", "-S", str(socket), "-f", "/dev/null"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        event(b"ready")
        if watcher.wait(timeout=1) != 0:
            raise RuntimeError("fixture watcher failed")
        host = json.loads((ROOT / "examples/workspace_host.json").read_text())
        host["endpoints"]["dev"] = {"socketPath": str(socket), "executable": tmux}
        config.write_text(json.dumps(host))
        native("new-session", "-d", "-s", "unmanaged", "/bin/cat")
        foreign = native("display-message", "-p", "-t", "unmanaged:", "#{session_id}").stdout
        document = {"version": 1, "id": "cli-tests", "endpoint": "dev", "sessions": [
            {"key": "s", "name": "project", "windows": [{"key": "w", "name": "api",
                "layout": "tiled", "panes": [{"key": f"p{i}", "cwd": str(directory),
                    "argv": ["/bin/cat"]} for i in range(3)]}]}]}
        write(document)
        result = invoke("plan", str(source), "--output", str(plan))
        if result["steps"] == 0 or plan.stat().st_mode & 0o777 != 0o600:
            raise RuntimeError("initial plan or plan mode is wrong")
        payload = json.loads(plan.read_text())
        if "argv" in plan.read_text() or '"cwd"' in plan.read_text():
            raise RuntimeError("plan leaked launch values")
        invoke("apply", str(plan))
        if invoke("plan", str(source), "--output", str(plan))["steps"] != 0:
            raise RuntimeError("second plan is not empty")
        invoke("apply", str(plan))
        native("rename-session", "-t", "project", "drifted")
        if invoke("apply", str(plan), expected=3)["error"]["completed"] != []:
            raise RuntimeError("drift dispatched a workspace mutation")
        native("rename-session", "-t", "drifted", "project")
        changed = copy.deepcopy(document)
        changed["sessions"][0]["windows"][0]["panes"][0]["argv"] = ["/bin/cat", "-u"]
        write(changed)
        if invoke("apply", str(plan), expected=3)["error"]["code"] != "desired_input_changed":
            raise RuntimeError("changed source was accepted")
        invoke("plan", str(source), "--output", str(plan))
        invoke("apply", str(plan))
        if invoke("plan", str(source), "--output", str(plan))["steps"] != 0:
            raise RuntimeError("changed launch did not settle")
        # Untagged existing names require explicit adoption; other resources survive.
        native("new-session", "-d", "-s", "adopt-me", "-n", "api", "/bin/cat")
        adopted = copy.deepcopy(document)
        adopted["id"] = "adopt-tests"
        adopted["sessions"][0]["name"] = "adopt-me"
        adopted["sessions"][0]["windows"][0]["panes"] = adopted["sessions"][0]["windows"][0]["panes"][:1]
        write(adopted)
        invoke("plan", str(source), "--output", str(plan), expected=3)
        invoke("plan", str(source), "--output", str(plan),
               "--adopt", "s", "--adopt", "w", "--adopt", "p0")
        invoke("apply", str(plan))
        if native("display-message", "-p", "-t", "unmanaged:", "#{session_id}").stdout != foreign:
            raise RuntimeError("pre-existing unmanaged session changed identity")
        native("new-session", "-d", "-s", "ambiguous", "-n", "api", "/bin/cat")
        native("new-window", "-d", "-t", "ambiguous:", "-n", "api", "/bin/cat")
        ambiguous = copy.deepcopy(adopted)
        ambiguous["id"] = "ambiguous-tests"
        ambiguous["sessions"][0]["name"] = "ambiguous"
        write(ambiguous)
        if invoke("plan", str(source), "--output", str(plan), "--adopt", "s",
                  expected=3)["error"]["reason"] != "ambiguous_match":
            raise RuntimeError("ambiguous existing windows were guessed")
        shell = copy.deepcopy(adopted)
        shell["id"] = "shell-tests"
        shell["sessions"][0]["name"] = "shell-project"
        shell_pane = shell["sessions"][0]["windows"][0]["panes"][0]
        del shell_pane["argv"]
        shell_pane["shell"] = "exec /bin/cat"
        write(shell)
        invoke("plan", str(source), "--output", str(plan), "--allow-shell", expected=2)
        host["allowShell"] = True
        config.write_text(json.dumps(host))
        invoke("plan", str(source), "--output", str(plan), expected=2)
        invoke("plan", str(source), "--output", str(plan), "--allow-shell")
        invoke("apply", str(plan))
        host["allowShell"] = False
        config.write_text(json.dumps(host))
        # A known first creation survives a later failed launch; no rollback claim.
        broken = copy.deepcopy(document)
        broken["id"] = "broken-tests"
        broken["sessions"][0]["name"] = "broken-project"
        window = copy.deepcopy(broken["sessions"][0]["windows"][0])
        window.update(key="broken-window", name="missing")
        window["panes"] = [{"key": "bad-pane", "cwd": str(directory),
                            "argv": ["/definitely-missing-workspace-executable"]}]
        broken["sessions"][0]["windows"].append(window)
        write(broken)
        invoke("plan", str(source), "--output", str(plan))
        failure = invoke("apply", str(plan), expected=4)["error"]
        if not failure["completed"] or failure["completed"][0]["number"] != 1:
            raise RuntimeError("failed apply lost its verified prefix")
        # Invalid schema and unknown endpoint cannot choose arbitrary sockets.
        write({**document, "endpoint": "not-configured"})
        invoke("plan", str(source), "--output", str(plan), expected=2)
        # SIGTERM arrives while a native command is held by an owned hook.
        cancel = copy.deepcopy(document)
        cancel["id"] = "cancel-tests"
        cancel["sessions"][0]["name"] = "cancel-project"
        write(cancel)
        invoke("plan", str(source), "--output", str(plan))
        native("set-hook", "-g", "after-new-session",
               "wait-for -S cli-entered ; wait-for cli-release")
        entered = subprocess.Popen([tmux, "-N", "-S", str(socket), "wait-for", "cli-entered"],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        running = subprocess.Popen([str(cli), "apply", str(plan), "--config", str(config)],
                                   cwd=directory, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            if entered.wait(timeout=3) != 0:
                raise RuntimeError("cancellation hook did not start")
            [runtime] = directory.glob("libtmux-workspace-*")
            helper = runtime / "libtmux_erlang/priv/tmux_owned_io"
            with zipfile.ZipFile(cli) as archive:
                bundled = archive.read("libtmux_erlang/priv/tmux_owned_io")
            if (hashlib.sha256(helper.read_bytes()).digest() != hashlib.sha256(bundled).digest()
                    or helper.stat().st_mode & 0o777 != 0o700
                    or runtime.stat().st_mode & 0o777 != 0o700
                    or list(runtime.rglob("*.beam"))):
                raise RuntimeError("materialized helper differs or BEAMs left the archive")
            running.send_signal(signal.SIGTERM)
            stdout, stderr = running.communicate(timeout=3)
            response = json.loads(stdout)
            if (running.returncode != 4 or response["error"]["code"] != "cancelled"
                    or response["error"]["operation_outcome"] != "unknown"
                    or response["error"]["cleanup"] != "complete"):
                raise RuntimeError(f"unexpected SIGTERM receipt: {response} {stderr!r}")
            if list(directory.glob("libtmux-workspace-*")):
                raise RuntimeError("cancelled CLI left its helper directory")
        finally:
            if running.poll() is None:
                running.kill()
                running.wait(timeout=1)
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=1)
            native("wait-for", "-S", "cli-release")
            native("set-hook", "-gu", "after-new-session")
        pids = native("list-panes", "-a", "-F", "#{pane_pid}").stdout.splitlines()
        pane_fds = [os.pidfd_open(int(pid)) for pid in pids]
        native("kill-server")
        if daemon.wait(timeout=1) != 0:
            raise RuntimeError("owned tmux server failed to retire")
        for fd in pane_fds:
            if not select.select([fd], [], [], 1)[0]:
                raise RuntimeError("owned pane process survived fixture cleanup")
        return {"result": "PASS", "seconds": time.monotonic() - started,
                "calls": calls, "sigterm_cancellation": "PASS",
                "sigint_receipt": "UNVERIFIED; OTP break signal has a separate path",
                "owned_server_and_panes_retired": True,
                "standalone_archive": True, "launch_fields_omitted": True}
    finally:
        for fd in pane_fds:
            os.close(fd)
        retire(daemon, watcher, lambda: native("kill-server", check=False))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--escript", type=Path,
                        default=ROOT / "_build/default/bin/libtmux-workspace")
    args = parser.parse_args()
    output = ROOT / "_build/checks/workspace-cli.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"result": "RUNNING"}) + "\n")
    started = time.monotonic()
    tmux = os.environ.get("LIBTMUX_TEST_TMUX") or shutil.which("tmux")
    try:
        with tempfile.TemporaryDirectory(prefix="ltm-cli-") as temporary:
            receipt = exercise_cli(args.escript.resolve(), str(Path(tmux).resolve()), Path(temporary))
        receipt["temporary_fixture_removed"] = not Path(temporary).exists()
    except Exception as error:
        receipt = {"result": "FAIL", "error": str(error)}
    receipt["whole_command_seconds"] = time.monotonic() - started
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: v for k, v in receipt.items() if k != "calls"}, indent=2))
    raise SystemExit(0 if receipt["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
