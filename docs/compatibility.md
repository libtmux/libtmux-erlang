# Support and remaining gaps

Get the released core on [Hex](https://hex.pm/packages/libtmux_erlang) and
its API documentation on [HexDocs](https://libtmux-erlang.hexdocs.pm/readme.html).

- **tmux:** Supports 3.3a through 3.8 on Linux x86_64 and arm64. The table
  below lists the routine CI tests.
- **Erlang/OTP:** 29 only. The application refuses to start on another release,
  and older-OTP branches are not maintained.
- **Native records:** experimental in OTP 29. Do not persist their internals or
  assume they carry over to another OTP line.
- **Built-in options and hooks:** each tmux release needs a catalogue entry. An
  unlisted release returns `unsupported_option_catalogue` for them.

| Platform | tmux releases in the required matrix |
| --- | --- |
| Ubuntu 24.04 x86_64 | 3.3a, 3.8 |
| Ubuntu 24.04 arm64 | 3.3a, 3.8 |

- CI uses only the latest stable Erlang/OTP and tests the oldest and newest
  tmux. 3.3a is the oldest release in this port's native qualification. The
  endpoint refuses earlier clients and daemons. Releases between the tested
  endpoints stay supported.
- Earlier intermediate-version results keep their recorded scope.
- Read the [workflow](../.github/workflows/ci.yml) jobs at the commit you will
  use. A minimum-version check does not prove support on every newer release.
- Tracking builds, macOS, native Windows and psmux are not advertised as
  supported.

## Check a feature before use

Read the endpoint's daemon version with `tmux_server:version/1`. Pass that
version to `tmux_capability:decision/2` to learn the feature's minimum and
what happens below it. For example, JSON layouts require tmux 3.8. Before
3.6, control attachment omits the option that keeps the client attached
when its session is destroyed.

The [capability manifest](../capabilities.json) lists each gate's minimum,
APIs, commands, and refusal or fallback behavior. The endpoint caches its
observed version. Commands recheck endpoint identity before dispatch.

Configured `command-alias` entries keep tmux's native behavior, including
overrides of full command names. Identity discovery and preflight use native
`list-commands`, which has no supported after-hook. Keep that exact spelling
unaliased while an endpoint is in use. The library does not audit the alias
table through `show-options`, which can run hooks. An override of a probe or
guard command can change its effects and defeats that command's checks.

## Linux process interface

- Linux must provide a readable `/proc/self/task/<pid>/children`, enabled by
  CONFIG_PROC_CHILDREN. The helper checks it before it launches a child.
- When it is missing, the call returns `unsupported_capability` with
  `capability => proc_children`, the OS `errno` and `outcome => not_started`.
- The [helper protocol](../apps/libtmux_erlang/c_src/README.md) covers cleanup
  evidence and the limits of native process ownership.

## Retained rows and upgrades

Native model version 2 adds a private captured-target association to each
observed row.

- Actions check the entity, stable ID, origin and snapshot ID. A pane
  association also keeps the observed window and index. A window-link
  association keeps its session, index and expected physical window.
- Actions reject edited target fields before dispatch. A well-formed mismatch
  returns `observation_mismatch`. Detached and malformed rows keep their
  validation errors.
- `tmux_server:bind/2` reads the requested target and returns a new actionable
  row. Ordinary record matching and detached constructors still work.
- The association holds identifiers, not the snapshot graph. It stops
  accidental retargeting through public row updates. It is not an authorization
  boundary against trusted code in the VM. The internal construction functions
  are implementation details.

Moving from model version 1:

- Discard version-1 rows and snapshots. Stop consumers that retain them, clear
  their process and ETS state, and observe the server afresh after a restart.
- There is no `appup` or `relup` conversion. Old or unknown model versions fail
  row validation. Validate a retained value before you read a field another
  model version added.
- Any exported-field addition, rename, removal or default change needs a model
  compatibility review, whatever the OTP version. Its changelog says whether
  retained values stay usable, need an explicit validated conversion, or must
  be discarded.
- Hot loading does not change fields in existing native values.

## Store model fields

Convert a row with `tmux_model:to_map/1`. Its example shows how to keep the
session ID and name with `maps:with/2`. Choose the fields your application
stores and define how it encodes binaries and absence values.

To use a stored ID as a target, construct a row and call
`tmux_server:bind/2` to obtain a fresh observation.

## Implemented surfaces

This table describes the source checkout. See the
[changelog](../CHANGELOG.md) for released APIs.

| Surface | Current behavior |
| --- | --- |
| Model | Exported native session/window/window-link/pane records; runtime validation |
| Capture | Immutable complete graph, coverage, ordering, conflict detection and read intervals |
| Local query | Map predicates, Boolean callbacks, quantifiers, cardinality and bounded JSON |
| Source query | Explicit plans/fetch, conservative candidates, full residuals and final limits |
| Operations | Bounded one-shot submission, waits, cancellation, transfer and cleanup |
| Managed programs | Private PTY, literal arguments and input, bounded final screen and verified retirement on tmux 3.8 |
| [Pane exit](jobs.md) | Exit status or signal. Waits can time out on unpatched tmux builds before 3.6 linked with `libutempter`, including Ubuntu `3.4-1ubuntu0.2`. [Fixed upstream in tmux 3.6](https://github.com/tmux/tmux/commit/fa5f3cef3d651b0eb9abfa77fc37ccade81679b5). |
| Pane text | Bounded current-screen waits on live owned or borrowed panes, with explicit cancellation and process checks |
| Control attachment | Explicit session, same-connection identity, no-output/ignore-size, skipped environment update and separate native cleanup |
| [Control groups](control.md#submit-a-read-group) | Bounded ID reads, session rename and window or pane resize on an owned attachment, with ordered replies and cancellation |
| [Pane stream](control.md#read-pane-output) | Live pane bytes and native notifications on owned or borrowed sessions, with credit, acknowledgements and terminal gaps |
| Daemon ownership | Empty private startup, separate ownership token, caller lifetime, explicit stop and identity-checked namespace cleanup |
| Borrowed daemon shutdown | Explicit `tmux_server:kill/1` with process preflight and a native daemon PID guard |
| Domain commands | Initial create/read/rename/kill calls, explicit client/session selection, checked window memberships, pane split/break/join/move/swap/resize, pane/window respawn, window layouts, literal/key input and capture |
| Options | Explicit local/global tables, local or inherited reads, indexed writes/unsets and generated source metadata; hooks remain outside the option API |
| Hooks | Versioned builtin arrays, indexed command values, inheritance and explicit execution contexts |
| Buffers | Named or automatic binary load, exact show, metadata lists, delete/rename and paste; native version differences are explicit |
| Server utilities | Command values for literal source-file/stdin configuration and native wait-for signals, waits and explicit advisory locks |
| Pane pipe | Literal shell command, output/input/both directions, native toggle and explicit stop; tmux-owned process and delivery checks |

- Each guide's program exercises the current public API.
- A captured row can vanish before an action. A stable ID is no permission to
  read a missing target by position.

## Not yet built

- General command execution through control mode.
- Complete performance qualification.
- Complete typed command coverage, public cross-port
  filter conformance and independent implementation reviews.

## Source installation

- The [source-package check](../scripts/package/check_source_package.erl)
  builds the core with pinned `rebar3_hex` tooling, serves the tarball through
  a signed local registry, and builds a fresh Rebar3 consumer whose only
  dependency is the core.
- The core must compile its helper from packaged C source. Missing compiler
  support fails installation.
- CI runs the check on both architectures with tmux 3.3a and 3.8. Read its
  receipt for the commit you use.
- The check does not publish to Hex or prove a release fetched from the
  registry.

## Performance

- The suite checks behavior and resource limits.
- A published benchmark must compare equal workloads and values, name the
  source, tool and platform, and report errors and cleanup as well as time.
- Test-loop durations are not throughput benchmarks.
