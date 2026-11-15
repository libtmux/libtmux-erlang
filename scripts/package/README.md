# package

Scripts that qualify `libtmux_erlang` as an installed package. Each one
installs the library outside the checkout and runs the public consumers
against the installed copy, so a file that only exists in the checkout fails
the check.

Run them from the repository root after `rebar3 compile`. Set
`LIBTMUX_TEST_TMUX` to an absolute tmux path to choose the release under test;
otherwise `tmux` on `PATH` is used. The checks clear `TMUX`, `TMUX_PANE` and
`ERL_LIBS` for every child, and run each child command with a 30 second
deadline.

## check_package

Assembles the compiled OTP archive from `_build/default/lib/libtmux_erlang`,
unpacks it into a private directory and runs the installed consumers there:
the example programs against the installed `ebin`, the native consumer, the
retained-model check, the packaged helper, the transport, a relative code path
whose child working directory differs, and a borrowed tmux endpoint.

Developers run it before a change, and the outer check runs it. It writes
`_build/package-check/receipt.json` and the archive beside it.

```console
$ mise exec -- escript scripts/package/check_package.erl
```

`--dialyzer` adds two checks: the consumer modules against the project's
Dialyzer table, and the constructor-type consumer, which must produce exactly
four Dialyzer diagnostics for its deliberate misuses. Run
`rebar3 dialyzer` first so the table exists.

```console
$ mise exec -- escript scripts/package/check_package.erl --dialyzer
```

`check_package:exercise_consumer/4` is the one function that runs the
installed consumers. The scripts below call it too.

## check_source_package

Builds the Hex source artifact for `libtmux_erlang` and installs it the way a
user would, without publishing anything. It serves the artifact from a private,
signed registry on a loopback socket, builds a consumer whose only dependency
is the core, proves that a missing C compiler fails before the helper is
installed, and runs the same installed consumers as `check_package`.

Two commands run it. CI runs both on every matrix cell, and the release
workflow reads the receipt's `result`, `source.head`, `source.status` and
`packages.libtmux_erlang.sha256` to bind the published tarball to a passing
run. `--prepare` downloads the pinned `rebar3_hex`, `hex_core` and `verl`
archives from `tools/package-tool.json`, checks their digests and compiles
`hex_core` under `_build/source-package-tools`. It needs the network and runs
once, outside any timed check.

```console
$ mise exec -- escript scripts/package/check_source_package.erl --prepare
```

The run itself needs no network. The registry is a small `gen_tcp` file server
that adds an `ETag` header, records every request path, answers `429` after 256
requests and shuts down before the script exits. `tools/source_package_registry.escript`
signs the registry files.

```console
$ mise exec -- escript scripts/package/check_source_package.erl
```

The receipt is `_build/source-package-check/receipt.json`. Each run also keeps
its logs, the Hex tarball and the consumer's `rebar.lock` in
`_build/source-package-check/run-<time>/`. The receipt records `registry_retired`,
which is `true` only when the listening socket and every registry process are gone.

## Tests

The EUnit modules in [tests](tests) run in the mid loop. They check the
archive bytes, members and modes, the consumer file list, the environment
scrubbing and the receipt shape without network or tmux.

```console
$ mise exec -- rebar3 eunit --module check_package_tests
```
