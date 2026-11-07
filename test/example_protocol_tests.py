#!/usr/bin/env python3
"""The terminal example must wait for a real parser acknowledgement."""

import os
from pathlib import Path
import pty
import select
import subprocess
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


if __name__ == "__main__":
    unittest.main()
