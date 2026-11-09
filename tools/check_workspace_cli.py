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


def has_receipt(output: bytes) -> bool:
    """Find complete JSON objects even beside terminal echo or diagnostics."""
    text = output.decode(errors="replace")
    decoder = json.JSONDecoder()
    for offset, char in enumerate(text):
        if char == "{":
            try:
                value, _ = decoder.raw_decode(text, offset)
            except ValueError:
                continue
            if isinstance(value, dict):
                return True
    return False


def cli_roots(pid: int, helper: Path, tmux: str, found: dict[int, int]) -> None:
    """Pin descendants; caller owns partial handles even if capture fails."""
    def identity(candidate):
        text = Path(f"/proc/{candidate}/stat").read_text()
        fields = text[text.rfind(")") + 2:].split()
        return int(fields[1]), fields[19]

    root_fd = os.pidfd_open(pid)
    identities = {}
    pending, executables = [pid], set()

    def current(parent):
        fd = root_fd if parent == pid else found[parent]
        try:
            return identity(parent) == identities[parent] and not select.select([fd], [], [], 0)[0]
        except (FileNotFoundError, ProcessLookupError):
            return False

    try:
        identities[pid] = identity(pid)
        while pending:
            parent = pending.pop()
            if not current(parent):
                continue
            children = set()
            try:
                tasks = list(Path(f"/proc/{parent}/task").iterdir())
            except FileNotFoundError:
                continue
            for task in tasks:
                try:
                    children.update(int(p) for p in (task / "children").read_text().split())
                except FileNotFoundError:
                    pass
            if not current(parent):
                continue
            for child in children - found.keys():
                fd = None
                try:
                    before = identity(child)
                    if before[0] != parent:
                        continue
                    fd = os.pidfd_open(child)
                    executable = Path(os.readlink(f"/proc/{child}/exe"))
                    if (identity(child) != before or not current(parent)
                            or select.select([fd], [], [], 0)[0]):
                        os.close(fd)
                        continue
                except (FileNotFoundError, ProcessLookupError):
                    if fd is not None:
                        os.close(fd)
                    continue
                found[child] = fd
                identities[child] = before
                executables.add(executable)
                pending.append(child)
                if len(found) > 64:
                    raise RuntimeError("unexpectedly large CLI process tree")
        if helper not in executables or Path(tmux).resolve() not in executables:
            observed = sorted(path.name for path in executables)
            raise RuntimeError("blocked CLI helper or native client was not observed: " + str(observed))
        return
    finally:
        os.close(root_fd)


def wait_cli_roots(roots: dict[int, int]) -> None:
    pending = set(roots.values())
    deadline = time.monotonic() + 0.9
    while pending:
        ready, _, _ = select.select(list(pending), [], [], max(0, deadline-time.monotonic()))
        if not ready:
            raise RuntimeError("native helper/client outlived the CLI VM")
        pending.difference_update(ready)


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
        # Outer: interrupt a command after its mutation, before its native reply.
        server_identity = native("display-message", "-p", "#{pid}\t#{start_time}").stdout
        unmanaged = native("display-message", "-p", "-t", "unmanaged:",
                           "#{session_id}\t#{pane_id}\t#{pane_pid}").stdout
        signal_results = []
        for mode in ("sigterm", "ctrl_c", "sigkill"):
            cancel = copy.deepcopy(document)
            cancel["id"] = mode + "-tests"
            name = mode + "-project"
            cancel["sessions"][0]["name"] = name
            write(cancel)
            invoke("plan", str(source), "--output", str(plan))
            entered_channel = "cli-" + mode + "-entered"
            release_channel = "cli-" + mode + "-release"
            native("set-hook", "-g", "after-new-session",
                   f"wait-for -S {entered_channel} ; wait-for {release_channel}")
            entered = running = None
            roots, master, slave = {}, None, None
            try:
                entered = subprocess.Popen(
                    [tmux, "-N", "-S", str(socket), "wait-for", entered_channel],
                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                args = [str(cli), "apply", str(plan), "--config", str(config)]
                if mode == "ctrl_c":
                    master, slave = os.openpty()
                    # A separate exec avoids preexec_fn in the source-package
                    # checker, whose registry thread is already running.
                    terminal_exec = (
                        "import fcntl,os,sys,termios\n"
                        "fcntl.ioctl(0,termios.TIOCSCTTY,0)\n"
                        "m=termios.tcgetattr(0)\n"
                        "m[3]&=~(termios.ECHO|termios.ECHOCTL)\n"
                        "termios.tcsetattr(0,termios.TCSANOW,m)\n"
                        "os.execv(sys.argv[1],sys.argv[1:])\n")
                    running = subprocess.Popen(["/usr/bin/python3", "-c", terminal_exec, *args],
                        cwd=directory, env=env, stdin=slave, stdout=slave, stderr=slave,
                        start_new_session=True)
                    os.close(slave)
                    slave = None
                else:
                    running = subprocess.Popen(args, cwd=directory, env=env,
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if entered.wait(timeout=3) != 0 or running.poll() is not None:
                    raise RuntimeError("signal hook did not hold a live CLI")
                [runtime] = directory.glob("libtmux-workspace-*")
                helper = runtime / "libtmux_erlang/priv/tmux_owned_io"
                with zipfile.ZipFile(cli) as archive:
                    bundled = archive.read("libtmux_erlang/priv/tmux_owned_io")
                if (hashlib.sha256(helper.read_bytes()).digest() != hashlib.sha256(bundled).digest()
                        or helper.stat().st_mode & 0o777 != 0o700
                        or runtime.stat().st_mode & 0o777 != 0o700
                        or list(runtime.rglob("*.beam"))):
                    raise RuntimeError("materialized helper differs or BEAMs left the archive")
                cli_roots(running.pid, helper, tmux, roots)
                if mode == "ctrl_c":
                    if os.tcgetpgrp(master) != running.pid:
                        raise RuntimeError("CLI did not own the isolated terminal foreground")
                    os.write(master, b"\x03")
                    running.wait(timeout=3)
                    terminal = bytearray()
                    while select.select([master], [], [], 0)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError as error:
                            if error.errno != 5:
                                raise
                            break
                        if not chunk:
                            break
                        terminal.extend(chunk)
                        if len(terminal) > 65536:
                            raise RuntimeError("unexpectedly large terminal output")
                    stdout, stderr = bytes(terminal), b""
                else:
                    running.send_signal(signal.SIGTERM if mode == "sigterm" else signal.SIGKILL)
                    stdout, stderr = running.communicate(timeout=3)
                wait_cli_roots(roots)
                runtime_remains = runtime.exists()
                if mode == "sigterm":
                    response = json.loads(stdout)
                    if (running.returncode != 4 or response["error"]["code"] != "cancelled"
                            or response["error"]["operation_outcome"] != "unknown"
                            or response["error"]["cleanup"] != "complete"):
                        raise RuntimeError(f"unexpected SIGTERM receipt: {response} {stderr!r}")
                    if runtime_remains:
                        raise RuntimeError("cancelled CLI left its helper directory")
                else:
                    expected = -signal.SIGINT if mode == "ctrl_c" else -signal.SIGKILL
                    if running.returncode != expected:
                        raise RuntimeError(f"unexpected abrupt CLI exit: {running.returncode}")
                    if has_receipt(stdout):
                        raise RuntimeError("abrupt CLI emitted an unexpected JSON receipt")
                    # The VM could not run its cleanup clause. Remove only this
                    # fixture's runtime after all pinned native roots have exited.
                    if runtime_remains:
                        shutil.rmtree(runtime)
                if native("display-message", "-p", "#{pid}\t#{start_time}").stdout != server_identity:
                    raise RuntimeError("CLI signal replaced the borrowed server")
                if native("display-message", "-p", "-t", "unmanaged:",
                          "#{session_id}\t#{pane_id}\t#{pane_pid}").stdout != unmanaged:
                    raise RuntimeError("CLI signal changed the unmanaged pane")
                native("has-session", "-t", "=" + name)
                signal_results.append({"mode": mode, "exit_status": running.returncode,
                    "tracked_roots": len(roots), "native_roots_retired": True,
                    "server_and_unmanaged_pane_unchanged": True,
                    "created_session_survives": True,
                    "json_receipt": mode == "sigterm", "runtime_remained": runtime_remains})
            finally:
                try:
                    if running is not None and running.poll() is None:
                        running.kill()
                        running.wait(timeout=1)
                    if entered is not None and entered.poll() is None:
                        entered.kill()
                        entered.wait(timeout=1)
                    try:
                        wait_cli_roots(roots)
                    except RuntimeError:
                        for fd in roots.values():
                            try:
                                signal.pidfd_send_signal(fd, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        wait_cli_roots(roots)
                        raise
                finally:
                    for fd in roots.values():
                        os.close(fd)
                    for fd in (master, slave):
                        if fd is not None:
                            os.close(fd)
                    native("wait-for", "-S", release_channel)
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
                "signal_lifecycle": signal_results,
                "sigint_receipt": "ABSENT; escript disables the break handler and exits by SIGINT",
                "abrupt_runtime_cleanup": "fixture removed residual files after native retirement",
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
