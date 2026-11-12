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
import tempfile
import time
import unittest


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
        ebin = str(self.root / "_build/default/lib/libtmux_erlang/ebin")
        self.command = [shutil.which("escript"),
                        str(self.project / "tools/run_examples.escript"),
                        "--ebin", ebin, "filter"]
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
