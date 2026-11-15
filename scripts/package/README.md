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
installed consumers. The two scripts below call it too.

## Tests

The EUnit modules in [tests](tests) run in the mid loop. They check the
archive bytes, members and modes, the consumer file list, the environment
scrubbing and the receipt shape without network or tmux.

```console
$ mise exec -- rebar3 eunit --module check_package_tests
```
