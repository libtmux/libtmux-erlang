# Owned I/O helper

Rebar builds this Linux executable from source through the adjacent Makefile.
It uses libc and Linux process/pipe interfaces, including a mounted /proc and
readable `/proc/self/task/<pid>/children` (CONFIG_PROC_CHILDREN). Before forking
the child, it checks that exact interface. Missing support returns a capability
failure with the OS errno; the child has not started. The check establishes
initial availability, not immunity to later procfs changes.
It is a separate process, not a NIF or a sandbox.

The source derives from the pinned libtmux Elixir helper, with local capability
admission and protocol changes recorded in
[provenance.json](provenance.json) and the retained [MIT license](LICENSE).
Source reuse does not establish Erlang transport qualification.

The private protocol uses two-byte big-endian packet lengths. Input is capped
at 32,768 bytes. stdout and stderr have separate child pipes. Each read credit
permits one response of at most 8,192 data bytes; the output queue has eight
fixed slots. A child cannot write the helper's framing descriptor.

| Input | Payload |
|---|---|
| O | Version 4, stdin-open byte, timeout u32, cwd string, argv u16 count and strings, environment u16 count and strings |
| R | Stream byte (1 stdout, 2 stderr), credit u16 |
| W | Request ID u32 and one nonempty write of at most 8,192 bytes |
| C | Close child stdin after the acknowledged write |
| Q | Stop and retire the owned child tree |
| T | Acknowledge terminal proof; send no later input |

Strings are u16-length bytes without NUL. Argv has at most 2,048 entries and
environment at most 256. The complete initial frame must fit the input cap.

| Output | Meaning |
|---|---|
| S + pid u32 | Exec succeeded; PID is diagnostic, not a retained identity handle |
| D + stream + bytes | One credited output chunk |
| Z + stream | Credited stream EOF |
| A + request ID u32 + delivered u16 + failed byte | Pipe-write result, not command completion |
| C | Child stdin closed |
| E + reason + status u32 | Children retired; reason 0 natural, 1 stop, 2 timeout, 3 failure |
| F + kind + errno u32 | Kind 1 setup/protocol, 2 exec, 3 I/O, 4 cleanup incomplete, 5 proc children capability unavailable before fork |

E and F kinds 1–3 and 5 prove child retirement. Acknowledge them with T, then observe
the actual helper exit. F kind 4 does not prove retirement and must not be
acknowledged. Cleanup and terminal delivery each have a 750 ms allowance.
Incomplete cleanup retains the helper as reaper. A helper exit alone is not
a successful command result.

The Erlang adapter exposes kind 5 as `unsupported_capability`, with
`capability => proc_children`, `errno` and `outcome => not_started`. Cleanup is
complete only after terminal acknowledgement and actual helper exit. Version 4
requires the matching adapter; older helpers reject its initial frame before
launching a child.

Parent EOF and handled termination signals initiate cleanup. The helper
signals its process group before reaping its leader, then kills and reaps
adopted children. Helper SIGKILL and hostile indefinite forks have no
unconditional cleanup guarantee. Borrowed tmux clients require -N; starting
an owned server needs a separate lifecycle.

The private --exec-one PROGRAM mode replaces the helper with precisely one
executable argument. It exists because tmux treats a singleton command argument
as shell text. It has no framed ownership protocol; tmux owns that pane.
