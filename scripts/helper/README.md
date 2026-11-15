# Native helper checks

`tests/helper_protocol_SUITE.erl` is a Common Test suite that drives the
packaged helper (`tmux_owned_io`) over its framed stdio protocol: independent
byte credits for both streams, stdout and stderr with an exit status, a
partly delivered write, a descendant that leaves the process group, retirement
when the parent closes its end, a timeout, an oversized header and an exec
error. It checks retirement from procfs once the helper has exited. A build
that hides `/proc` children is linked at run time to prove the helper refuses
to start a child it could not track.

`LIBTMUX_TEST_HELPER` selects another helper binary and `LIBTMUX_TEST_CC` and
`LIBTMUX_TEST_CFLAGS` choose the compiler for that build. `rebar3 ct` runs the
suite with the others.

`check_helper_native.erl` is the sanitizer check. It builds the helper with
AddressSanitizer and UndefinedBehaviorSanitizer, runs the suite against it,
builds `test/helper_fuzz.c` with libFuzzer and fuzzes the frame parser from a
generated seed corpus. Any sanitizer report fails the run. It writes a receipt
and logs to `_build/checks/helper-native/`; the `native-helper` job in
`.github/workflows/ci.yml` runs it and uploads them.

Compile the library, then run with Clang 18 and its sanitizer runtime
installed:

```console
$ escript scripts/helper/check_helper_native.erl
```

Run the protocol suite alone with:

```console
$ rebar3 ct --dir scripts/helper/tests --suite helper_protocol_SUITE
```

Run the script's unit tests with:

```console
$ rebar3 eunit --module=check_helper_native_tests
```
