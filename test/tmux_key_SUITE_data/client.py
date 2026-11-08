"""Drive one owned tmux terminal client through a binding completion signal."""

import errno
import fcntl
import json
import os
import pty
import selectors
import struct
import subprocess
import sys
import termios
import time


def own_terminal():
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())


def wait_exit(process, client, master, observed):
    """Drain terminal output while waiting for a Linux PID descriptor event."""
    deadline = time.monotonic() + 0.8
    pidfd = os.pidfd_open(process.pid)
    clientfd = None if process is client else os.pidfd_open(client.pid)
    try:
        with selectors.DefaultSelector() as events:
            events.register(pidfd, selectors.EVENT_READ, 'process')
            events.register(master, selectors.EVENT_READ, 'terminal')
            if clientfd is not None:
                events.register(clientfd, selectors.EVENT_READ, 'client')
            while process.poll() is None:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError('native terminal event did not complete')
                for key, _ in events.select(left):
                    if key.data == 'client' and client.poll() is not None:
                        raise RuntimeError('terminal client exited before its signal')
                    if key.data == 'terminal':
                        try:
                            data = os.read(master, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                events.unregister(master)
                                continue
                            if error.errno == errno.EAGAIN:
                                continue
                            raise
                        observed.extend(data)
                        if len(observed) > 1024 * 1024:
                            raise RuntimeError('terminal output limit')
                        if not data:
                            events.unregister(master)
            return process.wait()
    finally:
        os.close(pidfd)
        if clientfd is not None:
            os.close(clientfd)


def main():
    executable, socket, session, ready, done, hex_keys = sys.argv[1:]
    base = [executable, '-N', '-S', socket]
    env = {key: value for key, value in os.environ.items()
           if key not in {'TMUX', 'TMUX_PANE'}}
    env['TERM'] = 'xterm-256color'
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    terminal_name = os.ttyname(slave)
    processes = []
    observed = bytearray()
    client = None
    try:
        readiness = subprocess.Popen(base + ['wait-for', ready],
                                     stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, env=env)
        processes.append(readiness)
        client = subprocess.Popen(base + ['-u', 'attach-session', '-E', '-t', session],
                                  stdin=slave, stdout=slave, stderr=slave,
                                  start_new_session=True, preexec_fn=own_terminal,
                                  env=env)
        processes.append(client)
        os.close(slave)
        slave = None
        os.set_blocking(master, False)
        if wait_exit(readiness, client, master, observed) != 0:
            raise RuntimeError('attachment signal command failed')
        completion = subprocess.Popen(base + ['wait-for', done],
                                      stdin=subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, env=env)
        processes.append(completion)
        keys = bytes.fromhex(hex_keys)
        if not keys or len(keys) > 4096:
            raise ValueError('key input must contain 1..4096 bytes')
        count = os.write(master, keys)
        if count != len(keys):
            raise RuntimeError('partial terminal key write')
        if wait_exit(completion, client, master, observed) != 0:
            raise RuntimeError('binding completion signal failed')
        detached = subprocess.run(base + ['detach-client', '-t', terminal_name],
                                  stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=0.8, env=env)
        if detached.returncode != 0:
            raise RuntimeError('owned client detach failed')
        status = wait_exit(client, client, master, observed)
        if status != 0:
            raise RuntimeError('owned terminal client did not exit normally')
        print(json.dumps({'key_bytes': count, 'client_exit': status,
                          'binding_signal': True}))
    except Exception as error:
        print(json.dumps({'error': str(error),
                          'terminal_tail_hex': bytes(observed[-1024:]).hex()}),
              file=sys.stderr)
        raise
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)


if __name__ == '__main__':
    main()
