#!/usr/bin/env python3
"""The terminal example must wait for a real parser acknowledgement."""

import json
import os
from pathlib import Path
import pty
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from check_workspace_cli import retire


class WorkspaceFixtureRetirement(unittest.TestCase):
    def test_native_stop_timeout_still_retires_owned_processes(self):
        daemon = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE,
                                  stdout=subprocess.DEVNULL)
        watcher = subprocess.Popen(["/usr/bin/python3", "-c",
                                    "import sys; sys.stdin.buffer.read(1)"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        def timeout():
            raise subprocess.TimeoutExpired("owned-stop", 0.1)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                retire(daemon, watcher, timeout)
            self.assertIsNotNone(daemon.poll())
            self.assertIsNotNone(watcher.poll())
        finally:
            for process in (daemon, watcher):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=1)
                if process.stdin:
                    process.stdin.close()
                if process.stdout:
                    process.stdout.close()


class TerminalCompletion(unittest.TestCase):
    def exercise(self, response, expected_status):
        master, slave = pty.openpty()
        child = subprocess.Popen(
            ["/usr/bin/python3", str(Path(__file__).resolve().parents[1] / "examples/terminal_job.py")],
            stdin=slave, stdout=slave, stderr=subprocess.PIPE,
        )
        os.close(slave)
        try:
            output = b""
            deadline = time.monotonic() + 0.9
            while not output.endswith(b"\x1b[5n"):
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0)
                self.assertTrue(select.select([master], [], [], remaining)[0])
                output += os.read(master, 4096)
            self.assertEqual(output, b"build complete\r\n\x1b[5n")
            self.assertIsNone(child.poll(), "job completed without a terminal acknowledgement")
            if response is not None:
                os.write(master, response)
            _, error = child.communicate(timeout=1)
            self.assertEqual(child.returncode, expected_status, error)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=1)
            child.stderr.close()
            os.close(master)

    def test_parser_reply_allows_completion(self):
        self.exercise(b"\x1b[0n", 0)

    def test_unexpected_reply_fails(self):
        self.exercise(b"nope", 1)

    def test_missing_reply_fails(self):
        self.exercise(None, 1)


class InertWorkspace(unittest.TestCase):
    def test_workspace_without_tmux(self):
        escript = Path(shutil.which("escript")).resolve()
        environment = dict(os.environ)
        for name in ("LIBTMUX_TEST_TMUX", "TMUX", "TMUX_PANE"):
            environment.pop(name, None)
        with tempfile.TemporaryDirectory(prefix="ltm-no-tmux-") as directory:
            # OTP's erl launcher uses dirname to locate its installation.
            (Path(directory) / "dirname").symlink_to(shutil.which("dirname"))
            environment["PATH"] = os.pathsep.join((str(escript.parent), directory))
            self.assertIsNone(shutil.which("tmux", path=environment["PATH"]))
            result = subprocess.run(
                [str(escript), "tools/run_examples.escript", "workspace"],
                cwd=Path(__file__).resolve().parents[1], env=environment,
                capture_output=True, text=True, timeout=5,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        example, = json.loads(result.stdout)["examples"]
        self.assertEqual(example["transport"], "not_used")
        self.assertTrue(example["output"]["files_removed"])
        self.assertFalse(example["output"]["launched"])

    def test_absolute_file_without_current_directory(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="ltm-deleted-cwd-") as directory:
            source = Path(directory) / "workspace.json"
            shutil.copyfile(root / "examples/workspace.json", source)
            removed = Path(directory) / "removed"
            removed.mkdir()
            environment = dict(os.environ)
            environment.update(LTM_WORKSPACE=str(source), LTM_REMOVED=str(removed),
                               ERL_CRASH_DUMP=str(Path(directory) / "erl_crash.dump"))
            for name in ("TMUX", "TMUX_PANE"):
                environment.pop(name, None)
            expression = (
                '{ok,_}=application:ensure_all_started(crypto), '
                '{module,tmux_workspace}=code:ensure_loaded(tmux_workspace), '
                '{module,tmux_json}=code:ensure_loaded(tmux_json), '
                'Path=unicode:characters_to_binary(os:getenv("LTM_WORKSPACE")), '
                'Removed=os:getenv("LTM_REMOVED"), '
                'ok=file:set_cwd(Removed), ok=file:del_dir(Removed), '
                '{ok,W}=tmux_workspace:load(Path), '
                '#{id:=<<"demo">>}=tmux_workspace:to_map(W), '
                '{error,#{code:=file_error,reason:=enoent}}='
                'tmux_workspace:load(<<"relative.json">>), halt(0).'
            )
            paths = [str(root / "_build/default/lib" / name / "ebin") for name in
                     ("libtmux_erlang", "libtmux_erlang_workspace")]
            result = subprocess.run(
                [shutil.which("erl"), "-noshell", "-noinput", "-pa", *paths,
                 "-eval", expression], cwd=root, env=environment,
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class ExampleReceipts(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        temporary = tempfile.TemporaryDirectory(prefix="ltm-example-receipt-")
        self.addCleanup(temporary.cleanup)
        self.project = Path(temporary.name)
        for name in ("tools", "test", "examples", "_build/checks", "scratch"):
            (self.project / name).mkdir(parents=True)
        shutil.copyfile(self.root / "tools/run_examples.escript",
                        self.project / "tools/run_examples.escript")
        self.receipt = self.project / "_build/checks/examples.json"
        self.receipt.write_text(json.dumps({"result": "PASS", "old": True}))
        paths = [str(self.root / "_build/default/lib" / name / "ebin")
                 for name in ("libtmux_erlang", "libtmux_erlang_workspace")]
        self.command = [shutil.which("escript"),
                        str(self.project / "tools/run_examples.escript"),
                        "--ebin", paths[0], "--ebin", paths[1], "filter"]
        self.environment = dict(os.environ)
        self.environment["TMPDIR"] = str(self.project / "scratch")
        for name in ("LIBTMUX_TEST_TMUX", "TMUX", "TMUX_PANE"):
            self.environment.pop(name, None)

    def test_failed_run_replaces_previous_success(self):
        result = subprocess.run(self.command, cwd=self.project,
                                env=self.environment, capture_output=True,
                                text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("enoent", result.stderr)
        current = json.loads(self.receipt.read_text())
        self.assertEqual(current["result"], "FAIL", current)
        self.assertNotIn("old", current)

    def test_interrupted_run_cannot_leave_success(self):
        self.prepare_filter('io:format("ready ~s~n", [code:which(?MODULE)]), '
                            'receive stop -> #{} end')
        process = subprocess.Popen(self.command, cwd=self.project,
                                   env=self.environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 0.9)[0])
            ready = process.stdout.readline().decode().strip()
            self.assertTrue(ready.startswith("ready "), ready)
            compiled = Path(ready.removeprefix("ready "))
            self.assertEqual(compiled.name, "filter_demo.beam")
            self.assertRegex(compiled.parent.name, r"^ltm-examples-[0-9a-f]{20}$")
            self.assertEqual(compiled.parent.parent, self.project / "scratch")
            self.assertEqual(json.loads(self.receipt.read_text())["result"], "RUNNING")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=1)
            process.stdout.close()
            process.stderr.close()
        self.assertNotEqual(json.loads(self.receipt.read_text())["result"], "PASS")

    def test_unencodable_result_records_failure(self):
        self.prepare_filter("make_ref()")
        result = subprocess.run(self.command, cwd=self.project,
                                env=self.environment, capture_output=True,
                                text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.receipt.read_text())["result"], "FAIL")

    def prepare_filter(self, body):
        for name in ("tmux_test_fixture.erl", "tmux_fixture_watch.py"):
            shutil.copyfile(self.root / "test" / name, self.project / "test" / name)
        (self.project / "examples/filter_demo.erl").write_text(
            '-module(filter_demo).\n-export([run/0]).\n'
            f'run() -> {body}.\n'
        )


if __name__ == "__main__":
    unittest.main()
