#!/usr/bin/env python3
"""The terminal example must wait for a real parser acknowledgement."""

import json
import os
from pathlib import Path
import pty
import select
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


if __name__ == "__main__":
    unittest.main()
