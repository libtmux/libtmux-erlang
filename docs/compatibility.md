# Support and remaining gaps

Support covers tmux **3.3a–3.8**, including intermediate releases, on Linux
x86_64 and arm64. The [workflow](../.github/workflows/ci.yml) tests the oldest
supported and newest stable tmux releases on both architectures.
OTP 29.1.2 is the only supported Erlang baseline;
older-OTP compatibility branches are not maintained. Native records remain an
experimental language dependency in OTP 29. Do not persist their internals or
assume compatibility with another OTP line.

| Platform | tmux releases in the required matrix |
| --- | --- |
| Ubuntu 24.04 x86_64 | 3.3a, 3.8 |
| Ubuntu 24.04 arm64 | 3.3a, 3.8 |

CI uses only the latest stable Erlang/OTP release. Testing the endpoints keeps
the routine matrix small; it does not exclude releases between them from
support. Earlier intermediate-version results retain their recorded scope.

Inspect the individual jobs at the commit you will consume. A minimum-version
check does not prove runtime support on every newer release. Tracking builds,
macOS, native Windows and psmux are not advertised as qualified platforms.

Linux must provide readable `/proc/self/task/<pid>/children`, enabled by
CONFIG_PROC_CHILDREN. The helper checks this interface before launching a
child. An unavailable interface returns `unsupported_capability` with
`capability => proc_children`, the OS `errno` and `outcome => not_started`.
See the [helper protocol](../apps/libtmux_erlang/c_src/README.md) for cleanup
evidence and the limits of native process ownership.

## Retained rows and upgrades

Native model version 2 adds a private captured target association to each
observed row. Actions check the entity, stable ID, origin and snapshot ID;
pane associations also retain the observed window and index, and window-link
associations retain their session, index and expected physical window.
Actions reject edited target fields before dispatch. Valid-shaped binding
mismatches return `observation_mismatch`; detached and malformed rows retain
their validation errors. `tmux_server:bind/2` reads the requested target and returns
a new actionable row. Ordinary record matching and detached constructors
remain available.

The private value retains identifiers, not the snapshot graph. It prevents
accidental retargeting through public row updates; it is not an authorization
boundary against trusted code running inside the VM. The internal construction
functions remain implementation details.

Discard version-1 rows and snapshots when upgrading to model version 2. Stop
consumers that retain them, clear their process/ETS state and freshly observe
the server after restart. This release supplies no `appup`/`relup` conversion.
Old or unknown model versions fail row validation. New code must validate a
retained value before accessing fields added by another model version.

Every exported-field addition, rename, removal or default change requires a
model compatibility review independently of the OTP version. Its changelog
must state whether retained values remain usable, need an explicit validated
conversion, or must be discarded. Do not assume hot loading changes fields in
existing native values.

`tmux_model:to_map/1` extracts the documented domain fields from a valid row.
Validate those fields with the destination model's constructor when migrating
data. The map loses actionable provenance; bind it through a freshly
constructed row before an action. It is not a versioned storage or cross-port
wire format: absence atoms, binary bytes and field inventories still require
an application-defined schema.

## Implemented surfaces

| Surface | Current behavior |
| --- | --- |
| Model | Exported native session/window/window-link/pane records; runtime validation |
| Capture | Immutable complete graph, coverage, ordering, conflict detection and read intervals |
| Local query | Map predicates, Boolean callbacks, quantifiers, cardinality and bounded JSON |
| Source query | Explicit plans/fetch, conservative candidates, full residuals and final limits |
| Operations | Bounded one-shot submission, waits, cancellation, transfer and cleanup |
| Control attachment | Explicit session, same-connection identity, no-output/ignore-size, skipped environment update and separate native cleanup |
| Daemon ownership | Empty private startup, separate ownership token, caller lifetime, explicit stop and identity-checked namespace cleanup |
| Domain commands | Initial create/read/rename/kill calls, explicit client/session selection, checked window memberships, pane split/break/join/move/swap/resize, pane/window respawn, window layouts, literal/key input and capture |
| Options | Explicit local/global tables, local or inherited reads, indexed writes/unsets and generated source metadata; hooks remain outside the option API |
| Hooks | Versioned builtin arrays, indexed command values, inheritance and explicit execution contexts |
| Buffers | Named or automatic binary load, exact show, metadata lists, delete/rename and paste; native version differences are explicit |
| Server utilities | Command values for literal source-file/stdin configuration and native wait-for signals, waits and explicit advisory locks |
| Pane pipe | Literal shell command, output/input/both directions, native toggle and explicit stop; tmux-owned process and delivery checks |

The [examples](../examples) exercise the current public API. Real integration
checks use private sockets and verify owned process retirement. A captured row
can disappear before an action; stable IDs are not permission to reinterpret a
missing target positionally.

## Not yet shipped

Control command submission and groups and output subscriptions/streams remain
implementation work. Complete performance qualification remains open.

Typed command coverage, generated capability inventory, public cross-port
filter conformance, published native API pages, shared-site documentation and
independent implementation reviews remain open. Current test success does not
pass those unfinished surfaces. The only registry publication is the core
package on [Hex](https://hex.pm/packages/libtmux_erlang); HexDocs is not
published.

## Source installation

The [source-package check](../tools/check_source_package.py) builds the core
application with pinned `rebar3_hex` tooling. It serves the exact tarball
through a signed local registry, then creates a fresh Rebar3 consumer whose
only dependency is the core. The core must compile its helper from packaged C
source. Missing compiler support fails installation.
The installed examples, native-record imports, model-upgrade check and owned
transport checks run against that consumer.

CI runs this gate on both supported architectures with tmux 3.3a and 3.8.
Inspect its receipt for the commit being consumed. These local source artifacts
retain the development version; the check neither publishes to Hex nor proves
an independently retrieved registry release. The older compiled-archive check
remains separate evidence for its own payload.

## Performance evidence

The current suite checks behavior and resource limits. It does not establish a
control/grouping/streaming comparison because those execution lanes are not implemented.
Any published benchmark must compare equal workloads and values, state the
source/tool/platform identities, and report errors and cleanup as well as time.
Test-loop durations are not throughput benchmarks.
