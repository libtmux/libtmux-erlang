# Support and remaining gaps

The implemented core passed the exact Linux/tmux matrix at the
[source-query commit](https://github.com/libtmux/libtmux-erlang/actions/runs/42378067926).
The [workflow](../.github/workflows/ci.yml) defines the checks for later commits.
OTP 29.1.2 is the only supported Erlang baseline;
older-OTP compatibility branches are not maintained. Native records remain an
experimental language dependency in OTP 29. Do not persist their internals or
assume compatibility with another OTP line.

| Platform | tmux releases in the required matrix |
| --- | --- |
| Ubuntu 24.04 x86_64 | 3.3, 3.3a, 3.4, 3.5a, 3.6b, 3.7c, 3.8 |
| Ubuntu 24.04 arm64 | 3.3, 3.8 |

Inspect the individual jobs at the commit you will consume. A minimum-version
check does not prove runtime support on every newer release. Tracking builds,
macOS, native Windows and psmux are not advertised as qualified platforms.

## Implemented surfaces

| Surface | Current behavior |
| --- | --- |
| Model | Exported native session/window/window-link/pane records; runtime validation |
| Capture | Immutable complete graph, coverage, ordering, conflict detection and read intervals |
| Local query | Map predicates, Boolean callbacks, quantifiers, cardinality and bounded JSON |
| Source query | Explicit plans/fetch, conservative candidates, full residuals and final limits |
| Operations | Bounded one-shot submission, waits, cancellation, transfer and cleanup |
| Domain commands | Initial create/read/rename/kill calls, explicit client/session selection, checked window memberships, pane split/break/join/move/swap/resize, pane/window respawn, window layouts, literal/key input and capture |
| Options | Explicit local/global tables, local or inherited reads, indexed writes/unsets and generated source metadata; hooks remain outside the option API |
| Buffers | Named or automatic binary load, exact show, metadata lists, delete/rename and paste; native version differences are explicit |
| Server utilities | Command values for literal source-file/stdin configuration and native wait-for signals, waits and explicit advisory locks |

The [examples](../examples) exercise the current public API. Real integration
checks use private sockets and verify owned process retirement. A captured row
can disappear before an action; stable IDs are not permission to reinterpret a
missing target positionally.

## Not yet shipped

Persistent control connections, command groups, output subscriptions/streams
and the workspace file-loader/CLI remain implementation work. The workspace
OTP application exists in the umbrella; it does not provide a usable CLI yet.

MCP packages, servers and SDK integration are excluded by
[project policy](project-policy.md).

Typed command coverage, generated capability inventory, source packaging,
public cross-port filter conformance, published native API pages, shared-site documentation and
independent implementation reviews remain open. Current test success does not
pass those unfinished surfaces. No registry or documentation publication is
claimed.

## Performance evidence

The current suite checks behavior and resource limits. It does not establish a
control/grouping/streaming comparison because those lanes are not implemented.
Any published benchmark must compare equal workloads and values, state the
source/tool/platform identities, and report errors and cleanup as well as time.
Test-loop durations are not throughput benchmarks.
