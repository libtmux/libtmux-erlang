"""Linux helper qualification: byte credits, writes and owned retirement."""

from __future__ import annotations

import errno
import fcntl
import os
from pathlib import Path
import selectors
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(os.environ.get("LIBTMUX_TEST_HELPER",
                            ROOT / "apps/libtmux_erlang/priv/tmux_owned_io"))


def string(value: bytes) -> bytes:
    return struct.pack(">H", len(value)) + value


class Helper:
    def __init__(self, executable=HELPER):
        self.executable = executable

    def __enter__(self):
        env = {key: value for key, value in os.environ.items()
               if key not in {"TMUX", "TMUX_PANE"}}
        self.process = subprocess.Popen(
            [str(self.executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.pidfds = []
        self.terminal = None
        return self

    def __exit__(self, _kind, _value, _traceback):
        try:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                status = self.process.wait(timeout=0.9)
            except subprocess.TimeoutExpired:
                for fd in self.pidfds:
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                self.process.kill()
                self.process.wait(timeout=0.9)
                raise AssertionError("helper did not retire after parent EOF")
            if status != 0:
                raise AssertionError(f"helper exited with status {status}")
            with selectors.DefaultSelector() as retired:
                for fd in self.pidfds:
                    retired.register(fd, selectors.EVENT_READ)
                deadline = time.monotonic() + 0.9
                while retired.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise AssertionError("owned child outlived retired helper")
                    for key, _ in retired.select(remaining):
                        retired.unregister(key.fd)
            assert self.process.stderr.read() == b""
        finally:
            self.selector.close()
            for fd in self.pidfds:
                os.close(fd)
            self.process.stdout.close()
            self.process.stderr.close()

    def track(self, pid: int) -> None:
        def identity(candidate):
            try:
                text = Path(f"/proc/{candidate}/stat").read_text()
            except (FileNotFoundError, ProcessLookupError):
                return None
            fields = text[text.rfind(")") + 2:].split()
            return int(fields[1]), fields[19]

        before = identity(pid)
        if before is None:
            return
        ancestor = before[0]
        while ancestor != self.process.pid:
            parent = identity(ancestor)
            if parent is None:
                return
            assert ancestor > 1, "reported process is outside the owned helper tree"
            ancestor = parent[0]
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            return
        if identity(pid) == before:
            self.pidfds.append(fd)
        else:
            os.close(fd)

    def send(self, payload: bytes) -> None:
        self.process.stdin.write(struct.pack(">H", len(payload)) + payload)
        self.process.stdin.flush()

    def receive(self) -> bytes:
        deadline = time.monotonic() + 0.9
        while True:
            if len(self.buffer) >= 2:
                size = struct.unpack(">H", self.buffer[:2])[0]
                assert 0 < size <= 8194, f"invalid output frame size: {size}"
                if len(self.buffer) >= size + 2:
                    packet = bytes(self.buffer[2:size + 2])
                    del self.buffer[:size + 2]
                    return packet
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError("helper event deadline exceeded")
            chunk = os.read(self.process.stdout.fileno(), 16384)
            assert chunk, "helper exited before its terminal proof"
            self.buffer.extend(chunk)

    def configure(self, args: list[bytes], *, timeout: int = 0) -> bytes:
        self.send(
            b"O\x04\x01" + struct.pack(">I", timeout) + string(os.fsencode(os.getcwd()))
            + struct.pack(">H", len(args)) + b"".join(string(arg) for arg in args)
            + struct.pack(">H", 0)
        )
        packet = self.receive()
        if packet[:1] == b"S":
            self.track(struct.unpack(">I", packet[1:])[0])
        return packet

    def python(self, body: str, *, timeout: int = 0) -> int:
        packet = self.configure([os.fsencode(sys.executable), b"-c", body.encode()],
                                timeout=timeout)
        assert packet[:1] == b"S", packet
        return struct.unpack(">I", packet[1:])[0]

    def credit(self, stream: int, count: int = 8192) -> None:
        self.send(b"R" + bytes([stream]) + struct.pack(">H", count))

    def acknowledge(self, terminal: bytes) -> None:
        assert terminal[:1] in {b"E", b"F"}, terminal
        assert terminal[:2] != b"F\x04", "cleanup incomplete"
        self.terminal = terminal
        self.send(b"T")
        assert self.process.wait(timeout=0.9) == 0

    def stop(self) -> tuple[list[bytes], bytes]:
        self.send(b"Q")
        packets = []
        while True:
            packet = self.receive()
            if packet[:1] in {b"E", b"F"}:
                self.acknowledge(packet)
                return packets, packet
            packets.append(packet)


class TrackingTests(unittest.TestCase):
    def test_child_disappearing_during_stat_read_needs_no_pidfd(self):
        for error in [FileNotFoundError(errno.ENOENT, "gone"),
                      ProcessLookupError(errno.ESRCH, "gone")]:
            with self.subTest(error=type(error).__name__):
                helper = Helper()
                helper.pidfds = []
                with patch.object(Path, "read_text", side_effect=error):
                    helper.track(42)
                self.assertEqual([], helper.pidfds)
        with patch.object(Path, "read_text", side_effect=PermissionError(errno.EACCES, "denied")):
            with self.assertRaises(PermissionError):
                helper.track(42)


def build_missing_children_helper(root: Path) -> Path:
    """Build a test-only helper that refuses proc children and traps any fork."""
    shim = root / "missing_children.c"
    shim.write_text(r'''
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
FILE *__real_fopen(const char *, const char *);
FILE *__wrap_fopen(const char *path, const char *mode) {
    char children[80];
    snprintf(children, sizeof children, "/proc/self/task/%ld/children", (long)getpid());
    if (strcmp(path, children) == 0) { errno = ENOENT; return NULL; }
    return __real_fopen(path, mode);
}
pid_t __wrap_fork(void) { _exit(99); }
''')
    executable = root / "tmux_owned_io"
    subprocess.run([
        os.environ.get("LIBTMUX_TEST_CC", "cc"),
        *shlex.split(os.environ.get("LIBTMUX_TEST_CFLAGS", "")),
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic",
        str(ROOT / "apps/libtmux_erlang/c_src/owned_io.c"), str(shim),
        "-Wl,--wrap=fopen", "-Wl,--wrap=fork", "-o", str(executable)
    ], check=True, capture_output=True)
    return executable


class ProtocolTests(unittest.TestCase):
    def test_missing_children_interface_rejects_before_fork(self):
        # Link-time injection leaves the host procfs and packaged helper intact.
        with tempfile.TemporaryDirectory(prefix="tmux-erlang-capability-") as directory:
            executable = build_missing_children_helper(Path(directory))
            with Helper(executable) as helper:
                terminal = helper.configure([b"/bin/true"])
                self.assertEqual(terminal, b"F\x05" + struct.pack(">I", errno.ENOENT))
                helper.acknowledge(terminal)

    def test_independent_credits_and_protocol_like_output(self):
        payload = b"\x00\x06E\x00\x00\x00\x00\x00%end\n"
        with Helper() as helper:
            helper.python(
                f"import os,signal;os.write(1,{payload!r});"
                "os.write(2,b'ready');signal.pause()"
            )
            helper.credit(2, 5)
            self.assertEqual(helper.receive(), b"D\x02ready")
            self.assertFalse(helper.buffer)
            self.assertFalse(helper.selector.select(0))
            received = bytearray()
            while len(received) < len(payload):
                helper.credit(1, 3)
                packet = helper.receive()
                self.assertEqual(packet[:2], b"D\x01")
                self.assertLessEqual(len(packet) - 2, 3)
                received.extend(packet[2:])
            self.assertEqual(received, payload)
            _, terminal = helper.stop()
            self.assertEqual(terminal[:2], b"E\x01")

    def test_stdout_stderr_and_exit_status(self):
        with Helper() as helper:
            ready = helper.configure([
                b"/bin/sh", b"-c", b"printf output; printf diagnostic >&2; exit 7"
            ])
            self.assertEqual(ready[:1], b"S")
            helper.credit(1)
            helper.credit(2)
            streams = {1: bytearray(), 2: bytearray()}
            closed = set()
            while True:
                packet = helper.receive()
                if packet[:1] == b"D":
                    streams[packet[1]].extend(packet[2:])
                    helper.credit(packet[1])
                elif packet[:1] == b"Z":
                    closed.add(packet[1])
                else:
                    self.assertEqual(packet, b"E\x00" + struct.pack(">I", 7))
                    helper.acknowledge(packet)
                    break
            self.assertEqual(streams, {1: b"output", 2: b"diagnostic"})
            self.assertEqual(closed, {1, 2})

    def test_partial_write_is_accounted_before_stop(self):
        with Helper() as helper:
            pid = helper.python("import signal;signal.pause()")
            reader = os.open(f"/proc/{pid}/fd/0", os.O_RDONLY | os.O_NONBLOCK)
            try:
                self.assertEqual(fcntl.fcntl(reader, fcntl.F_SETPIPE_SZ, 4096), 4096)
                helper.send(b"W" + struct.pack(">I", 41) + b"x" * 8192)
                with selectors.DefaultSelector() as written:
                    written.register(reader, selectors.EVENT_READ)
                    self.assertTrue(written.select(0.9))
                packets, terminal = helper.stop()
                self.assertIn(b"A" + struct.pack(">IHB", 41, 4096, 1), packets)
                self.assertEqual(terminal[:2], b"E\x01")
            finally:
                os.close(reader)

    def test_reaps_a_descendant_that_leaves_the_process_group(self):
        with Helper() as helper:
            helper.python(
                "import os,signal\n"
                "if os.fork()==0:\n"
                " os.setsid();os.write(1,str(os.getpid()).encode()+b'\\n')\n"
                "signal.pause()"
            )
            helper.credit(1)
            packet = helper.receive()
            self.assertEqual(packet[:2], b"D\x01")
            helper.track(int(packet[2:]))
            _, terminal = helper.stop()
            self.assertEqual(terminal[:2], b"E\x01")

    def test_parent_eof_retires_its_child(self):
        with Helper() as helper:
            helper.python("import signal;signal.pause()")
            helper.process.stdin.close()
            self.assertEqual(helper.process.wait(timeout=0.9), 0)

    def test_timeout_preserves_its_reason(self):
        with Helper() as helper:
            helper.python("import signal;signal.pause()", timeout=40)
            terminal = helper.receive()
            self.assertEqual(terminal[:2], b"E\x02")
            helper.acknowledge(terminal)

    def test_oversized_header_retires_and_remains_acknowledgeable(self):
        with Helper() as helper:
            helper.python("import signal;signal.pause()")
            helper.process.stdin.write(struct.pack(">H", 32769))
            helper.process.stdin.flush()
            terminal = helper.receive()
            self.assertEqual(terminal[:2], b"F\x01")
            helper.acknowledge(terminal)

    def test_exec_error_is_distinct_from_child_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="tmux-erlang-missing-") as directory:
            with Helper() as helper:
                terminal = helper.configure([os.fsencode(Path(directory) / "missing")])
                self.assertEqual(terminal[:2], b"F\x02")
                helper.acknowledge(terminal)


if __name__ == "__main__":
    unittest.main(verbosity=2)
