"""Observe tmux's post-listen socket chmod without polling or starting a server."""

import ctypes
import os
from pathlib import Path
import select
import struct
import sys
import time


def main() -> None:
    target = Path(sys.argv[1])
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_add_watch.restype = ctypes.c_int
    fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "inotify_init1")
    try:
        # tmux 3.3 and 3.8 call server_update_socket after listen succeeds.
        watch = libc.inotify_add_watch(fd, os.fsencode(target.parent), 0x4)
        if watch < 0:
            raise OSError(ctypes.get_errno(), "inotify_add_watch")
        print("armed", flush=True)
        deadline = time.monotonic() + 0.9
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("tmux socket readiness")
            ready, _, _ = select.select([fd, sys.stdin.fileno()], [], [], remaining)
            if sys.stdin.fileno() in ready:
                return
            if fd not in ready:
                raise TimeoutError("tmux socket readiness")
            data = os.read(fd, 4096)
            offset = 0
            while offset < len(data):
                _, mask, _, size = struct.unpack_from("iIII", data, offset)
                name = data[offset + 16:offset + 16 + size].rstrip(b"\0")
                offset += 16 + size
                if mask & 0x4000:
                    raise RuntimeError("inotify queue overflow")
                if mask & 0x4 and name == os.fsencode(target.name):
                    print("ready", flush=True)
                    return
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
