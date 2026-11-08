# Contributing

This repository uses a Rebar umbrella with core and workspace OTP applications
under apps/. Workspace code depends on the core's public API. The
[project policy](../docs/project-policy.md) defines these package boundaries,
OTP runtime dependencies and the explicit MCP exclusion.
Current checks cover models, the helper adapter, owned fixtures, borrowed
endpoints, operation ownership, initial domain commands, captured graphs,
local filtering, bounded JSON, source-query planning and package structure.
Full command, consumer and CI qualification remains in the epic.

[AGENTS.md](../AGENTS.md) governs scope and change discipline.
[WRITING.md](WRITING.md) governs prose and commit messages.

## Setup

Use mise to install the exact development versions in
[.tool-versions](../.tool-versions). Initial development targets only the
latest stable Erlang/OTP release. Check the
[official downloads](https://www.erlang.org/downloads) when updating OTP,
then update the exact pin. Older OTP compatibility is outside the current
scope. Install tools before timing checks:

```console
$ mise install
```

Check the selected versions:

```console
$ mise current
```

Verify that the pinned build tool runs on the selected Erlang runtime:

```console
$ mise exec -- rebar3 version
```

The pure model checks do not start tmux. Live integration checks must use
owned sockets and prove cleanup. Selecting a toolchain does not establish
runtime compatibility.

## Current checks

Run a focused EUnit module after changing its critical behavior:

```console
$ time python3 tools/check.py inner \
    --module tmux_model_tests
```

Run the unit, generated-source and tracked whitespace checks:

```console
$ time python3 tools/check.py mid
```

The mid loop also checks public EEP-48 documentation/spec coverage, generated
field references, guide links and exact example excerpts. Write contracts in
`-moduledoc` and `-doc`; follow the native
[interlinking rules](WRITING.md#interlinking) for modules, functions, types and
callbacks. Use `ct_doctest` shell transcripts for
native code blocks. Prose-only contracts need no artificial example; every
advertised Erlang block must execute without skips.

[Building the API browser](../docs/api.md) explains the pinned ExDoc tool,
captured source links and working-tree provenance. The HTML build treats
warnings and broken local links/anchors as failures. Add complete runnable
programs under examples/ and drift-checked excerpts to their reader guides.

Run compilation, native helper qualification, Dialyzer, real subprocess/tmux
integration, executable docs and the external OTP archive consumer:

```console
$ time python3 tools/check.py outer
```

These commands retain command output and timing under _build/checks/.
The Python runner needs Python 3.12 or newer from the development host.
It times each complete child command, including mise and VM startup; the
shell time command measures the complete loop invocation.
The runner defaults to four Erlang schedulers to bound its share of a busy
development host. An explicit ERL_FLAGS overrides that test profile; receipts
record the selected flags. This does not configure the installed application.

[Portable filter fixtures](../test/fixtures/README.md) define shared graph,
result and validation cases. EUnit consumes them and checks composed wire
round trips. Other-port conformance remains a separate qualification gate.

The restricted ASCII regex dialect has a separate
[reference-engine check](../tools/regex-conformance/README.md). Node and Rust
are test-only tools; the core remains OTP-only. The mid loop checks fixture
drift, while CI runs matching against PCRE2, JavaScript and Rust regex.

[CI source builds](../tools/ci/README.md) explains the pinned tmux matrix,
cache validation and separate PropEr profile. CI uses setup-beam's installed
tools directly; the local runner uses mise.

Edit schema/entities.json, then regenerate the native records and registry:

```console
$ mise exec -- escript tools/generate_schema.escript
```

The generator uses OTP JSON. Generated files are checked in so package
consumers do not need the generator. Do not hand-edit generated Erlang.

The option catalogue uses the same pinned tmux source commits as CI. After
changing those pins, refresh it from a local tmux Git clone:

```console
$ python3 tools/generate_options.py \
    --refresh-from /path/to/tmux
```

This maintainer operation needs a C preprocessor to expand hook macros. The
mid loop only checks the committed JSON against generated Erlang/reference
files; consumers need neither the tmux checkout nor this generator.

The native command catalogue records parser declarations and selected feature
minimums from those same pins. Refresh its data and reference together:

```console
$ python3 tools/generate_commands.py \
    --refresh-from /path/to/tmux
```

The mid loop checks source-pin identity and generated drift without reading a
tmux checkout. Native command discovery does not establish facade coverage,
complete argument validation or runtime qualification.

The core application builds its Linux helper with make and a C11 compiler.
The pinned source and its license live under apps/libtmux_erlang/c_src/.
The helper checks use events and PID descriptors to verify owned retirement;
the Erlang adapter checks require retirement proof and actual helper exit.
Output limits reserve one additional byte per stream to distinguish EOF from
overflow. Completed results release the accumulator's chunk references.

With Clang 18 and its sanitizer runtime installed, run the additional native
outer check:

```console
$ time python3 tools/check_helper_native.py
```

This compiles the helper with AddressSanitizer and UndefinedBehaviorSanitizer
and runs its existing lifecycle/protocol suite. A separate libFuzzer harness
executes 10,000 parser inputs with fragmented reads, partial frames and EOF.
Its fork stub prevents fuzz bytes from executing a child; the protocol suite
exercises real owned children. The check records compiler/source identities,
seed, whole-command times and logs under _build/checks/helper-native/. A crash
input is retained there. CI runs this check on Linux x86_64 and arm64.
This bounded corpus is regression evidence, not exhaustive protocol proof.

Common Test selects tmux from LIBTMUX_TEST_TMUX, or PATH when unset. Set that
variable to an absolute executable path to qualify a particular release.
The fixture owns a foreground server on a private socket. A test-only Linux
inotify watcher waits for its post-listen permission event; startup never
polls a borrowed server. The watcher uses the host's /usr/bin/python3.
Passing this local suite does not establish the complete CI version matrix.

Dialyzer includes Common Test in its analysis table because the external
consumer executes ct_doctest. Its first run builds the table; retain that
setup time when reporting the outer check.

Validate the repository settings after editing them:

```console
$ time jq empty .github/repository.json
```

Before handoff, check changed files for whitespace errors:

```console
$ time git diff --check
```

Check staged files before committing:

```console
$ time git diff --cached --check
```

Git does not include untracked files in those checks; inspect newly created
files before staging them. Verify relative Markdown links, the
`CLAUDE.md -> AGENTS.md` symlink, and the settings on both GitHub repositories.
Compiler warnings are errors. Native formatter qualification, source package
assembly and the full real-tmux matrix remain explicit implementation gates.

## Check budgets

Time the entire command, including startup and setup. Add tests only for
critical behavior once implementation begins.

| Loop | Budget | Library target | Scope |
| --- | --- | --- | --- |
| Inner | Under 5s | Under 2s | Changed critical behavior or metadata |
| Mid | Under 30s | Under 10s | Unit, lint, and generated-file checks |
| Outer | Under 5 min | Under 60s | Builds, types, integration, and matrices |

The inner and mid loops must not install tools, use the network, build for
production, launch browsers, sleep, or scan broad corpora. Use events or
subscriptions instead of arbitrary waits. Investigate timeouts and waits
over one second as structural defects. Tag slow tests with a one-line reason
and run them in the outer loop. Fix a loop that exceeds its budget before
adding tests; do not raise the budget. Benchmarks are separate: each run
stays under 10 minutes and the full sweep under one hour.

## Review

Keep changes focused. Follow native Erlang conventions and preserve existing
work. A review description explains the resulting behavior and reports
relevant checks, whole-command durations, failures, and skipped checks.
Implementation, release, and compatibility claims need their own evidence.

Real-tmux checks follow the ownership rules in [AGENTS.md](../AGENTS.md).
Package, CI, documentation export and release claims require their respective
epic gates; current local checks do not pass unimplemented surfaces.
